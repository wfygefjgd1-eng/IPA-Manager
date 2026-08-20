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
        // 安装链路生命周期收尾：itms-services 安装期间 App 在前后台往返，
        // 回到前台时立即停止本地服务器与静音音频保活，避免 NWListener + 音频
        // 永久驻留后台（耗电 + 每 5 秒心跳日志刷屏）。stop 均幂等，未启动时调用无害。
        LocalInstallServer.shared.stop()
        BackgroundAudioKeepAlive.shared.stop()
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