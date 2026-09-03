import Foundation
import os.log

/// 外部投递追踪（持久化）：系统把文件投递给本 App 的每一条信号都记录到 UserDefaults
/// 环形缓冲，诊断报告末尾输出。此前诊断日志是纯内存态（每次启动清空），分享投递
/// 发生在上一次会话时报告里完全看不到——"分享后无反应"无法定位。记录的事件：
/// 启动（launchOptions 是否携带 URL/Activity）、openURL 事件（含 openInPlace）、
/// 回前台 Inbox 扫描结果、外部文件处理路由与结算结果。
enum ExternalDeliveryJournal {
    struct Entry: Codable {
        let timestamp: Date
        let event: String
    }

    private static let storageKey = "external_delivery_journal"
    /// 上限：分享 → 打开 App → 导出报告通常发生在最近几次启动内，120 条足够回溯
    static let maxEntries = 120
    private static let lock = OSAllocatedUnfairLock()
    private static var entries: [Entry] = []

    /// 记录一条投递事件并立即落盘：分享 → App 被杀 → 重新打开的时序下，
    /// 未落盘的最后几条会随进程死亡丢失，逐条持久化才能保证报告完整。
    static func record(_ event: String) {
        let entry = Entry(timestamp: Date(), event: event)
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        let snapshot = entries
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 启动时载入持久化记录（仅冷启动调用一次；已在内存时不动，避免覆盖本会话新增）
    static func load() {
        lock.lock()
        defer { lock.unlock() }
        guard entries.isEmpty,
              let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = stored
    }

    /// 诊断报告章节文本（按时间倒序）
    static func reportText() -> String {
        lock.lock()
        let snapshot = Array(entries.reversed())
        lock.unlock()
        guard !snapshot.isEmpty else { return "（无投递记录）" }
        // 诊断报告导出是低频操作：局部 formatter，不与其它路径共享实例
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return snapshot
            .map { "[\(formatter.string(from: $0.timestamp))] \($0.event)" }
            .joined(separator: "\n")
    }
    
    /// 获取当前所有投递日志条目（按时间正序，供 UI 实时展示）
    static func getEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
