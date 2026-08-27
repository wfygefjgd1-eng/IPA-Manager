import SwiftUI
import Foundation

/// 阶段感知的 ETA 估算器：从 AppDetailView 抽取，保证 View 与 ViewModel 共用同一算法
/// zsign 真实进度只有 5/20/85/100 四档，平滑器假进度不能线性外推，需分段估算
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

/// 签名进度 ViewModel：抽取 AppDetailView 中分散的 @State 时序/计时逻辑
/// 采用 @MainActor 保证 Published 更新在主线程，Timer 仅在主线程调度
@MainActor
final class SignViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var phase: String = ""
    @Published var elapsedSeconds: Int = 0
    @Published var etaSeconds: Int = 0
    @Published var isSigning: Bool = false
    @Published var closeLocked: Bool = false

    private var signStartTime: Date?
    private var repackStartTime: Date?
    private var signTimer: Timer?
    private var lastProgressUpdate = Date.distantPast

    /// 开始一次签名会话：重置状态并启动计时器
    func start() {
        progress = 0
        phase = "准备中…"
        elapsedSeconds = 0
        etaSeconds = 0
        lastProgressUpdate = Date.distantPast
        repackStartTime = nil
        signStartTime = Date()
        isSigning = true
        closeLocked = true
        startTimer()
    }

    /// 进度回调：节流更新 progress/phase，并在需要时刷新 ETA 与锚点
    func update(progress newProgress: Double, phase newPhase: String) {
        let now = Date()
        // 节流：变化 ≥1% 或间隔 ≥0.1s 才更新
        if abs(newProgress - progress) >= 0.01 || now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
            progress = newProgress
            lastProgressUpdate = now
        }
        if !newPhase.isEmpty {
            phase = newPhase
        }
        if newProgress >= 0.85 && repackStartTime == nil {
            repackStartTime = now
        }
        if newProgress > 0, let start = signStartTime {
            let elapsed = now.timeIntervalSince(start)
            elapsedSeconds = Int(elapsed)
            etaSeconds = ETACalculator.estimatedRemainingSeconds(
                progress: newProgress,
                elapsed: elapsed,
                now: now,
                repackStartTime: repackStartTime,
                signStartTime: signStartTime
            )
        }
    }

    func completeSuccess() {
        stopTimer()
        isSigning = false
        closeLocked = false
        progress = 1.0
        phase = "签名完成"
        if let start = signStartTime {
            elapsedSeconds = Int(Date().timeIntervalSince(start))
        }
        etaSeconds = 0
    }

    func completeFailure() {
        stopTimer()
        isSigning = false
        closeLocked = false
    }

    func resetAfterComplete(signStartTime: Date? = nil) {
        // 供外部在需要时手动重置（当前由 start() 统一处理）
    }

    private func startTimer() {
        stopTimer()
        signTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard let start = self.signStartTime else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.elapsedSeconds = Int(elapsed)
                if self.progress > 0 && self.progress < 1.0 {
                    self.etaSeconds = ETACalculator.estimatedRemainingSeconds(
                        progress: self.progress,
                        elapsed: elapsed,
                        now: Date(),
                        repackStartTime: self.repackStartTime,
                        signStartTime: self.signStartTime
                    )
                } else if self.progress >= 1.0 {
                    self.etaSeconds = 0
                }
            }
        }
    }

    func stopTimer() {
        signTimer?.invalidate()
        signTimer = nil
    }

    func cleanupOnDisappear() {
        stopTimer()
    }

    // 暴露给 View 的锚点设置（兼容旧 AppDetailView 直接操作 repackStartTime 的路径）
    func setRepackStartIfNeeded(progress: Double) {
        if progress >= 0.85 && repackStartTime == nil {
            repackStartTime = Date()
        }
    }

    deinit {
        // Timer 由 View 的 onDisappear / complete 调用 stopTimer 清理，避免在 deinit 触及 MainActor 隔离状态
    }
}
