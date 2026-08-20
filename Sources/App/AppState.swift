import SwiftUI
import Foundation
import UIKit

/// 首页导入进度状态：nil 表示当前没有导入任务进行中。
/// 导入流程按阶段推进（解压转换 → 复制 → 解析 → 提取图标），
/// 每个阶段都会更新 phase 文字与 progress 百分比，让用户在耗时操作期间
/// 看到明确反馈（阶段内百分比由 ZIPFoundation 逐条目解压真实字节推算）。
struct ImportProgress: Equatable {
    /// 正在导入的文件名（如 xxx.ipa）
    let fileName: String
    /// 当前是第几个（从 1 开始）
    let currentIndex: Int
    /// 一共几个文件（单文件导入为 1）
    let totalCount: Int
    /// 阶段文字，如 "解压中…" / "解析中…" / "复制文件…"
    let phase: String
    /// 整体进度 0~1（各阶段加权合成：解压转换 60% / 复制 20% / 解析 10% / 图标 10%）
    let progress: Double
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var installedApps: [AppInfo] = []
    @Published var importedApps: [AppInfo] = []
    @Published var certificates: [CertificateInfo] = []
    @Published var profiles: [ProvisioningInfo] = []
    @Published var signingTasks: [SigningTask] = []

    @Published var selectedCertificate: CertificateInfo?
    @Published var selectedProfile: ProvisioningInfo?
    @Published var selectedTab: Int = 0

    /// 首页导入进度（nil = 无导入进行中）；多文件导入时随文件逐个推进
    @Published var importProgress: ImportProgress?

    private let fileManager = AppFileManager.shared
    private let store = UserDefaultsStore()
    private let parser = IPAParser()

    /// 已签名应用刷新串行队列：parseAppInfo 会解压整个 IPA（较慢），且
    /// refreshInstalledApps 可能在主线程被多次触发（签名完成 / 删除应用 / 启动），
    /// 用串行队列保证多次解析互不重叠、不阻塞主线程；@Published 赋值仍回主线程。
    private let installedAppsRefreshQueue = DispatchQueue(label: "com.ipamanager.installed-apps-refresh")

    /// 已签名列表是否正在后台扫描（UI 显示加载态，避免“已签应用”页空态闪烁）
    @Published var isRefreshingInstalledApps = false

    /// 全局轻提示（外部打开文件失败、后台操作结果等无专门 UI 的场景）；
    /// 主界面 RootView 用 overlay 展示，非 nil 时显示，自动 3 秒后清除。
    @Published var toastMessage: String?
    private var toastWorkItem: DispatchWorkItem?

    /// 在任意线程设置全局轻提示（内部切回主线程并安排自动清除；重复设置会重置计时）。
    func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.toastMessage = nil
            }
            self.toastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    /// 挂起 App 回到 iOS 桌面（主屏幕）。
    ///
    /// 民间技巧说明：iOS 没有公开 API 能直接把 App“最小化到桌面”，这里通过 selector
    /// 调用 UIApplication 的私有 suspend 动作，效果与用户按 Home 键一致——App 退到后台
    /// （回到主屏幕），进程仍保留在后台，用户点击图标可随时恢复，无数据丢失。
    /// 用 responds(to:) 守卫：个别系统版本若不支持该 selector 则静默失败，
    /// 不影响调用方在此之前已执行的动作（如关闭详情页、切换 Tab）。
    /// 注意：该技巧仅适用于本类自签名安装的侧载工具，不可用于 App Store 上架应用。
    /// 必须在主线程调用（UIApplication 操作）。
    func minimizeToHomeScreen() {
        let selector = NSSelectorFromString("suspend")
        if UIApplication.shared.responds(to: selector) {
            // perform(_:) 返回的 Unmanaged 结果无需使用，显式丢弃避免“结果未使用”警告
            _ = UIApplication.shared.perform(selector)
        }
    }

    init() {
        loadPersistedState()
        refreshInstalledApps()
        DownloadManager.shared.onDownloadComplete = { [weak self] url in
            self?.handleDownloadedFile(at: url)
        }
        Logger.info("AppState 初始化完成")
    }

    private enum DownloadedArchiveKind {
        case certificateBundle
        case appPackage
        /// zip 内嵌 .ipa（GitHub release 常见格式：zip 包着 ipa + 校验 txt）；
        /// 携带已复制到 Documents/IPA 持久位置的 .ipa 文件 URL（不会是临时目录内的路径）
        case embeddedIPA(URL)
        /// 压缩包能正常解压但既非应用包也非证书包；携带顶层内容摘要，便于定位真实结构
        case unknown(String)
    }

    func handleDownloadedFile(
        at url: URL,
        completion: ((Result<AppInfo, Error>) -> Void)? = nil
    ) {
        Logger.info("下载完成，自动解析: \(url.lastPathComponent)")
        let ext = url.pathExtension.lowercased()
        let isArchive = ext == "zip" || ext == "tgz" || ext == "tar"
            || (ext == "gz" && url.lastPathComponent.lowercased().hasSuffix(".tar.gz"))

        guard isArchive else {
            // .ipa 及其它格式：直接走原有导入逻辑
            importFile(from: url) { result in
                self.logImportResult(result, fileName: url.lastPathComponent)
                completion?(result)
            }
            return
        }

        // 压缩包：后台先判断内容（证书包 / 应用包 / 未知），避免阻塞 UI。
        // 安全作用域在后台流程入口持有、defer 在闭包内释放，覆盖 classifyArchivedContent
        // 解压扫描与 convertToIPAIfNeeded 读取外部文件的全过程（文件 App 打开的
        // in-place 安全作用域 URL 若未授权访问，解压会 EPERM）。
        let accessed = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let kind = try self.classifyArchivedContent(at: url)
                switch kind {
                case .certificateBundle:
                    // 内含 .p12/.mobileprovision → 证书包，走现有证书导入
                    DispatchQueue.main.async {
                        Logger.info("检测到证书包，走证书导入: \(url.lastPathComponent)")
                    }
                    self.importCertificateBundleOrFile(url)
                case .appPackage:
                    // 内含 .app → 应用包：解压并重新打包成 .ipa 后导入“我的应用”
                    let ipaURL = try self.parser.convertToIPAIfNeeded(fileURL: url)
                    self.importFile(from: ipaURL) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                Logger.info("自动解析成功（zip→ipa）: \(ipaURL.lastPathComponent)")
                            case .failure(let error):
                                Logger.error("自动解析失败: \(error.localizedDescription)")
                            }
                            completion?(result)
                        }
                    }
                case .embeddedIPA(let ipaURL):
                    // zip 内嵌 .ipa → 直接导入“我的应用”：
                    // 文件已复制到 .ipa 目录（url.path == destination.path），importFile 会跳过复制直接 parse
                    self.importFile(from: ipaURL) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                Logger.info("自动解析成功（zip 内嵌 ipa）: \(ipaURL.lastPathComponent)")
                            case .failure(let error):
                                Logger.error("自动解析失败: \(error.localizedDescription)")
                            }
                            completion?(result)
                        }
                    }
                case .unknown(let summary):
                    // 保留原始分类信息，并附上“压缩包内包含：…”内容摘要，方便定位真实结构
                    let message = "该 ZIP 不是应用包（未发现 .app 应用包或 .ipa 文件）也不是证书包（无 .p12/.mobileprovision）。\(summary)"
                    DispatchQueue.main.async {
                        Logger.error("自动解析失败: \(url.lastPathComponent) - \(message)")
                        completion?(.failure(AppError.operationFailed(message)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    Logger.error("自动解析失败: \(url.lastPathComponent) - \(error.localizedDescription)")
                    completion?(.failure(error))
                }
            }
        }
    }

    private func logImportResult(_ result: Result<AppInfo, Error>, fileName: String) {
        DispatchQueue.main.async {
            switch result {
            case .success:
                Logger.info("自动解析成功: \(fileName)")
            case .failure(let error):
                Logger.error("自动解析失败: \(error.localizedDescription)")
            }
        }
    }

    /// 把压缩包解压到临时目录后扫描内容，判断它属于证书包还是应用包。
    /// 不做列表 API 依赖：ZipManager 只有 unzip/zip，因此采用“解压后扫目录”方案。
    private func classifyArchivedContent(at url: URL) throws -> DownloadedArchiveKind {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DLScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try ZipManager.shared.unzip(archiveURL: url, destinationURL: tempDir)
        } catch {
            // 透传 ZipManager 的 ZipError（errorDescription 已是中文，区分“非 zip / 网页错误页 / 损坏不完整”）：
            // “该文件不是有效的 ZIP 压缩包” / “下载到的是网页而不是文件（…）” /
            // “ZIP 文件已损坏或下载不完整，请删除后重新下载”
            Logger.error("压缩包分类失败: \(url.lastPathComponent) - \(error.localizedDescription)")
            throw error
        }

        var hasCertificate = false
        var hasAppBundle = false
        // zip 内嵌的独立 .ipa 文件在 Documents/IPA 下的持久副本；nil 表示尚未发现或复制失败
        var embeddedIPAURL: URL? = nil

        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) else {
            throw AppError.operationFailed("无法读取压缩包内容: \(url.lastPathComponent)")
        }

        while let element = enumerator.nextObject() as? URL {
            let elementExt = element.pathExtension.lowercased()
            if elementExt == "app" {
                // 找到 .app 即视为应用包（无论位于 Payload/、Archive/ 还是根目录）
                hasAppBundle = true
            } else if elementExt == "p12" || elementExt == "pfx" {
                hasCertificate = true
            } else if elementExt == "mobileprovision" && !isInsideAppBundle(element) {
                // 排除 .app 内部的 embedded.mobileprovision，避免应用包被误判为证书包
                hasCertificate = true
            } else if elementExt == "ipa" && !isInsideAppBundle(element) {
                // zip 内嵌 .ipa（GitHub release 常见格式：zip 包着 ipa + 校验 txt）。
                // 临时目录会被本函数末尾的 defer 删除，因此必须立即复制到 Documents/IPA 持久位置，
                // 否则返回的 URL 会在 defer 后失效。只记录第一个成功复制的副本。
                guard embeddedIPAURL == nil else { continue }
                // 数据安全：目标同名文件已存在时追加唯一后缀，绝不覆盖可能仍被其它记录
                // 引用的旧文件（与 convertToIPAIfNeeded 的输出唯一化策略一致）。
                let ipaBase = URL(fileURLWithPath: element.lastPathComponent).deletingPathExtension().lastPathComponent
                var destURL = self.fileManager.directoryURL(.ipa)
                    .appendingPathComponent(element.lastPathComponent)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    destURL = self.fileManager.directoryURL(.ipa)
                        .appendingPathComponent("\(ipaBase)-\(UUID().uuidString.prefix(8)).ipa")
                    while FileManager.default.fileExists(atPath: destURL.path) {
                        destURL = self.fileManager.directoryURL(.ipa)
                            .appendingPathComponent("\(ipaBase)-\(UUID().uuidString.prefix(8)).ipa")
                    }
                }
                // copyItem 不返回 URL，复制成功后用目标路径构造并校验文件已存在
                if (try? self.fileManager.copyItem(from: element, to: destURL)) != nil,
                   FileManager.default.fileExists(atPath: destURL.path) {
                    embeddedIPAURL = destURL
                    Logger.info("压缩包内检测到内嵌 .ipa，已复制到: \(destURL.lastPathComponent)")
                }
                // 复制失败：绝不返回临时目录路径，跳过，最终落 .unknown
            }
        }

        if hasCertificate { return .certificateBundle }
        if hasAppBundle { return .appPackage }
        if let embeddedURL = embeddedIPAURL { return .embeddedIPA(embeddedURL) }
        // 压缩包能正常解压但内部既无 .app 也无证书结构 → 未知类型（下游会报“不是应用包也不是证书包”）
        // 附上顶层内容摘要，说明“压缩包里到底有什么”（源码包 / 空包 / 其它结构）。
        let summary = topLevelSummary(of: tempDir)
        Logger.error("压缩包分类失败: \(url.lastPathComponent) - 压缩包内未发现 .app（应用包）或 .p12/.pfx/.mobileprovision（证书包）结构。\(summary)")
        return .unknown(summary)
    }

    /// 列出解压目录顶层内容（最多 5 个 + 总数），用于错误信息中说明“压缩包里到底有什么”。
    private func topLevelSummary(of dir: URL) -> String {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return "压缩包内内容无法读取"
        }
        if items.isEmpty { return "压缩包内没有任何内容" }
        let names = items.map { $0.lastPathComponent }
        let shown = names.prefix(5).joined(separator: "、")
        return names.count > 5
            ? "压缩包内包含：\(shown) 等 \(names.count) 个条目"
            : "压缩包内包含：\(shown)"
    }

    private func isInsideAppBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasSuffix(".app") }
    }

    /// 更新导入进度（任意线程可调，内部切回主线程赋值 @Published，
    /// 避免后台队列直接修改 ObservableObject 状态导致 SwiftUI 更新异常）。
    /// progress 为整体进度 0~1；阶段内由各阶段自身推进（解压按字节、其余按权重）。
    /// 节流：主线程内同阶段 progress 变化 <1% 时跳过，避免大包解压逐条目高频
    /// 刷新主队列（数万次 async 会造成 UI 掉帧）；首次进入阶段与跨阶段必更新。
    private var lastImportProgressKey: String = ""
    private var lastImportProgressValue: Double = -1
    func updateImportProgress(
        fileName: String,
        index: Int,
        total: Int,
        phase: String,
        progress: Double = 0
    ) {
        DispatchQueue.main.async {
            let key = "\(index)-\(total)-\(phase)"
            let shouldThrottle = key == self.lastImportProgressKey
                && abs(self.lastImportProgressValue - progress) < 0.01
            guard !shouldThrottle else { return }
            self.lastImportProgressKey = key
            self.lastImportProgressValue = progress
            self.importProgress = ImportProgress(
                fileName: fileName,
                currentIndex: index,
                totalCount: total,
                phase: phase,
                progress: progress
            )
        }
    }

    /// 清除导入进度（导入成功/失败后调用，内部切回主线程赋值）。
    func clearImportProgress() {
        DispatchQueue.main.async {
            self.importProgress = nil
            // 重置节流状态：下一文件/下次导入的首档进度必须显示
            self.lastImportProgressKey = ""
            self.lastImportProgressValue = -1
        }
    }

    /// 导入单个文件。progressContext 携带多选导入时的序号/总数（单文件调用可省略，
    /// 默认按 total=1 处理），用于首页进度卡片显示"正在导入 i/N"。
    /// 进度状态在后台各阶段间更新（内部切回主线程赋值 @Published），
    /// 成功/失败均会清除进度，失败仍走既有 completion(.failure) 错误提示逻辑。
    func importFile(
        from url: URL,
        progressContext: (index: Int, total: Int)? = nil,
        completion: @escaping (Result<AppInfo, Error>) -> Void
    ) {
        // 进度上下文：未传时按单文件处理（index/total = 1）
        let index = progressContext?.index ?? 1
        let total = progressContext?.total ?? 1
        let fileName = url.lastPathComponent

        // 初始阶段（调用方通常在主线程；updateImportProgress 内部仍会切回主线程赋值）
        updateImportProgress(fileName: fileName, index: index, total: total, phase: "准备导入…")

        DispatchQueue.global(qos: .userInitiated).async {
            // 安全作用域必须在真正执行 I/O 的后台闭包内持有（defer 作用域 = 闭包）：
            // 若在进入队列前就 start/stop，文件 App 外部打开（LSSupportsOpeningDocumentsInPlace
            // 生效的 in-place 安全作用域 URL）的后台解压/复制/解析会处于未授权状态 → EPERM。
            // 闭包开头 start、defer stop 覆盖 zip 转换到复制解析的全过程；闭包内所有
            // 错误路径的 defer 都会执行，保证成对释放。
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            // destination 声明在 do 外，便于解析失败时清理可能残留的半成品文件；
            // destinationCreatedByThisImport 标记 destination 是否由本次导入写入：
            // 同 bundleID 重导入覆盖时 destination 可能仍是旧文件，失败清理绝不能误删旧文件。
            var destination = self.fileManager.directoryURL(.ipa).appendingPathComponent(url.lastPathComponent)
            var destinationCreatedByThisImport = false
            do {
                // zip 输入先统一转换为标准 .ipa（含内嵌 .ipa 提取、.app 重打包为 Payload）：
                // 入库后 app.path 一定指向可签名的 .ipa。不含 .app/.ipa 的 zip（如证书包）
                // 会在转换时抛“未找到 .app 应用包”，由上层给用户明确提示，不会入库。
                let importURL: URL
                if url.pathExtension.lowercased() == "zip" {
                    // 阶段：解压源压缩包并重新打包成 .ipa（可能耗时最长）。
                    // 权重 0~60%：convertToIPAIfNeeded 内部按解压字节上报 p*0.6
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解压转换中…", progress: 0)
                    importURL = try self.parser.convertToIPAIfNeeded(fileURL: url, progress: { p in
                        self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解压转换中…", progress: p * 0.6)
                    })
                } else {
                    importURL = url
                }
                destination = self.fileManager.directoryURL(.ipa).appendingPathComponent(importURL.lastPathComponent)

                // 转换得到的 .ipa 已直接输出到 .ipa 目录（importURL 即 destination），
                // 跳过复制，避免删掉源文件；此时 destination 是本次导入产生的产物
                if importURL.path != destination.path {
                    // 同名冲突处理（数据安全）：目标已存在时——
                    // 1) 若已有记录正是同 bundleID（重复导入同一应用）：直接覆盖，记录同步更新；
                    // 2) 若已存在但归属其它 bundleID（或无可查记录）：改用唯一后缀名，
                    //    绝不覆盖可能仍被其它记录引用的旧文件（旧记录 path 会指向被替换文件，
                    //    出现“元数据与磁盘内容错配”）。
                    var isSameApp = false
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let existing = self.importedApps.first { $0.path == destination.path }
                        isSameApp = existing != nil
                            && existing?.bundleID == (try? self.parser.parseAppInfo(fileURL: importURL).bundleID)
                        if !isSameApp {
                            let base = destination.deletingPathExtension().lastPathComponent
                            var candidate = self.fileManager.directoryURL(.ipa)
                                .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).ipa")
                            // 二次保险：唯一后缀仍可能碰撞（理论上不可能），存在则继续加随机
                            while FileManager.default.fileExists(atPath: candidate.path) {
                                candidate = self.fileManager.directoryURL(.ipa)
                                    .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).ipa")
                            }
                            destination = candidate
                        }
                    }
                    // 阶段：复制到 IPA 目录（权重 60~80%）
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "复制文件…", progress: 0.6)
                    if isSameApp {
                        // 同 bundleID 重复导入（数据安全）：绝不“先删旧文件再拷”——
                        // 复制失败会让旧文件永久丢失、旧记录悬空。改为先复制新文件到
                        // 临时名，完整成功后移除旧文件并换位；任何一步失败旧文件仍在。
                        let tempURL = self.fileManager.directoryURL(.ipa)
                            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(destination.lastPathComponent)")
                        do {
                            try FileManager.default.copyItem(at: importURL, to: tempURL)
                        } catch {
                            // 复制失败：旧文件原封未动，删掉临时残留后抛错
                            try? FileManager.default.removeItem(at: tempURL)
                            throw error
                        }
                        // 新文件已完整落盘，此时才移除旧文件并换位
                        try? FileManager.default.removeItem(at: destination)
                        do {
                            try FileManager.default.moveItem(at: tempURL, to: destination)
                        } catch {
                            // 极罕见：换位失败时旧文件已删，尽力把新文件恢复到目标位置
                            try? FileManager.default.moveItem(at: tempURL, to: destination)
                            throw error
                        }
                    } else {
                        try self.fileManager.copyItem(from: importURL, to: destination)
                    }
                }
                // 走到这里 destination 必为本次导入写入/产生的文件（复制分支成功后，
                // 或 skip-copy 分支的转换产物），失败清理时才允许删除它
                destinationCreatedByThisImport = true
                // 阶段：解压 IPA 并解析 Info.plist / 提取图标（权重 80~95%）
                self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解析中…", progress: 0.8)
                var app = try self.parser.parseAppInfo(fileURL: destination)
                // skip-copy 分支唯一后缀保护：转换产物已直接写入 destination，但该路径若
                // 已被其它 bundleID 的记录引用（如旧记录指向已丢失的文件、或转换输出恰好
                // 撞上残留同名文件），把产物改名到唯一后缀，杜绝新旧两条记录指向同一文件。
                if importURL.path == destination.path {
                    if let existing = self.importedApps.first(where: { $0.path == destination.path }),
                       existing.bundleID != app.bundleID,
                       FileManager.default.fileExists(atPath: destination.path) {
                        let base = destination.deletingPathExtension().lastPathComponent
                        var candidate = self.fileManager.directoryURL(.ipa)
                            .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).ipa")
                        while FileManager.default.fileExists(atPath: candidate.path) {
                            candidate = self.fileManager.directoryURL(.ipa)
                                .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).ipa")
                        }
                        try FileManager.default.moveItem(at: destination, to: candidate)
                        destination = candidate
                        Logger.info("转换产物与既有记录冲突，已改名: \(destination.lastPathComponent)")
                    }
                }
                app.path = destination.path
                // 待签名图标持久化：parseAppInfo 返回的 iconPath 是本次解压目录
                // （Extracted/<baseName>/）内的 .app 内部路径，而每次解析都会解压并整体
                // 清空重建该目录，图标路径在下一次刷新时即失效。这里复制到
                // Extracted/Icons/<baseName>/ 稳定目录后回填 app.iconPath，首页「待签名」
                // 列表才能稳定显示图标（与已签名列表 persistInstalledAppIcon 同源修复）。
                // 当前仍在后台队列执行，文件复制不阻塞主线程。
                // 阶段：把解析出的图标复制到稳定目录（权重 95~100%）
                self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "提取图标…", progress: 0.95)
                if let iconPath = app.iconPath,
                   FileManager.default.fileExists(atPath: iconPath),
                   let stablePath = self.persistImportedAppIcon(
                       from: iconPath,
                       baseName: destination.deletingPathExtension().lastPathComponent
                   ) {
                    app.iconPath = stablePath
                }
                DispatchQueue.main.async {
                    if let index = self.importedApps.firstIndex(where: { $0.bundleID == app.bundleID }) {
                        self.importedApps[index] = app
                    } else {
                        self.importedApps.append(app)
                    }
                    self.saveState()
                    // 导入成功：清除进度
                    self.clearImportProgress()
                    completion(.success(app))
                }
            } catch {
                DispatchQueue.main.async {
                    // 复制/解析失败时，清理本次导入可能残留的半成品文件。
                    // 仅删除由本次导入写入的文件（destinationCreatedByThisImport）：
                    // 同 bundleID 覆盖场景失败时 destination 仍是旧文件，绝不能误删
                    //（否则旧记录悬空、旧文件丢失）。
                    if destinationCreatedByThisImport,
                       FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    // 导入失败：同样清除进度，错误提示走既有逻辑
                    self.clearImportProgress()
                    completion(.failure(error))
                }
            }
        }
    }

    /// 把导入（待签名）应用解压出的图标复制到稳定位置 Extracted/Icons/<baseName>/，
    /// 避免后续 parseAppInfo 再次解压时清空重建 Extracted/<baseName>/ 目录导致图标路径失效。
    /// 与已签名列表的 persistInstalledAppIcon 同模式；复制失败返回 nil（调用方保留原路径兜底）。
    private func persistImportedAppIcon(from iconPath: String, baseName: String) -> String? {
        let source = URL(fileURLWithPath: iconPath)
        // 文件名安全化：只保留字母数字与 ._-，其余替换为 -，避免 copyItem 因非法字符失败
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var label = String(baseName.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        if label.isEmpty { label = baseName }
        let fileName = "\(label)-icon.\(source.pathExtension.lowercased())"
        // 注意：不能把图标写回 Extracted/<baseName>/ —— 这正是每次 parse 时
        // ZipManager.unzip 会整体删除重建的目录；Extracted/Icons/<baseName>/ 才真正稳定。
        let target = fileManager.directoryURL(.extracted)
            .appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            // AppFileManager.copyItem 会先创建父目录（Extracted/Icons/<baseName>/）、
            // 再移除已存在的同名目标，重复导入同一 baseName 也安全
            try fileManager.copyItem(from: source, to: target)
            Logger.info("待签名应用图标持久化成功: \(target.path)")
            return target.path
        } catch {
            Logger.warning("待签名应用图标持久化失败: \(fileName) - \(error.localizedDescription)")
            return nil
        }
    }

    func signApp(
        _ app: AppInfo,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double) -> Void,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        var task = SigningTask()
        task.sourceFile = app.path
        task.sourceAppName = app.name
        task.certificateID = certificate.id
        task.profileID = profile.id
        task.status = .queued
        signingTasks.append(task)
        saveState()

        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async {
                if let index = self.signingTasks.firstIndex(where: { $0.id == task.id }) {
                    self.signingTasks[index].status = .processing
                }
            }

            do {
                let signedPath = try SigningEngine.shared.sign(
                    sourcePath: app.path,
                    certificate: certificate,
                    profile: profile,
                    progress: { p in
                        DispatchQueue.main.async {
                            progress(p)
                            if let index = self.signingTasks.firstIndex(where: { $0.id == task.id }) {
                                self.signingTasks[index].progress = p
                            }
                        }
                    }
                )

                DispatchQueue.main.async {
                    if let index = self.signingTasks.firstIndex(where: { $0.id == task.id }) {
                        self.signingTasks[index].status = .success
                        self.signingTasks[index].progress = 1.0
                        self.signingTasks[index].outputPath = signedPath
                    }
                    // 同步更新 importedApps 旧记录：签名成功后置 isSigned=true 并回填签名产物路径，
                    // 否则首页“待签名”列表一直显示已签名应用（用户误以为签名失败）。
                    if let index = self.importedApps.firstIndex(where: { $0.path == app.path || $0.id == app.id }) {
                        self.importedApps[index].isSigned = true
                        self.importedApps[index].signedPath = signedPath
                    }
                    self.saveState()
                    // 已签名列表在后台串行队列解析后回主线程赋值，完成后才回调，
                    // 保证 AppDetailView.liveApp 在 completion 后能立刻按 path 匹配到签名产物。
                    self.refreshInstalledApps {
                        completion?(.success(signedPath))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let index = self.signingTasks.firstIndex(where: { $0.id == task.id }) {
                        self.signingTasks[index].status = .failed
                        self.signingTasks[index].error = error.localizedDescription
                    }
                    self.saveState()
                    completion?(.failure(error))
                }
            }
        }
    }

    func installApp(_ app: AppInfo, certificate: CertificateInfo) throws {
        guard app.isSigned else {
            throw AppError.installFailed("应用尚未签名")
        }
        try Installer.shared.install(ipaPath: app.path, certificate: certificate)
    }

    func installSignedPath(_ ipaPath: String, certificate: CertificateInfo) throws {
        try Installer.shared.install(ipaPath: ipaPath, certificate: certificate)
    }

    /// 外部打开文件去重：SwiftUI 生命周期下 application(_:open:) 与 onOpenURL 可能
    /// 对同一 URL 双触发（两个入口并存），短窗口内同一 URL 只处理一次，避免重复导入。
    private var lastOpenedExternalURL: String = ""
    private var lastOpenedExternalDate: Date = .distantPast

    func handleFileOpenedFromOutside(_ url: URL) {
        let now = Date()
        if url.absoluteString == lastOpenedExternalURL,
           now.timeIntervalSince(lastOpenedExternalDate) < 2.0 {
            Logger.info("外部打开文件去重跳过: \(url.lastPathComponent)")
            return
        }
        lastOpenedExternalURL = url.absoluteString
        lastOpenedExternalDate = now
        let ext = url.pathExtension.lowercased()
        Logger.info("外部打开文件: \(url.lastPathComponent)")

        switch ext {
        case "zip":
            // zip 统一走下载完成的分类导入（证书包 / 应用包 / zip 内嵌 ipa / 未知），
            // 修复“文件 App 打开 zip 包着 ipa”时一律被当证书包导入、内嵌 .ipa 无法识别的问题。
            // 分类为 .certificateBundle 时其内部仍会调 importCertificateBundleOrFile，证书包不受影响。
            handleDownloadedFile(at: url)
        case "p12", "pfx", "mobileprovision":
            // 单个证书相关文件保持原逻辑（zip 才是证书包载体）
            importCertificateBundleOrFile(url)
        default:
            importFile(from: url) { result in
                switch result {
                case .success(let app):
                    // 外部打开的应用导入成功后，切到首页并提示（用户可进详情签名）
                    self.selectedTab = 0
                    Logger.info("外部打开文件导入成功: \(app.name)")
                case .failure(let error):
                    // 外部打开失败必须给反馈（否则用户在文件 App 里点了毫无反应）
                    self.showToast("导入失败: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 单个证书相关文件（p12/pfx/mobileprovision）的外部导入反馈：
    /// - p12/pfx：尝试常见密码 "1" 直接导入（与 zip 证书包路径一致）；成功给 toast，
    ///   失败提示用户去证书页手动输入密码导入，并切到证书 Tab。
    /// - mobileprovision：无需密码，直接导入描述文件；成功/失败均给 toast 反馈。
    /// 注：CertificateManager / ProvisioningManager 在各自内部持有安全作用域，
    /// 这里无需再 startAccessing。
    private func handleSingleCertificateFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "p12", "pfx":
            CertificateManager.shared.importCertificate(from: url, password: "1") { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let cert):
                        self.addCertificate(cert)
                        self.showToast("已导入证书文件，请到证书页查看")
                    case .failure:
                        self.showToast("请在证书页手动导入该文件")
                        self.selectedTab = 3
                    }
                }
            }
        case "mobileprovision":
            // 描述文件解析/归档（读文件 + 复制）下沉到后台队列，避免阻塞主线程
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let profile = try ProvisioningManager.shared.importProfile(from: url)
                    DispatchQueue.main.async {
                        // 按 uuid 去重/更新（与证书页导入行为一致），避免重复添加
                        if let index = self.profiles.firstIndex(where: { $0.uuid == profile.uuid }) {
                            self.profiles[index].path = profile.path
                            if self.selectedProfile?.uuid == profile.uuid {
                                self.selectedProfile?.path = profile.path
                            }
                            self.saveState()
                        } else {
                            self.addProfile(profile)
                        }
                        self.showToast("已导入描述文件，请到证书页查看")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.showToast("描述文件导入失败，请在证书页手动导入该文件")
                        self.selectedTab = 3
                    }
                }
            }
        default:
            break
        }
    }

    /// 从解压产物 URL 向上回溯到 bundle-extract-<uuid> 解压目录根：
    /// findFile 支持一层子目录，p12/profile 可能位于 bundle-extract-* 的深层。
    private func bundleExtractRoot(from fileURL: URL?) -> URL? {
        guard var current = fileURL?.deletingLastPathComponent() else { return nil }
        let certDirPath = fileManager.directoryURL(.certificates).path
        while current.path.hasPrefix(certDirPath) {
            if current.lastPathComponent.hasPrefix("bundle-extract-") {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// 兜底清理：删除 Certificates/ 下所有 bundle-extract-* 解压目录。
    /// 仅在 extract 抛错（拿不到确切解压目录 URL）时使用；正常路径一律用精确 URL 清理。
    private func sweepBundleExtractDirs() {
        let certDir = fileManager.directoryURL(.certificates)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: certDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, entry.lastPathComponent.hasPrefix("bundle-extract-") {
                try? fileManager.deleteItem(at: entry)
            }
        }
    }

    /// zip 证书包导入收尾：删除托管 P12 明文副本（Certificates/cert-*.p12）与解压目录
    /// （bundle-extract-*），避免私钥材料明文常驻 Documents（文件 App/备份可导出）。
    /// 证书导入成功后私钥已进 Keychain，明文 P12 不再需要；失败同样清理。
    private func cleanupManagedCertBundle(
        importer: CertificateBundleImporter,
        moved: (p12URL: URL?, profileURL: URL?)?,
        extractDir: URL?
    ) {
        if let moved = moved {
            importer.deleteManagedP12(moved.p12URL)
        }
        if let extractDir = extractDir {
            importer.cleanup(extractDir: extractDir)
        }
    }

    private func importCertificateBundleOrFile(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "zip":
            let importer = CertificateBundleImporter.shared
            // 安全作用域：zip 证书包的后台解压/复制/清理全程必须处于授权状态，
            // start/stop 需成对；defer 在后台闭包内释放，覆盖所有错误路径。
            let accessed = url.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                // 解压目录：无论成功失败都必须清理（内含明文 P12 材料）
                var extractDir: URL? = nil
                do {
                    let content = try importer.extract(from: url)
                    extractDir = self.bundleExtractRoot(from: content.p12URL)
                        ?? self.bundleExtractRoot(from: content.profileURL)
                    let moved = try importer.moveToManagedLocation(
                        p12URL: content.p12URL,
                        profileURL: content.profileURL
                    )
                    DispatchQueue.main.async {
                        // 描述文件
                        if let profileURL = moved.profileURL,
                           let profile = try? ProvisioningManager.shared.importProfile(from: profileURL) {
                            self.addProfile(profile)
                        }
                        // 证书：尝试用常见密码 "1" 导入（兼容多数自签证书包），
                        // 失败则提示用户走证书页手动输入密码导入
                        if let p12URL = moved.p12URL {
                            CertificateManager.shared.importCertificate(from: p12URL, password: "1") { result in
                                DispatchQueue.main.async {
                                    switch result {
                                    case .success(let cert):
                                        self.addCertificate(cert)
                                        Logger.info("zip 证书包证书导入成功: \(cert.name)")
                                    case .failure(let error):
                                        Logger.warning("zip 证书包证书需手动导入: \(error.localizedDescription)")
                                    }
                                    // 证书导入处理完毕（无论成败）后清理托管 P12 与解压目录
                                    self.cleanupManagedCertBundle(importer: importer, moved: moved, extractDir: extractDir)
                                }
                            }
                        } else {
                            // 无证书：描述文件已归档到 Profiles，直接清理
                            self.cleanupManagedCertBundle(importer: importer, moved: moved, extractDir: extractDir)
                        }
                        Logger.info("zip 证书包导入完成")
                    }
                } catch {
                    // 解压/移动失败：同样清理。extract 抛错时拿不到确切解压目录
                    // （unzip 可能已创建 bundle-extract-* 且残留部分内容），按前缀兜底清扫；
                    // moveToManagedLocation 抛错时按已确知的解压目录清理。
                    if let extractDir = extractDir {
                        importer.cleanup(extractDir: extractDir)
                    } else {
                        self.sweepBundleExtractDirs()
                    }
                    Logger.error("zip 证书包导入失败: \(error)")
                }
            }
        default:
            // 单个 p12/pfx/mobileprovision：直接尝试导入并给用户反馈
            handleSingleCertificateFile(url)
        }
    }

    func loadPersistedState() {
        certificates = store.loadCertificates()
        profiles = store.loadProfiles()
        var restoredTasks = store.loadSigningTasks()
        // 签名任务启动对账：进程被杀后 .queued/.processing 任务原样持久化会永远“处理中”，
        // 统一标记为 failed（附“上次会话中断”原因），杜绝永久卡死。
        var reconciled = false
        for index in restoredTasks.indices {
            if restoredTasks[index].status != .success && restoredTasks[index].status != .failed {
                restoredTasks[index].status = .failed
                restoredTasks[index].error = "上次会话中断，任务未完成"
                reconciled = true
            }
        }
        signingTasks = restoredTasks
        if reconciled {
            store.saveSigningTasks(signingTasks)
        }
        // 下载任务由 DownloadManager.restoreSavedTasks() 负责恢复并持久化，
        // 这里不再加载，避免与 DownloadManager 的内存态互相覆盖。
        importedApps = store.loadImportedApps()

        // 路径重定位：iOS 更新/重装 app 后沙盒容器路径（Bundle/Data 的 UUID）会变化，
        // 持久化的旧路径可能失效。用文件名在对应的 Documents 目录下找回，
        // 找到则更新为稳定路径并持久化；找不到则保留原记录（UI 显示文件缺失），不影响其它记录。
        relocateProfilePaths()
        relocateImportedAppPaths()
        relocateImportedAppIconPaths()
        // 孤儿清扫：清理不再被任何记录引用的解析临时目录（避免 Extracted/ 无限膨胀）
        sweepOrphanExtractDirs()

        // 选中项不持久化，恢复后必须重新挑选，避免首页显示“未选择证书”
        if selectedCertificate == nil {
            selectedCertificate = certificates.first { $0.status == .valid } ?? certificates.first
        }
        if selectedProfile == nil {
            selectedProfile = profiles.first { $0.status == .valid } ?? profiles.first
        }
    }

    /// 描述文件路径重定位：path 失效时，按文件名（或 `profile-<uuid>.mobileprovision`）在
    /// Documents/Profiles 下找回文件；找到则更新 path 并落盘，找不到保留原记录。
    private func relocateProfilePaths() {
        let available = fileManager.contents(of: .profiles)
        var changed = false
        for index in profiles.indices {
            let profile = profiles[index]
            guard !profile.path.isEmpty,
                  !FileManager.default.fileExists(atPath: profile.path) else { continue }

            let oldFileName = URL(fileURLWithPath: profile.path).lastPathComponent
            let uuidFileName = UUID(uuidString: profile.uuid).map { "profile-\($0.uuidString).mobileprovision" }

            guard let match = available.first(where: { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDirectory else { return false }
                return entry.lastPathComponent == oldFileName
                    || (uuidFileName != nil && entry.lastPathComponent == uuidFileName)
            }) else { continue }

            profiles[index].path = match.path
            changed = true
            Logger.info("描述文件路径重定位: \(oldFileName) -> \(match.path)")
        }
        if changed {
            store.saveProfiles(profiles)
        }
    }

    /// 导入应用路径重定位：与描述文件同理，按文件名在 Documents/IPA 下找回，
    /// 修复签名/重打包时 “Input file not found” 同类问题。
    private func relocateImportedAppPaths() {
        let available = fileManager.contents(of: .ipa)
        var changed = false
        for index in importedApps.indices {
            let app = importedApps[index]
            guard !app.path.isEmpty,
                  !FileManager.default.fileExists(atPath: app.path) else { continue }

            let oldFileName = URL(fileURLWithPath: app.path).lastPathComponent

            guard let match = available.first(where: { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDirectory else { return false }
                return entry.lastPathComponent == oldFileName
            }) else { continue }

            importedApps[index].path = match.path
            changed = true
            Logger.info("应用路径重定位: \(oldFileName) -> \(match.path)")
        }
        if changed {
            store.saveImportedApps(importedApps)
        }
    }

    /// 待签名应用图标路径重定位：iOS 更新/重装后容器 UUID 变化，持久化的
    /// iconPath（Extracted/Icons/<baseName>/...）整体失效。图标目录虽稳定但在容器
    /// 迁移后路径前缀失效；按 baseName 在 Extracted/Icons/<baseName>/ 下按文件名找回。
    private func relocateImportedAppIconPaths() {
        let iconsRoot = fileManager.directoryURL(.extracted)
            .appendingPathComponent("Icons", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: iconsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        let iconDirsByBase = Dictionary(grouping: entries) { $0.lastPathComponent }
        var changed = false
        for index in importedApps.indices {
            guard let iconPath = importedApps[index].iconPath,
                  !iconPath.isEmpty,
                  !FileManager.default.fileExists(atPath: iconPath) else { continue }
            let fileName = URL(fileURLWithPath: iconPath).lastPathComponent
            let baseName = importedApps[index].path.isEmpty
                ? ""
                : URL(fileURLWithPath: importedApps[index].path).deletingPathExtension().lastPathComponent
            // 在对应的 <baseName> 图标目录下找同名文件
            if let dirs = iconDirsByBase[baseName], let dirURL = dirs.first {
                let matches = (try? FileManager.default.contentsOfDirectory(atPath: dirURL.path)) ?? []
                if let match = matches.first(where: { $0 == fileName }) {
                    importedApps[index].iconPath = dirURL.appendingPathComponent(match).path
                    changed = true
                    Logger.info("应用图标路径重定位: \(fileName)")
                }
            }
        }
        if changed {
            store.saveImportedApps(importedApps)
        }
    }

    /// 重新扫描 Documents/Signed 下的签名产物并刷新已签名应用列表。
    /// 对每个签名 IPA 完整解析，拿到 bundleID / version / iconPath（修复“未知 Bundle ID”、
    /// 图标不显示）；解析失败时回退为旧逻辑（文件名 + isSigned）。
    /// 解析在串行后台队列执行（解压较慢，不可上主线程），最终 @Published 赋值回到主线程。
    func refreshInstalledApps(completion: (() -> Void)? = nil) {
        isRefreshingInstalledApps = true
        installedAppsRefreshQueue.async {
            let signedURLs = self.fileManager.contents(of: .signed)
            let apps = signedURLs.map { self.makeInstalledAppInfo(from: $0) }
            DispatchQueue.main.async {
                self.installedApps = apps
                self.isRefreshingInstalledApps = false
                completion?()
            }
        }
    }

    /// 解析单个签名产物为完整 AppInfo；失败时回退旧逻辑（文件名 + isSigned）。
    private func makeInstalledAppInfo(from url: URL) -> AppInfo {
        // parseAppInfo 会解压 IPA 并读取 Info.plist / 提取图标
        if var parsed = try? parser.parseAppInfo(fileURL: url) {
            // 覆盖回签名产物自身：parseAppInfo 返回的 path 是 .app 内部路径、
            // size 是 IPA 大小。其它调用方（AppDetailView 按 path 匹配已签名列表、
            // 详情/首页按 signedPath/path 取签名文件时间）依赖这些字段指向签名 IPA。
            parsed.path = url.path
            parsed.size = fileManager.fileSize(at: url)
            parsed.isSigned = true
            parsed.signedPath = url.path
            // extractIcon 返回的是 .app 内部路径，而解压目录（Extracted/<baseName>/）
            // 会在下一轮解析时被整体清空重建，因此把图标复制到稳定位置再回填 iconPath，
            // 保证刷新后 iconPath 指向存在的文件。
            if let iconPath = parsed.iconPath,
               FileManager.default.fileExists(atPath: iconPath),
               let stablePath = persistInstalledAppIcon(
                   from: iconPath,
                   baseName: url.deletingPathExtension().lastPathComponent,
                   app: parsed
               ) {
                parsed.iconPath = stablePath
            }
            return parsed
        }

        var fallback = AppInfo()
        fallback.name = url.deletingPathExtension().lastPathComponent
        fallback.path = url.path
        fallback.size = fileManager.fileSize(at: url)
        fallback.isSigned = true
        return fallback
    }

    /// 把签名 IPA 解压出的图标复制到稳定位置 Extracted/Icons/<baseName>/<标识>-icon.<ext>，
    /// 避免后续解析清理解压目录后图标路径失效。复制失败返回 nil（调用方保留原路径兜底）。
    private func persistInstalledAppIcon(from iconPath: String, baseName: String, app: AppInfo) -> String? {
        let source = URL(fileURLWithPath: iconPath)
        var label = app.bundleID.isEmpty ? app.name : app.bundleID
        // 文件名安全化：只保留字母数字与 ._-（bundleID/显示名里的 / : \ * ? 等全部替换），
        // 避免 copyItem 因非法字符失败导致图标路径退回易失效的临时目录。
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        label = String(label.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        if label.isEmpty { label = baseName }
        let fileName = "\(label)-icon.\(source.pathExtension.lowercased())"
        // 注意：不能把图标写回 Extracted/<baseName>/ —— 这正是每次 parse 时
        // ZipManager.unzip 会整体删除重建的目录（图标“稳定路径”必须位于其之外）。
        // Extracted/Icons/<baseName>/ 不会被任何 unzip 清理，才是真正稳定。
        let target = fileManager.directoryURL(.extracted)
            .appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            // AppFileManager.copyItem 会先创建父目录（Extracted/Icons/<baseName>/）、
            // 再移除已存在的同名目标，重复刷新安全
            try fileManager.copyItem(from: source, to: target)
            Logger.info("已签名应用图标持久化成功: \(target.path)")
            return target.path
        } catch {
            Logger.warning("已签名应用图标持久化失败: \(fileName) - \(error.localizedDescription)")
            return nil
        }
    }

    func saveState() {
        store.saveCertificates(certificates)
        store.saveProfiles(profiles)
        store.saveSigningTasks(signingTasks)
        // 下载任务以 DownloadManager 的内存态为准，避免用恒为空的
        // downloadTasks 覆盖 DownloadManager 已持久化的任务记录。
        store.saveDownloadTasks(DownloadManager.shared.snapshotTasks())
        store.saveImportedApps(importedApps)
    }

    func addCertificate(_ certificate: CertificateInfo) {
        certificates.append(certificate)
        if selectedCertificate == nil {
            selectedCertificate = certificates.first { $0.status == .valid } ?? certificate
        }
        saveState()
    }

    func removeCertificate(_ certificate: CertificateInfo) {
        certificates.removeAll { $0.id == certificate.id }
        if selectedCertificate?.id == certificate.id {
            selectedCertificate = certificates.first { $0.status == .valid }
        }
        // 同步清理 Keychain 中的私钥与密码条目，避免删除后残留
        CertificateManager.shared.deleteCertificate(certificate)
        saveState()
    }

    func addProfile(_ profile: ProvisioningInfo) {
        profiles.append(profile)
        if selectedProfile == nil {
            selectedProfile = profiles.first { $0.status == .valid } ?? profile
        }
        saveState()
    }

    func removeProfile(_ profile: ProvisioningInfo) {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfile?.id == profile.id {
            selectedProfile = profiles.first { $0.status == .valid }
        }
        saveState()
    }

    func removeSignedApp(_ app: AppInfo) {
        removeSignedApps([app])
    }

    /// 批量删除已签应用：逐个清理文件/记录，最后只触发一次 refreshInstalledApps，
    /// 避免 N 个应用删除时 N 次全量重扫（每次都会逐 IPA 解压解析，重复开销大）。
    func removeSignedApps(_ apps: [AppInfo]) {
        guard !apps.isEmpty else { return }
        for app in apps {
            // 从两条列表中都移除（未签名导入的也会出现在 importedApps）
            importedApps.removeAll { $0.id == app.id || $0.path == app.path }
            installedApps.removeAll { $0.path == app.path }
            // 同步移除引用该应用源文件的历史签名任务，避免残留“success”指向已删除文件
            signingTasks.removeAll { $0.sourceFile == app.path || $0.outputPath == app.path }
            let url = URL(fileURLWithPath: app.path)
            try? fileManager.deleteItem(at: url)
            // 一并清理对应的解压目录（保留基线安全）：目录名可能是 <baseName>（旧版）
            // 或 <baseName>-<UUID>（解析目录加 UUID 后），按前缀匹配清理
            let baseName = url.deletingPathExtension().lastPathComponent
            cleanupExtractDirs(matching: baseName)
            // 清理稳定图标目录 Extracted/Icons/<baseName>/（persistImportedAppIcon /
            // persistInstalledAppIcon 写入的位置），避免随删除历史单调累积
            let iconsDir = fileManager.directoryURL(.extracted)
                .appendingPathComponent("Icons", isDirectory: true)
                .appendingPathComponent(baseName, isDirectory: true)
            try? fileManager.deleteItem(at: iconsDir)
        }
        saveState()
        refreshInstalledApps()
    }

    /// 删除 Extracted/ 下所有以指定前缀开头的解压目录（兼容旧版 <baseName> 与新版
    /// <baseName>-<UUID> 两种命名）。
    private func cleanupExtractDirs(matching prefix: String) {
        let extractedRoot = fileManager.directoryURL(.extracted)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            // Icons/ 是稳定图标目录，绝不能按前缀误删
            guard isDirectory, entry.lastPathComponent != "Icons" else { continue }
            if entry.lastPathComponent == prefix || entry.lastPathComponent.hasPrefix(prefix + "-") {
                try? fileManager.deleteItem(at: entry)
            }
        }
    }

    /// 启动时孤儿清扫：删除 Extracted/ 下不被任何记录引用的解析目录
    /// （parseAppInfo 每次解压都生成 <baseName>-<UUID> 临时目录，路径会随 UUID 变化，
    /// 无法像 Icons/ 图标那样重定位，必须定期清理避免磁盘无限膨胀）。
    private func sweepOrphanExtractDirs() {
        let extractedRoot = fileManager.directoryURL(.extracted)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let referencedPaths = (importedApps.map { $0.path }
            + installedApps.map { $0.path }
            + importedApps.compactMap { $0.iconPath }
            + installedApps.compactMap { $0.iconPath })
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            // 保留 Icons/ 稳定目录；只清理确定是解析临时目录的条目
            guard isDirectory, entry.lastPathComponent != "Icons" else { continue }
            let isReferenced = referencedPaths.contains { $0.hasPrefix(entry.path) }
            if !isReferenced {
                try? fileManager.deleteItem(at: entry)
            }
        }
    }
}
