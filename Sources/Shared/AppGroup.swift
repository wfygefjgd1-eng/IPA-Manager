import Foundation
import os

/// 主 App 与分享/动作扩展共用的 App Group 常量与收件箱逻辑。
enum AppGroup {
    /// 默认组名（与两个 target 的 entitlements 声明一致），作为自动发现失败时的兜底
    static let defaultIdentifier = "group.com.ipamanager.app"

    private static let lock = OSAllocatedUnfairLock()
    private static var cachedIdentifier: String?
    private static var didResolve = false
    
    private static let resolvedIdentifierKey = "resolved_app_group_identifier"
    
    static var containerURL: URL? {
        let identifier = resolvedIdentifier()
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var inboxURLIfPresent: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func ensureInboxURL() -> URL? {
        guard let container = containerURL else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: inbox.path) {
            do {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return inbox
    }

    static func saveIncomingFile(at sourceURL: URL, preferredFileName: String? = nil) throws -> URL {
        guard let inbox = ensureInboxURL() else {
            throw NSError(
                domain: "AppGroup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "共享容器不可用：当前签名描述文件未授予任何 App Group 能力，无法从分享面板接收文件。请更换含 App Group 的描述文件重签，或改用文件 App → 分享 → 拷贝到 IPA Manager"]
            )
        }
        var baseName = (preferredFileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty { baseName = sourceURL.lastPathComponent }
        baseName = (baseName as NSString).lastPathComponent
        if baseName.isEmpty { baseName = "shared-file" }
        let base = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        var dest = inbox.appendingPathComponent(baseName)
        var attempt = 0
        while FileManager.default.fileExists(atPath: dest.path) {
            attempt += 1
            dest = inbox.appendingPathComponent(ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)")
        }
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return dest
    }

    static func resolvedIdentifier() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if didResolve { return cachedIdentifier }
        didResolve = true
        
        // 优先测试默认组名
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: defaultIdentifier) != nil {
            cachedIdentifier = defaultIdentifier
            UserDefaults.standard.set(defaultIdentifier, forKey: resolvedIdentifierKey)
            return cachedIdentifier
        }
        
        // 从 UserDefaults 读取缓存
        if let cached = UserDefaults.standard.string(forKey: resolvedIdentifierKey),
           FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: cached) != nil {
            cachedIdentifier = cached
            return cachedIdentifier
        }
        
        // 扫描 AppGroup 目录找可用容器
        if let found = scanAvailableAppGroups() {
            cachedIdentifier = found
            UserDefaults.standard.set(found, forKey: resolvedIdentifierKey)
            return found
        }
        
        cachedIdentifier = nil
        return nil
    }
    
    private static func scanAvailableAppGroups() -> String? {
        let appGroupDir = "/var/mobile/Containers/Shared/AppGroup"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appGroupDir) else {
            return nil
        }
        
        for containerUUID in contents {
            let metadataPath = "\(appGroupDir)/\(containerUUID)/.com.apple.mobile_container_manager.metadata.plist"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  let identifier = dict["MCMMetadataIdentifier"] as? String else { continue }
            
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil {
                return identifier
            }
        }
        return nil
    }
}