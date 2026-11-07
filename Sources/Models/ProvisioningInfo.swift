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
        case mismatched // 由调用方按需设置（如 Bundle ID 不匹配时）
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

    // MARK: - Bundle ID 覆盖校验（手动签名模式）

    /// Bundle ID 字符格式校验（与描述文件无关的硬性规则，任何 profile 下都不合法）。
    /// 仅保留字符门槛：空格/中文等非法字符会让重写后的 Info.plist/entitlement
    /// 无法成立，装不上设备；提前 fail-fast 把迭代成本从"数十秒签名+安装失败"
    /// 压缩到秒级报错。描述文件兼容性判定已整体移除——签名层不再预判"名字
    /// 能不能装"（自动模式零改写照样装机成功即为反例），是否可装交系统裁决。
    static func bundleIDFormatError(_ newID: String) -> String? {
        let trimmed = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Bundle ID 不能为空" }
        // 字符白名单：iOS bundle id 只允许字母/数字/点/横线/下划线（空格或中文
        // 会让重写后的包无法安装）
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"
        )
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Bundle ID 只能包含字母、数字、点、横线和下划线"
        }
        return nil
    }
}
