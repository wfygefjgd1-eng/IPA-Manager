import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showBrowser = false
    @State private var tasks: [DownloadTask] = []
    @State private var timer: Timer?
    @State private var selectedApp: AppInfo?
    @State private var showUnrecognizedAlert = false

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
                Text("文件已下载，但未能识别为可签名应用")
            }
            .onAppear {
                refreshTasks()
                startTimer()
            }
            .onDisappear {
                stopTimer()
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
                showUnrecognizedAlert = true
            }
        }
    }

    private func matchedApp(for task: DownloadTask) -> AppInfo? {
        let fileName = task.fileName
        return appState.importedApps.first { app in
            if !task.destinationPath.isEmpty, app.path == task.destinationPath {
                return true
            }
            let appPathName = (app.path as NSString).lastPathComponent
            return app.name == fileName || appPathName == fileName
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
        tasks = DownloadManager.shared.snapshotTasks()
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
