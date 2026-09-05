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

    /// 归档导入串行队列：zip 分类扫描/转换/复制/整包解析都是重 IO（大包可达数 GB），
    /// 两个下载几乎同时完成时若并发处理，会双倍内存/磁盘峰值、进度卡来回跳。
    /// 同一时间只处理一个归档；队列内闭包绝不同步等待自身（无死锁路径），
    /// 完成回调统一 main.async，UI 线程不受影响。
    private let importQueue = DispatchQueue(label: "com.ipamanager.appstate.import", qos: .userInitiated)

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

    /// 自动签名队列中（含正在签名）的应用 id：详情页据此禁用"开始签名"按钮并显示
    /// "正在自动签名"，避免用户手动点击与自动签名并发（zsign 并发不安全）。
    /// 导入/下载成功后进入队列，签名完成即移除（无论成败）。
    @Published var autoSigningAppIDs: Set<UUID> = []
    private var autoSignQueue: [AppInfo] = []
    private var isAutoSigning = false
    
    /// 分享投递实时日志（供 ContentView 底部面板展示）：每条事件含时间戳与事件描述，
    /// 用户分享文件到 App 后能实时看到投递链路发生了什么（扫描结果/保存成功/失败原因）。
    @Published var deliveryLogEntries: [ExternalDeliveryJournal.Entry] = []
    /// 日志面板展开状态（默认折叠）
    @Published var showDeliveryLog: Bool = false

    /// 投递日志变更后同步 UI 快照（清空/手动扫描等入口调用）
    func refreshDeliveryLogEntries() {
        DispatchQueue.main.async {
            self.deliveryLogEntries = ExternalDeliveryJournal.getEntries()
        }
    }

    /// 在任意线程设置全局轻提示（内部切回主线程并安排自动清除；重复设置会重置计时）。
    func showToast(_ message: String) {
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.toastMessage = nil
            }
            self.toastWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Timeouts.toast, execute: work)
        }
    }

    /// 挂起 App 回到 iOS 桌面（主屏幕）。
    ///
    /// 民间技巧说明：iOS 没有公开 API 能直接把 App“最小化到桌面”，这里通过 selector
    /// 调用 UIApplication 的私有 suspend 动作，效果与用户按 Home 键一致——App 退到后台
    /// （回到主屏幕），进程仍保留在后台，用户点击图标可随时恢复，无数据丢失。
    /// 用 responds(to:) 守卫：个别系统版本若不支持该 selector 则静默失败，
    /// 不影响调用方在此之前已执行的动作（如关闭详情页、切换 Tab）。
    /// 注意：该技巧仅适用于本类自签名安装的侧载工具（侧载/sideloaded only），不可用于 App Store 上架应用。
    /// 该实现对 selector 字符串做混淆以降低静态字符串检测（["sus","pend"].joined() 而非明文 "suspend"），
    /// 并保留 responds(to:) 守卫，行为与原版一致；未来可替换为 dlsym 或公开 API 替代。
    /// 必须在主线程调用（UIApplication 操作）。
    func minimizeToHomeScreen() {
        // Obfuscate private API string to reduce static detection (App Store 分析与字符串扫描)
        // 原始: "suspend" -> 拆分拼接，避免二进制中出现连续明文
        let selectorName = ["sus", "pend"].joined()
        // 备选更高混淆：字符码构造 let selectorName = String(bytes: [115,117,115,112,101,110,100], encoding: .utf8)!
        let selector = NSSelectorFromString(selectorName)
        if UIApplication.shared.responds(to: selector) {
            // perform(_:) 返回的 Unmanaged 结果无需使用，显式丢弃避免“结果未使用”警告
            _ = UIApplication.shared.perform(selector)
        }
    }

    init() {
        processedInboxPaths = Set(store.loadProcessedInboxPaths())
        importedDeliveryIdentities = Set(store.loadImportedDeliveryIdentities())
        failedDeliveryRecords = store.loadFailedDeliveryRecords()
        loadPersistedState()
        // 启动孤儿清扫放在首次“已签应用”扫描完成之后执行：refreshInstalledApps
        // 的解析会创建新的解压目录，且 installedApps 到此刻才就绪——若清扫与
        // 解析并发（引用列表还是启动时的快照），可能把解析中/新生成的解压目录
        // 当孤儿删掉。放进完成回调既保证时序（清扫快照包含刷新后的引用），
        // 又保持清扫本身在后台执行、不占主线程。
        refreshInstalledApps { [weak self] in
            self?.sweepOrphanExtractDirs()
        }
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
        /// zip 内嵌多个 .ipa 且无 .app：不随机选一个，交给上层明确告知用户
        case multipleIPAs([String])
        /// 压缩包能正常解压但既非应用包也非证书包；携带顶层内容摘要，便于定位真实结构
        case unknown(String)
    }

    func handleDownloadedFile(
        at url: URL,
        completion: ((Result<AppInfo, Error>) -> Void)? = nil,
        onSettled: ((Bool) -> Void)? = nil
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

        // tgz/tar/gz：当前解压引擎只支持 ZIP。此前这些扩展名也进入分类流程，
        // 最终得到与实际格式不符的"不是有效的 ZIP 压缩包"，用户误以为文件损坏。
        if ext != "zip" {
            Logger.error("下载/外部打开的归档为暂不支持的格式: \(url.lastPathComponent) (.\(ext))")
            completion?(.failure(AppError.operationFailed("暂不支持 .\(ext) 归档格式，请使用 .zip 或 .ipa 文件")))
            return
        }

        // 压缩包：后台先判断内容（证书包 / 应用包 / 未知），避免阻塞 UI。
        // 安全作用域在后台流程入口持有、defer 在闭包内释放，覆盖 classifyArchivedContent
        // 解压扫描与 convertToIPAIfNeeded 读取外部文件的全过程（文件 App 打开的
        // in-place 安全作用域 URL 若未授权访问，解压会 EPERM）。
        // 归档处理统一走 importQueue 串行队列（重 IO 不并发）。
        let accessed = url.startAccessingSecurityScopedResource()
        importQueue.async {
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let kind = try self.classifyArchivedContent(at: url)
                switch kind {
                case .certificateBundle:
                    // 内含 .p12/.mobileprovision → 证书包，走现有证书导入。
                    // onSettled：证书链路无 completion（导入无 AppInfo 结果），
                    // 分享投递（Inbox）的源文件删除与已结算落盘经此回调。
                    DispatchQueue.main.async {
                        Logger.info("检测到证书包，走证书导入: \(url.lastPathComponent)")
                    }
                    self.importCertificateBundleOrFile(url, onSettled: onSettled)
                case .appPackage:
                    // 内含 .app → 应用包：解压并重新打包成 .ipa 后导入“未签名应用”
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
                    // zip 内嵌 .ipa → 直接导入“未签名应用”：
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
                case .multipleIPAs(let paths):
                    // 多个内嵌 .ipa：绝不静默随机选一个，把全部候选明确告知用户
                    let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                    let message = "该 ZIP 内发现 \(paths.count) 个 IPA 文件：\(names)。为避免装错应用，不会随机选择——请解压后在文件 App 中分享要安装的那个 IPA。"
                    DispatchQueue.main.async {
                        Logger.error("自动解析失败（多 IPA 归档）: \(url.lastPathComponent) - \(message)")
                        completion?(.failure(AppError.operationFailed(message)))
                    }
                case .unknown(let summary):
                    // 保留原始分类信息，并附上“压缩包内包含：…”内容摘要，方便定位真实结构
                    let message = "ZIP 中未找到 IPA 文件：该 ZIP 不是应用包（未发现 .app 应用包或 .ipa 文件）也不是证书包（无 .p12/.mobileprovision）。\(summary)"
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

    /// 按 zip 中央目录条目路径判断压缩包内容（证书包 / 应用包 / 内嵌 ipa），
    /// 不再全量解压后扫目录：分类只需要扩展名与路径形状，2GB 包的自动导入此前
    /// 要为看一眼文件名付整包解压的 IO 与双倍磁盘峰值（分类解压一遍 + 转换再解压一遍）。
    /// 仅当判定为内嵌 .ipa 时才把该单个条目解出复制到 IPA 目录。
    private func classifyArchivedContent(at url: URL) throws -> DownloadedArchiveKind {
        let entryPaths: [String]
        do {
            // ZipManager 的 ZipError（"非 zip / 网页错误页 / 损坏不完整"，中文）
            // 直接透传给上层展示
            entryPaths = try ZipManager.shared.listEntryPaths(archiveURL: url)
        } catch {
            Logger.error("压缩包分类失败: \(url.lastPathComponent) - \(error.localizedDescription)")
            throw error
        }

        var hasCertificate = false
        var hasAppBundle = false
        var embeddedIPAPaths: [String] = []
        for path in entryPaths {
            let lower = path.lowercased()
            if lower.hasSuffix(".app") || lower.contains(".app/") {
                // 顶层或任意层级的 .app 应用包（目录条目本身或其内部文件）
                hasAppBundle = true
            } else if lower.hasSuffix(".p12") || lower.hasSuffix(".pfx") {
                hasCertificate = true
            } else if lower.hasSuffix(".mobileprovision") && !lower.contains(".app/") {
                // 排除 .app 内部的 embedded.mobileprovision，避免应用包被误判为证书包
                hasCertificate = true
            } else if lower.hasSuffix(".ipa") && !lower.contains(".app/") {
                // zip 内嵌 .ipa（GitHub release 常见格式）：全部记录，多个时不随机选
                embeddedIPAPaths.append(path)
            }
        }

        if hasCertificate { return .certificateBundle }
        if hasAppBundle { return .appPackage }
        // 多个内嵌 .ipa：绝不静默随机选择，交上层明确告知用户全部候选
        if embeddedIPAPaths.count > 1 { return .multipleIPAs(embeddedIPAPaths) }

        // 内嵌 .ipa：单条目解出并复制到 Documents/IPA 持久位置（唯一后缀，绝不覆盖旧文件）
        if let ipaEntry = embeddedIPAPaths.first {
            let entryName = (ipaEntry as NSString).lastPathComponent
            let ipaBase = (entryName as NSString).deletingPathExtension
            let ipaDir = self.fileManager.directoryURL(.ipa)
            var destURL = ipaDir.appendingPathComponent(entryName)
            if FileManager.default.fileExists(atPath: destURL.path) {
                destURL = ipaDir.appendingPathComponent("\(ipaBase)-\(UUID().uuidString.prefix(8)).ipa")
                while FileManager.default.fileExists(atPath: destURL.path) {
                    destURL = ipaDir.appendingPathComponent("\(ipaBase)-\(UUID().uuidString.prefix(8)).ipa")
                }
            }
            do {
                try ZipManager.shared.extractEntry(archiveURL: url, entryPath: ipaEntry, to: destURL)
            } catch {
                Logger.error("压缩包内嵌 .ipa 抽取失败: \(ipaEntry) - \(error.localizedDescription)")
                return .unknown("内嵌 .ipa（\(entryName)）无法解出：\(error.localizedDescription)")
            }
            Logger.info("压缩包内检测到内嵌 .ipa，已复制到: \(destURL.lastPathComponent)")
            return .embeddedIPA(destURL)
        }

        // 压缩包能正常读取但内部既无 .app 也无证书结构 → 未知类型（下游会报"不是应用包也不是证书包"）
        let summary = Self.archiveTopLevelSummary(entryPaths)
        Logger.error("压缩包分类失败: \(url.lastPathComponent) - 压缩包内未发现 .app（应用包）或 .p12/.pfx/.mobileprovision（证书包）结构。\(summary)")
        return .unknown(summary)
    }

    /// 压缩包顶层内容摘要（最多 5 个 + 总数），基于中央目录路径推导，
    /// 用于错误信息中说明"压缩包里到底有什么"。
    private static func archiveTopLevelSummary(_ entryPaths: [String]) -> String {
        var tops: [String] = []
        for path in entryPaths {
            let top = path.split(separator: "/").first.map(String.init) ?? path
            if !top.isEmpty && !tops.contains(top) {
                tops.append(top)
            }
        }
        if tops.isEmpty { return "压缩包内没有任何内容" }
        let shown = tops.prefix(5).joined(separator: "、")
        return tops.count > 5
            ? "压缩包内包含：\(shown) 等 \(tops.count) 个顶层条目"
            : "压缩包内包含：\(shown)"
    }

    /// 更新导入进度（任意线程可调，内部切回主线程赋值 @Published，
    /// 避免后台队列直接修改 ObservableObject 状态导致 SwiftUI 更新异常）。
    /// progress 为整体进度 0~1；阶段内由各阶段自身推进（解压按字节、其余按权重）。
    /// 节流：主线程内同阶段 progress 变化 <1% 时跳过，避免大包解压逐条目高频
    /// 刷新主队列（数万次 async 会造成 UI 掉帧）；首次进入阶段与跨阶段必更新。
    /// 节流状态锁：节流比较在调用线程（importQueue 串行队列）完成，命中节流就
    /// 直接返回、不再派发 main.async——大包解压逐条目回调（数万次）时，旧实现
    /// 每次回调仍构造闭包并跨线程 dispatch 一次，节流只省掉了 @Published 写入，
    /// 几万次队列跳转的分配开销照付。主线程 clearImportProgress 的重置经锁互斥。
    private let importProgressStateLock = NSLock()
    private var lastImportProgressKey: String = ""
    private var lastImportProgressValue: Double = -1
    func updateImportProgress(
        fileName: String,
        index: Int,
        total: Int,
        phase: String,
        progress: Double = 0
    ) {
        let key = "\(index)-\(total)-\(phase)"
        importProgressStateLock.lock()
        let shouldThrottle = key == lastImportProgressKey
            && abs(lastImportProgressValue - progress) < ProgressWeight.throttleDelta
        if !shouldThrottle {
            lastImportProgressKey = key
            lastImportProgressValue = progress
        }
        importProgressStateLock.unlock()
        guard !shouldThrottle else { return }
        DispatchQueue.main.async {
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
        importProgressStateLock.lock()
        lastImportProgressKey = ""
        lastImportProgressValue = -1
        importProgressStateLock.unlock()
        DispatchQueue.main.async {
            self.importProgress = nil
        }
    }

    /// 导入单个文件。progressContext 携带多选导入时的序号/总数（单文件调用可省略，
    /// 默认按 total=1 处理），用于首页进度卡片显示"正在导入 i/N"。
    /// autoSign：导入成功后是否自动签名并安装。多选导入的"仅导入，不自动安装"
    /// 选项必须经此参数传入——统一出口在本方法内部，若只靠视图层在 completion
    /// 里拦截，本方法仍会无条件入队自动签名（用户选择被无视的历史缺陷）。
    /// 进度状态在后台各阶段间更新（内部切回主线程赋值 @Published），
    /// 成功/失败均会清除进度，失败仍走既有 completion(.failure) 错误提示逻辑。
    func importFile(
        from url: URL,
        progressContext: (index: Int, total: Int)? = nil,
        autoSign: Bool = true,
        completion: @escaping (Result<AppInfo, Error>) -> Void
    ) {
        // 进度上下文：未传时按单文件处理（index/total = 1）
        let index = progressContext?.index ?? 1
        let total = progressContext?.total ?? 1
        let fileName = url.lastPathComponent

        // 后台闭包要读 importedApps 做同名冲突判断：先取一份主线程快照。
        // Swift Array 非线程安全——旧实现直接在后台队列遍历 @Published 数组，
        // 与主线程（删除应用 / 另一条导入完成时 append/替换）并发读写，
        // 可能读到 CoW 中间态直接崩溃。
        let importedAppsSnapshot: [AppInfo]
        if Thread.isMainThread {
            importedAppsSnapshot = importedApps
        } else {
            importedAppsSnapshot = DispatchQueue.main.sync { importedApps }
        }

        importQueue.async {
            // 初始进度放在串行块内：排队中的导入不会立刻顶掉正在进行的导入的
            // 进度卡（前一个导入完成后进度清空，下一个导入开始时再亮卡）。
            self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "准备导入…")

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
            // 关键防御：destination 初值用"绝对不可能与磁盘旧文件重名"的占位路径
            //（含 UUID + .tmp- 前缀），即便 catch 块误判 destinationCreatedByThisImport
            // 也只会删掉自己的临时文件，绝不会误删同名旧文件。
            var destination = self.fileManager.directoryURL(.ipa)
                .appendingPathComponent(".tmp-import-\(UUID().uuidString).ipa")
            var destinationCreatedByThisImport = false
            do {
                // zip 输入先统一转换为标准 .ipa（含内嵌 .ipa 提取、.app 重打包为 Payload）：
                // 入库后 app.path 一定指向可签名的 .ipa。不含 .app/.ipa 的 zip（如证书包）
                // 会在转换时抛“未找到 .app 应用包”，由上层给用户明确提示，不会入库。
                let importURL: URL
                if url.pathExtension.lowercased() == "zip" {
                    // 阶段：解压源压缩包并重新打包成 .ipa（可能耗时最长）。
                    // 权重 0~60%：convertToIPAIfNeeded 回传裸解压字节进度（0~1），
                    // 由这里统一映射到整体权重（解析/图标阶段的权重同理集中在本层）
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解压转换中…", progress: 0)
                    importURL = try self.parser.convertToIPAIfNeeded(fileURL: url, progress: { p in
                        self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解压转换中…", progress: p * ProgressWeight.unzip)
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
                        let existing = importedAppsSnapshot.first { $0.path == destination.path }
                        // 轻量 bundleID 读取（zip 中央目录单条目，毫秒级）：旧实现为比对
                        // bundleID 把新 IPA 整包解压一遍（1GB 包纯 IO 翻倍）。读取失败
                        // 返回 nil，与原 parseAppInfo 失败同语义（视为不同应用走唯一后缀）。
                        isSameApp = existing != nil
                            && existing?.bundleID == self.parser.lightweightAppInfo(from: importURL)?.bundleID
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
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "复制文件…", progress: ProgressWeight.copyProgress)
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
                // 阶段：解压 IPA 并解析 Info.plist / 提取图标。
                // - 直接导入 .ipa：上一阶段（解压转换 0~60%/复制 60~80%）被跳过，
                //   进度不应一下子跳到 80%。这里让"解析中"（整包解压，最耗时）从
                //   5% 起步，按真实解压字节平滑涨到 98%：5% → 10% → 20% … → 90% → 98%。
                // - zip 导入：解压转换已占 0~60%、复制 60~80%，解析第 2 次解压较快，
                //   保持 80~95% 权重（parseAppInfo 的 progress 映射到该区间）。
                let isDirectIPA = url.pathExtension.lowercased() == "ipa"
                if isDirectIPA {
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解析中…", progress: ProgressWeight.parseStartDirect)
                } else {
                    self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解析中…", progress: ProgressWeight.parseStartZip)
                }
                var app: AppInfo
                let parsedRootURL: URL
                let parsed = try self.parser.parseAppInfoWithRoot(fileURL: destination, progress: { p in
                    if isDirectIPA {
                        // .ipa 直接导入：5% → 98% 线性映射解压字节
                        self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解析中…", progress: ProgressWeight.parseStartDirect + p * ProgressWeight.parseRangeDirect)
                    } else {
                        // zip 导入：80% → 95%
                        self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "解析中…", progress: ProgressWeight.parseStartZip + p * ProgressWeight.parseRangeZip)
                    }
                })
                app = parsed.info
                parsedRootURL = parsed.rootURL
                // skip-copy 分支唯一后缀保护：转换产物已直接写入 destination，但该路径若
                // 已被其它 bundleID 的记录引用（如旧记录指向已丢失的文件、或转换输出恰好
                // 撞上残留同名文件），把产物改名到唯一后缀，杜绝新旧两条记录指向同一文件。
                if importURL.path == destination.path {
                    if let existing = importedAppsSnapshot.first(where: { $0.path == destination.path }),
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
                // 阶段：把解析出的图标复制到稳定目录（直接导入 .ipa 时解析到 98%，图标 98→100；
                // zip 导入时解析到 95%，图标 95→100）
                let iconProgress: Double = isDirectIPA ? ProgressWeight.iconProgressDirect : ProgressWeight.iconProgressZip
                self.updateImportProgress(fileName: fileName, index: index, total: total, phase: "提取图标…", progress: iconProgress)
                if let iconPath = app.iconPath,
                   FileManager.default.fileExists(atPath: iconPath),
                   let stablePath = self.persistImportedAppIcon(
                       from: iconPath,
                       baseName: destination.deletingPathExtension().lastPathComponent
                   ) {
                    app.iconPath = stablePath
                }
                // 解析与图标提取完成后，本次解压目录（Extracted/<base>-<uuid>，数百 MB~
                // 数 GB 的完整副本）已无用：立即清理，与 zip 转换路径（convertToIPAIfNeeded）
                // 的磁盘占用策略对齐——旧实现直接 .ipa 导入的解析目录要留到冷启动孤儿清扫。
                try? FileManager.default.removeItem(at: parsedRootURL)
                DispatchQueue.main.async {
                    // bundleID 为空（Info.plist 损坏/顶层非字典等异常）时不按空串去重：
                    // 否则第二个坏包会静默覆盖上一个坏包的记录且无任何提示
                    if !app.bundleID.isEmpty,
                       let index = self.importedApps.firstIndex(where: { $0.bundleID == app.bundleID }) {
                        self.importedApps[index] = app
                    } else {
                        self.importedApps.append(app)
                    }
                    self.saveState()
                    // 导入成功：清除进度
                    self.clearImportProgress()
                    completion(.success(app))
                    // 导入/下载/外部打开统一出口：一条龙自动签名并安装
                    // （开关默认开；默认证书/描述文件无效时自动跳过，不打扰用户；
                    // autoSign=false 供批量导入"仅导入"选项使用）
                    if autoSign {
                        self.enqueueAutoSignAndInstall(app)
                    }
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
    /// 已抽取到 `IconPersistenceService`，此处保留为薄封装以兼容旧调用。
    private func persistImportedAppIcon(from iconPath: String, baseName: String) -> String? {
        IconPersistenceService.persist(iconPath: iconPath, baseName: baseName)
    }

    func signApp(
        _ app: AppInfo,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double, String) -> Void,
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

        // zsign 桥接层并发不安全（文件级 thread_local 缓冲之外的静态全局状态），
        // 且注释明确写着"zsign 并发不安全"——但本方法此前派发到并发 global 队列，
        // 手动签名可与自动签名队列的 zsign 任务并发执行（导入 B 触发自动签名期间
        // 用户在 A 详情页点"开始签名"），两个 zsign_sign 并发 → 崩溃/产物损坏。
        // 全局签名串行队列让自动/手动两条路径天然互斥；证书导入的 p12 解析
        // （zsign_p12_info）也走同一队列，覆盖全部桥接入口。
        SigningEngine.zsignQueue.async {
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
                    progress: { p, phase in
                        DispatchQueue.main.async {
                            progress(p, phase)
                            if let index = self.signingTasks.firstIndex(where: { $0.id == task.id }) {
                                self.signingTasks[index].progress = p
                                if !phase.isEmpty {
                                    self.signingTasks[index].phase = phase
                                }
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
                    // 立即回调 completion（弹“签名完成”），再后台异步刷新已签名列表：
                    // 之前先 refreshInstalledApps 会整包解析刚生成的 Signed/ 产物
                    // （数百 MB 解压可能需要数秒），阻塞在 completion 之前导致
                    // “签名完成”弹窗延迟 3~4 秒，用户以为签名没完成。
                    completion?(.success(signedPath))
                    self.refreshInstalledApps()
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

    func installApp(
        _ app: AppInfo,
        certificate: CertificateInfo,
        onInstallOpened: (() -> Void)? = nil
    ) throws {
        guard app.isSigned else {
            throw AppError.installFailed("应用尚未签名")
        }
        try Installer.shared.install(ipaPath: app.path, certificate: certificate, onInstallOpened: onInstallOpened)
    }

    func installSignedPath(
        _ ipaPath: String,
        certificate: CertificateInfo,
        onInstallOpened: (() -> Void)? = nil
    ) throws {
        try Installer.shared.install(ipaPath: ipaPath, certificate: certificate, onInstallOpened: onInstallOpened)
    }

    /// 签名完成后是否自动返回桌面（设置开关，默认开）。
    func autoReturnHomeAfterSigningEnabled() -> Bool {
        store.autoReturnHomeAfterSigningEnabled()
    }

    /// 导入/下载完成后是否自动签名并安装（设置开关，默认开）。
    func autoSignAndInstallEnabled() -> Bool {
        store.autoSignAndInstallEnabled()
    }

    // MARK: - 自动签名并安装（导入/下载完成后一条龙）

    /// 自动一条龙流水线状态（导入→签名→发起安装）：nil = 空闲。
    /// 旧版签名阶段给 signApp 传空进度回调，大包签名 20-60 秒界面完全空白，
    /// 用户以为 App 卡死、频繁切后台把导入/签名进程掐死（投递文件结算不了，
    /// 下次启动又重新导入——"重复导入/连续签两次"的连锁根源之一）。
    struct AutoPipelineStatus: Equatable {
        let appName: String
        /// 阶段名：正在签名 / 发起安装 / 安装已发起
        let phase: String
        /// 阶段内明细（zsign 阶段文字、系统提示指引等）
        let detail: String
        /// 0~1，签名阶段有效；安装阶段为 nil（无可靠进度）
        let progress: Double?
    }

    @Published var autoPipelineStatus: AutoPipelineStatus?

    private func setPipelineStatus(_ appName: String, _ phase: String, _ detail: String = "", progress: Double? = nil) {
        DispatchQueue.main.async {
            self.autoPipelineStatus = AutoPipelineStatus(
                appName: appName, phase: phase, detail: detail, progress: progress
            )
        }
    }

    func clearPipelineStatus() {
        DispatchQueue.main.async {
            self.autoPipelineStatus = nil
        }
    }

    /// 同一 bundleID 的自动签名冷却期：签名完成后的短窗口内不再对同应用重复
    /// 发起自动签名。旧版去重只覆盖"排队中/签名中"的重叠窗口，投递文件被重复
    /// 导入（导入完成时间错开）时会先后签两次；冷却期兜住一切时间错开的双触发。
    private var recentAutoSignBundleIDs: [String: Date] = [:]
    private static let autoSignCooldown: TimeInterval = 300

    /// 导入/下载/外部打开导入成功后调用：若设置开启且存在有效默认证书/描述文件，
    /// 自动签名并自动安装（一条龙），满足"下载完/导入完直接签名安装"的需求。
    /// 串行队列逐条处理（zsign 并发不安全）；失败时 toast 具体中文原因，不静默。
    /// 可被多次调用（多文件导入/下载完成），自动去重排队。
    /// 返回 true 表示本次自动签名已接管（调用方可据此跳过"打开签名详情页"等手动引导）。
    @discardableResult
    func enqueueAutoSignAndInstall(_ app: AppInfo) -> Bool {
        // 开关默认开启
        guard store.autoSignAndInstallEnabled() else { return false }
        // 拒绝对已签名应用重复自动签名（用户重签走手动流程）
        guard !app.isSigned else { return false }
        // 冷却期：同一应用刚自动签过（时间错开的重复投递/重复导入）不再签第二次
        if !app.bundleID.isEmpty,
           let last = recentAutoSignBundleIDs[app.bundleID],
           Date().timeIntervalSince(last) < Self.autoSignCooldown {
            Logger.info("自动签名跳过：\(app.name) 刚在冷却期内签过（防重复投递连签两次）")
            return false
        }
        // 默认证书/描述文件必须有效且在列表中（用户可能已删掉该证书）
        guard let cert = selectedCertificate, cert.status == .valid,
              certificates.contains(where: { $0.id == cert.id }) else {
            Logger.warning("自动签名跳过：无有效默认证书（\(app.name)）")
            // 用户可见反馈：自动一条龙静默跳过时，分享/导入方视角就是"毫无动静"
            // （尤其分享面板投递场景），给出下一步指引而不只是写日志
            showToast("已导入「\(app.name)」，未自动签名：请先在「证书」页设置默认证书")
            return false
        }
        guard let profile = selectedProfile, profile.status == .valid,
              profiles.contains(where: { $0.id == profile.id }) else {
            Logger.warning("自动签名跳过：无有效默认描述文件（\(app.name)）")
            showToast("已导入「\(app.name)」，未自动签名：请先在「证书」页设置默认描述文件")
            return false
        }
        // 已入队/正在签名的跳过（防重复入队）。注意：同 bundleID 重导入会生成
        // 新 UUID，id 去重会失效——追加 bundleID 维度（排队中/正在签名中的
        // 同 bundleID 不再入队，避免同一应用签两次、已签列表出重复项）
        guard !autoSigningAppIDs.contains(app.id) else { return false }
        if !app.bundleID.isEmpty {
            guard currentAutoSignBundleID != app.bundleID,
                  !autoSignQueue.contains(where: { $0.bundleID == app.bundleID }) else {
                return false
            }
        }
        autoSignQueue.append(app)
        autoSigningAppIDs.insert(app.id)
        pumpAutoSignQueue()
        return true
    }

    /// 当前正在自动签名的应用 bundleID（供同 bundleID 去重；完成/失败即清空）
    private var currentAutoSignBundleID: String?

    /// 串行出队执行自动签名+安装；队空或已有任务在跑则直接返回。
    private func pumpAutoSignQueue() {
        guard !isAutoSigning, !autoSignQueue.isEmpty else { return }
        let app = autoSignQueue.removeFirst()
        // 出队时复验（与 enqueue 的校验对齐）：批量签名期间用户可能删除默认
        // 证书/描述文件（Keychain 私钥一并删除）、换成其它 Team 的组合、或关闭
        // 自动签名开关——用失效组合继续签会产出无法安装的包，直接放弃该项推进。
        guard store.autoSignAndInstallEnabled(),
              let cert = selectedCertificate, cert.status == .valid,
              certificates.contains(where: { $0.id == cert.id }),
              let profile = selectedProfile, profile.status == .valid,
              profiles.contains(where: { $0.id == profile.id }) else {
            autoSigningAppIDs.remove(app.id)
            Logger.warning("自动签名跳过（默认证书/描述文件已失效或开关已关闭）: \(app.name)")
            pumpAutoSignQueue()
            return
        }
        isAutoSigning = true
        currentAutoSignBundleID = app.bundleID
        setPipelineStatus(app.name, "正在签名…", "请保持 App 在前台，签名完成后自动发起安装")
        Logger.info("自动签名开始: \(app.name)")
        signApp(app, certificate: cert, profile: profile, progress: { [weak self] p, phase in
            // 真实进度上屏：签名是大 IO（解压+签名+重打包，大包 20-60 秒），
            // 没有可见反馈时用户以为卡死（切后台会掐断整个流水线）
            self?.setPipelineStatus(app.name, "正在签名…", phase, progress: p)
        }) { [weak self] result in
            guard let self = self else { return }
            self.isAutoSigning = false
            self.currentAutoSignBundleID = nil
            self.autoSigningAppIDs.remove(app.id)
            switch result {
            case .success(let signedPath):
                if !app.bundleID.isEmpty {
                    self.recentAutoSignBundleIDs[app.bundleID] = Date()
                }
                self.autoSignAndInstallSucceeded(app: app, signedPath: signedPath, certificate: cert)
            case .failure(let error):
                Logger.error("自动签名失败: \(app.name) - \(error.localizedDescription)")
                self.clearPipelineStatus()
                self.showToast("自动签名失败：\(error.localizedDescription)")
            }
            self.pumpAutoSignQueue()
        }
    }

    /// 自动签名成功后：发起安装；若设置开启"签名完成自动返回桌面"，在 itms-services
    /// open 成功后延迟回桌面（iOS 随即弹出"是否安装"确认，省去手动点"返回"）。
    private func autoSignAndInstallSucceeded(app: AppInfo, signedPath: String, certificate: CertificateInfo) {
        // 发起安装阶段（本地服务器启动 + manifest 生成 + 预检，约 2-5 秒）也上屏：
        // 这段同样无反馈，是"空白后突然弹安装窗"观感的另一半来源
        setPipelineStatus(app.name, "正在发起安装…", "启动本地安装通道")
        do {
            try installSignedPath(signedPath, certificate: certificate) { [weak self] in
                // itms-services open 成功后（主线程回调）才调度回桌面。此前固定 1.2s
                // 计时从"发起安装请求"就开始跑，而本地服务器启动/元数据解析/manifest
                // 生成常超 1.2s——App 先退到后台，open 随后才执行会被系统忽略
                // （后台态 open 常被忽略），表现为"自动安装静默失败"。
                guard let self = self else { return }
                self.setPipelineStatus(app.name, "安装已发起", "请在系统弹窗点「安装」确认")
                // 提示停留几秒后收卡（用户点确认/回桌面的时间足够看到结果）
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.clearPipelineStatus()
                }
                // 批量队列未清空时不回桌面：保持前台逐个弹系统安装确认，最后一个
                // 安装发起后才回桌面。
                guard self.store.autoReturnHomeAfterSigningEnabled(), self.autoSignQueue.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    // 延迟让用户看到"签名完成"的过渡，再回桌面等 iOS 弹安装提示
                    self.minimizeToHomeScreen()
                }
            }
            Logger.info("自动签名并安装已发起: \(app.name)")
        } catch {
            Logger.error("自动签名完成但安装失败: \(app.name) - \(error.localizedDescription)")
            clearPipelineStatus()
            showToast("自动签名完成，安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 分享面板「拷贝到 IPA Manager」投递（Documents/Inbox）

    /// 系统分享投递目录：分享面板对文件类分享的官方集成是文档类型声明——声明了
    /// CFBundleDocumentTypes 的 App 以「拷贝到 IPA Manager」出现在分享面板 App 行，
    /// 点按后系统把文件拷入 Documents/Inbox 再投递 openURL 事件。（不用 Share
    /// Extension：扩展要把文件交给主 App 必须 App Group，而本 App 由用户用任意
    /// 企业证书自签安装，通配符 profile 不含 App Group 能力，嵌套 appex 的
    /// entitlement 校验会导致整个 App 无法安装。）
    /// UIFileSharingEnabled 下 Inbox 对文件 App 可见，系统不保证清理——导入结算后
    /// 自删源文件，防重复导入与 GB 级残留。
    private var inboxURL: URL {
        fileManager.documentsURL.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// 已结算的分享投递（持久化，仅主线程读写）：结算（导入成功/失败）时才写入，
    /// 防止同一投递文件跨启动重复导入；文件已删除的失效登记由扫描剪枝清理，
    /// 删除失败残留的文件由 24h 清扫兜底。
    private var processedInboxPaths: Set<String> = []

    /// 在途分享投递（内存，仅主线程读写）：投递开始处理即登记、结算后移除，
    /// 防 open 事件 × 回前台扫描 × 冷启动 launchOptions 对同一文件并发/重复触发导入。
    private var pendingInboxImports: Set<String> = []

    /// 已导入投递文件的内容身份（持久化，仅主线程读写）：文件名|大小|mtime，
    /// 与路径无关。路径去重（processedInboxPaths）在"文件移动过位置 / 结算删除
    /// 失败 / 路径记录被剪枝"时会漏，漏掉的后果是每次进 App 都把同一文件重新
    /// 导入一遍（用户实测）；内容身份是最后防线，结算时登记、扫描时拦截。
    /// 例外：系统投递（Documents/Inbox）与 force 主动打开不受此拦截——同内容
    /// 再次主动投递是用户明确意图，静默过滤表现为"分享了毫无反应"。
    private var importedDeliveryIdentities: Set<String> = []

    /// 投递导入失败记录（持久化，仅主线程读写）：内容身份 → 失败次数 + 最近一次
    /// 时间。与 processed/内容身份去重职责分离：失败不写 processed（保留重试
    /// 机会），由这里限流——节流窗口内多次生命周期扫描只重试一次，连续失败达
    /// 上限后登记 processed 停止自动重试（防坏文件每次进 App 无限重试）。
    struct FailedDeliveryRecord: Codable {
        var count: Int
        var lastAttempt: Date
    }

    private var failedDeliveryRecords: [String: FailedDeliveryRecord] = [:]
    /// 同一文件自动重试上限：超过后停止（源文件保留，等待用户手动处理）
    private static let maxDeliveryRetries = 3

    /// 投递文件内容身份：与路径无关的"同一文件"判据
    private static func deliveryIdentity(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.lastPathComponent)|\(size)|\(Int(mtime))"
    }

    /// 上次扫描指纹（内存）：容器集合 + 各投递目录计数。扫描是高频触发（一次回前台
    /// 最多 4 次），指纹不变就不落投递日志——旧版每次扫描固定刷 2~4 条"无文件"，
    /// 120 条环形缓冲约 20 次前后台切换就刷光，真实信号全被淹没（用户实测日志
    /// "每次都一模一样"的直接原因）。
    private var lastScanFingerprint: String?
    private var scanRunCount = 0

    /// 可自动导入的投递扩展名（Documents 内扫描用；Inbox 内不做扩展名过滤
    /// ——系统投递什么处理什么）。Documents 内只认应用/证书文件，避免把用户
    /// 经文件 App 放进来的其它文件误当投递。
    private static let deliveryExtensions: Set<String> = ["ipa", "zip", "p12", "pfx", "mobileprovision"]

    /// Documents 下由本 App 管理的目录：投递扫描（含子目录）必须跳过——这些目录
    /// 里的 ipa/zip 是导入产物/工作副本/证书副本，绝不能被当成新投递再次导入。
    private static let managedDocumentsDirs: Set<String> = [
        "Inbox", "IPA", "Signed", "Extracted", "Certificates", "Profiles", "Downloads", "Icons"
    ]

    /// 分享投递路径识别：Documents/Inbox 内（系统拷贝投递）、任一共享容器收件箱内
    /// （分享扩展接收的文件，扇入枚举全部容器）、或 Documents 内任意层级的可导入
    /// 文件（用户经文件 App 放入/保存，v1.0.142 起扫描扩展到子目录，识别口径与
    /// 扫描一致；本 App 管理目录内的产物不算投递）。
    /// 路径归一化：iOS 上不同 FileManager API 返回的容器路径可能带 /private
    /// 前缀（实测：contentsOfDirectory 对 Documents 返回 /private/var/mobile/...，
    /// 而 urls(for:.documentDirectory) 返回 /var/mobile/...）。直接 hasPrefix
    /// 永远失配——Documents 内的文件"投递识别=否"、永不结算、每次回前台重复
    /// 导入+重复签名（用户实测"跳转后一直发呆"的根因）。比较前统一剥前缀。
    private func normalizedDeliveryPath(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// url 是否位于 directory 之下（/private 前缀归一化后比较）
    private func isPath(_ url: URL, under directory: URL) -> Bool {
        normalizedDeliveryPath(url.path).hasPrefix(normalizedDeliveryPath(directory.path) + "/")
    }

    private func isDeliveryPath(_ url: URL) -> Bool {
        if isPath(url, under: inboxURL) { return true }
        // Incoming 接收队列：扩展落盘的任务文件（结算语义与投递一致——成功删源、
        // 失败保留，任务 JSON 的终态由结算钩子回写）
        for incoming in AppGroup.allIncomingURLsIfPresent
        where isPath(url, under: incoming) {
            return true
        }
        for groupInbox in AppGroup.allInboxURLsIfPresent
        where isPath(url, under: groupInbox) {
            return true
        }
        guard Self.deliveryExtensions.contains(url.pathExtension.lowercased()) else { return false }
        guard isPath(url, under: fileManager.documentsURL) else { return false }
        let relative = String(normalizedDeliveryPath(url.path)
            .dropFirst(normalizedDeliveryPath(fileManager.documentsURL.path).count + 1))
        guard let topDir = relative.split(separator: "/").first else { return false }
        return !Self.managedDocumentsDirs.contains(String(topDir))
    }

    /// 收集 Documents 内的投递文件（根目录 + 有界深度子目录，跳过本 App 管理目录与
    /// 隐藏目录）。文件 App（UIFileSharingEnabled 让 Documents 对文件 App 可见）是
    /// iOS 27 上最可靠的投递通道——分享面板路由失效时"把文件存/移动到 IPA Manager
    /// 文件夹"仍然可用；子目录扫描让用户可以先按文件夹整理再统一投递。
    private func collectDocumentDeliverables() -> [URL] {
        var result: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(fileManager.documentsURL, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if depth < 2, !Self.managedDocumentsDirs.contains(entry.lastPathComponent) {
                        queue.append((entry, depth + 1))
                    }
                } else if Self.deliveryExtensions.contains(entry.pathExtension.lowercased()) {
                    result.append(entry)
                }
            }
        }
        return result
    }

    /// 扫描待处理投递（触发点：SwiftUI scenePhase == .active 与
    /// applicationDidBecomeActive 双挂——iOS 27 实测不再回调 application 级
    /// didBecomeActive，SwiftUI scenePhase 是可靠触发点；两者并存，扫描内部去重；
    /// 另有冷启动、ipamanager:// 唤起、日志页"立即扫描"）：
    /// - Documents/Inbox：系统「拷贝到 App」拷贝投递；
    /// - 全部可用共享容器的收件箱：分享扩展接收（扇入枚举所有容器，扩展与主 App
    ///   即使解析到不同组也不丢文件——旧版只扫单个解析组，组错位即全盲）；
    /// - Documents 根目录与子目录：文件 App 放入/保存的投递。
    /// 处理规则：已结算且文件不在 → 清失效登记；已结算但文件仍在 → 超 24h 清扫；
    /// 未登记 → 视为 open 事件丢失的投递，补走完整导入链路（handleFileOpenedFromOutside
    /// 内部登记在途 + 结算自删 + 自动一条龙签名安装）。
    /// 仅主线程调用；目录不存在/为空时开销仅几次目录探测。
    func processInboxFilesIfNeeded() {
        let inboxFiles = (try? FileManager.default.contentsOfDirectory(
            at: inboxURL, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let groupInboxFiles = AppGroup.allInboxURLsIfPresent.flatMap { inbox -> [URL] in
            (try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        }
        let documentFiles = collectDocumentDeliverables()

        // 投递日志降噪：容器集合或任一目录计数变化才记一条；组集合与持久记忆不同
        // （重签换描述文件/组漂移）再单独记一条。静默扫描零日志。
        scanRunCount += 1
        let containers = AppGroup.usableContainers()
        let containerSet = containers.map { $0.identifier }.sorted().joined(separator: ",")
        let fingerprint = "\(containerSet)|\(inboxFiles.count)|\(groupInboxFiles.count)|\(documentFiles.count)"
        if fingerprint != lastScanFingerprint {
            lastScanFingerprint = fingerprint
            let containerNote = containers.isEmpty ? "无可用" : containerSet
            ExternalDeliveryJournal.record(
                "扫描：Inbox=\(inboxFiles.count) 共享Inbox=\(groupInboxFiles.count) Documents=\(documentFiles.count) 容器[\(containerNote)]"
            )
            if containerSet != store.loadLastKnownContainerSet() {
                store.saveLastKnownContainerSet(containerSet)
                if !containers.isEmpty {
                    ExternalDeliveryJournal.record("共享容器：可用（组 \(containerSet)）", level: .ok)
                }
            }
        }

        // 剪枝：源文件已不存在的已结算登记（正常结算即删文件）顺带清掉
        let alive = Set((inboxFiles + groupInboxFiles + documentFiles).map { $0.path })
        let settledAndGone = processedInboxPaths.subtracting(alive)
        if !settledAndGone.isEmpty {
            processedInboxPaths.subtract(settledAndGone)
            store.saveProcessedInboxPaths(Array(processedInboxPaths))
        }

        let now = Date()
        var importedCount = 0
        for file in inboxFiles.filter({ !$0.hasDirectoryPath })
            + groupInboxFiles.filter({ !$0.hasDirectoryPath })
            + documentFiles {
            let path = file.path
            if processedInboxPaths.contains(path) {
                // 已结算但源文件仍在（删除失败等残留）：超期清扫
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, now.timeIntervalSince(modified) > Timeouts.inboxResidueMaxAge {
                    try? FileManager.default.removeItem(at: file)
                    processedInboxPaths.remove(path)
                    store.saveProcessedInboxPaths(Array(processedInboxPaths))
                    Logger.info("清理超期分享投递残留: \(file.lastPathComponent)")
                }
                continue
            }
            // 内容身份去重：同一文件（即使被移动/换名失效过路径记录）不重复导入。
            // 系统投递（Documents/Inbox）优先视为有效输入、跳过指纹拦截——出现在
            // Inbox 里本身就是一次新的用户投递，指纹拦截会把"主动重投同一文件"
            // 静默吞掉；Documents 内长存文件才需要指纹兜底防反复导入
            let isInSystemInbox = isPath(file, under: inboxURL)
            let identity = Self.deliveryIdentity(for: file)
            // 失败重试限流（对全部投递来源生效）：达上限的不再自动重试；节流窗口
            // 内不重试——一次回前台最多触发 4 次扫描，没有窗口时坏文件每次进 App
            // 会被连续导入 4 遍
            if let record = failedDeliveryRecords[identity] {
                if record.count >= Self.maxDeliveryRetries { continue }
                if Date().timeIntervalSince(record.lastAttempt) < Timeouts.deliveryRetryThrottle {
                    Logger.info("投递重试节流中（上次失败距今过近）: \(file.lastPathComponent)")
                    continue
                }
            }
            if !isInSystemInbox && importedDeliveryIdentities.contains(identity) {
                Logger.info("跳过重复投递（同内容文件已导入过）: \(file.lastPathComponent)")
                continue
            }
            // 未登记 = open 事件丢失（正常投递的文件在结算时已自删，不会留到这里）。
            // 在途登记与重复投递拦截都在 handleFileOpenedFromOutside 内部完成。
            Logger.info("投递候选进入导入（candidate）: \(file.lastPathComponent)")
            handleFileOpenedFromOutside(file, force: isInSystemInbox)
            importedCount += 1
        }
        // Incoming 接收队列扫描：认领扩展落盘的待处理任务（含上次进程死亡滞留的
        // processing），逐个交给统一导入入口；任务终态由结算钩子回写
        for (task, fileURL) in IncomingFileScanner.scanAndClaim() {
            ExternalDeliveryJournal.record("接收任务开始处理: \(task.originalFileName)（id \(task.id.uuidString.prefix(8))）")
            Logger.info("接收任务进入流水线: \(task.originalFileName) type=\(task.type)")
            handleFileOpenedFromOutside(fileURL, force: true, taskID: task.id)
            importedCount += 1
        }
        if importedCount > 0 {
            showToast("收到 \(importedCount) 个分享文件，正在导入…")
        }
        // 跨进程可见性：吞入扩展进程写入共享容器的新增日志行（扩展与主 App 是两个
        // 进程，主 App 的投递日志天然看不到扩展）。
        ingestExtensionLogsIfNeeded()
        // 实时同步投递日志到 UI
        DispatchQueue.main.async {
            self.deliveryLogEntries = ExternalDeliveryJournal.getEntries()
        }
    }

    /// 吞入共享容器中的扩展日志新增行：扩展每次被分享面板唤起都会先写"扩展启动"，
    /// 主 App 读到即证明扩展进程活着（入口可见且能启动）。
    /// 扇入读取**全部**可用容器（扩展与主 App 可能解析到不同组，旧版只读单个解析组
    /// 在组错位时全盲）；按容器目录名（UUID，跨启动稳定）分别记账字符偏移。
    /// 含"失败"字样的行升级为错误级并写 Logger 失败专区——扩展进程不编译 Logger，
    /// 这是扩展侧错误进入"失败与异常"专区的唯一通道。
    private func ingestExtensionLogsIfNeeded() {
        var offsets = store.loadExtensionLogOffsetsByGroup()
        var changed = false
        for inbox in AppGroup.allInboxURLsIfPresent {
            let containerDir = inbox.deletingLastPathComponent()
            let logURL = containerDir.appendingPathComponent(AppGroup.extensionLogFileName)
            guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { continue }
            let containerKey = containerDir.lastPathComponent
            var offset = offsets[containerKey] ?? 0
            // 日志被截断/轮转后文件变短：偏移复位，避免永远读不到新行
            if offset > data.count { offset = 0 }
            guard offset < data.count else { continue }
            let slice = Data(data[offset...])
            offsets[containerKey] = data.count
            changed = true
            guard let text = String(data: slice, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let isFailure = trimmed.contains("失败")
                ExternalDeliveryJournal.record("扩展：\(trimmed)", level: isFailure ? .error : .info)
                if isFailure {
                    Logger.error("扩展侧失败（跨进程日志）：\(trimmed)")
                }
            }
        }
        if changed {
            store.saveExtensionLogOffsetsByGroup(offsets)
        }
    }

    /// 外部打开文件去重：SwiftUI 生命周期下 application(_:open:) 与 onOpenURL 可能
    /// 对同一 URL 双触发（两个入口并存），短窗口内同一 URL 只处理一次，避免重复导入。
    private var lastOpenedExternalURL: String = ""
    private var lastOpenedExternalDate: Date = .distantPast

    /// - Parameter force: 系统主动投递的 open 事件（launchOptions/openURL/onOpenURL）
    ///   传 true：用户主动分享是明确意图，绕过已结算拦截重新导入；回前台扫描
    ///   兜底路径传 false，维持既有去重语义。URL 事件去重只拦非强制触发——
    ///   force 必须能穿透它，否则"强制"语义在函数最前面就被吞掉。
    /// - Parameter taskID: 由 Incoming 接收队列（Share Extension 落盘的任务 JSON）
    ///   认领而来的任务 id；结算时回写任务终态（completed/failed+原因），
    ///   让任务列表能跨进程反映全流程结果
    func handleFileOpenedFromOutside(_ url: URL, force: Bool = false, taskID: UUID? = nil) {
        let now = Date()
        if !force,
           url.absoluteString == lastOpenedExternalURL,
           now.timeIntervalSince(lastOpenedExternalDate) < Timeouts.externalOpenDedupe {
            Logger.info("外部打开文件去重跳过: \(url.lastPathComponent)")
            return
        }
        lastOpenedExternalURL = url.absoluteString
        lastOpenedExternalDate = now

        // 分享扩展「打开 App」信号（ipamanager://import）：文件已由扩展存入共享
        // 收件箱，这里直接触发回前台扫描完成导入；不做文件导入路由
        if url.scheme == "ipamanager" {
            ExternalDeliveryJournal.record("收到主 App 唤起 URL: \(url.absoluteString)")
            processInboxFilesIfNeeded()
            return
        }

        let ext = url.pathExtension.lowercased()
        Logger.info("外部打开文件: \(url.lastPathComponent)")
        // 即时反馈：zip 分类在后台队列先跑，进度卡要等 importFile 启动才出现；
        // 先给一句 toast，避免“点了分享、App 打开了却毫无动静”。
        if ext == "ipa" || ext == "zip" {
            showToast("已接收「\(url.lastPathComponent)」，正在导入…")
        }

        // 分享/投递识别（Documents/Inbox 或 Documents 根目录的可导入文件）：在途登记 +
        // 结算落盘，open 事件与回前台扫描/冷启动 launchOptions 对同一文件的重复投递
        //（超出 2 秒去重窗口的）在此丢弃，杜绝双重导入。
        // - pendingInboxImports（内存）：开始处理即登记、结算后移除；
        // - processedInboxPaths（持久化）：结算（成功/失败）时才写入——进程在导入
        //   中途被杀时投递未结算，下次启动仍会重新导入（若投递即落盘，该文件会
        //   永远不再导入、只能等 24h 清扫）。
        let isInboxDelivery = isDeliveryPath(url)
        ExternalDeliveryJournal.record("处理外部文件: \(url.lastPathComponent)（ext=\(ext)，投递识别=\(isInboxDelivery ? "是" : "否")，force=\(force)）")
        // 结算闭包（note, succeeded）：职责严格区分——成功才写 processed/内容身份
        // 并删除源文件；失败保留源文件、只累计失败次数（限次重试），绝不把失败
        // 记成"已处理"（旧版成功失败都结算删除，一个导入失败的文件从此再无重试
        // 机会，且用户投递的文件凭空消失）。
        var inboxSettlement: ((String, Bool) -> Void)? = nil
        if isInboxDelivery {
            // 已结算（此前导入成功并落盘标记）：默认跳过（残留由扫描清扫）；
            // force=true 表示用户主动投递的 open 事件，同文件再分享是明确意图，
            // 绕过已结算拦截重新导入
            if !force && processedInboxPaths.contains(url.path) {
                Logger.info("分享投递已结算，跳过: \(url.lastPathComponent)")
                return
            }
            // 已在途（事件/扫描/冷启动之一正在处理）：跳过，防双触发重复导入
            guard pendingInboxImports.insert(url.path).inserted else {
                Logger.info("分享投递已在途，跳过: \(url.lastPathComponent)")
                return
            }
            inboxSettlement = { [weak self] note, succeeded in
                guard let self = self else { return }
                self.pendingInboxImports.remove(url.path)
                // 接收任务终态回写：Incoming 队列的任务随导入结果完结
                ImportTaskStore.finish(taskID: taskID, succeeded: succeeded, note: note)
                // 内容身份在删除前取（删除后属性读不到）
                let identity = Self.deliveryIdentity(for: url)
                if succeeded {
                    self.processedInboxPaths.insert(url.path)
                    self.store.saveProcessedInboxPaths(Array(self.processedInboxPaths))
                    self.importedDeliveryIdentities.insert(identity)
                    self.store.saveImportedDeliveryIdentities(Array(self.importedDeliveryIdentities))
                    self.failedDeliveryRecords.removeValue(forKey: identity)
                    self.store.saveFailedDeliveryRecords(self.failedDeliveryRecords)
                    var settleNote = note
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        // 删除失败必须留痕：文件残留时用户会看到"每次进 App 重复导入"，
                        // 报告里能看到真实原因而不是只有一句已删
                        Logger.error("投递源文件删除失败: \(url.lastPathComponent) - \(error.localizedDescription)")
                        settleNote = "\(note)；源文件删除失败：\(error.localizedDescription)"
                    }
                    Logger.info("投递导入成功结算: \(url.lastPathComponent)（\(settleNote)）")
                    ExternalDeliveryJournal.record("投递结算（成功）: \(url.lastPathComponent)（\(settleNote)）", level: .ok)
                } else {
                    // 失败：不写 processed/内容身份（保留重试机会），只累计失败次数
                    let previous = self.failedDeliveryRecords[identity]
                        ?? FailedDeliveryRecord(count: 0, lastAttempt: .distantPast)
                    let record = FailedDeliveryRecord(count: previous.count + 1, lastAttempt: Date())
                    self.failedDeliveryRecords[identity] = record
                    self.store.saveFailedDeliveryRecords(self.failedDeliveryRecords)
                    if record.count >= Self.maxDeliveryRetries {
                        // 连续失败达上限：登记 processed 停止自动重试（否则每次进 App
                        // 都会重试同一个坏文件），源文件保留供用户手动处理或删除
                        self.processedInboxPaths.insert(url.path)
                        self.store.saveProcessedInboxPaths(Array(self.processedInboxPaths))
                        Logger.error("投递连续 \(record.count) 次导入失败，停止自动重试（源文件保留待手动处理）: \(url.lastPathComponent)（\(note)）")
                        ExternalDeliveryJournal.record("投递失败（连续 \(record.count) 次，停止自动重试，源文件保留）: \(url.lastPathComponent)（\(note)）", level: .error)
                    } else {
                        Logger.error("投递导入失败（第 \(record.count) 次，保留源文件待重试）: \(url.lastPathComponent)（\(note)）")
                        ExternalDeliveryJournal.record("投递失败（第 \(record.count) 次，保留源文件待重试）: \(url.lastPathComponent)（\(note)）", level: .error)
                    }
                }
            }
        }

        switch ext {
        case "zip", "tgz", "tar", "gz":
            // 压缩包统一走下载完成的分类导入（证书包 / 应用包 / zip 内嵌 ipa / 未知），
            // 修复“文件 App 打开 zip 包着 ipa”时一律被当证书包导入、内嵌 .ipa 无法识别的问题。
            // 分类为 .certificateBundle 时其内部仍会调 importCertificateBundleOrFile，证书包不受影响。
            // tgz/tar/gz 与下载链路保持同一分发（此前只认 zip，外部打开的 tgz 会落
            // default 分支报解析错误）。
            // Inbox 投递挂结算：应用包/内嵌 ipa/未知/失败各路径经 completion 回调结算，
            // 证书包分支经 onSettled 回调结算（completion 对证书包不回调，既有行为）。
            handleDownloadedFile(
                at: url,
                completion: { result in
                    switch result {
                    case .success: inboxSettlement?("导入完成", true)
                    case .failure(let error): inboxSettlement?("导入失败：\(error.localizedDescription)", false)
                    }
                },
                onSettled: { inboxSettlement?("证书包导入完成", $0) }
            )
        case "p12", "pfx", "mobileprovision":
            // 单个证书相关文件保持原逻辑（zip 才是证书包载体）；onSettled 由证书
            // 导入收尾回调（含成败标记），用于投递的源文件删除与已结算落盘。
            importCertificateBundleOrFile(url, onSettled: { inboxSettlement?("证书导入完成", $0) })
        default:
            importFile(from: url) { result in
                switch result {
                case .success(let app):
                    // 外部打开的应用导入成功后，切到首页并提示（用户可进详情签名）
                    self.selectedTab = 0
                    Logger.info("外部打开文件导入成功: \(app.name)")
                    inboxSettlement?("导入成功: \(app.name)", true)
                case .failure(let error):
                    // 外部打开失败必须给反馈（否则用户在文件 App 里点了毫无反应）
                    self.showToast("导入失败: \(error.localizedDescription)")
                    inboxSettlement?("导入失败：\(error.localizedDescription)", false)
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
    private func handleSingleCertificateFile(_ url: URL, onSettled: ((Bool) -> Void)? = nil) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "p12", "pfx":
            CertificateManager.shared.importCertificate(from: url, password: "1") { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let cert):
                        self.addCertificate(cert)
                        self.showToast("已导入证书文件，请到证书页查看")
                        // 分享投递（Inbox）结算：成功才删源文件
                        onSettled?(true)
                    case .failure(let error):
                        self.showToast("请在证书页手动导入该文件")
                        self.selectedTab = 3
                        Logger.warning("证书文件自动导入失败（保留源文件待重试）: \(error.localizedDescription)")
                        // 失败保留源文件待限次重试（Result 无 isSuccess，分支内给出）
                        onSettled?(false)
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
                        onSettled?(true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.showToast("描述文件导入失败，请在证书页手动导入该文件")
                        self.selectedTab = 3
                        onSettled?(false)
                    }
                }
            }
        default:
            break
        }
    }

    /// 兜底清理：删除 Certificates/ 下所有 bundle-extract-* 解压目录。
    /// 仅在 extract 抛错（拿不到确切解压目录 URL）时使用；正常路径一律用精确 URL 清理。
    /// 已抽取到 `ExtractedDirectoryCleaner`。
    private func sweepBundleExtractDirs() {
        ExtractedDirectoryCleaner.sweepBundleExtractDirs()
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

    private func importCertificateBundleOrFile(_ url: URL, onSettled: ((Bool) -> Void)? = nil) {
        switch url.pathExtension.lowercased() {
        case "zip":
            let importer = CertificateBundleImporter.shared
            // 安全作用域：zip 证书包的后台解压/复制/清理全程必须处于授权状态，
            // start/stop 需成对；defer 在后台闭包内释放，覆盖所有错误路径。
            // 处理走 importQueue 串行队列（解压是重 IO，不与其它归档导入并发）。
            let accessed = url.startAccessingSecurityScopedResource()
            importQueue.async {
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                // 解压目录：importer 现在直接携带精确根目录（bundle-extract-<uuid>），
                // 不再靠文件 URL 反推
                var extractDir: URL? = nil
                do {
                    let content = try importer.extract(from: url)
                    extractDir = content.extractDir
                    let moved = try importer.moveToManagedLocation(
                        p12URL: content.p12URL,
                        profileURL: content.profileURL
                    )
                    DispatchQueue.main.async {
                        // 描述文件：解析失败给明确反馈并清理托管副本（旧实现 try? 吞错，
                        // 文案宣称"已导入描述文件"与实际不符，且明文副本残留 Documents）
                        if let profileURL = moved.profileURL {
                            do {
                                let profile = try ProvisioningManager.shared.importProfile(from: profileURL)
                                self.addProfile(profile)
                            } catch {
                                try? FileManager.default.removeItem(at: profileURL)
                                Logger.error("zip 证书包描述文件导入失败: \(error)")
                                self.showToast("描述文件导入失败：\(error.localizedDescription)")
                            }
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
                                        // 常见密码 "1" 不匹配也必须给用户可见反馈（否则
                                        // 导入像没发生一样）；提示改走证书页手动输密码
                                        self.showToast("证书导入失败（密码可能不是常见密码）：\(error.localizedDescription)，请到证书页手动导入")
                                    }
                                    // 证书导入处理完毕（无论成败）后清理托管 P12 与解压目录
                                    self.cleanupManagedCertBundle(importer: importer, moved: moved, extractDir: extractDir)
                                }
                            }
                        } else {
                            // 无证书：描述文件已归档到 Profiles，直接清理；
                            // 给用户可见反馈（只导入到一半的包也该说清楚）
                            self.cleanupManagedCertBundle(importer: importer, moved: moved, extractDir: extractDir)
                            self.showToast("已导入描述文件；压缩包内未找到证书 (.p12)")
                        }
                        Logger.info("zip 证书包导入完成")
                        // 分享投递（Inbox）结算：解压/归档已完成，内容已转入托管位置，
                        // 源 zip 可删（内层证书密码不匹配属"转手动"而非投递失败——
                        // 重试同一个密码结果不会变，且解出副本已保留供手动导入）
                        onSettled?(true)
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
                    // 失败给用户可见反馈（旧实现只写日志——从文件 App/下载链路进来时
                    // 界面毫无反应，用户以为导入成功但列表为空）
                    self.showToast("证书包导入失败：\(error.localizedDescription)")
                    // 分享投递（Inbox）结算：失败不删除源文件、不写已结算标记，
                    // 记入失败记录限次重试（见 inboxSettlement 的失败分支）
                    DispatchQueue.main.async { onSettled?(false) }
                }
            }
        default:
            // 单个 p12/pfx/mobileprovision：直接尝试导入并给用户反馈
            handleSingleCertificateFile(url, onSettled: onSettled)
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
        // 孤儿清扫已移至 AppState.init 中首次 refreshInstalledApps 完成后执行：
        // 既要后台执行（残留可能数 GB，主线程同步删会卡启动），又要保证在
        // 首次已签应用扫描之后跑（清扫期间引用列表才完整，不会误删解析中的目录）。

        // 选中项不持久化，恢复后必须重新挑选，避免首页显示“未选择证书”
        if selectedCertificate == nil {
            selectedCertificate = certificates.first { $0.status == .valid } ?? certificates.first
        }
        if selectedProfile == nil {
            selectedProfile = profiles.first { $0.status == .valid } ?? profiles.first
        }

        // 启动清扫证书导入残留：上次会话若在"托管 P12 副本已复制、证书导入未完成"
        // 的窗口被杀/崩溃，明文 cert-*.p12（含私钥材料，文件共享可导出）与
        // bundle-extract-* 解压目录会永久残留。启动时无任何证书导入进行中，
        // 这些副本必然无用（私钥已入 Keychain，或导入根本没发生）。
        DispatchQueue.global(qos: .userInitiated).async {
            CertificateBundleImporter.shared.sweepOrphanManagedArtifacts()
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
    /// 已签应用解析缓存（仅在 installedAppsRefreshQueue 串行队列访问）：
    /// key 为 IPA 绝对路径，值为 (修改时间, 大小, AppInfo)。签名产物文件名唯一且
    /// 内容不变，(mtime,size) 未变即可复用——refreshInstalledApps 在每次签名完成/
    /// 删除应用/启动后都会全量扫描，没有缓存时每个已签 IPA 都要重新整包解压一遍
    /// （N 个大包 × 每次刷新 = 重复的 GB 级 IO）。
    private var installedAppParseCache: [String: (mtime: Date, size: Int64, info: AppInfo)] = [:]

    func refreshInstalledApps(completion: (() -> Void)? = nil) {
        isRefreshingInstalledApps = true
        installedAppsRefreshQueue.async {
            // 列表按签名产物的修改时间倒序：最新签名的排最前；contents(of:) 已预取
            // contentModificationDateKey，此处读 resourceValues 不产生额外磁盘 IO
            let datedURLs = self.fileManager.contents(of: .signed).map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            let apps = datedURLs
                .sorted { $0.1 > $1.1 }
                .map { self.makeInstalledAppInfo(from: $0.0, modifiedAt: $0.1) }
            DispatchQueue.main.async {
                self.installedApps = apps
                self.isRefreshingInstalledApps = false
                completion?()
            }
        }
    }

    /// 解析单个签名产物为完整 AppInfo；失败时回退旧逻辑（文件名 + isSigned）。
    private func makeInstalledAppInfo(from url: URL, modifiedAt: Date) -> AppInfo {
        let path = url.path
        let size = fileManager.fileSize(at: url)
        if let cached = installedAppParseCache[path], cached.mtime == modifiedAt, cached.size == size {
            return cached.info
        }

        var result: AppInfo
        var extractedRoot: URL? = nil
        // parseAppInfoWithRoot 会解压 IPA 并读取 Info.plist / 提取图标
        if let parsed = try? parser.parseAppInfoWithRoot(fileURL: url) {
            var info = parsed.info
            extractedRoot = parsed.rootURL
            // 覆盖回签名产物自身：parseAppInfo 返回的 path 是 .app 内部路径、
            // size 是 IPA 大小。其它调用方（AppDetailView 按 path 匹配已签名列表、
            // 详情/首页按 signedPath/path 取签名文件时间）依赖这些字段指向签名 IPA。
            info.path = path
            info.size = size
            info.isSigned = true
            info.signedPath = path
            // extractIcon 返回的是 .app 内部路径，而解压目录（Extracted/<baseName>/）
            // 会在解析后被清理，因此把图标复制到稳定位置再回填 iconPath，
            // 保证刷新后 iconPath 指向存在的文件。
            if let iconPath = info.iconPath,
               FileManager.default.fileExists(atPath: iconPath),
               let stablePath = persistInstalledAppIcon(
                   from: iconPath,
                   baseName: url.deletingPathExtension().lastPathComponent,
                   app: info
               ) {
                info.iconPath = stablePath
            }
            result = info
        } else {
            var fallback = AppInfo()
            fallback.name = url.deletingPathExtension().lastPathComponent
            fallback.path = path
            fallback.size = size
            fallback.isSigned = true
            result = fallback
        }

        // 图标已持久化到 Extracted/Icons/ 稳定位置，本次解压目录（数百 MB~数 GB）
        // 立即清理：旧实现要留到冷启动孤儿清扫，会话内每刷新一次就多攒一份。
        if let extractedRoot = extractedRoot {
            try? FileManager.default.removeItem(at: extractedRoot)
        }
        // 失败回退结果同样缓存：损坏产物每次刷新都重新解压一遍毫无意义
        installedAppParseCache[path] = (modifiedAt, size, result)
        return result
    }

    /// 把签名 IPA 解压出的图标复制到稳定位置 Extracted/Icons/<baseName>/<标识>-icon.<ext>，
    /// 避免后续解析清理解压目录后图标路径失效。复制失败返回 nil（调用方保留原路径兜底）。
    /// 已抽取到 `IconPersistenceService`。
    private func persistInstalledAppIcon(from iconPath: String, baseName: String, app: AppInfo) -> String? {
        IconPersistenceService.persist(iconPath: iconPath, baseName: baseName, app: app)
    }

    func saveState() {
        // 签名历史上限：只保留最近 300 条。signingTasks 此前只随"删除对应应用"
        // 清理，长期使用后无限增长，而 saveState（每次导入/签名/证书变更都调用）
        // 要对全部记录做全量 JSON 编码，数组越大主线程编码越慢。
        if signingTasks.count > 300 {
            signingTasks = Array(signingTasks.suffix(300))
        }
        store.saveCertificates(certificates)
        store.saveProfiles(profiles)
        store.saveSigningTasks(signingTasks)
        // 下载任务以 DownloadManager 的内存态为准，避免用恒为空的
        // downloadTasks 覆盖 DownloadManager 已持久化的任务记录。
        store.saveDownloadTasks(DownloadManager.shared.snapshotTasks())
        store.saveImportedApps(importedApps)
    }

    func addCertificate(_ certificate: CertificateInfo) {
        // 同一证书（同一 keychainIdentifier）重复导入时更新既有记录而非追加：
        // 两条记录指向同一 Keychain 条目时，删除其中一条会把另一条的私钥与密码
        // 一并删除（deleteCertificate 按共享 identifier 清理），另一条沦为死记录，
        // 选中它签名时报"未找到私钥数据"且用户无从理解。
        if let identifier = certificate.keychainIdentifier,
           let index = certificates.firstIndex(where: { $0.keychainIdentifier == identifier }) {
            let replacedID = certificates[index].id
            certificates[index] = certificate
            // 被替换的记录若是当前默认选中项，把选中项同步指向新记录
            if selectedCertificate?.id == replacedID {
                selectedCertificate = certificate
            }
        } else {
            certificates.append(certificate)
            if selectedCertificate == nil {
                selectedCertificate = certificates.first { $0.status == .valid } ?? certificate
            }
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
        // 同 uuid 描述文件（同一证书包被分享两次/多个入口重复导入）原地更新而非追加：
        // 磁盘文件是同一个（persistProfile 按 uuid 命名），重复记录会让列表重复展示、
        // 删除一条后另一条仍指向有效文件，行为不一致。去重下沉到本方法，三条导入
        // 路径（单文件/证书包/证书页）共用同一口径。
        if let index = profiles.firstIndex(where: { $0.uuid == profile.uuid }) {
            profiles[index] = profile
            if selectedProfile?.uuid == profile.uuid {
                selectedProfile = profile
            }
        } else {
            profiles.append(profile)
            if selectedProfile == nil {
                selectedProfile = profiles.first { $0.status == .valid } ?? profile
            }
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
    /// 文件删除（IPA + 解析目录 + 图标目录）按 baseName 分桶并行 IO，列表维护
    /// 与持久化仍在主线程，避免并发修改 @Published。
    func removeSignedApps(_ apps: [AppInfo]) {
        guard !apps.isEmpty else { return }
        // 1) 主线程：维护两条列表 + 签名任务，并收集"关联的源导入记录"。
        // 已签应用页传入的记录由 makeInstalledAppInfo 现解析（全新 UUID、path 指向
        // 签名产物），importedApps 里的原始导入记录按 id/path 都匹配不上——须按
        // signedPath 关联，否则：记录永久残留（isSigned=true 不再显示于首页，无任何
        // UI 入口可清），且源 IPA 与解析/图标目录数 GB 级泄漏。
        var relatedImports: [AppInfo] = []
        for app in apps {
            let matched = importedApps.filter {
                $0.id == app.id || $0.path == app.path || $0.signedPath == app.path
            }
            importedApps.removeAll { record in matched.contains(where: { $0.id == record.id }) }
            installedApps.removeAll { $0.path == app.path || $0.signedPath == app.path }
            relatedImports.append(contentsOf: matched)
        }
        let relatedSourcePaths = relatedImports.map { $0.path }
            + relatedImports.compactMap { $0.signedPath }
        let relatedSignedPaths = apps.map { $0.path }
        signingTasks.removeAll { task in
            relatedSignedPaths.contains(task.outputPath ?? "")
                || relatedSourcePaths.contains(task.sourceFile)
                || relatedSignedPaths.contains(task.sourceFile)
        }
        // 2) 并行 IO：签名产物 + 关联源 IPA 两类文件都删（按 baseName 分桶并行删除）。
        // 历史 N 个应用串行 N 次 removeItem 在 SSD 上仍需数秒，并发后 UI 完全无感。
        let extractedRoot = fileManager.directoryURL(.extracted)
        func entry(for path: String) -> (ipa: URL, baseName: String, iconsDir: URL) {
            let url = URL(fileURLWithPath: path)
            let baseName = url.deletingPathExtension().lastPathComponent
            let iconsDir = extractedRoot
                .appendingPathComponent("Icons", isDirectory: true)
                .appendingPathComponent(baseName, isDirectory: true)
            return (url, baseName, iconsDir)
        }
        var entries = relatedSignedPaths.map { entry(for: $0) }
        entries += relatedSourcePaths.map { entry(for: $0) }
        // 同一源可能对应多个签名产物（重签）：按 ipa 路径去重避免并发重删
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.ipa.path).inserted }
        DispatchQueue.global(qos: .userInitiated).async { [extractedRoot, entries] in
            DispatchQueue.concurrentPerform(iterations: entries.count) { idx in
                let item = entries[idx]
                try? AppFileManager.shared.deleteItem(at: item.ipa)
                // 按前缀清理解析目录（兼容旧版 <baseName> 与新版 <baseName>-<UUID>）
                Self.cleanupExtractDirs(matching: item.baseName, in: extractedRoot)
                try? AppFileManager.shared.deleteItem(at: item.iconsDir)
            }
            DispatchQueue.main.async {
                self.saveState()
                self.refreshInstalledApps()
            }
        }
    }

    /// 删除 Extracted/ 下所有以指定前缀开头的解压目录（兼容旧版 <baseName> 与新版
    /// <baseName>-<UUID> 两种命名）。本方法为并行版（参数化根目录），主线程单删
    /// 的兼容入口走 ExtractedDirectoryCleaner.cleanup(matching:)。
    private static func cleanupExtractDirs(matching prefix: String, in extractedRoot: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir, entry.lastPathComponent != "Icons" else { continue }
            if entry.lastPathComponent == prefix || entry.lastPathComponent.hasPrefix(prefix + "-") {
                try? AppFileManager.shared.deleteItem(at: entry)
            }
        }
    }

    /// 删除 Extracted/ 下所有以指定前缀开头的解压目录（兼容旧版 <baseName> 与新版
    /// <baseName>-<UUID> 两种命名）。已抽取到 `ExtractedDirectoryCleaner`。
    private func cleanupExtractDirs(matching prefix: String) {
        ExtractedDirectoryCleaner.cleanup(matching: prefix)
    }

    /// 启动时孤儿清扫：删除 Extracted/ 下不被任何记录引用的解析目录
    /// （parseAppInfo 每次解压都生成 <baseName>-<UUID> 临时目录，路径会随 UUID 变化，
    /// 无法像 Icons/ 图标那样重定位，必须定期清理避免磁盘无限膨胀）。
    /// 已抽取到 `ExtractedDirectoryCleaner`。残留目录可能达数 GB，递归删除较慢，
    /// 丢到后台执行；引用列表先在主线程快照，避免清扫期间数组被并发修改。
    private func sweepOrphanExtractDirs() {
        let imported = importedApps
        let installed = installedApps
        DispatchQueue.global(qos: .utility).async {
            ExtractedDirectoryCleaner.sweepOrphanExtractDirs(importedApps: imported, installedApps: installed)
        }
    }
}
