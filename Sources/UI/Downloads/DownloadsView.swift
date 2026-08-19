import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showBrowser = false
    @State private var showBookmarks = false
    /// 从书签选中后待打开的 URL；为 nil 时浏览器加载默认主页
    @State private var initialBrowserURL: URL?
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
                    HStack(spacing: 16) {
                        Button {
                            showBookmarks = true
                        } label: {
                            Image(systemName: "bookmark.fill")
                        }
                        Button {
                            // 直接打开浏览器：清除上次书签跳转遗留的初始 URL
                            initialBrowserURL = nil
                            showBrowser = true
                        } label: {
                            Image(systemName: "safari")
                        }
                    }
                }
            }
            .sheet(isPresented: $showBrowser) {
                if let url = initialBrowserURL {
                    BrowserView(initialURL: url)
                } else {
                    BrowserView()
                }
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarkView { url in
                    // 点书签 → 关闭书签 sheet → 记录待打开 URL → 打开浏览器
                    initialBrowserURL = url
                    showBookmarks = false
                    showBrowser = true
                }
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
                recognizeUnmatchedTask(task)
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
            if appPathLast == fileName || appPathBase == baseName {
                return true
            }
            // 4) 包含关系兜底：任务名（去扩展名）与导入应用名 / 文件名互相包含，
            //    提高 zip 文件名（如 "EPICKLE-VR.6.19-IOS"）与 Info.plist 显示名
            //    （如 "ePickle"）不一致时的命中率。名称过短容易误匹配，低于 3 字符不启用。
            let baseLower = baseName.lowercased()
            guard baseLower.count >= 3 else { return false }
            if !app.name.isEmpty {
                let appNameLower = app.name.lowercased()
                if appNameLower.contains(baseLower) || baseLower.contains(appNameLower) {
                    return true
                }
            }
            if !appPathBase.isEmpty {
                let appPathBaseLower = appPathBase.lowercased()
                return appPathBaseLower.contains(baseLower) || baseLower.contains(appPathBaseLower)
            }
            return false
        }
    }

    /// 已 completed 但未匹配到已导入应用：先做轻量快速判断（文件缺失 / ZIP 魔数损坏），
    /// 需要真实解压解析时放到后台执行，避免大文件解压阻塞主线程。
    private func recognizeUnmatchedTask(_ task: DownloadTask) {
        let path = task.destinationPath
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        let isZip = (path as NSString).pathExtension.lowercased() == "zip"

        // 快速失败：文件不存在，或 ZIP 连魔数都不对（截断文件 / HTML 错误页）——无需解析
        if !exists || (isZip && isCorruptedArchive(at: path)) {
            unrecognizedMessage = unrecognizedReason(for: task)
            showUnrecognizedAlert = true
            return
        }

        // 魔数正常但仍解析失败：后台实际解析一次拿到真实原因，保持界面流畅
        DispatchQueue.global(qos: .userInitiated).async {
            let reason = self.unrecognizedReason(for: task)
            DispatchQueue.main.async {
                self.unrecognizedMessage = reason
                self.showUnrecognizedAlert = true
            }
        }
    }

    /// 已 completed 但未匹配到已导入应用时，给出具体导入失败原因而非笼统的“无法识别”。
    /// 所有路径都会把具体原因写入 Logger（供设置中“收集全部错误并导出”的诊断报告使用）。
    private func unrecognizedReason(for task: DownloadTask) -> String {
        let path = task.destinationPath
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)

        if !exists {
            let reason = "文件已下载，但目标文件不存在（可能已被移动或清理）。可重新下载后再试。"
            Logger.error("无法识别下载文件: \(task.fileName) - \(reason)")
            return reason
        }

        switch (path as NSString).pathExtension.lowercased() {
        case "zip":
            if isCorruptedArchive(at: path) {
                let reason = "文件损坏或网络异常导致下载不完整，请删除后重新下载"
                Logger.error("无法识别下载文件: \(task.fileName) - \(reason)")
                return reason
            }
            // 文件头（PK 魔数）正常但自动导入仍失败：这里实际解析一次。
            // 解析成功说明 zip 内包含 .app 或 .ipa（IPAParser 已支持 zip 内嵌 .ipa）；
            // 若仍未匹配到已导入应用，说明自动导入没跑成，主动补一次导入兜底。
            do {
                _ = try IPAParser().parse(fileURL: URL(fileURLWithPath: path))
                // matchedApp 读取 @Published importedApps，需在主线程判断；
                // handleDownloadedFile 内部会再切到后台执行分类与导入，调用安全。
                DispatchQueue.main.async {
                    if self.matchedApp(for: task) == nil {
                        Logger.info("zip 可解析但未匹配到已导入应用，主动补导入: \(task.fileName)")
                        self.appState.handleDownloadedFile(at: URL(fileURLWithPath: path))
                    }
                }
                let reason = "压缩包内包含应用（.app 或 .ipa），自动导入应已将其加入「我的应用」；若未出现，请删除任务后重新下载导入。"
                Logger.info("下载文件可解析（自动导入未匹配，已补导入）: \(task.fileName) - \(reason)")
                return reason
            } catch {
                return zipParseFailureReason(task: task, detail: error.localizedDescription)
            }
        case "ipa":
            let reason = "自动导入失败：IPA 解析未生成应用记录，文件可能损坏或不是有效的 IPA 包，可重新下载验证。"
            Logger.error("无法识别下载文件: \(task.fileName) - \(reason)")
            return reason
        default:
            let reason = "自动导入失败：无法将“\(task.fileName)”识别为可签名应用（文件已存在但解析失败）。"
            Logger.error("无法识别下载文件: \(task.fileName) - \(reason)")
            return reason
        }
    }

    /// 把 ZIP 真实解析错误（中文）分类成用户可操作的中文提示，并写入诊断日志。
    private func zipParseFailureReason(task: DownloadTask, detail: String) -> String {
        let reason: String
        if detail.contains("解压") || detail.contains("损坏") || detail.contains("不完整")
            || detail.contains("不是有效的 ZIP") || detail.contains("网页") {
            reason = "压缩包无法解压（可能损坏或下载不完整），请删除后重新下载。详情：\(detail)"
        } else if detail.contains("未找到 .app") {
            // detail 形如“操作失败: 未找到 .app 应用包。压缩包内包含：xxx 等 N 个条目”，
            // 去掉前缀与重复短语，保留“压缩包内包含：…”内容摘要。
            let summary = detail
                .replacingOccurrences(of: "操作失败: ", with: "")
                .replacingOccurrences(of: "未找到 .app 应用包", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "。. "))
            reason = "压缩包内没有找到 .app 应用包，可能不是应用安装包。"
                + (summary.isEmpty ? "（详情见日志）" : summary)
        } else {
            reason = "自动导入失败：\(detail)"
        }
        // 日志同时保留用户提示与原始错误全文，方便诊断
        Logger.error("无法识别下载文件: \(task.fileName) - \(reason)[原始错误: \(detail)]")
        return reason
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
