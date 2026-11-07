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

    /// Bundle ID 字符格式校验（与描述文件无关的两条硬性规则，任何 profile 下都不合法）。
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

    /// 校验手动修改后的 Bundle ID 是否与该描述文件兼容（签名时经 zsign 重写包内
    /// CFBundleIdentifier，重写后的签名 ID 必须被描述文件的 application-identifier
    /// 覆盖，否则 iOS 安装层必然拒签包）。镜像系统的通配覆盖语义：
    /// - 通配 AppID（TEAMID.a.*）：允许任意「a.」开头的 Bundle ID（TEAMID.* 则任意）；
    /// - 精确 AppID（TEAMID.a.b）：只允许「a.b」本身。
    /// 注意：这只是【单条描述文件】的兼容性判定——编辑界面应同时对比全部有效
    /// 描述文件（见 AppDetailView 的编辑器），"任一兼容"即可保存改用那条签名；
    /// 不能只拿默认描述文件把保存卡死（此前版本的误拦：库里明明有通配
    /// 描述文件可用，编辑框却按默认那条直接拒绝）。
    /// 返回 nil 表示通过；非 nil 为面向用户展示的错误说明。
    func bundleIDOverrideError(_ newID: String) -> String? {
        if let formatError = Self.bundleIDFormatError(newID) { return formatError }
        let trimmed = newID
        // AppID 缺失（畸形描述文件）时不拦：交给签名/安装链路的系统裁决，宁可放行
        guard !bundleID.isEmpty else { return nil }
        // 直接填完整 AppID（含 Team 前缀）视为一致
        if trimmed == bundleID { return nil }

        let teamPrefix = teamID.isEmpty ? "" : teamID + "."
        let bare = trimmed.hasPrefix(teamPrefix) ? String(trimmed.dropFirst(teamPrefix.count)) : trimmed
        if bundleID.hasSuffix("*") {
            // 通配段包含结尾的点（"TEAMID.a.*" → base "TEAMID.a."）
            let base = String(bundleID.dropLast())
            if (teamPrefix + bare).hasPrefix(base) { return nil }
            let wildcardName = String(bundleID.dropLast()).dropFirst(teamPrefix.count)
            return "该描述文件的通配段仅允许「\(wildcardName)…」开头的 Bundle ID"
        }
        if teamPrefix + bare == bundleID { return nil }
        // 描述文件缺 TeamIdentifier 字段时 teamPrefix 为空，退化为后缀比对
        //（镜像 zsign 的 endsWith 匹配语义，避免误拦）
        if teamPrefix.isEmpty && bundleID.hasSuffix(bare) { return nil }
        let expected = bundleID.hasPrefix(teamPrefix) ? String(bundleID.dropFirst(teamPrefix.count)) : bundleID
        return "该描述文件是精确绑定（非通配符），只支持不改名为「\(expected)」。想改名需要通配描述文件（application-identifier 以 * 结尾，如 TEAMID.xxx.*）：可在「签名选项」中改选通配描述文件，或向证书供应商申请"
    }
}
