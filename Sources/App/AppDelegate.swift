import Foundation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 启动清理：本地服务器 TLS 身份遗留的钥匙串孤儿条目。
        // 服务器已改明文 HTTP（NWParameters.tcp），旧版本 setIdentity 写入的
        // "IPA Manager Server Cert" / "IPA Manager Server Identity <uuid>"
        // 证书/私钥条目 App 卸载后不会自动清除，统一在启动时清理。
        CertificateManager.cleanupServerIdentityKeychainItems()
        // 冷启动分享投递兜底：分享面板「拷贝到 IPA Manager」冷启动 App 时，个别系统
        // 版本/时序下 application(_:open:) 与 onOpenURL 均不回调，open 事件丢失表现为
        // "分享后毫无反应"。launchOptions[.url] 是系统冷启动保证携带的投递通道；若
        // open/onOpenURL 随后重复投递同一 URL，由 AppState 的去重兜住，不会双重导入。
        if let url = launchOptions?[.url] as? URL {
            Logger.info("冷启动携带外部文件: \(url.lastPathComponent)")
            AppState.shared.handleFileOpenedFromOutside(url)
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 安装链路生命周期收尾：回前台时若安装仍在进行则保留本地服务器与音频保活，
        // 判定依据两个（任一满足即保留）：
        // ① 最近 4 分钟内有安装活动（itms-services 打开 / SpringBoard 拉取
        //    manifest/ipa 的连接或分块传输）——覆盖弹窗已确认、下载进行中的场景；
        // ② 服务器启动未满 10 分钟（安装会话仍在进行）——覆盖用户在系统安装确认
        //    弹窗停留较久（期间无任何活动事件）后切回 App 的场景。
        // 用户在安装确认弹窗停留或大包下载期间切回 App 查看进度是常见操作，
        // 此时停服务器会掐断正在进行的安装且无任何提示（历史缺陷）。
        // 会话上限 10 分钟兜底：放弃安装后服务器/音频最迟 10 分钟清理（耗电可控）。
        // stop 均幂等，未启动时调用无害。
        if LocalInstallServer.shared.hasRecentInstallActivity(within: 240)
            || LocalInstallServer.shared.isInstallSessionActive(within: 600) {
            Logger.info("回前台：检测到近期安装活动/进行中的安装会话，保留本地服务器与保活（不打断安装）")
        } else {
            LocalInstallServer.shared.stop()
            BackgroundAudioKeepAlive.shared.stop()
        }
        // 分享投递 Inbox 兜底扫描：「拷贝到 App」的文件本体必然已拷入 Documents/Inbox，
        // open 事件丢失时在回前台时补处理（见 AppState.processInboxFilesIfNeeded）。
        AppState.shared.processInboxFilesIfNeeded()
        // 迟到投递保险：极少数场景系统在 App 激活之后才完成 Inbox 拷贝，2.5 秒后
        // 复查一次（仅一次，不链式；在途/已结算投递在 AppState 内部去重跳过）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            AppState.shared.processInboxFilesIfNeeded()
        }
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Logger.info("App opened with URL: \(url.absoluteString)")
        AppState.shared.handleFileOpenedFromOutside(url)
        return true
    }
}