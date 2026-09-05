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
        // 统一浮层：导入进度卡/自动流水线卡/全局 toast 同挂一个容器、垂直排布。
        // 旧实现分挂 ContentView / HomeView 两个容器还互设 zIndex——zIndex 只在
        // 同级兄弟间排序，跨容器必然叠压（批量导入时黑色胶囊直接叠在一起）。
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let progress = appState.importProgress {
                    importProgressCard(progress)
                }
                if let pipeline = appState.autoPipelineStatus {
                    pipelineCard(pipeline)
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
            }
            .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.25), value: appState.toastMessage)
        .animation(.easeInOut(duration: 0.25), value: appState.importProgress)
        .animation(.easeInOut(duration: 0.25), value: appState.autoPipelineStatus)
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

    /// 自动一条龙流水线状态卡：签名与发起安装阶段原本完全无反馈（大包 20-60 秒
    /// 空白，用户以为卡死、切后台会掐断整条流水线），与导入进度卡同容器展示。
    private func pipelineCard(_ pipeline: AppState.AutoPipelineStatus) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: 40, height: 40)
                Image(systemName: "hammer.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(pipeline.phase) \(pipeline.appName)")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !pipeline.detail.isEmpty {
                    Text(pipeline.detail)
                        .font(.caption2)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                if let progress = pipeline.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                }
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.black.opacity(0.8)))
    }
}