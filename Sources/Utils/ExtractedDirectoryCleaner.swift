import Foundation

/// Consolidates all Extracted / bundle-extract cleanup logic previously duplicated
/// across `AppState` and `CertificatesView`.
///
/// Entries: `cleanup(matching:)` (per-app extract dirs), `sweepBundleExtractDirs()`
/// (certificate bundle fallback) and `sweepOrphanExtractDirs(importedApps:installedApps:)`
/// (startup orphan sweep), all operating on `Documents/Extracted` by default.
final class ExtractedDirectoryCleaner {

    // MARK: - Convenience wrappers mirroring AppState's old methods

    /// Delete `Documents/Certificates/bundle-extract-*` directories.
    /// Used as fallback when `CertificateBundleImporter.extract` fails without returning a precise `extractDir`.
    static func sweepBundleExtractDirs() {
        let certDir = AppFileManager.shared.directoryURL(.certificates)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: certDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, entry.lastPathComponent.hasPrefix("bundle-extract-") {
                try? AppFileManager.shared.deleteItem(at: entry)
                Logger.info("已清理 bundle-extract 目录: \(entry.path)")
            }
        }
    }

    /// Delete `Documents/Extracted/<prefix>` or `<prefix>-<UUID>` directories.
    /// Used when removing a signed/unsigned app's associated extract dirs.
    static func cleanup(matching prefix: String) {
        let extractedRoot = AppFileManager.shared.directoryURL(.extracted)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, entry.lastPathComponent != "Icons" else { continue }
            if entry.lastPathComponent == prefix || entry.lastPathComponent.hasPrefix(prefix + "-") {
                try? AppFileManager.shared.deleteItem(at: entry)
                Logger.info("已清理关联解压目录: \(entry.path)")
            }
        }
    }

    /// Startup orphan sweep: delete `Extracted/` subdirectories not referenced by any
    /// known app path or icon path. Always preserves `Icons/`.
    /// Additionally preserves recently-modified directories: 并发导入（下载恢复后
    /// 自动导入）正在解压写入的目录不在引用快照里，且解析耗时可达数十秒——
    /// mtime 在 10 分钟内的目录一律视为"可能正在使用"，绝不能删。
    static func sweepOrphanExtractDirs(referencedPaths: [String]) {
        let extractedRoot = AppFileManager.shared.directoryURL(.extracted)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return }
        let now = Date()
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, entry.lastPathComponent != "Icons" else { continue }
            // 进行中的解析/导入保护：刚创建或仍在写入的目录 mtime 很新
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) < 600 {
                continue
            }
            let isReferenced = referencedPaths.contains { $0.hasPrefix(entry.path) }
            if !isReferenced {
                try? AppFileManager.shared.deleteItem(at: entry)
                Logger.info("已清理孤儿解压目录: \(entry.path)")
            }
        }
    }

    /// Convenience: build referenced paths from AppState's model arrays and sweep.
    static func sweepOrphanExtractDirs(importedApps: [AppInfo], installedApps: [AppInfo]) {
        let refs = importedApps.map { $0.path }
            + installedApps.map { $0.path }
            + importedApps.compactMap { $0.iconPath }
            + installedApps.compactMap { $0.iconPath }
        sweepOrphanExtractDirs(referencedPaths: refs)
    }
}
