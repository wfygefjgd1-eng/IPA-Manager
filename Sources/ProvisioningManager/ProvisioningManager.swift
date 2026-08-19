import Foundation

final class ProvisioningManager {
    static let shared = ProvisioningManager()

    /// 导入描述文件：解析成功后把源文件归档到 Documents/Profiles（沙盒内稳定路径），
    /// 返回的 info.path 一定指向 Documents 下的目标文件。
    ///
    /// 背景：iOS 每次更新/重装 app 后，Bundle 容器路径（/var/mobile/Containers/Bundle/Application/<UUID>/…）
    /// 的 UUID 会变化，若把 Bundle 内路径直接存进 path，持久化的旧路径会失效，
    /// 签名时 zsign（ZFile::ReadFile）将读不到描述文件。因此统一落盘到 Documents/Profiles。
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

        info.path = try persistProfile(from: url, info: info)
        return info
    }

    /// 归档描述文件到 Documents/Profiles 并返回目标 path。
    /// - 源文件已在 Documents/Profiles 目录内：直接复用原路径，避免重复复制自己。
    /// - 目标文件名用 UUID 唯一化（`profile-<uuid>.mobileprovision`），避免重名冲突。
    /// - 复制失败不崩溃：先清理冲突目标再重试一次，仍失败则抛出中文错误由调用方提示。
    private func persistProfile(from url: URL, info: ProvisioningInfo) throws -> String {
        let profilesDir = AppFileManager.shared.directoryURL(.profiles)
        let profilesDirPath = profilesDir.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path

        // 源已在 Documents/Profiles 目录内：无需再复制（调用方可能已先复制到该目录）
        if sourcePath.hasPrefix(profilesDirPath + "/") {
            return sourcePath
        }

        // 用规范化 UUID 做文件名（Apple 生成的 UUID 一定是合法 UUID；畸形值回退随机 UUID）
        let canonicalUUID = UUID(uuidString: info.uuid)?.uuidString ?? UUID().uuidString
        let destination = profilesDir.appendingPathComponent("profile-\(canonicalUUID).mobileprovision")

        do {
            // copyItem 内部会先移除同名目标再复制，天然处理文件名冲突
            try AppFileManager.shared.copyItem(from: url, to: destination)
        } catch {
            // 首次复制失败：清理可能残留的目标后重试一次
            try? AppFileManager.shared.deleteItem(at: destination)
            do {
                try AppFileManager.shared.copyItem(from: url, to: destination)
            } catch {
                throw AppError.profileInvalid("描述文件复制到 Documents/Profiles 失败: \(error.localizedDescription)")
            }
        }
        return destination.path
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