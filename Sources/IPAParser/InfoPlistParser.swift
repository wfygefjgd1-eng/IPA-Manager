import Foundation

protocol InfoPlistParsing {
    func parse(at url: URL) throws -> AppInfo
    func extractIcon(from plistURL: URL, appURL: URL) throws -> String?
}

final class InfoPlistParser {
    func parse(at url: URL) throws -> AppInfo {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.operationFailed("无法读取 Info.plist")
        }

        let plist: [String: Any]
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        } catch {
            throw AppError.operationFailed("Info.plist 解析失败: \(error.localizedDescription)")
        }

        var info = AppInfo()
        info.name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? "未知应用"
        info.bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        info.version = plist["CFBundleShortVersionString"] as? String ?? ""
        info.build = plist["CFBundleVersion"] as? String ?? ""
        info.minimumOSVersion = plist["MinimumOSVersion"] as? String

        return info
    }

    func extractIcon(from plistURL: URL, appURL: URL) throws -> String? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        if let iconsDict = plist["CFBundleIcons"] as? [String: Any],
           let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String],
           let iconName = files.first {
            return searchIcon(named: iconName, in: appURL)
        }

        if let files = plist["CFBundleIconFiles"] as? [String],
           let iconName = files.first {
            return searchIcon(named: iconName, in: appURL)
        }

        return nil
    }

    private func searchIcon(named name: String, in appDir: URL) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: appDir,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let matched = items
            .filter { $0.lastPathComponent.starts(with: name) && ["png", "jpg", "jpeg"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.count > $1.lastPathComponent.count }

        return matched.first?.path
    }
}