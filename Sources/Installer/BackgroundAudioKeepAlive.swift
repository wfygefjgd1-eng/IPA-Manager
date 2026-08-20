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

    private init() {}

    /// 开始保活：激活 playback AudioSession 并无限循环播放 1 秒静音 WAV。
    /// 幂等：已在保活时直接返回。
    func start() {
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
        } catch {
            Logger.warning("后台音频保活启动失败: \(error.localizedDescription)")
        }
    }

    /// 停止保活：停掉静音播放并释放 AudioSession。幂等。
    func stop() {
        guard isActive else { return }
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