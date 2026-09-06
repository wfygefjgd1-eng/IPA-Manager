import Foundation

/// 导入任务的持久化存储（App Group 扇出/扇入）：
/// - 扩展侧：复制完文件后创建任务 JSON（写入全部可用容器并读回验证），
///   任务持久化确认完成后扩展才允许结束请求；
/// - 主 App 侧：扫描待认领任务 → 标记 processing → 交给现有导入流水线 →
///   结算钩子回写 completed/failed。
/// 任务 JSON 极小（<1KB），扇出成本可忽略；读取按任务 id 去重（多容器冗余）。
enum ImportTaskStore {
    /// 任务 JSON 的相对目录（相对各可用共享容器根）：Incoming/Tasks/
    private static let tasksDir = "Incoming/Tasks"
    /// Incoming 残留清扫时限：终态任务与孤儿文件超此时限后回收（24h）。
    /// 注意：本文件同时编入主 App 与两个扩展 target，而 Constants.swift 仅主
    /// App 编译——清扫常量必须本地定义，引用 Timeouts 会在扩展 target 编译失败。
    private static let residueMaxAge: TimeInterval = 24 * 60 * 60

    private static func tasksDirectoryURL(in container: AppGroup.Container) -> URL {
        container.url.appendingPathComponent(tasksDir, isDirectory: true)
    }

    // MARK: - 创建（扩展侧）

    /// 在文件落盘后创建任务记录：写入全部可用容器并读回验证（主容器必须
    /// 读回一致），任何容器都没有成功时返回 false——扩展据此判定投递失败，
    /// 绝不在任务未持久化时结束请求。
    @discardableResult
    static func create(_ task: ImportTask) -> Bool {
        guard let data = try? JSONEncoder().encode(task) else { return false }
        var wrote = false
        for container in AppGroup.usableContainers() {
            let dir = tasksDirectoryURL(in: container)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                continue
            }
            let url = dir.appendingPathComponent(task.id.uuidString + ".json")
            guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
            // 读回验证：写入成功 ≠ 内容在盘（扩展进程随时可能被杀）
            guard let readBack = try? Data(contentsOf: url), readBack == data else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            wrote = true
        }
        return wrote
    }

    // MARK: - 扫描与认领（主 App 侧）

    /// 扫描全部容器的任务记录并按 id 去重，返回"待处理"任务及其文件 URL：
    /// - status == .pending：从未被认领；
    /// - status == .processing 且文件仍在：上次认领后进程死亡（导入未结算），
    ///   重新认领——以文件存在为准，任务状态只是凭据。
    /// 文件缺失的任务视为已完成残留（正常结算会删除源文件），顺带清理 JSON。
    /// 同时做 Incoming 残留清扫：终态任务（completed/failed）的源文件超过保留
    /// 窗口后删除（含 JSON）——失败任务的文件按设计保留"供手动处理"，但共享
    /// 容器对用户不可见、无任何其它出口，不清扫就是永久滞留（GB 级 IPA 的失败
    /// 导入 = 永久 GB 级泄漏）。孤儿文件（扩展写文件成功但任务 JSON 写失败的
    /// 残迹）按文件 mtime 超窗删除。
    static func scanClaimableTasks() -> [(task: ImportTask, fileURL: URL)] {
        var byID: [UUID: (task: ImportTask, fileURL: URL)] = [:]
        let now = Date()
        for container in AppGroup.usableContainers() {
            let dir = tasksDirectoryURL(in: container)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            let incomingDir = dir.deletingLastPathComponent()
            var staleJSONs: [URL] = []
            /// 本容器内被任务 JSON 引用的存储名（孤儿判定必须按容器分别记账：
            /// 冗余扇出的副本在主容器有 JSON 引用、在副本容器可能没有）
            var referencedNames = Set<String>()
            /// 本容器内终态任务（completed/failed）：文件保留供手动处理，
            /// 超过保留窗口后连文件带 JSON 一起回收
            var terminalTasks: [(json: URL, file: URL, createdAt: Date)] = []
            /// 容器内有 10 分钟内的任务活动（扩展刚落盘 JSON）：孤儿清扫本容器跳过。
            /// copyItem 完成时会把源文件的旧 mtime 应用到副本上，"文件已拷完、JSON
            /// 还差几毫秒落盘"的在途文件会呈现为旧 mtime 孤儿——近期活动护栏避免
            /// 扫描恰落在该窗口内把在途文件当垃圾删掉。
            var recentTaskActivity = false
            for jsonURL in files where jsonURL.pathExtension == "json" {
                if let modified = (try? jsonURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                   now.timeIntervalSince(modified) < 600 {
                    recentTaskActivity = true
                }
                guard let data = try? Data(contentsOf: jsonURL),
                      let task = try? JSONDecoder().decode(ImportTask.self, from: data) else {
                    // 损坏的任务 JSON：删除防反复解析失败
                    staleJSONs.append(jsonURL)
                    continue
                }
                let fileURL = incomingDir.appendingPathComponent(task.storedFileName)
                referencedNames.insert(task.storedFileName)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    // 源文件已结算删除：任务生命周期已结束，清理 JSON
                    staleJSONs.append(jsonURL)
                    continue
                }
                switch task.status {
                case .pending, .processing, .copied:
                    if byID[task.id] == nil {
                        byID[task.id] = (task, fileURL)
                    }
                case .completed, .failed:
                    terminalTasks.append((jsonURL, fileURL, task.createdAt))
                default:
                    // 中间态（copying/extracting 等）：视为在途，保留
                    break
                }
            }
            for url in staleJSONs {
                try? FileManager.default.removeItem(at: url)
            }
            // 终态任务残留清扫。年龄用任务 createdAt（任务创建≈投递时刻）而非文件
            // mtime——copyItem 保留源文件旧 mtime，压缩包解出物更是携带压缩包内
            // 记录的旧日期，按 mtime 判会把刚失败的文件立刻回收。
            for entry in terminalTasks
            where now.timeIntervalSince(entry.createdAt) > residueMaxAge {
                try? FileManager.default.removeItem(at: entry.file)
                try? FileManager.default.removeItem(at: entry.json)
            }
            // 孤儿文件清扫：无任何本容器任务 JSON 引用且文件 mtime 超窗；
            // 容器近期有任务活动时跳过（见 recentTaskActivity 竞态护栏）
            guard !recentTaskActivity,
                  let incomingFiles = try? FileManager.default.contentsOfDirectory(
                at: incomingDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for file in incomingFiles where !file.hasDirectoryPath {
                if referencedNames.contains(file.lastPathComponent) { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > residueMaxAge {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        return Array(byID.values)
    }

    /// 更新任务状态（全部存有该任务的容器同步写，best-effort）
    static func update(task: ImportTask) {
        guard let data = try? JSONEncoder().encode(task) else { return }
        for container in AppGroup.usableContainers() {
            let url = tasksDirectoryURL(in: container).appendingPathComponent(task.id.uuidString + ".json")
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 结算钩子：导入流水线成功/失败后回写任务终态。
    /// 成功 → completed（源文件已由结算删除，JSON 随 scanClaimableTasks 清理）；
    /// 失败 → failed + 原因（源文件保留，任务列表可见，用户可重新分享重试）。
    static func finish(taskID: UUID?, succeeded: Bool, note: String) {
        guard let taskID else { return }
        for container in AppGroup.usableContainers() {
            let url = tasksDirectoryURL(in: container).appendingPathComponent(taskID.uuidString + ".json")
            guard let data = try? Data(contentsOf: url),
                  var task = try? JSONDecoder().decode(ImportTask.self, from: data) else { continue }
            task.status = succeeded ? .completed : .failed
            task.error = succeeded ? nil : note
            // 必须重新编码修改后的 task 再落盘：写回解码前的原始 data 会让终态
            // 永不生效（磁盘上仍是 .processing），scanClaimableTasks 每次扫描都会
            // 重新认领该失败任务、无限重试导入（坏文件每次进 App 反复解析的根因）。
            guard let updated = try? JSONEncoder().encode(task) else { continue }
            try? updated.write(to: url, options: .atomic)
        }
    }

    /// 最近任务（UI 展示用，按创建时间倒序，跨容器去重）
    static func recentTasks(limit: Int = 20) -> [ImportTask] {
        var byID: [UUID: ImportTask] = [:]
        for container in AppGroup.usableContainers() {
            let dir = tasksDirectoryURL(in: container)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for jsonURL in files where jsonURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: jsonURL),
                      let task = try? JSONDecoder().decode(ImportTask.self, from: data) else { continue }
                if let existing = byID[task.id] {
                    // 同一任务多容器冗余：取更晚创建的副本（状态可能已更新）
                    if task.createdAt >= existing.createdAt {
                        byID[task.id] = task
                    }
                } else {
                    byID[task.id] = task
                }
            }
        }
        return Array(byID.values)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }
}
