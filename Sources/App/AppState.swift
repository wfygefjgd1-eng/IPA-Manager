import SwiftUI
import Foundation

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

    private let fileManager = AppFileManager.shared
    private let store = UserDefaultsStore()
    private let parser = IPAParser()

    init() {
        loadPersistedState()
        refreshInstalledApps()
        DownloadManager.shared.onDownloadComplete = { [weak self] url in
            self?.handleDownloadedFile(at: url)
        }
        BundledCertificateBootstrap.shared.importIfNeeded(into: self)
        Logger.info("AppState 初始化完成")
    }

    private enum DownloadedArchiveKind {
        case certificateBundle
        case appPackage
        /// 压缩包能正常解压但既非应用包也非证书包；携带顶层内容摘要，便于定位真实结构
        case unknown(String)
    }

    private func handleDownloadedFile(
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

        // 压缩包：后台先判断内容（证书包 / 应用包 / 未知），避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async {
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
                case .unknown(let summary):
                    // 保留原始分类信息，并附上“压缩包内包含：…”内容摘要，方便定位真实结构
                    let message = "该 ZIP 不是应用包（无 Payload/*.app 结构）也不是证书包（无 .p12/.mobileprovision）。\(summary)"
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
            }
        }

        if hasCertificate { return .certificateBundle }
        if hasAppBundle { return .appPackage }
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

    func importFile(from url: URL, completion: @escaping (Result<AppInfo, Error>) -> Void) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = fileManager.directoryURL(.ipa).appendingPathComponent(url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 转换得到的 .ipa 已直接输出到 .ipa 目录（url 即 destination），跳过复制，避免删掉源文件
                if url.path != destination.path {
                    // 目标已存在（重复导入同名文件）时先移除，再用新文件覆盖
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try self.fileManager.copyItem(from: url, to: destination)
                }
                var app = try self.parser.parseAppInfo(fileURL: destination)
                app.path = destination.path
                DispatchQueue.main.async {
                    if let index = self.importedApps.firstIndex(where: { $0.bundleID == app.bundleID }) {
                        self.importedApps[index] = app
                    } else {
                        self.importedApps.append(app)
                    }
                    self.saveState()
                    completion(.success(app))
                }
            } catch {
                DispatchQueue.main.async {
                    // 复制成功但解析失败时，清理可能残留的半成品文件
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    completion(.failure(error))
                }
            }
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
                        self.refreshInstalledApps()
                    }
                    self.saveState()
                    completion?(.success(signedPath))
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

    func handleFileOpenedFromOutside(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        Logger.info("外部打开文件: \(url.lastPathComponent)")

        switch ext {
        case "zip", "p12", "pfx", "mobileprovision":
            importCertificateBundleOrFile(url)
        default:
            importFile(from: url) { _ in }
        }
    }

    private func importCertificateBundleOrFile(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "zip":
            let importer = CertificateBundleImporter.shared
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let content = try importer.extract(from: url)
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
                        // 证书：优先用捆绑证书的已知密码尝试导入，失败则提示用户走证书页手动导入
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
                                }
                            }
                        }
                        Logger.info("zip 证书包导入完成")
                    }
                } catch {
                    Logger.error("zip 证书包导入失败: \(error)")
                }
            }
        default:
            // p12/mobileprovision need UI flow; route to certificates tab later
            Logger.info("单个证书文件需通过证书页导入: \(url.lastPathComponent)")
        }
    }

    func loadPersistedState() {
        certificates = store.loadCertificates()
        profiles = store.loadProfiles()
        signingTasks = store.loadSigningTasks()
        // 下载任务由 DownloadManager.restoreSavedTasks() 负责恢复并持久化，
        // 这里不再加载，避免与 DownloadManager 的内存态互相覆盖。
        importedApps = store.loadImportedApps()

        // 路径重定位：iOS 更新/重装 app 后沙盒容器路径（Bundle/Data 的 UUID）会变化，
        // 持久化的旧路径可能失效。用文件名在对应的 Documents 目录下找回，
        // 找到则更新为稳定路径并持久化；找不到则保留原记录（UI 显示文件缺失），不影响其它记录。
        relocateProfilePaths()
        relocateImportedAppPaths()

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

    func refreshInstalledApps() {
        let signedURLs = fileManager.contents(of: .signed)
        installedApps = signedURLs.map { url in
            var app = AppInfo()
            app.name = url.deletingPathExtension().lastPathComponent
            app.path = url.path
            app.size = fileManager.fileSize(at: url)
            app.isSigned = true
            return app
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
        // 从两条列表中都移除（未签名导入的也会出现在 importedApps）
        importedApps.removeAll { $0.id == app.id || $0.path == app.path }
        installedApps.removeAll { $0.path == app.path }
        let url = URL(fileURLWithPath: app.path)
        try? fileManager.deleteItem(at: url)
        // 一并清理对应的解压目录（保留基线安全）
        let baseName = url.deletingPathExtension().lastPathComponent
        let extractDir = fileManager.directoryURL(.extracted).appendingPathComponent(baseName, isDirectory: true)
        try? fileManager.deleteItem(at: extractDir)
        saveState()
        refreshInstalledApps()
    }
}
