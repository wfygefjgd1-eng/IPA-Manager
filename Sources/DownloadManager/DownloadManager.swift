import Foundation

final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // 线程约定：`tasks` / `taskModels` 仅在主队列读写（delegateQueue 为 .main，
    // 且 startDownload/pause/resume/cancel/snapshotTasks 均由 UI 主线程调用）；
    // 文件系统操作（移动大文件）放到后台队列执行，完成后回到主队列更新模型。
    // 本文件新增的只读文件头（<4KB）、UserDefaults 持久化均为小 IO，主队列执行即可。
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var taskModels: [UUID: DownloadTask] = [:]
    private let store = UserDefaultsStore()

    /// 同一任务自动重试的次数上限：校验失败（HTML 错误页 / 截断）时最多自动重下 1 次，避免死循环。
    private let maxRetryCount = 1
    /// 每个任务已自动重试的次数（仅进程内有效；恢复的任务没有活跃下载，不会触发重试）。
    private var retryCounts: [UUID: Int] = [:]

    var onDownloadComplete: ((URL) -> Void)?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        // 启动时恢复上次持久化的下载任务。放到下一 runloop 执行，避免在 init 阶段
        // 做文件存在性检查等 IO（量小，但延迟到主队列更稳）。
        DispatchQueue.main.async { [weak self] in
            self?.restoreSavedTasks()
        }
    }

    func startDownload(urlString: String, completion: @escaping (DownloadTask) -> Void) {
        var task = DownloadTask()
        task.url = urlString
        task.fileName = URL(string: urlString)?.lastPathComponent ?? "download"
        task.status = .downloading

        guard let url = URL(string: urlString) else {
            task.status = .failed
            task.error = "无效 URL"
            completion(task)
            return
        }

        let sessionTask = session.downloadTask(with: url)
        taskModels[task.id] = task
        tasks[task.id] = sessionTask
        sessionTask.resume()
        persistTasks()
        completion(task)
    }

    func pauseDownload(id: UUID) {
        tasks[id]?.suspend()
        taskModels[id]?.status = .paused
        persistTasks()
    }

    func resumeDownload(id: UUID) {
        tasks[id]?.resume()
        taskModels[id]?.status = .downloading
        persistTasks()
    }

    func cancelDownload(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        taskModels.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        persistTasks()
    }

    func snapshotTasks() -> [DownloadTask] {
        Array(taskModels.values)
    }

    /// 启动时从 UserDefaults 恢复上次保存的下载任务。
    /// 恢复的任务没有活跃的 sessionTask（不放入 `tasks`），列表仅展示状态：
    /// - completed：校验 `destinationPath` 文件是否仍存在；不存在 → 标记 failed「文件已丢失」。
    /// - failed / 其它：原样恢复到 taskModels 展示。
    func restoreSavedTasks() {
        let saved = store.loadDownloadTasks()
        guard !saved.isEmpty else { return }

        for var task in saved {
            switch task.status {
            case .completed:
                let exists = !task.destinationPath.isEmpty
                    && FileManager.default.fileExists(atPath: task.destinationPath)
                if exists {
                    taskModels[task.id] = task
                } else {
                    task.status = .failed
                    task.error = "文件已丢失"
                    taskModels[task.id] = task
                }
            default:
                // failed / downloading / paused / waiting：原样恢复展示
                taskModels[task.id] = task
            }
        }
        persistTasks()
        Logger.info("恢复下载任务 \(taskModels.count) 个")
    }

    // MARK: - 收尾 / 校验 / 重试

    /// 下载完成的收尾：移动到持久位置 → 校验内容真实性 → 更新模型并持久化。
    /// 校验失败且属于“网络类”问题（HTML 错误页 / 截断损坏）时自动重试一次。
    private func finishDownload(id: UUID, model: DownloadTask, location: URL) {
        var updated = model
        let destination = AppFileManager.shared.directoryURL(.downloads)
            .appendingPathComponent(updated.fileName.isEmpty ? "download" : updated.fileName)

        // 校验失败且可重试（HTML / 截断）时自动重下；本地移动失败等不重试。
        var retryableFailure = false

        do {
            try AppFileManager.shared.moveItem(from: location, to: destination)
            updated.destinationPath = destination.path

            switch classifyDownload(at: destination.path) {
            case .zip:
                // 文件头为 PK\x03\x04（zip/ipa 魔数）→ 正常
                updated.status = .completed
            case .html:
                // 下载到的是网页而非文件（404 / 重定向错误页 / 拦截页）
                updated.status = .failed
                updated.error = "下载到的是网页而非文件（可能链接失效或被拦截），请检查链接后重试"
                try? AppFileManager.shared.deleteItem(at: destination)
                retryableFailure = true
            case .other:
                // 截断 / 损坏
                updated.status = .failed
                if updated.totalBytes > 0 && updated.receivedBytes < updated.totalBytes {
                    updated.error = "下载不完整，文件可能损坏"
                } else {
                    updated.error = "下载的文件无法识别，可能已损坏"
                }
                try? AppFileManager.shared.deleteItem(at: destination)
                retryableFailure = true
            }
        } catch {
            updated.status = .failed
            updated.error = error.localizedDescription
        }

        tasks.removeValue(forKey: id)
        taskModels[id] = updated
        persistTasks()

        if updated.status == .completed {
            retryCounts.removeValue(forKey: id)
            onDownloadComplete?(destination)
        } else if retryableFailure && (retryCounts[id] ?? 0) < maxRetryCount {
            Logger.warning("下载内容校验失败，自动重试一次: \(updated.fileName)")
            retryDownload(id: id, model: updated)
        } else {
            retryCounts.removeValue(forKey: id)
        }
    }

    /// 用同一个 URL 重新下载：复用同一个任务 id、保留模型（更新状态为下载中），
    /// 移除旧 task、创建新的 sessionTask 并重新关联到同一 id。
    private func retryDownload(id: UUID, model: DownloadTask) {
        guard let url = URL(string: model.url) else {
            var failed = model
            failed.status = .failed
            failed.error = "无效 URL"
            taskModels[id] = failed
            tasks.removeValue(forKey: id)
            retryCounts.removeValue(forKey: id)
            persistTasks()
            return
        }

        retryCounts[id, default: 0] += 1

        var retrying = model
        retrying.status = .downloading
        retrying.error = nil
        retrying.receivedBytes = 0
        retrying.totalBytes = 0

        let sessionTask = session.downloadTask(with: url)
        taskModels[id] = retrying
        tasks[id] = sessionTask
        sessionTask.resume()
        persistTasks()
    }

    private enum DownloadContentKind {
        case zip      // PK\x03\x04 → 正常的 zip/ipa
        case html     // 网页错误页 / 拦截页
        case other    // 截断或无法识别的数据
    }

    /// 读取文件头少量字节判断下载内容真实性（小 IO，主队列可接受）。
    private func classifyDownload(at path: String) -> DownloadContentKind {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .other }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        if data.isEmpty { return .other }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        let htmlSignals = ["<!doctype html", "<html", "<head", "not found", "404"]
        if htmlSignals.contains(where: { text.contains($0) }) { return .html }
        return .other
    }

    private func persistTasks() {
        store.saveDownloadTasks(Array(taskModels.values))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        taskModels[id]?.receivedBytes = totalBytesWritten
        taskModels[id]?.totalBytes = totalBytesExpectedToWrite
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        let model = taskModels[id] ?? DownloadTask()
        finishDownload(id: id, model: model, location: location)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // 成功完成（error == nil）时无需处理：didFinishDownloadingTo 已负责收尾。
        // 失败（error != nil）时才在此标记为 failed。
        guard let error = error else { return }
        guard let id = tasks.first(where: { $0.value == task })?.key else { return }
        taskModels[id]?.status = .failed
        taskModels[id]?.error = error.localizedDescription
        tasks.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        persistTasks()
    }
}
