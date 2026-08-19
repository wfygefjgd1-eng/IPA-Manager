import Foundation

final class ProvisioningManager {
    static let shared = ProvisioningManager()

    func importProfile(from url: URL) throws -> ProvisioningInfo {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.profileInvalid("无法读取描述文件")
        }

        let parsed = try parseProfile(data)
        guard var info = parsed else {
            throw AppError.profileInvalid("描述文件解析失败")
        }
        info.path = url.path
        return info
    }

    func parseProfile(_ data: Data) throws -> ProvisioningInfo? {
        guard let cmsData = Self.stripCMSEnvelope(from: data) else { return nil }

        guard let plist = try PropertyListSerialization.propertyList(
            from: cmsData,
            options: [],
            format: nil
        ) as? [String: Any] else { return nil }

        var info = ProvisioningInfo()
        info.uuid = plist["UUID"] as? String ?? ""
        info.name = plist["Name"] as? String ?? "未命名描述文件"
        info.teamID = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        info.bundleID = plist["ApplicationIdentifier"] as? String ?? ""
        info.createdAt = plist["CreationDate"] as? Date
        info.expireDate = plist["ExpirationDate"] as? Date

        if let entitlements = plist["Entitlements"] as? [String: Any] {
            info.entitlements = entitlements.mapValues { AnyCodable($0) }
        }

        return info
    }

    private static func stripCMSEnvelope(from data: Data) -> Data? {
        guard let range = data.range(of: Data("<plist".utf8), options: .backwards) else { return nil }
        return data.subdata(in: range.lowerBound..<data.count)
    }
}