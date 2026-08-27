import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)

            AppsView()
                .tabItem {
                    Label("已签应用", systemImage: "apps.iphone")
                }
                .tag(1)

            DownloadsView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tag(2)

            CertificatesView()
                .tabItem {
                    Label("证书", systemImage: "lock.shield")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(4)
        }
        // 全局轻提示：外部打开文件失败、后台操作结果等无专属 UI 的场景
        // Overlay竞争修复：与HomeView的进度卡片同处.bottom对齐，用更高zIndex保证toast始终在最上层
        .overlay(alignment: .bottom) {
            if let message = appState.toastMessage {
                Text(message)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .foregroundColor(.white)
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toastMessage)
    }
}