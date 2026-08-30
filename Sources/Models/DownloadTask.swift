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

extension DownloadTask {
    private enum CodingKeys: String, CodingKey {
        case id, url, fileName, destinationPath, totalBytes, receivedBytes, createdAt
        case resumeData, retryCount, lastRetryDate, status, error, resolvedBundleID
    }

    /// 自定义解码：全部键用 decodeIfPresent + 默认值。
    /// Swift 合成 Decodable 不使用属性默认值——历史版本持久化的 JSON 缺少后加的
    /// 非可选字段（如 retryCount）时，合成解码会整体抛 keyNotFound，导致
    /// UserDefaultsStore.load 备份后清空，升级安装后全部下载任务记录消失。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        receivedBytes = try container.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        lastRetryDate = try container.decodeIfPresent(Date.self, forKey: .lastRetryDate)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .waiting
        error = try container.decodeIfPresent(String.self, forKey: .error)
        resolvedBundleID = try container.decodeIfPresent(String.self, forKey: .resolvedBundleID)
    }
}
