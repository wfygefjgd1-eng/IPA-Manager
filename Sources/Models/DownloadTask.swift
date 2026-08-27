import Foundation

struct DownloadTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: String = ""
    var fileName: String = ""
    var destinationPath: String = ""
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var createdAt: Date = Date()
    /// 断点续传数据：下载中断/失败时由 URLSession 提供，重启后可续传
    var resumeData: Data?
    /// 自动重试计数：用于追踪已重试次数，避免进程重启后无限重试
    var retryCount: Int = 0
    /// 上次重试时间：用于超过 24 小时后自动重置 `retryCount`，防止长时间未完成的任务永远卡在"已达重试上限"
    var lastRetryDate: Date?

    enum Status: String, Codable {
        case waiting
        case downloading
        case paused
        case completed
        case failed
    }

    var status: Status = .waiting
    var error: String?
    /// 自动导入成功后回填的 bundleID：matchedApp 优先按它精确匹配，
    /// 不依赖可能重名的文件名/应用名
    var resolvedBundleID: String?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(receivedBytes) / Double(totalBytes), 1.0)
    }

    var statusDescription: String {
        switch status {
        case .waiting: return "等待中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}
