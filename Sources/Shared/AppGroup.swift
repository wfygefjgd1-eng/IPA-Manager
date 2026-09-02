import Foundation

/// 主 App 与分享扩展共用的 App Group 常量与收件箱逻辑。
/// 分享扩展把用户分享的文件复制到共享 Inbox；主 App 回前台时扫描该目录，
/// 走「导入 → 自动签名 → 自动安装」流水线。两个 target 各自独立编译本文件
/// （各自二进制内一份，无符号冲突）。
/// 注意：若用户签名所用描述文件未包含 App Group 能力（通配符 profile 常见），
/// containerURL 返回 nil——扩展端给出明确提示、主 App 端跳过共享目录扫描，
/// 其余功能不受影响；安装本身不受该 entitlement 影响（zsign 按描述文件内嵌
/// entitlements 签名，签名结果与 profile 一致）。
enum AppGroup {
    /// 必须与两个 target 的 entitlements（com.apple.security.application-groups）保持一致
    static let identifier = "group.com.ipamanager.app"

    /// App Group 容器（描述文件未授权该能力时为 nil）
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 共享收件箱路径（不创建；无容器权限时为 nil）
    static var inboxURLIfPresent: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// 共享收件箱目录（不存在则创建；无容器权限时返回 nil）
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

    /// 把分享收到的文件复制进共享 Inbox（唯一文件名，绝不覆盖既有文件）。
    /// loadFileRepresentation 给出的临时 URL 只在该回调块内有效，必须当场复制。
    static func saveIncomingFile(at sourceURL: URL) throws -> URL {
        guard let inbox = ensureInboxURL() else {
            throw NSError(
                domain: "AppGroup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "共享容器不可用：当前签名描述文件未包含 App Group 能力，无法从分享面板接收文件"]
            )
        }
        let baseName = sourceURL.lastPathComponent
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
}
