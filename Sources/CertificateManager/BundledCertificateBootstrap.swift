import Foundation

final class BundledCertificateBootstrap {
    static let shared = BundledCertificateBootstrap()

    private let bundledPassword = "1"
    private let key = "bundled_cert_imported"

    func importIfNeeded(into appState: AppState) {
        guard let p12URL = Bundle.main.url(forResource: "bundled", withExtension: "p12") else { return }
        guard let provURL = Bundle.main.url(forResource: "bundled", withExtension: "mobileprovision") else { return }

        // 仅在“已导入过 且 证书已导入 且所有已存描述文件记录的文件都真实存在”时跳过；
        // 任一描述文件记录的 path 失效（文件不存在，如旧版本只存了 Bundle 内路径，而
        // Bundle 的 UUID 会随 app 更新/重装变化）都不能跳过，必须重新走导入流程，
        // 把 Bundle 内描述文件复制到 Documents/Profiles 并回填稳定路径，
        // 否则签名时 zsign 将读不到描述文件。
        let alreadyImported = UserDefaults.standard.bool(forKey: key)
        let hasCert = !appState.certificates.isEmpty
        let profilesUsable = !appState.profiles.isEmpty && appState.profiles.allSatisfy { profile in
            !profile.path.isEmpty && FileManager.default.fileExists(atPath: profile.path)
        }
        if alreadyImported && hasCert && profilesUsable { return }

        Logger.info("检测到捆绑证书，开始自动导入")

        // Import provisioning profile
        var profileOK = false
        do {
            // importProfile 会自动把 Bundle 内描述文件复制到 Documents/Profiles，
            // 并返回 Documents 下的稳定路径；不要再用 provURL.path（Bundle 内路径）
            // 覆盖它——Bundle 的 UUID 会随 app 更新/重装变化，导致持久化路径失效。
            let profile = try ProvisioningManager.shared.importProfile(from: provURL)
            // 按 uuid upsert：已存在同 uuid 记录时，原地把 path 更新为新的稳定路径
            // （修复旧版本的 Bundle 内失效路径），保持记录 id 不变，避免破坏
            // selectedProfile / 签名任务对旧 id 的引用；不存在则新增。
            if let index = appState.profiles.firstIndex(where: { $0.uuid == profile.uuid }) {
                appState.profiles[index].path = profile.path
                // selectedProfile 持有的是 struct 副本，同步修复其 path，
                // 避免后续“默认选中”签名流程仍读到失效路径
                if appState.selectedProfile?.uuid == profile.uuid {
                    appState.selectedProfile?.path = profile.path
                }
                appState.saveState()
            } else {
                appState.addProfile(profile)
            }
            // 重新确认文件真实存在后再视为成功（决定是否记录“已导入”标记，
            // 避免标记提前打上导致下次启动跳过修复）
            profileOK = FileManager.default.fileExists(atPath: profile.path)
            if profileOK {
                Logger.info("捆绑描述文件已就绪: \(profile.path)")
            } else {
                Logger.error("捆绑描述文件导入后文件仍不存在: \(profile.path)")
            }
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