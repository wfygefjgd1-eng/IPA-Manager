import Foundation
import os.log
import UIKit

enum Logger {
    static let subsystem = "com.ipamanager.app"

    struct LogEntry: Codable {
        let timestamp: Date
        let level: String
        let message: String
    }

    private static let maxEntries = Limits.maxLogEntries
    private static let maxFailureEntries = Limits.maxFailureEntries
    // os_unfair_lock：相比 NSLock 轻量（不自旋、不绑定 pthread），且不会在等锁线程
    // 持有 Send 权限上出问题；关键修复点：NSLock 是阻塞锁，若 os_log 内部触发 KVO/
    // NotificationCenter → 再调 Logger.log → 同线程可重入 NSLock 直接死锁。
    // os_unfair_lock 显式标 _checking(Foundation,Swift) 即可在 Swift 6 strict-concurrency
    // 下安全使用。
    private static let lock = OSAllocatedUnfairLock()
    private(set) static var recentEntries: [LogEntry] = []
    /// 失败与异常专区：只收集 ERROR / warning（DEFAULT）等非 INFO/DEBUG 的消息，供诊断报告使用。
    private(set) static var failureEntries: [LogEntry] = []
    /// OSLog 对象可复用：每次调用都新建会白白浪费一次对象构造开销（签名/下载
    /// 进度类高频日志尤其明显），提升为单一 static 实例。
    private static let log = OSLog(subsystem: subsystem, category: "IPA Manager")

    static func log(_ message: String, level: OSLogType = .info, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        // 提前求值 level.description 为本地常量：避免直接传入 OSLogType 临时
        // 描述字符串作为 os_log 的 %@ vararg（C 字符串约定下生命周期不显式，
        // Swift 6 strict-concurrency 下需要明确 ownership）
        let levelDesc = level.description
        os_log("%@ [%@:%d] %@", log: log, type: level, levelDesc, fileName, line, message)
        #if DEBUG
        print("[\(levelDesc)] \(fileName):\(line) \(message)")
        #endif

        lock.lock()
        defer { lock.unlock() }
        let entry = LogEntry(timestamp: Date(), level: levelDesc, message: "[\(fileName):\(line)] \(message)")
        recentEntries.append(entry)
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
        }
        // 错误类消息（error / warning，即非 info/debug）自动进入失败专区
        if level != .info && level != .debug {
            failureEntries.append(entry)
            if failureEntries.count > maxFailureEntries {
                failureEntries.removeFirst(failureEntries.count - maxFailureEntries)
            }
        }
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .info, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .error, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .default, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .debug, file: file, line: line)
    }

    static func diagnosticsReport() -> String {
        // 诊断报告导出是低频操作（设置页手动触发）：在这里新建局部 formatter，
        // 不与其它路径共享 DateFormatter 实例（DateFormatter 非线程安全，
        // 共享实例在报告生成与并发日志写入之间是潜伏的数据竞争）。
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let device = UIDevice.current
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = bundle?["CFBundleVersion"] as? String ?? "未知"

        lock.lock()
        let recent = Array(recentEntries.suffix(Limits.maxRecentInReport).reversed())
        let failures = Array(failureEntries.reversed())
        lock.unlock()

        var lines: [String] = []
        lines.append("IPA Manager 诊断报告")
        lines.append("")
        lines.append("===== 基本信息 =====")
        lines.append("时间：\(timestampFormatter.string(from: Date()))")
        lines.append("设备型号：\(device.model)")
        lines.append("系统版本：\(device.systemName) \(device.systemVersion)")
        lines.append("App 版本：\(version) (构建 \(build))")
        lines.append("")
        lines.append("===== 失败与异常（按时间倒序）=====")

        if failures.isEmpty {
            lines.append("（无失败记录）")
        } else {
            for entry in failures {
                lines.append("[\(timeFormatter.string(from: entry.timestamp))][\(entry.level)] \(entry.message)")
            }
        }

        lines.append("")
        lines.append("===== 最近日志（最近 100 条含 INFO）=====")

        if recent.isEmpty {
            lines.append("（无日志记录）")
        } else {
            for entry in recent {
                lines.append("[\(timeFormatter.string(from: entry.timestamp))][\(entry.level)] \(entry.message)")
            }
        }

        lines.append("")
        lines.append("由 IPA Manager 诊断功能导出")

        return lines.joined(separator: "\n")
    }
}

private extension OSLogType {
    var description: String {
        switch self {
        case .info: return "INFO"
        case .error: return "ERROR"
        case .debug: return "DEBUG"
        case .fault: return "FAULT"
        default: return "DEFAULT"
        }
    }
}