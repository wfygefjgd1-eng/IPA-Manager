import Foundation

struct CertificateInfo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var teamID: String = ""
    var commonName: String = ""
    var organization: String = ""
    var startDate: Date?
    var expireDate: Date?
    var isPasswordProtected: Bool = false
    var keychainIdentifier: String?
    var passwordKeychainIdentifier: String?

    enum Status: String, Codable {
        case valid
        case expired
        case unknown
    }

    var status: Status {
        guard let expire = expireDate else { return .unknown }
        return expire > Date() ? .valid : .expired
    }

    var statusDescription: String {
        switch status {
        case .valid: return "有效"
        case .expired: return "已过期"
        case .unknown: return "未知"
        }
    }

    /// 证书身份指纹：Team ID + 证书 CN + 生效/到期时间。
    /// 同一张证书重新打包后（p12 换密码/重新加密 → 文件字节变化 →
    /// keychainIdentifier 变化）这四个字段不变，用它去重可避免"每重新导入
    /// 一次就多一条重复记录"。字段缺失时返回 nil（退回按 Keychain 标识去重）。
    var identityKey: String? {
        let cn = commonName.isEmpty ? name : commonName
        guard !cn.isEmpty, let start = startDate, let expire = expireDate else { return nil }
        return "\(teamID)|\(cn)|\(Int(start.timeIntervalSince1970))|\(Int(expire.timeIntervalSince1970))"
    }

    /// 缓存的日期格式化器：避免每次访问都重新创建 DateFormatter（创建开销约数毫秒），
    /// 与 Logger.cachedTimestampFormatter 同模式，全局复用。
    private static let cachedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var expireDateDescription: String {
        guard let expire = expireDate else { return "未知" }
        return Self.cachedDateFormatter.string(from: expire)
    }
}
