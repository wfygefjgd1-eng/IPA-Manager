import Foundation

final class BundledCertificateBootstrap {
    static let shared = BundledCertificateBootstrap()

    private let bundledPassword = "1"
    private let key = "bundled_cert_imported"

    func importIfNeeded(into appState: AppState) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let p12URL = Bundle.main.url(forResource: "bundled", withExtension: "p12") else { return }
        guard let provURL = Bundle.main.url(forResource: "bundled", withExtension: "mobileprovision") else { return }

        Logger.info("检测到捆绑证书，开始自动导入")

        // Import provisioning profile
        do {
            var profile = try ProvisioningManager.shared.importProfile(from: provURL)
            profile.path = provURL.path
            if !appState.profiles.contains(where: { $0.uuid == profile.uuid }) {
                appState.addProfile(profile)
            }
            Logger.info("捆绑描述文件导入成功: \(profile.name)")
        } catch {
            Logger.error("捆绑描述文件导入失败: \(error.localizedDescription)")
        }

        // Import certificate
        CertificateManager.shared.importCertificate(from: p12URL, password: bundledPassword) { result in
            switch result {
            case .success(let cert):
                appState.addCertificate(cert)
                Logger.info("捆绑证书导入成功: \(cert.name)")
            case .failure(let error):
                Logger.error("捆绑证书导入失败: \(error.localizedDescription)")
            }
        }

        UserDefaults.standard.set(true, forKey: key)
    }
}