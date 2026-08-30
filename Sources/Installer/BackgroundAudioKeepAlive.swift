import Foundation
import AVFoundation
import UIKit

/// 静音音频保活器：itms-services 打开后 App 立即退到后台，若进程被挂起，
/// 本地 HTTP 服务器（NWListener）将不再接受新连接，SpringBoard 下载
/// manifest 和 IPA 时就会"连不上 127.0.0.1"。通过 audio 后台模式播放一段
/// 静音音频，让系统认为 App 正在播放音频，从而保持进程在后台持续运行，
/// 直到安装完成（AI 助手下载 IPA 可能耗时数十秒，必须全程保活）。
final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()

    private var player: AVAudioPlayer?
    private var isActive = false
    private var heartbeatTimer: Timer?
    /// 最长保活时限任务：本地安装通常在几十秒内完成，超过该时限自动停止，
    /// 避免安装链路异常卡住时静音播放 + 心跳日志永久运行（耗电 + 刷屏）。
    /// 超时触发时会先检查服务器活动：安装仍在进行则顺延一个周期，绝不挂起
    /// 进行中的安装（大 IPA / 用户在安装确认弹窗停留的耗时可能远超固定时限）。
    private var autoStopWorkItem: DispatchWorkItem?
    private let autoStopInterval: TimeInterval = 5 * 60

    private init() {}

    /// 开始保活：激活 playback AudioSession 并无限循环播放 1 秒静音 WAV。
    /// 幂等：已在保活时直接返回。本地服务器可能在后台队列启动（安装重活已移出
    /// 主线程），AVAudioSession/AVAudioPlayer 的设置统一切回主线程执行；
    /// isActive 幂等判定也在主线程做（旧版在外部线程判定 + 主线程启动，
    /// 两者竞争时会出现"服务器已停但静音音频空转满时限"的错序）。
    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMainThread()
        }
    }

    private func startOnMainThread() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            let wav = Self.silentWAV(seconds: 1)
            let player = try AVAudioPlayer(data: wav)
            // 音量用极小的非零值（不用 0.0）：部分 iOS 版本把 0 音量判定为"无实际音频输出"，
            // 会导致 audio 后台模式不生效、进程退后台即被挂起（本地服务器随之失联）。
            // 0.001 人耳完全听不到，但系统识别为"正在播放音频"，保活可靠。
            player.volume = 0.001
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            self.player = player
            isActive = true
            Logger.info("后台音频保活已启动（player.isPlaying=\(player.isPlaying)，本地安装服务器持续监听）")
            // 后台心跳：每 5 秒记录一次，证明退后台后进程仍未被挂起。
            // 若心跳日志中断/消失 → 进程被系统挂起，NWListener 停止接受连接，
            // 这才能解释"SpringBoard 从未收到连接"的根本原因。
            // 心跳用 debug 级别：不进诊断报告的失败专区，也不在正常日志里刷屏。
            startHeartbeat()
            scheduleAutoStop()
        } catch {
            Logger.warning("后台音频保活启动失败: \(error.localizedDescription)")
        }
    }

    private func startHeartbeat() {
        let t = Timer(timeInterval: 5.0, repeats: true) { _ in
            let playing = BackgroundAudioKeepAlive.shared.player?.isPlaying ?? false
            Logger.debug("后台音频保活心跳: 进程存活, player.isPlaying=\(playing)")
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    /// 启动最长时限自动停止（默认 5 分钟）：安装链路异常卡住时兜底停止保活，
    /// stop() 触发时会一并取消该定时任务；重复 start() 会重置计时。
    /// 到期时若安装仍在活动（最近半周期内有 itms-services 打开/连接/请求），
    /// 顺延一个周期再检查——固定时限会让 1GB+ 大包在下载中途被挂起、安装静默失败。
    private func scheduleAutoStop() {
        autoStopWorkItem?.cancel()
        let interval = autoStopInterval
        let work = DispatchWorkItem { [weak self] in
            // 状态判定与 autoStopWorkItem 的读写统一回主线程（与 start/stop 一致）
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 安装仍在进行的两种判定：近期有活动（传输/请求/打开），或
                // 安装会话本身未超时（确认弹窗停留期间无活动事件）。任一满足
                // 即顺延，绝不挂起进行中的安装。
                if LocalInstallServer.shared.hasRecentInstallActivity(within: interval / 2)
                    || LocalInstallServer.shared.isInstallSessionActive(within: 600) {
                    Logger.info("安装仍在进行，顺延后台保活 \(Int(interval)) 秒")
                    self.scheduleAutoStop()
                } else {
                    self.stop()
                }
            }
        }
        autoStopWorkItem = work
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + autoStopInterval, execute: work)
    }

    /// 停止保活：停掉静音播放并释放 AudioSession。幂等。
    /// 本方法可能从任意线程被调（服务器 stop 在后台队列、回前台在主线程）：
    /// Timer 加在主 RunLoop 上必须在主线程 invalidate，状态读写同理，
    /// 统一切回主线程执行（与 start 的处理对称）。
    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.stopOnMainThread()
        }
    }

    private func stopOnMainThread() {
        guard isActive else { return }
        autoStopWorkItem?.cancel()
        autoStopWorkItem = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        player?.stop()
        player = nil
        isActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // 释放失败不影响功能，忽略
        }
        Logger.info("后台音频保活已停止")
    }

    /// 生成指定秒数的静音 16-bit PCM WAV 数据（44 字节 WAV 头 + 全零采样）。
    private static func silentWAV(seconds: Int, sampleRate: Int = 8000) -> Data {
        let numSamples = sampleRate * seconds
        let dataSize = numSamples * 2
        var header = Data(capacity: 44 + dataSize)
        func appendString(_ s: String) {
            header.append(s.data(using: .ascii)!)
        }
        func appendUInt32LE(_ value: UInt32) {
            var v = value
            header.append(Data(bytes: &v, count: 4))
        }
        func appendUInt16LE(_ value: UInt16) {
            var v = value
            header.append(Data(bytes: &v, count: 2))
        }
        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)          // fmt chunk size
        appendUInt16LE(1)           // PCM
        appendUInt16LE(1)           // mono
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * 2)) // byte rate
        appendUInt16LE(2)           // block align
        appendUInt16LE(16)          // bits per sample
        appendString("data")
        appendUInt32LE(UInt32(dataSize))
        header.append(Data(count: dataSize)) // 全零（静音）
        return header
    }
}