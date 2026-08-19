import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showBrowser = false
    @State private var tasks: [DownloadTask] = []
    @State private var timer: Timer?
    @State private var selectedApp: AppInfo?
    @State private var showUnrecognizedAlert = false
    @State private var unrecognizedMessage = ""

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
                    }
                }
            }
            .navigationTitle("下载")
            .toolbar {
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
            return "自动导入失败：该文件为 ZIP，需按证书包（.p12 / .mobileprovision）处理，目前未识别为可签名应用。"
        case "ipa":
            return "自动导入失败：IPA 解析未生成应用记录，文件可能损坏或不是有效的 IPA 包，可重新下载验证。"
        default:
            return "自动导入失败：无法将“\(task.fileName)”识别为可签名应用（文件已存在但解析失败）。"
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
