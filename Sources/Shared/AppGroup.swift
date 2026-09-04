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

    /// 扩展日志文件名（存放在共享容器根目录，主 App 与扩展共用）。
    /// 扩展是独立进程，主 App 的 ExternalDeliveryJournal 看不到它；
    /// 扩展把关键节点写进这个文件，主 App 扫描时吞入诊断。
    private static let extensionLogFileName = "ExtensionLog.txt"
    /// 扩展日志上限（字节）：超出后保留后半段，避免无限增长。
    private static let extensionLogMaxBytes = 65536

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
    
    /// 跨进程日志：由扩展进程调用，主 App 扫描时读取。best-effort，失败静默。
    /// 每行自带时间戳与写入时解析到的组名，便于定位“扩展存到了另一组”的错位问题。
    static func appendExtensionLog(_ message: String) {
        guard let identifier = resolvedIdentifier(),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else { return }
        let logURL = container.appendingPathComponent(extensionLogFileName)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let line = "[\(formatter.string(from: Date()))][\(identifier)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // 超限截断：只保留后半段
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > extensionLogMaxBytes,
           let existing = try? Data(contentsOf: logURL), existing.count > extensionLogMaxBytes / 2 {
            let trimmed = existing.suffix(extensionLogMaxBytes / 2).drop(while: { $0 != 0x0A }).dropFirst()
            try? Data(trimmed + data).write(to: logURL, options: .atomic)
            return
        }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    /// 读取扩展日志全文（主 App 诊断用；无容器/无文件/空文件时返回 nil）
    static func readExtensionLog() -> String? {
        guard let logURL = extensionLogURLIfPresent,
              let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 扩展日志文件 URL（共享容器不可用时为 nil）
    static var extensionLogURLIfPresent: URL? {
        containerURL?.appendingPathComponent(extensionLogFileName)
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