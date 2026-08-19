import Foundation

final class ProvisioningManager {
    static let shared = ProvisioningManager()

    func importProfile(from url: URL) throws -> ProvisioningInfo {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

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
        info.createdAt = plist["CreationDate"] as? Date
        info.expireDate = plist["ExpirationDate"] as? Date

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        if let entitlementsDict = entitlements as? [String: Any] {
            info.entitlements = entitlementsDict.mapValues { AnyCodable($0) }
        }

        // Application identifier lives in Entitlements (may be missing at top level)
        if let appID = entitlements["application-identifier"] as? String {
            info.bundleID = appID
        } else if let appID = plist["ApplicationIdentifier"] as? String {
            info.bundleID = appID
        }

        return info
    }

    static func isWildcard(bundleID: String, teamID: String) -> Bool {
        if bundleID.hasSuffix(".*") { return true }
        guard !teamID.isEmpty, bundleID.hasPrefix(teamID + ".") else { return false }
        return bundleID == teamID + ".*"
    }

    private static func stripCMSEnvelope(from data: Data) -> Data? {
        guard let range = data.range(of: Data("<plist".utf8), options: .backwards) else { return nil }
        return data.subdata(in: range.lowerBound..<data.count)
    }
}