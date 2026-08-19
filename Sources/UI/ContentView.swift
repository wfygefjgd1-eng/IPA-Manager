import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }

            AppsView()
                .tabItem {
                    Label("已签应用", systemImage: "apps.iphone")
                }

            DownloadsView()
                .tabItem {
                    Label("下载", systemImage: "arrow.down.circle")
                }

            CertificatesView()
                .tabItem {
                    Label("证书", systemImage: "lock.shield")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}
