import Foundation
import os

/// 主 App 与分享/动作扩展共用的 App Group 常量与收件箱逻辑。
/// 扩展把用户分享的文件复制到共享 Inbox；主 App 回前台时扫描该目录，
/// 走「导入 → 自动签名 → 自动安装」流水线。两个 target 各自独立编译本文件
/// （各自二进制内一份，无符号冲突）。
///
/// 组名解析（v1.0.130）：App Group 能力由**签名描述文件**授予。zsign 系签名按
/// 描述文件内嵌 entitlements 签名，组名以描述文件为准（企业签供应商常用任意
/// 组名，不一定是本 App 默认组）。因此运行时从 embedded.mobileprovision 原始
/// 数据里扫描 group.* 候选组名，逐个用 containerURL 实测可用性，取第一个可用
/// 的组；都不可用（描述文件完全没授予 App Group）返回 nil——扩展端给出明确
/// 提示，主 App 端跳过共享目录扫描，其余功能不受影响；安装本身不受影响。
enum AppGroup {
    /// 默认组名（与两个 target 的 entitlements 声明一致），作为自动发现失败时的兜底
    static let defaultIdentifier = "group.com.ipamanager.app"

    private static let lock = OSAllocatedUnfairLock()
    private static var cachedIdentifier: String?
    private static var didResolve = false
    
    /// 存储已解析组名的键（跨进程共享：主 App 解析后写入，扩展读取）
    private static let resolvedIdentifierKey = "resolved_app_group_identifier"
    
    /// 当前签名实际可用的共享容器（描述文件未授予 App Group 时为 nil）
    /// 注意：仅在 resolvedIdentifier() 调用之后安全调用
    static var containerURL: URL? {
        let identifier = resolvedIdentifier()
        guard let identifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
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
                userInfo: [NSLocalizedDescriptionKey: "共享容器不可用：当前签名描述文件未授予任何 App Group 能力，无法从分享面板接收文件。请更换含 App Group 的描述文件重签，或改用文件 App → 分享 → 拷贝到 IPA Manager"]
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

    /// 解析当前签名实际可用的组名（进程内只解析一次）：
    /// 描述文件内声明的组 → 默认组名；逐个 containerURL 实测，取第一个可用者。
    /// 扩展进程无法直接读主 App 的 embedded.mobileprovision，因此：
    /// 1. 每次启动强制从 embedded.mobileprovision 重新解析（避免旧版缓存干扰）
    /// 2. 解析成功后写入 UserDefaults 供扩展读取
    /// 3. 扩展优先读缓存；缓存无效则重新解析
    static func resolvedIdentifier() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if didResolve { return cachedIdentifier }
        didResolve = true
        
        // 强制从 embedded.mobileprovision 重新解析（忽略旧缓存，避免企业签组名不同时仍用旧缓存）
        var candidates = profileAppGroupCandidates()
        if !candidates.contains(defaultIdentifier) {
            candidates.append(defaultIdentifier)
        }
        for candidate in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                cachedIdentifier = candidate
                // 解析成功后写入缓存（standard + App Group 双写，确保跨进程可见）
                UserDefaults.standard.set(candidate, forKey: resolvedIdentifierKey)
                UserDefaults(suiteName: candidate)?.set(candidate, forKey: resolvedIdentifierKey)
                return cachedIdentifier
            }
        }
        cachedIdentifier = nil
        return nil
    }

    /// 从 embedded.mobileprovision 原始数据扫描 group.* 候选组名。描述文件是 CMS
    /// 包裹的 plist，组名字符串以明文形式存在于数据中，无需完整解包 CMS——正则
    /// 提取后逐个实测可用性即可（未授予的组 containerURL 必为 nil，天然过滤误报）。
    /// 扩展包内若无 embedded.mobileprovision 则返回空，由默认组名兜底。
    static func profileAppGroupCandidates() -> [String] {
        // 1. 优先尝试读取主 App 的 bundle（通过 bundle identifier）
        // 扩展的 Bundle.main 没有 mobileprovision，需找主 App 的
        var sourceBundle: Bundle? = Bundle(identifier: "com.ipamanager.app")
        
        // 2. 如果通过 identifier 找不到，尝试所有已加载的 bundle
        if sourceBundle == nil {
            for bundle in Bundle.allBundles + Bundle.allFrameworks {
                if bundle.bundleIdentifier == "com.ipamanager.app" {
                    sourceBundle = bundle
                    break
                }
            }
        }
        
        // 3. 兜底使用 Bundle.main
        let bundle = sourceBundle ?? Bundle.main
        
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"group\.[A-Za-z0-9._\-]{2,64}"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let name = String(text[matchRange])
            if seen.insert(name).inserted {
                result.append(name)
            }
            if result.count >= 10 { break }
        }
        return result
    }
}
