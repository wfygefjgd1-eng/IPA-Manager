import Foundation

final class BundledCertificateBootstrap {
    static let shared = BundledCertificateBootstrap()

    private let bundledPassword = "1"
    private let key = "bundled_cert_imported"

    func importIfNeeded(into appState: AppState) {
        guard let p12URL = Bundle.main.url(forResource: "bundled", withExtension: "p12") else { return }
        guard let provURL = Bundle.main.url(forResource: "bundled", withExtension: "mobileprovision") else { return }

        // If already imported once, but cert/profiles got cleared, re-import.
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

        // Run certificate import async and only mark done when it succeeds
        CertificateManager.shared.importCertificate(from: p12URL, password: bundledPassword) { [key, self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let cert):
                    if !appState.certificates.contains(where: { $0.keychainIdentifier == cert.keychainIdentifier }) {
                        appState.addCertificate(cert)
                    }
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