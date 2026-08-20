import Foundation

struct SigningTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var sourceFile: String = ""
    var sourceAppName: String = ""
    var certificateID: UUID?
    var profileID: UUID?
    var outputPath: String?
    var createdAt: Date = Date()

    enum Status: String, Codable {
        case queued
        case processing
        case success
        case failed
    }

    var status: Status = .queued
    var progress: Double = 0
    /// 当前阶段文字（如"正在解压 IPA..."/"正在签名主程序..."/"正在重新打包..."），
    /// 供签名过程页与历史记录展示"正在干什么"。
    var phase: String = ""
    var error: String?
    var log: [String] = []

    var statusDescription: String {
        switch status {
        case .queued: return "等待中"
        case .processing: return "处理中"
        case .success: return "成功"
        case .failed: return "失败"
        }
    }
}
