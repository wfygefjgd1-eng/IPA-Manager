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
    static func scanClaimableTasks() -> [(task: ImportTask, fileURL: URL)] {
        var byID: [UUID: (task: ImportTask, fileURL: URL)] = [:]
        var staleJSONs: [URL] = []
        for container in AppGroup.usableContainers() {
            let dir = tasksDirectoryURL(in: container)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for jsonURL in files where jsonURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: jsonURL),
                      let task = try? JSONDecoder().decode(ImportTask.self, from: data) else {
                    // 损坏的任务 JSON：删除防反复解析失败
                    staleJSONs.append(jsonURL)
                    continue
                }
                let fileURL = dir.deletingLastPathComponent()
                    .appendingPathComponent(task.storedFileName)
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
                default:
                    break
                }
            }
        }
        for url in staleJSONs {
            try? FileManager.default.removeItem(at: url)
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
            try? data.write(to: url, options: .atomic)
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
