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

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
