import SwiftUI
import Foundation

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var installedApps: [AppInfo] = []
    @Published var importedApps: [AppInfo] = []
    @Published var certificates: [CertificateInfo] = []
    @Published var profiles: [ProvisioningInfo] = []
    @Published var signingTasks: [SigningTask] = []
    @Published var downloadTasks: [DownloadTask] = []

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

    private func handleDownloadedFile(at url: URL) {
        Logger.info("下载完成，自动解析: \(url.lastPathComponent)")
        importFile(from: url) { result in
            switch result {
            case .success:
                Logger.info("自动解析成功: \(url.lastPathComponent)")
            case .failure(let error):
                Logger.error("自动解析失败: \(error.localizedDescription)")
            }
        }
    }

    func importFile(from url: URL, completion: @escaping (Result<AppInfo, Error>) -> Void) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = fileManager.directoryURL(.ipa).appendingPathComponent(url.lastPathComponent)
        do {
            try fileManager.copyItem(from: url, to: destination)
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var app = try self.parser.parseAppInfo(fileURL: destination)
                app.path = destination.path
                DispatchQueue.main.async {
                    if let index = self.importedApps.firstIndex(where: { $0.bundleID == app.bundleID }) {
                        self.importedApps[index] = app
                    } else {
                        self.importedApps.append(app)
                    }
                    completion(.success(app))
                }
            } catch {
                DispatchQueue.main.async {
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
                        if let profileURL = moved.profileURL,
                           let profile = try? ProvisioningManager.shared.importProfile(from: profileURL) {
                            self.addProfile(profile)
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
        downloadTasks = store.loadDownloadTasks()
        importedApps = store.loadImportedApps()

        // 选中项不持久化，恢复后必须重新挑选，避免首页显示“未选择证书”
        if selectedCertificate == nil {
            selectedCertificate = certificates.first { $0.status == .valid } ?? certificates.first
        }
        if selectedProfile == nil {
            selectedProfile = profiles.first { $0.status == .valid } ?? profiles.first
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
        store.saveDownloadTasks(downloadTasks)
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
        let url = URL(fileURLWithPath: app.path)
        try? fileManager.deleteItem(at: url)
        refreshInstalledApps()
    }
}
