import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

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
        // 统一浮层：导入进度卡与全局 toast 同挂一个容器、垂直排布。
        // 旧实现分挂 ContentView / HomeView 两个容器还互设 zIndex——zIndex 只在
        // 同级兄弟间排序，跨容器必然叠压（批量导入时黑色胶囊直接叠在一起）。
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let progress = appState.importProgress {
                    importProgressCard(progress)
                }
                if let message = appState.toastMessage {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .foregroundColor(.white)
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // 分享投递实时日志：折叠面板，仅在有事件时显示
                if !appState.deliveryLogEntries.isEmpty {
                    deliveryLogPanel(appState)
                        .padding(.bottom, 12)
                }
            }
            .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toastMessage)
        .animation(.easeInOut(duration: 0.25), value: appState.importProgress)
        .onChange(of: scenePhase) { phase in
            // 回前台兜底扫描的主触发点：iOS 27 实测不再回调 UIApplicationDelegate 的
            // applicationDidBecomeActive（冷启动有投递日志而回前台扫描无记录），而
            // SwiftUI 场景通道（onOpenURL/scenePhase）实测可用。AppDelegate 的
            // applicationDidBecomeActive 里保留同一扫描（旧系统兜底），扫描内部去重。
            guard phase == .active else { return }
            ExternalDeliveryJournal.record("scenePhase → active（回前台）")
            appState.processInboxFilesIfNeeded()
            // 迟到投递保险：极少数场景系统在激活之后才完成文件拷贝，2.5 秒后复查一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                appState.processInboxFilesIfNeeded()
            }
        }
    }

    /// 导入进度卡片：黑色胶囊 + 转圈/内圈百分比 + 文件名 + 阶段文字 + i/N。
    /// 整体百分比 0~1 由 AppState 各阶段加权后给出，解压阶段随字节数实时增长。
    private func importProgressCard(_ progress: ImportProgress) -> some View {
        HStack(spacing: 12) {
            ZStack {
                // 转圈 + 内圈百分比：双重反馈，进度直观
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .opacity(0.35)
                Text("\(Int((progress.progress * 100).rounded()))%")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在导入 \(progress.fileName)")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.totalCount > 1 {
                    Text("正在导入 \(progress.currentIndex)/\(progress.totalCount) · \(progress.phase)")
                        .font(.caption2)
                        .opacity(0.85)
                } else {
                    Text("\(progress.phase) \(Int((progress.progress * 100).rounded()))%")
                        .font(.caption2)
                        .opacity(0.85)
                }
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.black.opacity(0.8)))
    }
    
    /// 分享投递实时日志面板：显示最近 10 条 ExternalDeliveryJournal 事件
    private func deliveryLogPanel(_ appState: AppState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("📥 分享投递日志")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.accentColor)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showDeliveryLog.toggle()
                    }
                } label: {
                    Image(systemName: appState.showDeliveryLog ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            
            if appState.showDeliveryLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.deliveryLogEntries.prefix(10).reversed(), id: \.timestamp) { entry in
                            Text("[\(entry.timestamp, formatter: Self.logTimeFormatter)] \(entry.event)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .padding(.horizontal, 16)
    }
    
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}