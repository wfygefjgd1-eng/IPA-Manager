import Foundation

final class UserDefaultsStore {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let certificates = "stored_certificates"
        static let profiles = "stored_profiles"
        static let signingTasks = "stored_signing_tasks"
        static let downloadTasks = "stored_download_tasks"
        static let importedApps = "stored_imported_apps"
        static let schemaVersion = "storage_schema_version"
        /// 导入/下载完成后自动签名并安装（默认开）
        static let autoSignAndInstall = "setting_auto_sign_and_install"
        /// 签名完成后自动返回桌面（默认开）
        static let autoReturnHomeAfterSigning = "setting_auto_return_home"
        /// 解码失败时备份原始数据的键（<key>_backup），避免迁移/排查时永久丢失
        static func backupKey(for key: String) -> String { "\(key)_backup" }
    }

    /// 当前持久化 schema 版本：模型字段增删改都必须提升此版本并在此处补迁移逻辑
    private static let currentSchemaVersion = 1

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        // 版本迁移入口：未来模型结构变化（新增必填字段/改键名）时，
        // 在 decode 失败路径中实现逐版本的旧数据迁移。
        let storedVersion = defaults.integer(forKey: Keys.schemaVersion)
        if storedVersion == 0 {
            // 旧版本（无 schema 标记）：数据仍按 v1 结构存储，打上标记即可
            defaults.set(Self.currentSchemaVersion, forKey: Keys.schemaVersion)
        }
        // storedVersion > currentSchemaVersion 属于降级安装（装了更高版本后退回旧版），
        // 保持原数据不覆盖，避免主动破坏新版本写入的数据。
        if storedVersion > Self.currentSchemaVersion {
            Logger.warning("持久化数据版本高于当前 App 版本（\(storedVersion) > \(Self.currentSchemaVersion)），数据只读保留")
        }
    }

    func loadImportedApps() -> [AppInfo] {
        load([AppInfo].self, key: Keys.importedApps) ?? []
    }

    func saveImportedApps(_ items: [AppInfo]) {
        save(items, key: Keys.importedApps)
    }

    func loadCertificates() -> [CertificateInfo] {
        load([CertificateInfo].self, key: Keys.certificates) ?? []
    }

    func saveCertificates(_ items: [CertificateInfo]) {
        save(items, key: Keys.certificates)
    }

    func loadProfiles() -> [ProvisioningInfo] {
        load([ProvisioningInfo].self, key: Keys.profiles) ?? []
    }

    func saveProfiles(_ items: [ProvisioningInfo]) {
        save(items, key: Keys.profiles)
    }

    func loadSigningTasks() -> [SigningTask] {
        load([SigningTask].self, key: Keys.signingTasks) ?? []
    }

    func saveSigningTasks(_ items: [SigningTask]) {
        save(items, key: Keys.signingTasks)
    }

    func loadDownloadTasks() -> [DownloadTask] {
        load([DownloadTask].self, key: Keys.downloadTasks) ?? []
    }

    func saveDownloadTasks(_ items: [DownloadTask]) {
        save(items, key: Keys.downloadTasks)
    }

    // MARK: - 自动流程开关（默认开启）

    /// 导入/下载完成后是否自动签名并安装（默认 true）。
    func autoSignAndInstallEnabled() -> Bool {
        defaults.object(forKey: Keys.autoSignAndInstall) as? Bool ?? true
    }

    func setAutoSignAndInstallEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoSignAndInstall)
    }

    /// 签名完成后是否自动返回桌面（默认 true）。
    func autoReturnHomeAfterSigningEnabled() -> Bool {
        defaults.object(forKey: Keys.autoReturnHomeAfterSigning) as? Bool ?? true
    }

    func setAutoReturnHomeAfterSigningEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoReturnHomeAfterSigning)
    }

    /// 解码失败保护：失败时备份原始 Data（不覆盖），并清空该键让 UI 走空态。
    /// 返回 nil 表示读取失败/无数据；备份可用于后续排查或回滚。
    private func load<T: Codable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Logger.error("持久化数据解码失败 (\(key)): \(error.localizedDescription)")
            // 保留原始数据副本，防止迁移不及时导致数据永久丢失
            defaults.set(data, forKey: Keys.backupKey(for: key))
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    private func save<T: Codable>(_ value: T, key: String) {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key)
            // 保存成功后清理该键的失败备份，避免堆积
            defaults.removeObject(forKey: Keys.backupKey(for: key))
        } catch {
            Logger.error("持久化数据写入失败 (\(key)): \(error.localizedDescription)")
        }
    }
}