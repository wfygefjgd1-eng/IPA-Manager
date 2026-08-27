import Foundation

struct ProvisioningInfo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var uuid: String = ""
    var name: String = ""
    var teamID: String = ""
    var bundleID: String = ""
    var entitlements: [String: AnyCodable] = [:]
    /// 描述文件注册的设备 UDID 列表（企业分发）——空数组表示未限定设备（通配）
    var provisionedDevices: [String] = []
    var createdAt: Date?
    var expireDate: Date?
    var path: String = ""

    enum Status: String, Codable {
        case valid
        case expired
        case mismatched
        case unknown
    }

    var status: Status {
        guard let expire = expireDate else { return .unknown }
        guard expire > Date() else { return .expired }
        return .valid
    }

    var statusDescription: String {
        switch status {
        case .valid: return "有效"
        case .expired: return "已过期"
        case .mismatched: return "不匹配"
        case .unknown: return "未知"
        }
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
