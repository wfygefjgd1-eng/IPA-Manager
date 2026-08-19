import Foundation

final class BundledCertificateBootstrap {
    static let shared = BundledCertificateBootstrap()

    private let bundledPassword = "1"
    private let key = "bundled_cert_imported"

    func importIfNeeded(into appState: AppState) {
        guard let p12URL = Bundle.main.url(forResource: "bundled", withExtension: "p12") else { return }
        guard let provURL = Bundle.main.url(forResource: "bundled", withExtension: "mobileprovision") else { return }

        // 仅在“已导入过 且 证书/描述文件都在”时跳过；
        // 任一数据丢失（为空）都要重新导入，不受已设标记影响。
        let alreadyImported = UserDefaults.standard.bool(forKey: key)
        let hasCert = !appState.certificates.isEmpty
        let hasProfile = !appState.profiles.isEmpty
        if alreadyImported && hasCert && hasProfile { return }

        Logger.info("检测到捆绑证书，开始自动导入")

        // Import provisioning profile
        var profileOK = false
        do {
            var profile = try ProvisioningManager.shared.importProfile(from: provURL)
            profile.path = provURL.path
            if !appState.profiles.contains(where: { $0.uuid == profile.uuid }) {
                appState.addProfile(profile)
            }
            profileOK = true
            Logger.info("捆绑描述文件导入成功: \(profile.name)")
        } catch {
            Logger.error("捆绑描述文件导入失败: \(error.localizedDescription)")
        }

        // Run certificate import async and only mark done when it (and the profile) succeeds.
        // importCertificate 内部在后台队列执行，completion 可能不在主线程，须切回主线程更新 UI 状态。
        CertificateManager.shared.importCertificate(from: p12URL, password: bundledPassword) { [key] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let cert):
                    if !appState.certificates.contains(where: { $0.keychainIdentifier == cert.keychainIdentifier }) {
                        appState.addCertificate(cert)
                    }
                    // 描述文件与证书都成功才打标记；任一失败都不记录，便于下次启动重试
                    if profileOK {
                        UserDefaults.standard.set(true, forKey: key)
                    }
                    Logger.info("捆绑证书导入成功: \(cert.name)")
                case .failure(let error):
                    Logger.error("捆绑证书导入失败: \(error.localizedDescription)")
                }
            }
        }
    }
}