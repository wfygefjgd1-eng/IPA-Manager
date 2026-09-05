import Foundation
import os

/// 主 App 与分享/动作扩展共用的 App Group 常量与收件箱逻辑。
///
/// 组解析设计（v1.0.142 重构）——每个进程独立解析，跨进程没有可依赖的共享状态
/// （扩展的 UserDefaults 与主 App 完全隔离，扩展沙盒还常常禁止读主 App 能读的
/// 沙盒外路径），旧版"默认组名 → 本进程缓存 → 文件系统扫描"三连在扩展进程内
/// 会全部失败且**静默**（连"扩展启动"日志都写不出来，诊断全盲）。新版策略：
///
/// 1. 候选组名多来源合并：工程声明的默认组名 + **本 target 自己的
///    embedded.mobileprovision 实际授予的组**（签名服务常用任意组名，真相只在
///    这个文件里；App 与扩展各带一份自己的描述文件，无需跨进程传递）+ 本进程
///    历史缓存 + 沙盒外目录扫描兜底；
/// 2. 每个候选组逐一做"可写探针"实测（containerURL 非 nil 不代表可写），通过的
///    进入可用容器集合；
/// 3. **写入侧扇出**：扩展保存文件/日志时写入全部可用容器——即使两个进程解析
///    到不同组，文件也必然落在主 App 看得见的至少一个容器里；
/// 4. **读取侧扇入**：主 App 扫描收件箱/日志时枚举全部可用容器——与扇出对称，
///    组错位不再可能丢文件。
enum AppGroup {
    /// 工程 entitlements 声明的默认组名（xcodegen 生成，三 target 一致），作为候选之首
    static let defaultIdentifier = "group.com.ipamanager.app"

    /// 一个实测可用的共享容器（探针通过 = containerURL 非 nil 且可写）
    struct Container: Equatable {
        let identifier: String
        let url: URL
    }

    private static let lock = OSAllocatedUnfairLock()
    /// 进程内已解析的可用容器集合（探针结果缓存，进程生命周期内有效）
    private static var cachedContainers: [Container]?
    /// 本进程 UserDefaults 缓存的组名（仅辅助排序，不作为唯一依据）
    private static var cachedIdentifier: String?
    private static let resolvedIdentifierKey = "resolved_app_group_identifier"

    /// 扩展日志文件名（存放在共享容器根目录，主 App 与扩展共用）。
    /// 扩展是独立进程，主 App 的 ExternalDeliveryJournal 看不到它；
    /// 扩展把关键节点写进这个文件，主 App 扫描时吞入诊断。
    /// 主 App 扇入消费时需要按此文件名定位（公开给主 App 侧使用）。
    static let extensionLogFileName = "ExtensionLog.txt"
    /// 扩展日志上限（字节）：超出后保留后半段，避免无限增长。
    private static let extensionLogMaxBytes = 65_536
    /// 扇出写入的大小阈值：超过此大小的文件只在主容器保存一次（扩展进程磁盘
    /// 配额与耗时有限，数 GB 包双写既慢又挤占空间）；组解析已因"描述文件授予组"
    /// 进候选而高度一致，大文件双写的边际收益不抵成本。小于阈值才向其余容器冗余。
    private static let fanOutMaxBytes: Int64 = 512 * 1024 * 1024

    // MARK: - 候选组名

    /// 未探针状态下的原始候选（调用方必须已持锁）
    private static func unresolvedCandidateIdentifiersLocked() -> [String] {
        var candidates: [String] = [defaultIdentifier]
        candidates.append(contentsOf: profileGrantedIdentifiers())
        if cachedIdentifier == nil {
            cachedIdentifier = UserDefaults.standard.string(forKey: resolvedIdentifierKey)
        }
        if let cached = cachedIdentifier {
            candidates.append(cached)
        }
        candidates.append(contentsOf: scanAvailableAppGroups())
        var seen = Set<String>()
        return candidates.filter { identifier in
            guard !identifier.isEmpty else { return false }
            return seen.insert(identifier).inserted
        }
    }

    /// 候选组名（对外/持锁包装）：诊断路径用，避免与解析状态的数据竞争
    private static var allCandidateIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedContainers { return cached.map { $0.identifier } }
        return unresolvedCandidateIdentifiersLocked()
    }

    /// 从本 target 自带的 embedded.mobileprovision 提取描述文件实际授予的 App Groups。
    /// App 与扩展的 bundle 内各有一份自己的描述文件（签名工具注入），这是不需要
    /// 跨进程传递、也不需要沙盒外路径权限的组名真相来源。
    static func profileGrantedIdentifiers() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }
        return groupsInProvisionData(data)
    }

    /// 从 mobileprovision 原始数据提取 group.* 组名。CMS 二进制包裹里组名是
    /// ASCII 明文，非法字节按替换字符解码后正则提取即可（诊断报告同源逻辑）。
    static func groupsInProvisionData(_ data: Data) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"group\.[A-Za-z0-9._\-]{2,64}"#) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let name = String(text[matchRange])
            if seen.insert(name).inserted { result.append(name) }
            if result.count >= 10 { break }
        }
        return result
    }

    /// 沙盒外目录扫描兜底：列出系统共享 AppGroup 目录、读各容器 metadata 的
    /// 组标识。该路径在扩展进程沙盒下常被拒绝（返回 nil 即放弃），主 App 在
    /// 部分签名环境下可用——仅作最后的兜底来源，失败完全不影响前两级候选。
    private static func scanAvailableAppGroups() -> [String] {
        let appGroupDir = "/var/mobile/Containers/Shared/AppGroup"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appGroupDir) else {
            return []
        }
        var found: [String] = []
        for containerUUID in contents {
            let metadataPath = "\(appGroupDir)/\(containerUUID)/.com.apple.mobile_container_manager.metadata.plist"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  let identifier = dict["MCMMetadataIdentifier"] as? String else { continue }
            if !found.contains(identifier) {
                found.append(identifier)
            }
            if found.count >= 10 { break }
        }
        return found
    }

    // MARK: - 可用容器（探针实测）

    /// 全部实测可用（containerURL 非 nil 且可写）的容器，进程内缓存。
    /// 顺序即候选优先级：第一个是主容器（保存文件的主落点）。
    static func usableContainers() -> [Container] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedContainers { return cached }
        var usable: [Container] = []
        for identifier in unresolvedCandidateIdentifiersLocked() {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier),
                  isWritable(url) else { continue }
            let container = Container(identifier: identifier, url: url)
            if !usable.contains(container) {
                usable.append(container)
            }
        }
        cachedContainers = usable
        // 记住解析结果（仅本进程视角的辅助缓存；下次启动排序用）
        if let first = usable.first?.identifier ?? cachedIdentifier {
            UserDefaults.standard.set(first, forKey: resolvedIdentifierKey)
            cachedIdentifier = first
        }
        return usable
    }

    /// 可写探针：写入-读回-删除一个小文件。containerURL(forSecurityApplicationGroupIdentifier:)
    /// 非 nil 只证明"系统认这个组名"，不代表本进程真的能写（签名/沙盒配置差异下
    /// 常见"有路径但 IO 被拒"），必须实测才算可用。
    private static func isWritable(_ containerURL: URL) -> Bool {
        let probe = containerURL.appendingPathComponent(".ipamanager-probe-\(UUID().uuidString)")
        let payload = Data("ok".utf8)
        guard (try? payload.write(to: probe, options: .atomic)) != nil else { return false }
        let readBack = try? Data(contentsOf: probe)
        try? FileManager.default.removeItem(at: probe)
        return readBack == payload
    }

    /// 主容器组名。返回 nil 表示当前进程没有任何可用共享容器。
    static func resolvedIdentifier() -> String? {
        usableContainers().first?.identifier
    }

    // MARK: - 收件箱

    private static func inboxURLIfPresent(in container: Container?) -> URL? {
        guard let container else { return nil }
        let inbox = container.url.appendingPathComponent("Inbox", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return inbox
    }

    /// 全部可用容器的收件箱 URL（读取侧扇入用）
    static var allInboxURLsIfPresent: [URL] {
        usableContainers().compactMap { inboxURLIfPresent(in: $0) }
    }

    private static func ensureInboxURL(in container: Container?) -> URL? {
        guard let container else { return nil }
        let inbox = container.url.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: inbox.path) {
            do {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return inbox
    }

    /// 把外部文件复制进**全部**可用容器的收件箱（写入侧扇出）：
    /// - 主容器必须成功，全部容器都失败时抛出携带完整诊断信息的错误（扩展 UI
    ///   直接展示，不再静默）；
    /// - 其余容器 best-effort 冗余写入（小文件才扇出，大文件只落主容器），
    ///   任一容器成功即保证主 App 扫得到（读取侧枚举全部容器）。
    @discardableResult
    static func saveIncomingFile(at sourceURL: URL, preferredFileName: String? = nil) throws -> URL {
        let containers = usableContainers()
        guard !containers.isEmpty else {
            throw NSError(
                domain: "AppGroup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: diagnosticUnavailableMessage()]
            )
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        var primaryDestination: URL?
        var failures: [String] = []
        for container in containers {
            // 主容器未成功前逐个尝试；成功后仅小文件继续向其余容器冗余
            if primaryDestination != nil && size > fanOutMaxBytes { break }
            do {
                let dest = try copyIntoInbox(of: container, sourceURL: sourceURL, preferredFileName: preferredFileName)
                if primaryDestination == nil {
                    primaryDestination = dest
                    appendExtensionLog("已保存到主容器（组 \(container.identifier)）：\(dest.lastPathComponent)")
                } else {
                    appendExtensionLog("冗余写入容器（组 \(container.identifier)）：\(dest.lastPathComponent)")
                }
            } catch {
                failures.append("组 \(container.identifier)：\(error.localizedDescription)")
                appendExtensionLog("写入容器失败（组 \(container.identifier)）：\(error.localizedDescription)")
            }
        }
        guard let primaryDestination else {
            throw NSError(
                domain: "AppGroup", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "共享收件箱写入失败（已尝试 \(containers.count) 个容器）\n"
                    + failures.joined(separator: "\n")]
            )
        }
        return primaryDestination
    }

    /// 单容器收件箱复制：收件箱不存在则创建，重名不覆盖（追加序号）
    private static func copyIntoInbox(of container: Container, sourceURL: URL, preferredFileName: String?) throws -> URL {
        guard let inbox = ensureInboxURL(in: container) else {
            throw NSError(domain: "AppGroup", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "收件箱目录创建失败"])
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

    /// 共享容器完全不可用时的用户可读诊断（扩展 UI 与错误信息共用）。
    /// 列出"声明了什么、描述文件授予了什么、试了哪些组、为什么不行"，
    /// 让用户拿着这段话就能找签名供应商解决。
    static func diagnosticUnavailableMessage() -> String {
        let granted = profileGrantedIdentifiers()
        let grantedText = granted.isEmpty
            ? "描述文件未授予任何 App Group（通配符/精简 profile 常见）"
            : granted.joined(separator: "、")
        let probeResults = allCandidateIdentifiers.map { identifier -> String in
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                return "\(identifier)：containerURL 为 nil（未授权给本进程）"
            }
            return isWritable(url)
                ? "\(identifier)：可用"
                : "\(identifier)：有路径但不可写（沙盒/签名限制）"
        }
        return """
        ⚠️ 共享容器不可用：当前进程没有任何可写的 App Group 容器，无法交接文件。
        声明的默认组：\(defaultIdentifier)
        描述文件实际授予：\(grantedText)
        逐组实测：\(probeResults.joined(separator: "；"))
        解决办法：用包含 App Group 能力、且同时覆盖主 App 与扩展 Bundle ID 的描述文件重签本 App（签名供应商处开通），或改用 文件 App → 分享 → 拷贝到 IPA Manager。
        """
    }

    // MARK: - 跨进程日志

    /// 跨进程日志：由扩展进程调用，主 App 扫描时读取。
    /// **绝不被组解析门控**：旧版在组解析失败时静默丢弃，导致"扩展启动"这行
    /// 日志永远写不出来、诊断全盲。新版写入全部可用容器；一个容器都没有时降级
    /// 走 NSLog（系统日志，sysdiagnose 可见），保证扩展侧活动永不静默消失。
    static func appendExtensionLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let tag = (Bundle.main.bundleIdentifier ?? "?")
            .replacingOccurrences(of: "com.ipamanager.app.", with: "")
        let line = "[\(formatter.string(from: Date()))][\(tag)] \(message)"
        let data = Data((line + "\n").utf8)
        var wrote = false
        for container in usableContainers() {
            if writeLogLine(data, to: container.url) { wrote = true }
        }
        if !wrote {
            NSLog("[IPAManagerExt][无可用共享容器] %@", line)
        }
    }

    /// 向单个容器写一行日志（超限截断：只保留后半段），失败返回 false
    private static func writeLogLine(_ data: Data, to containerURL: URL) -> Bool {
        let logURL = containerURL.appendingPathComponent(extensionLogFileName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int, size > extensionLogMaxBytes,
           let existing = try? Data(contentsOf: logURL), existing.count > extensionLogMaxBytes / 2 {
            let trimmed = existing.suffix(extensionLogMaxBytes / 2).drop(while: { $0 != 0x0A }).dropFirst()
            try? Data(trimmed + data).write(to: logURL, options: .atomic)
            return true
        }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
        do {
            try data.write(to: logURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 单容器扩展日志全文（诊断/扇入用；无容器/无文件/空文件返回 nil）
    private static func extensionLogData(in container: Container) -> Data? {
        let logURL = container.url.appendingPathComponent(extensionLogFileName)
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return nil }
        return data
    }

    /// 读取全部可用容器的扩展日志（主 App 扇入）：每容器一段，带组名标题。
    /// 返回 nil 表示所有容器都没有日志——扩展从未成功写入（可能从未被唤起、
    /// 启动即失败，或共享容器整体不可用）。
    static func readAllExtensionLogs() -> String? {
        let containers = usableContainers()
        guard !containers.isEmpty else { return nil }
        var sections: [String] = []
        for container in containers {
            guard let data = extensionLogData(in: container),
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if containers.count == 1 {
                sections.append(text)
            } else {
                sections.append("── 组 \(container.identifier) ──\n\(text)")
            }
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n")
    }

    /// 扩展日志文件 URL（历史 API 兼容：主容器；仅供旧调用点探测存在性）
    static var extensionLogLastModifiedDate: Date? {
        usableContainers().compactMap { container -> Date? in
            let logURL = container.url.appendingPathComponent(extensionLogFileName)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path) else { return nil }
            return attrs[.modificationDate] as? Date
        }.max()
    }

    // MARK: - 诊断摘要

    /// 当前进程的组解析与容器状态摘要（扩展失败 UI 与诊断报告共用，
    /// 每行一条，给用户直接可读的结论）。
    static func diagnosticsSummary() -> [String] {
        var lines: [String] = []
        let containers = usableContainers()
        let granted = profileGrantedIdentifiers()
        lines.append("进程：\(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("声明的默认组：\(defaultIdentifier)")
        lines.append("描述文件实际授予：\(granted.isEmpty ? "读不到（无 embedded.mobileprovision 或未授予组）" : granted.joined(separator: "、"))")
        if containers.isEmpty {
            lines.append("可用容器：无（全部候选组探针失败）")
            lines.append(diagnosticUnavailableMessage())
        } else {
            let ids = containers.map { $0.identifier }.joined(separator: "、")
            lines.append("可用容器（探针实测可写）：\(ids)")
            for container in containers {
                let inbox = inboxURLIfPresent(in: container)
                let count = inbox.flatMap { url -> Int? in
                    (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
                }
                lines.append("  组 \(container.identifier)：收件箱\(inbox != nil ? "存在" : "不存在")\(count.map { "，\($0) 个文件" } ?? "")")
            }
        }
        return lines
    }
}
