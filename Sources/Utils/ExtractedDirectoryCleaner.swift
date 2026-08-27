import Foundation

/// Consolidates all Extracted / bundle-extract cleanup logic previously duplicated
/// across `AppState.sweepBundleExtractDirs`, `cleanupExtractDirs(matching:)`
/// and `sweepOrphanExtractDirs`.
///
/// The canonical entry is `sweep(prefix:excluding:)` which operates on
/// `Documents/Extracted` by default; an overload allows targeting any
/// `AppFileManager.Directory` (e.g. `.certificates` for bundle-extract dirs).
final class ExtractedDirectoryCleaner {

    // MARK: - Primary API (required by task)

    /// Sweep `Documents/Extracted` for directories whose name starts with `prefix`.
    /// - Parameters:
    ///   - prefix: directory name prefix to match (e.g. `"bundle-extract-"` is handled via certificates overload)
    ///   - excluding: directory names to exclude (exact match). `"Icons"` is always excluded.
    static func sweep(prefix: String, excluding: [String] = []) {
        sweep(prefix: prefix, in: .extracted, excluding: excluding)
    }

    /// Sweep a specific `AppFileManager.Directory` for directories whose name starts with `prefix`.
    static func sweep(prefix: String, in directory: AppFileManager.Directory, excluding: [String] = []) {
        let root = AppFileManager.shared.directoryURL(directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // Always exclude Icons (stable icon storage) plus caller-supplied exclusions
        var excludedSet = Set(excluding)
        excludedSet.insert("Icons")

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            let name = entry.lastPathComponent
            guard !excludedSet.contains(name) else { continue }
            if name == prefix || name.hasPrefix(prefix) {
                try? AppFileManager.shared.deleteItem(at: entry)
                Logger.info("已清理目录: \(entry.path)")
            }
        }
    }

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
    static func sweepOrphanExtractDirs(referencedPaths: [String]) {
        let extractedRoot = AppFileManager.shared.directoryURL(.extracted)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory, entry.lastPathComponent != "Icons" else { continue }
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

    // MARK: - Helpers

    /// Resolve the `bundle-extract-<uuid>` root from a file URL inside it.
    /// Returns nil if not inside a bundle-extract directory.
    static func bundleExtractRoot(from fileURL: URL?) -> URL? {
        guard var current = fileURL?.deletingLastPathComponent() else { return nil }
        let certDirPath = AppFileManager.shared.directoryURL(.certificates).path
        while current.path.hasPrefix(certDirPath) {
            if current.lastPathComponent.hasPrefix("bundle-extract-") {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
