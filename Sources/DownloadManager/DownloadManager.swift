import Foundation

final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // 线程约定：`tasks` / `taskModels` 仅在主队列读写（delegateQueue 为 .main，
    // 且 startDownload/pause/resume/cancel/snapshotTasks 均由 UI 主线程调用）；
    // 文件系统操作（移动大文件）放到后台队列执行，完成后回到主队列更新模型。
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var taskModels: [UUID: DownloadTask] = [:]
    var onDownloadComplete: ((URL) -> Void)?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
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
        completion(task)
    }

    func pauseDownload(id: UUID) {
        tasks[id]?.suspend()
        taskModels[id]?.status = .paused
    }

    func resumeDownload(id: UUID) {
        tasks[id]?.resume()
        taskModels[id]?.status = .downloading
    }

    func cancelDownload(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        taskModels.removeValue(forKey: id)
    }

    func snapshotTasks() -> [DownloadTask] {
        Array(taskModels.values)
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
        var model = taskModels[id] ?? DownloadTask()

        // 注意：系统会在 didFinishDownloadingTo 返回后清理临时文件，
        // 因此必须在返回前把文件移动到持久位置（同卷移动 = 重命名，开销小）。
        let destination = AppFileManager.shared.directoryURL(.downloads)
            .appendingPathComponent(model.fileName.isEmpty ? "download" : model.fileName)

        do {
            try AppFileManager.shared.moveItem(from: location, to: destination)
            model.status = .completed
            model.destinationPath = destination.path
        } catch {
            model.status = .failed
            model.error = error.localizedDescription
        }

        tasks.removeValue(forKey: id)
        taskModels[id] = model
        if model.status == .completed {
            onDownloadComplete?(destination)
        }
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
    }
}