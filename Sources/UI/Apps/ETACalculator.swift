import SwiftUI
import Foundation

/// 阶段感知的 ETA 估算器：AppDetailView 专用，保证进度回调与计时器共用同一算法。
/// zsign 真实进度只有 5/20/85/100 四档，平滑器假进度不能线性外推，需分段估算。
/// （原文件还包含一个 SignViewModel：其 @Published 状态与 AppDetailView 的本地
/// @State 完全重复，双份状态 + 双计时器导致每秒多轮无效 body 重算，已删除——
/// UI 统一读本地 @State，计时/ETA 逻辑由 AppDetailView 的 startSignTimer 承担。）
struct ETACalculator {
    static func estimatedRemainingSeconds(
        progress: Double,
        elapsed: TimeInterval,
        now: Date,
        repackStartTime: Date?,
        signStartTime: Date?
    ) -> Int {
        guard progress > 0 else { return 0 }
        if progress >= 0.85 {
            let base = repackStartTime.map { $0.timeIntervalSince(signStartTime ?? $0) } ?? elapsed
            let totalEstimate = max(base, elapsed) * 1.6
            return max(2, Int(totalEstimate - elapsed))
        }
        if progress >= 0.2 {
            return max(3, min(Int(elapsed * 1.5), 80))
        }
        return max(3, min(Int(elapsed * 2.0), 30))
    }
}
