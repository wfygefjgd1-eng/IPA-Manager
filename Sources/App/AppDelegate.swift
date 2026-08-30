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
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 安装链路生命周期收尾：回前台时若安装仍在进行（最近 4 分钟内有安装活动：
        // itms-services 打开成功 / SpringBoard 拉取 manifest/ipa 的连接），保留本地
        // 服务器与音频保活——用户在安装确认弹窗停留或大包下载期间切回 App 查看进度
        // 是常见操作，此时停服务器会掐断正在进行的安装且无任何提示（历史缺陷）。
        // 无安装活动时立即停止，避免 NWListener + 音频永久驻留后台（耗电 + 心跳刷屏）。
        // stop 均幂等，未启动时调用无害。
        if LocalInstallServer.shared.hasRecentInstallActivity(within: 240) {
            Logger.info("回前台：检测到近期安装活动，保留本地服务器与保活（不打断安装）")
        } else {
            LocalInstallServer.shared.stop()
            BackgroundAudioKeepAlive.shared.stop()
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