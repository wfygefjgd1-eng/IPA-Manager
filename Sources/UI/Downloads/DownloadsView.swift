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

    /// unrecognizedReason 的 zip 分支“解析成功且已触发补导入”时返回此标记，
    /// 调用方据此跳过 alert（后续结果由补导入 completion 驱动），避免弹出“未出现”误导文案。
    private static let zipRecognizedMarker = "__zip_recognized_trigger__"

    /// 已 completed 但未匹配到已导入应用：先做主线程快速判断（文件缺失 / ZIP 魔数损坏），
    /// 以及“自动导入其实已经成功”的复查；需要真实解压解析或补导入时放到后台执行，
    /// 避免大文件解压阻塞主线程。
    private func recognizeUnmatchedTask(_ task: DownloadTask) {
        // 主线程优先复查 @Published importedApps：自动导入可能在下载完成时就已入库成功
        // （如 zip 内嵌 ipa，诊断日志里的“自动解析成功: xxx.ipa”），此时 matchedApp 直接命中。
        // 零延迟直接打开签名详情页——与列表点击已匹配任务行为一致，绝不再重复解析/导入，
        // 也绝不给用户弹任何 alert。
        if let app = matchedApp(for: task) {
            Logger.info("下载文件已识别（自动导入已完成），零延迟打开签名页: \(app.name)")
            selectedApp = app
            return
        }

        let path = task.destinationPath
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        let isZip = (path as NSString).pathExtension.lowercased() == "zip"

        // 快速失败：文件不存在，或 ZIP 连魔数都不对（截断文件 / HTML 错误页）——无需解析
        if !exists || (isZip && isCorruptedArchive(at: path)) {
            unrecognizedMessage = unrecognizedReason(for: task)
            showUnrecognizedAlert = true
            return
        }

        // 魔数正常但仍未匹配：后台实际解析 / 补导入一次拿到真实结果，保持界面流畅。
        // unrecognizedReason 返回 zipRecognizedMarker 表示“已识别并触发补导入”，
        // 此时不走 alert，后续结果由补导入 completion 驱动（成功打开签名页 / 失败弹原因）。
        DispatchQueue.global(qos: .userInitiated).async {
            let reason = self.unrecognizedReason(for: task)
            DispatchQueue.main.async {
                guard reason != Self.zipRecognizedMarker else { return }
                self.unrecognizedMessage = reason
                self.showUnrecognizedAlert = true
            }
        }
    }

    /// 识别/导入成功后的统一出口：零延迟直接打开签名详情页（AppDetailView 经
    /// .sheet(item: $selectedApp) 弹出，用户可立即一键签名），与列表点击“已匹配任务”
    /// 的行为完全一致；不弹 alert、不做二次解析、不插入任何中间提示。
    private func openSigning(for app: AppInfo) {
        selectedApp = app
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
            // 文件头（PK 魔数）正常但自动导入仍失败/未完成：后台实际解析一次
            // （调用方已确保本函数在后台队列执行，解析含解压，不阻塞主线程）。
            // 解析成功说明 zip 内含 .app 或内嵌 .ipa（IPAParser 已支持 zip 内嵌 .ipa）。
            // 此时绝不把“若未出现请删除任务后重新下载”的误导文案丢给用户，而是让用户能立刻去签名：
            //   1) 回主线程先查 importedApps——自动导入可能其实已经成功，matchedApp 直接命中，
            //      零延迟直接打开签名详情页，不弹任何 alert；
            //   2) 未命中则主动补一次完整导入（handleDownloadedFile，幂等：内嵌 ipa 复制到
            //      Documents/IPA 后走 importFile，importFile 按 bundleID 去重替换），
            //      导入结果经 completion 回到主线程：成功→零延迟打开签名详情页（无 alert），
            //      失败→弹 zipParseFailureReason 给出的具体中文原因。
            // 兜底：handleDownloadedFile 对“证书包 zip”不会回调 completion（证书导入无 completion），
            // 该分支几秒内无结果时再查一次 importedApps，仍未命中才弹通用提示，避免用户无任何反馈。
            do {
                _ = try IPAParser().parse(fileURL: URL(fileURLWithPath: path))
                DispatchQueue.main.async {
                    if let app = self.matchedApp(for: task) {
                        Logger.info("zip 已自动导入成功，零延迟打开签名页: \(app.name)")
                        self.openSigning(for: app)
                        return
                    }
                    Logger.info("zip 可解析但未匹配到已导入应用，主动补导入: \(task.fileName)")
                    var finished = false
                    let url = URL(fileURLWithPath: path)
                    self.appState.handleDownloadedFile(at: url) { result in
                        DispatchQueue.main.async {
                            guard !finished else { return }
                            finished = true
                            switch result {
                            case .success(let app):
                                Logger.info("zip 补导入成功，零延迟打开签名页: \(app.name)")
                                self.openSigning(for: app)
                            case .failure(let error):
                                let reason = self.zipParseFailureReason(task: task, detail: error.localizedDescription)
                                self.unrecognizedMessage = reason
                                self.showUnrecognizedAlert = true
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        guard !finished else { return }
                        finished = true
                        if let app = self.matchedApp(for: task) {
                            self.openSigning(for: app)
                        } else {
                            let reason = "压缩包内包含应用（.app 或 .ipa），已重新尝试导入。若仍失败，请查看下方具体原因。"
                            Logger.error("无法识别下载文件: \(task.fileName) - \(reason)")
                            self.unrecognizedMessage = reason
                            self.showUnrecognizedAlert = true
                        }
                    }
                }
                return Self.zipRecognizedMarker
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
