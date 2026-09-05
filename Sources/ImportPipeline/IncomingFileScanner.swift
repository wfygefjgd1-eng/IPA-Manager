import Foundation

/// Incoming 接收队列扫描器（主 App 侧）：把 Share Extension 写入 App Group 的
/// 待处理任务认领出来，交给现有导入流水线。
///
/// 设计要点：扩展与主 App 不是同时存活的，任务凭据（JSON + 文件）必须已持久化
/// 在 App Group 里，本扫描器在主 App 启动/回前台时兜住所有"扩展先跑、App 后开"
/// 的时序——不依赖扩展能否唤起主 App。
enum IncomingFileScanner {
    /// 认领全部可处理任务：pending / 滞留 processing（上次进程死亡）的任务
    /// 标记为 processing 并随文件 URL 一并返回；调用方逐个交给
    /// handleFileOpenedFromOutside（统一入口），结算钩子回写终态。
    static func scanAndClaim() -> [(task: ImportTask, fileURL: URL)] {
        let claimable = ImportTaskStore.scanClaimableTasks()
        guard !claimable.isEmpty else { return [] }
        var claimed: [(task: ImportTask, fileURL: URL)] = []
        for (task, fileURL) in claimable {
            var claimedTask = task
            claimedTask.status = .processing
            claimedTask.error = nil
            ImportTaskStore.update(task: claimedTask)
            claimed.append((claimedTask, fileURL))
        }
        return claimed
    }
}
