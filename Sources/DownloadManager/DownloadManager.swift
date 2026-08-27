import Foundation

final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    // 线程约定：`tasks` / `taskModels` 仅在主队列读写（delegateQueue 为 .main，
    // 且 startDownload/pause/resume/cancel/snapshotTasks 均由 UI 主线程调用）。
    // 注意：didFinishDownloadingTo 的临时文件移动**必须同步**（URLSession 在回调
    // 返回后删除临时文件），同卷 rename 瞬时完成；移动完成后的文件分类/校验
    // （读文件头、可能触发自动重下）放到后台队列执行，完成后回到主队列更新模型。
    // 本文件新增的只读文件头（<4KB）、UserDefaults 持久化均为小 IO，主队列执行即可。
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var taskModels: [UUID: DownloadTask] = [:]
    private let store = UserDefaultsStore()

    /// 同一任务自动重试的次数上限：校验失败（HTML 错误页 / 截断）时最多自动重下 1 次，避免死循环。
    private let maxRetryCount = Limits.maxRetryCount
    /// 每个任务已自动重试的次数（仅进程内有效；恢复的任务没有活跃下载，不会触发重试）。
    private var retryCounts: [UUID: Int] = [:]

    var onDownloadComplete: ((URL) -> Void)?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = true
        // GitHub releases 等站点对不带浏览器标识的请求会返回 HTML/错误页或 403，
        // 这就是下载到的"文件损坏"（实际是网页）的根因。补上完整浏览器 UA + 常规请求头。
        configuration.timeoutIntervalForRequest = Timeouts.request
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        // 启动时恢复上次持久化的下载任务。放到下一 runloop 执行，避免在 init 阶段
        // 做文件存在性检查等 IO（量小，但延迟到主队列更稳）。
        DispatchQueue.main.async { [weak self] in
            self?.restoreSavedTasks()
        }
    }

    /// 无 Referer 版本（保持旧行为）：转发给带 referer 的重载，referer 传 nil，
    /// 供非浏览器入口（外部链接/深链等）调用，不附加 Referer 头。
    func startDownload(urlString: String, completion: @escaping (DownloadTask) -> Void) {
        startDownload(urlString: urlString, referer: nil, completion: completion)
    }

    /// 浏览器下载入口：可选携带 Referer（防盗链站点缺 Referer 会拒绝对接）。
    /// 任务创建/持久化逻辑与旧版完全一致，仅把 downloadTask(with: URL)
    /// 换成 downloadTask(with: URLRequest) 以便附加 Referer 头。
    func startDownload(urlString: String, referer: String?, completion: @escaping (DownloadTask) -> Void) {
        var task = DownloadTask()
        task.url = urlString

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            task.status = .failed
            task.error = "仅支持 http/https 链接"
            task.fileName = Self.sanitizeFileName(urlString)
            completion(task)
            return
        }
        task.fileName = Self.sanitizeFileName(url.lastPathComponent)
        task.status = .downloading

        var request = URLRequest(url: url)
        // 防盗链：请求携带来源页面 URL 作 Referer（浏览器入口传入当前页面地址）
        if let referer = referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let sessionTask = session.downloadTask(with: request)
        // O(1) 回调查找：把任务 id 写入 taskDescription，避免进度回调线性扫描 tasks
        sessionTask.taskDescription = task.id.uuidString
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
        // 无活跃 sessionTask（如“暂停后重启”恢复的任务只恢复了模型、未建 sessionTask）：
        // 先按 rebuildTask 重建（有 resumeData 断点续传，否则整包重下），再恢复下载。
        if tasks[id] == nil {
            guard var model = taskModels[id] else { return }
            rebuildTask(&model)
            persistTasks()
            return
        }
        tasks[id]?.resume()
        taskModels[id]?.status = .downloading
        persistTasks()
    }

    func cancelDownload(id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        if let model = taskModels[id] {
            // 顺带删除已完成任务在磁盘上的目标文件，避免反复下载/删除堆积垃圾文件
            if model.status == .completed, !model.destinationPath.isEmpty {
                try? AppFileManager.shared.deleteItem(at: URL(fileURLWithPath: model.destinationPath))
            }
        }
        taskModels.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        persistTasks()
    }

    func snapshotTasks() -> [DownloadTask] {
        Array(taskModels.values)
    }

    /// 更新内存模型并持久化（如自动导入成功后回填 resolvedBundleID）。
    func updateTask(_ task: DownloadTask) {
        guard taskModels[task.id] != nil else { return }
        taskModels[task.id] = task
        persistTasks()
    }

    /// 启动时从 UserDefaults 恢复上次保存的下载任务。
    /// - completed：校验 `destinationPath` 文件是否仍存在；不存在 → 标记 failed「文件已丢失」。
    /// - downloading：重建 sessionTask 续传（有 resumeData 断点续传，否则整包重下）。
    /// - paused：暂停是用户显式意图——只恢复模型展示（status 保持 .paused、不建
    ///   sessionTask），绝不悄悄恢复下载；用户点“继续”时由 resumeDownload 按需重建。
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
            case .downloading:
                // 上次会话下载可能已完成并落盘，但中断/重试路径把状态残留成 downloading
                // （retryDownload / rebuildTask 都写 .downloading 并持久化）。
                // 若 Downloads 目录已存在该任务的完成产物（同名或唯一化后缀），
                // 直接按「已完成」恢复：不重建下载，否则启动后会整包重新下载，
                // 又触发「下载完成后自动签名并安装」，导致重复签名、已签应用堆重复。
                if let existing = existingCompletedFile(for: task) {
                    var done = task
                    done.status = .completed
                    done.destinationPath = existing.path
                    done.resumeData = nil
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: existing.path),
                       let size = attrs[.size] as? Int64 {
                        done.totalBytes = size
                        done.receivedBytes = size
                    }
                    taskModels[task.id] = done
                    Logger.info("下载任务已有完成产物，按已完成恢复: \(task.fileName)")
                } else {
                    // 无产物：确实未完成，正常重建续传/重下
                    rebuildTask(&task)
                }
            case .paused:
                // 保持暂停：只恢复模型（tasks[id] 保持 nil），
                // 用户点“继续”时 resumeDownload 会重建 sessionTask 再 resume。
                taskModels[task.id] = task
            default:
                // failed / waiting：原样恢复展示
                taskModels[task.id] = task
            }
        }
        persistTasks()
        Logger.info("恢复下载任务 \(taskModels.count) 个")
    }

    /// 在 Downloads 目录查找该任务的已完成产物。
    /// 命中条件：同名文件，或「基础名-8位十六进制.扩展名」（finishDownload 的同名唯一化产物）。
    /// 用于还原被中断/重试残留成 .downloading 但其实已下载完成的任务。
    private func existingCompletedFile(for task: DownloadTask) -> URL? {
        guard !task.fileName.isEmpty else { return nil }
        let dir = AppFileManager.shared.directoryURL(.downloads)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        for file in files {
            let name = file.lastPathComponent
            if name == task.fileName {
                return file
            }
            let base = (task.fileName as NSString).deletingPathExtension
            let ext = (task.fileName as NSString).pathExtension
            // unique 后缀为 UUID().uuidString.prefix(8)（8 位 hex）
            let prefix = "\(base)-"
            if name.hasPrefix(prefix) && name.hasSuffix(".\(ext)") {
                let mid = name.dropFirst(prefix.count).dropLast(ext.count + 1)
                if mid.count == 8, mid.allSatisfy({ $0.isHexDigit }) {
                    return file
                }
            }
        }
        return nil
    }

    /// 为恢复的 downloading/paused 任务重建真实 sessionTask：
    /// 有 resumeData 则断点续传，否则从 0 重新下载（登录/Session 过期后旧 resumeData
    /// 可能失效，从 0 重下是兜底）。重建失败（URL 无效等）则降级为 failed。
    private func rebuildTask(_ task: inout DownloadTask) {
        var candidate = task
        guard let url = URL(string: candidate.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            candidate.status = .failed
            candidate.error = "无效 URL"
            taskModels[candidate.id] = candidate
            return
        }

        var sessionTask: URLSessionDownloadTask?
        if let resumeData = candidate.resumeData, !resumeData.isEmpty {
            sessionTask = session.downloadTask(withResumeData: resumeData)
        }
        if sessionTask == nil {
            sessionTask = session.downloadTask(with: url)
            candidate.receivedBytes = 0
            candidate.totalBytes = 0
        }
        sessionTask?.taskDescription = candidate.id.uuidString
        candidate.status = .downloading
        candidate.error = nil
        taskModels[candidate.id] = candidate
        tasks[candidate.id] = sessionTask
        sessionTask?.resume()
        Logger.info("已重建下载任务: \(candidate.fileName)")
    }

    // MARK: - 收尾 / 校验 / 重试

    /// 下载完成的收尾：移动到持久位置 → 校验内容真实性 → 更新模型并持久化。
    /// 校验失败且属于“网络类”问题（HTML 错误页 / 截断损坏）时自动重试一次。
    ///
    /// 关键时序约束：URLSession 的 didFinishDownloadingTo 给出的临时文件
    /// （CFNetworkDownload_xxx.tmp）只在回调执行期间有效，**回调返回后系统立即删除**。
    /// 因此 moveItem 必须在回调内同步完成（临时目录与 Documents 同在 App 容器卷内，
    /// moveItem 是同卷 rename，瞬时完成，不会卡主线程）；文件安全落盘后的
    /// 分类/校验/模型更新再放后台队列执行。
    private func finishDownload(id: UUID, model: DownloadTask, location: URL) {
        var updated = model
        // 同名冲突唯一化：多个任务（重复下载/不同来源同名文件）先后完成时，
        // 若目标已存在且非本次任务自己，追加 UUID 后缀，避免后写覆盖先写、
        // 以及前一个任务的 destinationPath 指向被替换文件导致自动导入错乱。
        let baseName = Self.sanitizeFileName(updated.fileName.isEmpty ? "download" : updated.fileName)
        var destination = AppFileManager.shared.directoryURL(.downloads)
            .appendingPathComponent(baseName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            destination = AppFileManager.shared.directoryURL(.downloads)
                .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
        }

        // 同步移动（URLSession 临时文件生命周期约束，见上方注释）
        do {
            try AppFileManager.shared.moveItem(from: location, to: destination)
            updated.destinationPath = destination.path
        } catch {
            updated.status = .failed
            updated.error = error.localizedDescription
            Logger.error("下载文件移动失败: \(error.localizedDescription)")
            tasks.removeValue(forKey: id)
            taskModels[id] = updated
            persistTasks()
            return
        }

        // 校验失败且可重试（HTML / 截断）时自动重下；本地移动失败等不重试。
        var retryableFailure = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // classifyDownload 内部已全部容错（FileHandle nil / read 失败 → .other），不抛错，
            // 因此这里不再需要 do-catch（历史上 catch 分支不可达，只会触发编译警告）。
            switch self.classifyDownload(at: destination.path) {
            case .zip:
                updated.status = .completed
            case .html:
                updated.status = .failed
                updated.error = "下载到的是网页而非文件（可能链接失效或被拦截），请检查链接后重试"
                Logger.error("下载校验失败: \(updated.error ?? "")")
                try? AppFileManager.shared.deleteItem(at: destination)
                retryableFailure = true
            case .other:
                // 非 zip 且非 HTML 的完整下载（.tar/.apk/.tar.gz 等）按 completed 收尾：
                // 任务显示完成，是否可导入交给自动导入环节给出中文原因——这里不应把
                // 完整下载误判为“损坏”。只有确证截断（已知总大小且实际收到更少）才判
                // failed 并自动重下；截断文件删掉，避免把坏文件留在下载目录。
                if updated.totalBytes > 0 && updated.receivedBytes < updated.totalBytes {
                    updated.status = .failed
                    updated.error = "下载不完整，文件可能损坏"
                    Logger.error("下载校验失败: \(updated.error ?? "")")
                    try? AppFileManager.shared.deleteItem(at: destination)
                    retryableFailure = true
                } else {
                    updated.status = .completed
                }
            }

            DispatchQueue.main.async {
                // 竞态守卫：用户在后台校验期间取消/删除了任务（taskModels[id] 已移除），
                // 不得把任务“复活”回列表，更不能触发自动导入/自动重试。
                guard self.taskModels[id] != nil else {
                    // 文件已同步移入 Downloads（同卷 rename 已完成），但任务已删除：
                    // 目标文件不再被任何记录引用，清理掉避免堆积。
                    if updated.status == .completed {
                        try? AppFileManager.shared.deleteItem(at: destination)
                    }
                    return
                }
                self.tasks.removeValue(forKey: id)
                self.taskModels[id] = updated
                self.persistTasks()

                if updated.status == .completed {
                    self.retryCounts.removeValue(forKey: id)
                    self.onDownloadComplete?(destination)
                } else if retryableFailure && (self.retryCounts[id] ?? 0) < self.maxRetryCount {
                    Logger.warning("下载内容校验失败，自动重试一次: \(updated.fileName)")
                    self.retryDownload(id: id, model: updated)
                } else {
                    self.retryCounts.removeValue(forKey: id)
                }
            }
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
        // 重试计数现在使用 DownloadTask.retryCount 持久化字段，不再依赖内存 retryCounts
        retrying.retryCount = model.retryCount + 1
        retrying.lastRetryDate = Date()
        retrying.status = .downloading
        retrying.error = nil
        retrying.receivedBytes = 0
        retrying.totalBytes = 0

        let sessionTask = session.downloadTask(with: url)
        sessionTask.taskDescription = id.uuidString
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
    /// zip 分支额外校验文件尾 EOCD 记录：PK 头完好但缺中央目录/结束记录的
    /// 截断文件（最常见的“下载不完整”形态）会被判为可重试的失败而非 completed。
    private func classifyDownload(at path: String) -> DownloadContentKind {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .other }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Limits.downloadProbeLength)) ?? Data()
        if data.isEmpty { return .other }
        // 普通 zip (PK\x03\x04) 与 空 zip (PK\x05\x06) 都算有效压缩包，
        // 与 ZipManager.validateZipHeader 的判断保持一致
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || data.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return hasValidEndOfCentralDirectory(at: path) ? .zip : .other
        }
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        // 与 ZipManager.hasHTMLPageContent 的 markers 对齐：只保留真正的 HTML 标签起首，
        // 避免 "v2.0.4" / "file_not_found.txt" 等常见正常文本被误判为网页错误页
        let htmlSignals = ["<!doctype html", "<html", "<head", "<body", "<!doctype"]
        if htmlSignals.contains(where: { text.contains($0) }) { return .html }
        return .other
    }

    /// 读取文件末尾 64KB 查找 EOCD 签名（PK\x05\x06）。EOCD 位于压缩包最末
    /// 22+ 字节，注释可长达 65535 字节，读尾部 64KB 足够覆盖并容忍尾部差异。
    private func hasValidEndOfCentralDirectory(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return false }
        let tailLength = min(fileSize, Limits.downloadEOCTailLength)
        try? handle.seek(toOffset: fileSize - tailLength)
        let tail = (try? handle.read(upToCount: Int(tailLength))) ?? Data()
        // EOCD 签名 0x50 0x4B 0x05 0x06（空 zip 也以该签名结尾，与头部校验一致）
        return tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: [.backwards]) != nil
    }

    /// 文件名净化：百分号解码、剔除控制字符、拒绝路径穿越与非法字符。
    /// 未净化直接用 URL.lastPathComponent 拼路径时，%20 会落进文件名、
    /// "../.." 会让 appendingPathComponent 上跳一阶（路径穿越写出下载目录）。
    static func sanitizeFileName(_ raw: String) -> String {
        var name = raw.removingPercentEncoding ?? raw
        // 剔除控制字符
        name = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map { String($0) }.joined()
        // 路径穿越/分隔符防御：显式拒绝含路径分隔符或 ".." 组件的名字，
        // 不依赖 appendingPathComponent 的行为（不同系统版本对内嵌 ".." 解析不同）。
        let components = name.split(separator: "/").map(String.init)
        if components.contains("..")
            || name.contains("\\")
            || components.count > 1
            || name == "." || name == ".." || name.isEmpty {
            name = "download"
        }
        // 尾部点/斜杠清理（iOS 文件名规则）
        while name.hasSuffix(".") || name.hasSuffix("/") {
            name.removeLast()
            if name.isEmpty { name = "download"; break }
        }
        return name
    }

    private func persistTasks() {
        store.saveDownloadTasks(Array(taskModels.values))
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    /// O(1) 回调查找：任务创建时已写 sessionTask.taskDescription = id.uuidString
    private func taskID(for sessionTask: URLSessionTask) -> UUID? {
        guard let desc = sessionTask.taskDescription, let id = UUID(uuidString: desc) else { return nil }
        return id
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = taskID(for: downloadTask) else { return }
        taskModels[id]?.receivedBytes = totalBytesWritten
        taskModels[id]?.totalBytes = totalBytesExpectedToWrite
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = taskID(for: downloadTask) else { return }
        let model = taskModels[id] ?? DownloadTask()
        finishDownload(id: id, model: model, location: location)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        guard let id = taskID(for: task) else { return }

        // 守卫：任务已被主动取消/删除时（cancelDownload 已移除模型），
        // 忽略该回调——否则会以「新 UUID 的占位模型」写回旧 id 键，
        // 产生列表里永久删不掉的“未知文件/失败”幽灵任务（重启前无法消除）。
        // NSURLErrorCancelled 是 cancel() 的必然回调，模型不存在时直接丢弃。
        guard taskModels[id] != nil else { return }

        // 关键修复：检查 task 身份。retryDownload 会重建 sessionTask
        // 并替换 tasks[id]。如果到达的 task 对象不是当前活跃的 tasks[id]，
        // 说明这是旧任务的残留回调，必须直接忽略以防止旧回调覆盖新重试状态。
        guard tasks[id] === (task as? URLSessionDownloadTask) else {
            Logger.debug("忽略旧任务 didCompleteWithError 回调: id=\(id)")
            return
        }

        let nsError = error as NSError
        var updated = taskModels[id] ?? DownloadTask()
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            updated.resumeData = resumeData
        }

        // 断点续传失败整包兜底：续传最常见的失败是服务器不支持 Range / 会话失效 /
        // resumeData 损坏，此时旧 resumeData 已"毒化"，恢复时必然再次失败。
        // 未超重试上限时清空 resumeData 并整包重下（复用 retryDownload，内部
        // retryCounts 计数），防止死循环；超限则按普通失败收尾。
        // 注意：NSURLErrorCannotConnectToHost(-3004) / NSURLErrorTimedOut(-1001) /
        // NSURLErrorNetworkConnectionLost(-1005) 等都是网络瞬态错误，**不代表**
        // resumeData 无效——直接重试 URLSession 即可，盲目整包重下会浪费时间/流量。
        let resumeRelatedCodes: [Int] = [
            NSURLErrorCannotWriteToFile,      // -3000  文件系统异常，resumeData 可疑
            NSURLErrorDataNotAllowed          // -1020  策略禁止读取数据
        ]
        if let resumeData = updated.resumeData, !resumeData.isEmpty,
           resumeRelatedCodes.contains(nsError.code),
           (retryCounts[id] ?? 0) < maxRetryCount {
            updated.resumeData = nil
            Logger.warning("断点续传失败(\(nsError.code))，整包重新下载: \(updated.fileName)")
            taskModels[id] = updated
            tasks.removeValue(forKey: id)
            retryDownload(id: id, model: updated)
            return
        }

        updated.status = .failed
        updated.error = error.localizedDescription
        Logger.error("下载失败: \(error.localizedDescription)")
        taskModels[id] = updated
        tasks.removeValue(forKey: id)
        retryCounts.removeValue(forKey: id)
        persistTasks()
    }
}
