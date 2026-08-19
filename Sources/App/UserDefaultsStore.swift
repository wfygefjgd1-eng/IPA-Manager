import Foundation

final class UserDefaultsStore {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let certificates = "stored_certificates"
        static let profiles = "stored_profiles"
        static let signingTasks = "stored_signing_tasks"
        static let downloadTasks = "stored_download_tasks"
        static let importedApps = "stored_imported_apps"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    private func load<T: Codable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Codable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
