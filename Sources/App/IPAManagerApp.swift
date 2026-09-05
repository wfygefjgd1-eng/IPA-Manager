import SwiftUI
import UIKit

@main
struct IPAManagerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    init() {
        AppFileManager.shared.ensureDirectoryStructure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    // SwiftUI 生命周期兜底：application(_:open:) 不保证每次外部打开都回调
                    // （文件 App「打开方式」可能只触发 onOpenURL）。两者并存；AppState 内部
                    // 按 URL 短窗口去重，同一文件的重复投递只处理一次。
                    // force: true——onOpenURL 是系统主动投递事件，绕过已结算拦截
                    AppState.shared.handleFileOpenedFromOutside(url, force: true)
                }
        }
    }
}