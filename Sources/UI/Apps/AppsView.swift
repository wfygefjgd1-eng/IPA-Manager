import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedApp: AppInfo?
    @State private var showClearAllAlert = false
    /// 多选删除模式：true 时行变为勾选交互，操作按钮移到底部悬浮条
    @State private var isSelecting = false
    /// 多选模式下已勾选的应用 id
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        NavigationView {
            Group {
                if appState.isRefreshingInstalledApps && appState.installedApps.isEmpty {
                    // 启动/删除后的扫描期：显示加载态而非"暂无应用"空态，避免误认为没有应用
                    ProgressView("正在扫描已签应用...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.installedApps.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(appState.installedApps) { app in
                            Button {
                                if isSelecting {
                                    toggleSelection(app.id)
                                } else {
                                    selectedApp = app
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    // 多选模式：行首勾选圈（点击切换选中，由 Button 统一处理）
                                    if isSelecting {
                                        Image(systemName: selectedIDs.contains(app.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundColor(selectedIDs.contains(app.id) ? .accentColor : .secondary)
                                    }
                                    appRow(app)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .onDelete { offsets in
                            if isSelecting {
                                // 多选模式下滑动删除也走勾选集合路径，避免与选中态不一致
                                deleteSelectedApps()
                            } else {
                                deleteApps(at: offsets)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        // 底部悬浮操作条：位于 Tab 栏上方，拇指可及；半透明材质不突兀
                        floatingActionBar
                    }
                }
            }
            .navigationTitle("已签应用")
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

    /// 底部悬浮操作条：非选择模式展示「全部清除 / 选择」；
    /// 选择模式展示「取消 / 全选（取消全选）/ 删除选中 (N)」。
    private var floatingActionBar: some View {
        FloatingActionBar {
            if isSelecting {
                Button("取消") {
                    exitSelection()
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Button(allSelected ? "取消全选" : "全选") {
                    toggleSelectAll()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.accentColor)

                Spacer()

                Button(role: .destructive) {
                    deleteSelectedApps()
                } label: {
                    Label("删除选中 (\(selectedIDs.count))", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(selectedIDs.isEmpty)
            } else {
                Button(role: .destructive) {
                    showClearAllAlert = true
                } label: {
                    Label("全部清除", systemImage: "trash")
                        .font(.subheadline)
                }
                .disabled(appState.installedApps.isEmpty)

                Spacer()

                Button {
                    enterSelection()
                } label: {
                    Label("选择", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                }
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

    // MARK: - 多选删除

    /// 是否已全选当前列表（用于"全选 / 取消全选"切换）
    private var allSelected: Bool {
        !appState.installedApps.isEmpty && selectedIDs.count == appState.installedApps.count
    }

    /// 全选 / 取消全选：已全选时清空勾选，否则选中全部应用
    private func toggleSelectAll() {
        if allSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(appState.installedApps.map { $0.id })
        }
    }

    private func enterSelection() {
        selectedIDs.removeAll()
        isSelecting = true
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 删除勾选中的应用（只删本次勾选的，保留其余文件），删除后退出多选模式。
    /// 若期间列表被外部改动（应用被删/重扫），以当前 installedApps 为准重新匹配。
    private func deleteSelectedApps() {
        let selected = appState.installedApps.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        appState.removeSignedApps(selected)
        exitSelection()
    }
}