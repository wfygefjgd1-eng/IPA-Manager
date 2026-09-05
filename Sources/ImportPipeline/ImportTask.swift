import Foundation

/// 统一导入任务模型：Share Extension / 文件 App / 主 App 内部导入等所有来源
/// 的文件都对应一条任务记录，随文件一起持久化在 App Group 容器的
/// `Incoming/Tasks/<UUID>.json`。
///
/// 任务记录的作用：
/// 1. 扩展与主 App 不可能同时存活，任务 JSON 是两者之间唯一可靠的交接凭据
///   （扩展写入并验证后才结束请求，主 App 扫描认领，进程死亡也不丢）；
/// 2. 给 UI 提供跨进程可读的任务状态（正在导入/解析/签名/安装/完成/失败+原因）。
struct ImportTask: Codable, Equatable {
    /// 任务状态机：与导入流水线各阶段一一对应，禁止用散装布尔拼凑状态
    enum Status: String, Codable {
        case pending        // 扩展已落盘，等待主 App 认领
        case copying        // 文件复制中（扩展内部阶段，落盘前短暂存在）
        case copied         // 文件已复制、任务已写入（扩展侧完成态）
        case processing     // 主 App 已认领，进入导入流水线
        case extracting     // 解压/转换中（zip）
        case parsing        // IPA 解析中
        case signing        // 签名中
        case signed         // 签名完成
        case installing     // 安装已发起
        case completed      // 全流程完成
        case failed         // 失败（error 携带原因，源文件保留可重试）
    }

    let id: UUID
    /// 用户原始文件名（仅展示用）
    let originalFileName: String
    /// App Group 内的实际存储名（UUID 前缀，防同名覆盖/特殊字符/路径冲突）
    let storedFileName: String
    /// 文件类型（ipa / zip / 证书 / other），决定进入哪条管线
    let type: String
    let createdAt: Date
    var status: Status
    /// 失败原因（status == .failed 时有意义）
    var error: String?

    init(originalFileName: String, storedFileName: String, type: String) {
        self.id = UUID()
        self.originalFileName = originalFileName
        self.storedFileName = storedFileName
        self.type = type
        self.createdAt = Date()
        self.status = .pending
        self.error = nil
    }
}
