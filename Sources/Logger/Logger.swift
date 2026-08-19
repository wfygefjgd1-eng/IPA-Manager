import Foundation
import os.log

enum Logger {
    static let subsystem = "com.ipamanager.app"

    static func log(_ message: String, level: OSLogType = .info, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let log = OSLog(subsystem: subsystem, category: "IPA Manager")
        os_log("%@ [%@:%d] %@", log: log, type: level, level.description, fileName, line, message)
        #if DEBUG
        print("[\(level.description)] \(fileName):\(line) \(message)")
        #endif
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .info, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .error, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .debug, file: file, line: line)
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
