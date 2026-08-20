import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedApp: AppInfo?
    @State private var showClearAllAlert = false

    var body: some View {
        NavigationView {
            Group {
                if appState.isRefreshingInstalledApps && appState.installedApps.isEmpty {
                    // 启动/删除后的扫描期：显示加载态而非“暂无应用”空态，避免误认为没有应用
                    ProgressView("正在扫描已签应用...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.installedApps.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(appState.installedApps) { app in
                            Button {
                                selectedApp = app
                            } label: {
                                appRow(app)
                            }
                        }
                        .onDelete { offsets in
                            deleteApps(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("已签应用")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !appState.installedApps.isEmpty {
                        Button("全部清除", role: .destructive) {
                            showClearAllAlert = true
                        }
                    }
                }
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app)
            }
            .alert("全部清除已签应用？", isPresented: $showClearAllAlert) {
                Button("全部清除", role: .destructive) {
                    clearAllSignedApps()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除全部 \(appState.installedApps.count) 个已签应用及对应文件，此操作不可撤销。")
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "apps.iphone")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无已签名应用")
                .font(.headline)
            Text("签名完成后，应用会出现在这里")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func appRow(_ app: AppInfo) -> some View {
        HStack(spacing: 12) {
            AppIconView(iconPath: app.iconPath, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name.isEmpty ? "未命名" : app.name)
                    .font(.headline)
                Text(app.bundleID.isEmpty ? "未知 Bundle ID" : app.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(app.version) · \(app.sizeDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// 滑动删除：移除指定索引的已签应用（批量删除只触发一次全量重扫）
    private func deleteApps(at offsets: IndexSet) {
        guard offsets.allSatisfy({ $0 < appState.installedApps.count }) else { return }
        let appsToRemove = offsets.map { appState.installedApps[$0] }
        appState.removeSignedApps(appsToRemove)
    }

    /// 全部清除：移除所有已签应用及其文件（批量删除只触发一次全量重扫）
    private func clearAllSignedApps() {
        let all = appState.installedApps
        appState.removeSignedApps(all)
    }
}