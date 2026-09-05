import Foundation
import os.log

/// 外部投递追踪（持久化）：分享/投递链路每一条信号都记录到 UserDefaults 环形缓冲，
/// 诊断报告与日志页共用。此前诊断日志是纯内存态（每次启动清空），分享投递
/// 发生在上一次会话时报告里完全看不到——"分享后无反应"无法定位。
///
/// v1.0.142 重构：
/// - 条目带级别（info/ok/warning/error），"失败与异常"专区可跨启动覆盖投递链路；
/// - 连续重复条目去重（旧版每次回前台固定刷 2~4 条扫描行，120 条环形缓冲约
///   20 次前后台切换就刷光，真实信号被淹没——扫描日志已改为 AppState 侧状态
///   变化才记，这里再兜一层完全相同的连续条目）；
/// - 支持清空与查询（最近真实投递、扩展最近活动、错误计数），日志页据此展示摘要。
enum ExternalDeliveryJournal {
    enum Level: String, Codable {
        case info
        case ok
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: return "·"
            case .ok: return "✓"
            case .warning: return "⚠"
            case .error: return "✕"
            }
        }
    }

    struct Entry: Codable {
        let timestamp: Date
        let event: String
        /// 旧版本条目无该字段，解码缺省为 .info（历史记录不因升级丢失）
        let level: Level

        init(timestamp: Date, event: String, level: Level = .info) {
            self.timestamp = timestamp
            self.event = event
            self.level = level
        }

        private enum CodingKeys: String, CodingKey {
            case timestamp, event, level
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            event = try container.decode(String.self, forKey: .event)
            level = try container.decodeIfPresent(Level.self, forKey: .level) ?? .info
        }
    }

    private static let storageKey = "external_delivery_journal"
    /// 上限：降噪后扫描行只在状态变化时产生，真实投递事件是低频信号，120 条足够回溯
    static let maxEntries = 120
    /// 完全相同的连续条目在该时间窗口内不重复落盘（扫描/复查双触发去重兜底）
    private static let consecutiveDedupeWindow: TimeInterval = 2.0
    private static let lock = OSAllocatedUnfairLock()
    private static var entries: [Entry] = []
    private static var didLoad = false

    /// 记录一条投递事件并立即落盘：分享 → App 被杀 → 重新打开的时序下，
    /// 未落盘的最后几条会随进程死亡丢失，逐条持久化才能保证报告完整。
    static func record(_ event: String, level: Level = .info) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        // 连续重复去重：与上一条事件文本相同且在窗口内，只刷新时间不新增
        if let last = entries.last,
           last.event == event,
           Date().timeIntervalSince(last.timestamp) < consecutiveDedupeWindow {
            return
        }
        entries.append(Entry(timestamp: Date(), event: event, level: level))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persistLocked()
    }

    /// 清空全部记录（日志页"清空"按钮）：内存与持久化同步清
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 启动时载入持久化记录（仅冷启动调用一次；已在内存时不动，避免覆盖本会话新增）
    static func load() {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
    }

    /// 载入持久化记录（调用方必须已持锁）
    private static func loadIfNeededLocked() {
        guard !didLoad else { return }
        didLoad = true
        guard entries.isEmpty,
              let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = stored
    }

    /// 持久化当前快照（调用方必须已持锁）
    private static func persistLocked() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 诊断报告章节文本（按时间倒序；完全相同的连续条目折叠成一行计数，
    /// 降噪前的历史残留不再占满报告）
    static func reportText() -> String {
        lock.lock()
        let snapshot = Array(entries.reversed())
        lock.unlock()
        guard !snapshot.isEmpty else { return "（无投递记录）" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var lines: [String] = []
        var index = 0
        while index < snapshot.count {
            let entry = snapshot[index]
            var repeats = 1
            while index + repeats < snapshot.count, snapshot[index + repeats].event == entry.event {
                repeats += 1
            }
            let levelTag = entry.level == .info ? "" : "[\(entry.level.rawValue)] "
            if repeats == 1 {
                lines.append("[\(formatter.string(from: entry.timestamp))] \(levelTag)\(entry.event)")
            } else {
                lines.append("[\(formatter.string(from: entry.timestamp))] \(levelTag)\(entry.event)（连续重复 \(repeats) 次，已折叠）")
            }
            index += repeats
        }
        return lines.joined(separator: "\n")
    }

    /// 获取当前所有投递日志条目（按时间正序，供 UI 实时展示）
    static func getEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        return entries
    }

    // MARK: - 摘要查询（日志页摘要卡用）

    /// 最近一条"真实投递"事件（排除扫描/生命周期等常规噪音）：文本包含投递动作
    /// 关键词才计——扫描行是"扫描：/回前台"开头，事件行是"处理外部文件/投递结算/
    /// 已接收/已保存"等。找不到返回 nil（从未发生过投递动作）。
    static func lastDeliveryEvent() -> Entry? {
        let noisePrefixes = ["扫描：", "回前台", "冷启动", "scenePhase", "共享容器组集合"]
        return getEntries().reversed().first { entry in
            !noisePrefixes.contains { entry.event.hasPrefix($0) }
        }
    }

    /// 最近一条扩展侧记录（AppState 吞入的"扩展："前缀行）的时间
    static func lastExtensionActivityDate() -> Date? {
        getEntries().reversed().first { $0.event.hasPrefix("扩展：") }?.timestamp
    }

    /// 错误级条目计数
    static func errorCount() -> Int {
        getEntries().filter { $0.level == .error }.count
    }
}
