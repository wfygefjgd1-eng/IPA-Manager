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
        /// 备份时间戳键（<key>_backup_date），用于 TTL 清理（>7 天自动删除）
        static func backupDateKey(for key: String) -> String { "\(key)_backup_date" }
        /// 分享面板「拷贝到 App」已处理的 Inbox 投递路径（去重缓存，非业务数据：
        /// 丢失的代价只是对残留文件多导入一次，importFile 按 bundleID 去重，无副作用）
        static let processedInboxPaths = "processed_inbox_paths"
        /// 扩展日志消费偏移：主 App 扇入读取"全部可用容器"，按容器目录名分别记账
        ///（v1.0.142 起共享容器可能是多个，单一全局偏移会在多容器下串账）
        static let extensionLogOffsetsByGroup = "extension_log_offsets_by_group"
        /// 上次记录到投递日志的共享容器组集合：组集合变化（重签换描述文件/组漂移）
        /// 才记日志，避免每次冷启动都重复"共享容器：可用"刷屏
        static let lastKnownContainerSet = "last_known_container_set"
        /// 所有需要检查 TTL 的持久化键集合
        static let allPersistedKeys: [String] = [
            certificates, profiles, signingTasks, downloadTasks, importedApps
        ]
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
        // 启动时清理过期备份（>7 天），避免 _backup 数据无限堆积
        clearOldBackups()
    }

    /// 清理超过 TTL（7 天）的备份数据。每个备份键对应一个日期键，
    /// 无日期键的旧备份（历史版本）视为已过期直接清理。
    func clearOldBackups() {
        let now = Date()
        for key in Keys.allPersistedKeys {
            let backupKey = Keys.backupKey(for: key)
            let dateKey = Keys.backupDateKey(for: key)
            guard defaults.data(forKey: backupKey) != nil else { continue }
            if let date = defaults.object(forKey: dateKey) as? Date {
                if now.timeIntervalSince(date) > Limits.backupTTLInterval {
                    defaults.removeObject(forKey: backupKey)
                    defaults.removeObject(forKey: dateKey)
                    Logger.info("已清理过期备份: \(backupKey) (\(Int(now.timeIntervalSince(date)/86400)) 天前)")
                }
            } else {
                // 历史数据：无时间戳的备份视为过期，直接清理避免堆积
                defaults.removeObject(forKey: backupKey)
                // 同时清理可能残留的旧标记
                defaults.removeObject(forKey: dateKey)
                Logger.info("已清理无时间戳的旧备份: \(backupKey)")
            }
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

    // MARK: - 分享投递（Inbox）已处理记录

    func loadProcessedInboxPaths() -> [String] {
        load([String].self, key: Keys.processedInboxPaths) ?? []
    }

    func saveProcessedInboxPaths(_ paths: [String]) {
        // 上限截断：异常堆积时仅保留最近记录（投递频度低，64 条远超实际需要；
        // 记录丢失的代价只是对残留文件多导入一次，importFile 按 bundleID 去重）
        save(Array(paths.suffix(64)), key: Keys.processedInboxPaths)
    }

    // MARK: - 扩展日志消费偏移

    /// 按容器目录名记账的扩展日志消费偏移（扇入读取全部容器，每容器独立增量消费；
    /// 旧版单全局偏移在多容器下会串账）
    func loadExtensionLogOffsetsByGroup() -> [String: Int] {
        load([String: Int].self, key: Keys.extensionLogOffsetsByGroup) ?? [:]
    }

    func saveExtensionLogOffsetsByGroup(_ offsets: [String: Int]) {
        save(offsets, key: Keys.extensionLogOffsetsByGroup)
    }

    // MARK: - 共享容器组集合记忆

    func loadLastKnownContainerSet() -> String? {
        defaults.string(forKey: Keys.lastKnownContainerSet)
    }

    func saveLastKnownContainerSet(_ value: String) {
        defaults.set(value, forKey: Keys.lastKnownContainerSet)
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
    /// 备份会附带时间戳，供 TTL 清理使用（>7 天自动删除）。
    private func load<T: Codable>(_ type: T.Type, key: String) -> T? {
        // 缺失键优雅处理：无数据时返回 nil，调用方以 ?? [] / 默认值兜底
        guard let data = defaults.data(forKey: key) else { return nil }
        // 空数据亦视为缺失
        guard !data.isEmpty else {
            defaults.removeObject(forKey: key)
            return nil
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Logger.error("持久化数据解码失败 (\(key)): \(error.localizedDescription)")
            // 保留原始数据副本，防止迁移不及时导致数据永久丢失；带时间戳便于 TTL
            defaults.set(data, forKey: Keys.backupKey(for: key))
            defaults.set(Date(), forKey: Keys.backupDateKey(for: key))
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    private func save<T: Codable>(_ value: T, key: String) {
        // 降级保护落地：高版本 App 写入的数据在 init 中已声明"只读保留"，
        // 任何一次 saveState 都会用旧 schema 整体覆盖写回（新字段静默丢失）——
        // 这里直接跳过写入兑现该承诺。
        let storedVersion = defaults.integer(forKey: Keys.schemaVersion)
        if storedVersion > Self.currentSchemaVersion {
            Logger.warning("持久化数据版本高于当前 App（\(storedVersion)），跳过写入: \(key)")
            return
        }
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key)
            // 保存成功后清理该键的失败备份及时间戳，避免堆积
            defaults.removeObject(forKey: Keys.backupKey(for: key))
            defaults.removeObject(forKey: Keys.backupDateKey(for: key))
        } catch {
            Logger.error("持久化数据写入失败 (\(key)): \(error.localizedDescription)")
        }
    }
}