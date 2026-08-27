import Foundation

struct AppInfo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var bundleID: String = ""
    var version: String = ""
    var build: String = ""
    var iconPath: String?
    var size: Int64 = 0
    var path: String = ""
    var minimumOSVersion: String?
    var isSigned: Bool = false
    var signedPath: String?

    /// 缓存的 ByteCountFormatter：避免每次访问都重新创建（创建开销约数毫秒），
    /// 与 Logger.cachedTimestampFormatter / CertificateInfo.cachedDateFormatter 同模式。
    private static let cachedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var sizeDescription: String {
        Self.cachedFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
