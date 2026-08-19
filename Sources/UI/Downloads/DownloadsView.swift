import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showBrowser = false
    @State private var tasks: [DownloadTask] = []
    @State private var timer: Timer?
    @State private var selectedApp: AppInfo?
    @State private var showUnrecognizedAlert = false
    @State private var unrecognizedMessage = ""
    @State private var showClearAllAlert = false

    var body: some View {
        NavigationView {
            Group {
                if tasks.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(tasks) { task in
                            downloadRow(task)
                        }
                        .onDelete { offsets in
                            deleteTasks(at: offsets)
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !tasks.isEmpty {
                        Button("全部清除", role: .destructive) {
                            showClearAllAlert = true
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showBrowser = true
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
            .sheet(isPresented: $showBrowser) {
                BrowserView()
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app)
                    .environmentObject(appState)
            }
            .alert("无法识别", isPresented: $showUnrecognizedAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(unrecognizedMessage)
            }
            .alert("全部清除下载任务？", isPresented: $showClearAllAlert) {
                Button("全部清除", role: .destructive) {
                    clearAllTasks()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将取消并移除全部 \(tasks.count) 个下载任务，此操作不可撤销。")
            }
            .onAppear {
                refreshTasks()
                startTimer()
            }
            .onDisappear {
                stopTimer()
            }
            .onChange(of: appState.importedApps) { _ in
                // 自动导入完成（importedApps 更新）后立刻刷新，及时呈现可点击状态
                refreshTasks()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无下载任务")
                .font(.headline)
            Text("点击右上角 Safari 图标，在浏览器中下载 IPA 或 ZIP")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private func downloadRow(_ task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(task.fileName.isEmpty ? "未知文件" : task.fileName)
                        .font(.headline)
                    Text(task.statusDescription)
                        .font(.caption)
                        .foregroundColor(statusColor(task.status))
                }
                Spacer()
                Button {
                    togglePause(task)
                } label: {
                    Image(systemName: task.status == .paused ? "play.circle.fill" : "pause.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .disabled(task.status != .downloading && task.status != .paused)
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: task.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", task.progress * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if task.status == .failed, let error = task.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if task.status == .completed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("已完成·点击签名")
                }
                .font(.caption)
                .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard task.status == .completed else { return }
            if let app = matchedApp(for: task) {
                selectedApp = app
            } else {
                unrecognizedMessage = unrecognizedReason(for: task)
                showUnrecognizedAlert = true
            }
        }
        .contextMenu {
            if task.status == .failed {
                Button {
                    retryDownload(task)
                } label: {
                    Label("重新下载", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                DownloadManager.shared.cancelDownload(id: task.id)
                refreshTasks()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func matchedApp(for task: DownloadTask) -> AppInfo? {
        let fileName = task.fileName
        let baseName = (fileName as NSString).deletingPathExtension

        return appState.importedApps.first { app in
            // 1) 优先：导入后应用路径与任务目标路径一致 → 直接命中
            if !task.destinationPath.isEmpty, app.path == task.destinationPath {
                return true
            }
            // 2) 文件名（原始 + 去扩展名）与 app.name 比较
            if app.name == fileName || app.name == baseName {
                return true
            }
            // 3) 与 app.path 的 lastPathComponent（原始 + 去扩展名）比较
            let appPathLast = (app.path as NSString).lastPathComponent
            let appPathBase = (appPathLast as NSString).deletingPathExtension
            return appPathLast == fileName || appPathBase == baseName
        }
    }

    /// 已 completed 但未匹配到已导入应用时，给出具体导入失败原因而非笼统的“无法识别”。
    private func unrecognizedReason(for task: DownloadTask) -> String {
        let path = task.destinationPath
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)

        if !exists {
            return "文件已下载，但目标文件不存在（可能已被移动或清理）。可重新下载后再试。"
        }

        switch (path as NSString).pathExtension.lowercased() {
        case "zip":
            if isCorruptedArchive(at: path) {
                return "文件损坏或网络异常导致下载不完整，请删除后重新下载"
            }
            return "下载成功，但该 ZIP 未包含可解析的 .app 应用包（可能不是有效的 IPA/ZIP 结构），请确认文件完整后重试。"
        case "ipa":
            return "自动导入失败：IPA 解析未生成应用记录，文件可能损坏或不是有效的 IPA 包，可重新下载验证。"
        default:
            return "自动导入失败：无法将“\(task.fileName)”识别为可签名应用（文件已存在但解析失败）。"
        }
    }

    /// 判断下载文件是否损坏：文件头不是 zip/ipa 魔数（PK\x03\x04）即视为损坏
    /// （截断文件、HTML 错误页都不会以该魔数开头）。
    private func isCorruptedArchive(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), !data.isEmpty else { return true }
        return !data.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    /// 长按 failed 任务 → 重新下载：先移除原失败任务，再以同一 URL 发起新下载。
    private func retryDownload(_ task: DownloadTask) {
        DownloadManager.shared.cancelDownload(id: task.id)
        DownloadManager.shared.startDownload(urlString: task.url) { _ in
            refreshTasks()
        }
    }

    private func statusColor(_ status: DownloadTask.Status) -> Color {
        switch status {
        case .completed: return .green
        case .failed: return .red
        case .downloading: return .blue
        default: return .secondary
        }
    }

    private func togglePause(_ task: DownloadTask) {
        if task.status == .paused {
            DownloadManager.shared.resumeDownload(id: task.id)
        } else {
            DownloadManager.shared.pauseDownload(id: task.id)
        }
    }

    /// 滑动删除：取消并移除指定索引的下载任务。
    private func deleteTasks(at offsets: IndexSet) {
        let ids = offsets.map { tasks[$0].id }
        for id in ids {
            DownloadManager.shared.cancelDownload(id: id)
        }
        refreshTasks()
    }

    /// 全部清除：取消并移除所有下载任务。
    private func clearAllTasks() {
        let all = DownloadManager.shared.snapshotTasks()
        for task in all {
            DownloadManager.shared.cancelDownload(id: task.id)
        }
        refreshTasks()
    }

    private func refreshTasks() {
        // 排序保证顺序稳定；仅当快照确实变化时才替换数组，避免 0.5s 轮询造成无谓重绘
        let snapshot = DownloadManager.shared.snapshotTasks()
            .sorted { $0.createdAt < $1.createdAt }
        if snapshot != tasks {
            tasks = snapshot
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            refreshTasks()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
