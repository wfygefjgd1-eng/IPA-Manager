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

    var expireDateDescription: String {
        guard let expire = expireDate else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: expire)
    }
}
