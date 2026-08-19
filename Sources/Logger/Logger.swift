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

    private static let maxEntries = 300
    private static let lock = NSLock()
    private(set) static var recentEntries: [LogEntry] = []

    static func log(_ message: String, level: OSLogType = .info, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let log = OSLog(subsystem: subsystem, category: "IPA Manager")
        os_log("%@ [%@:%d] %@", log: log, type: level, level.description, fileName, line, message)
        #if DEBUG
        print("[\(level.description)] \(fileName):\(line) \(message)")
        #endif

        lock.lock()
        defer { lock.unlock() }
        recentEntries.append(LogEntry(timestamp: Date(), level: level.description, message: "[\(fileName):\(line)] \(message)"))
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
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
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        let device = UIDevice.current
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = bundle?["CFBundleVersion"] as? String ?? "未知"

        lock.lock()
        let entries = Array(recentEntries.suffix(100).reversed())
        lock.unlock()

        var lines: [String] = []
        lines.append("IPA Manager 诊断报告")
        lines.append("生成时间：\(timestampFormatter.string(from: Date()))")
        lines.append("")
        lines.append("设备信息")
        lines.append("型号：\(device.model)")
        lines.append("系统：\(device.systemName) \(device.systemVersion)")
        lines.append("")
        lines.append("App 信息")
        lines.append("版本：\(version) (\(build))")
        lines.append("")
        lines.append("最近日志")

        if entries.isEmpty {
            lines.append("（无日志记录）")
        } else {
            for entry in entries {
                lines.append("[\(timeFormatter.string(from: entry.timestamp))][\(entry.level)] \(entry.message)")
            }
        }

        lines.append("")
        lines.append("由 IPA Manager 诊断功能生成")

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
