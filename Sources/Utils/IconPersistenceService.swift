import Foundation

/// Consolidates duplicate icon persistence logic from
/// `AppState.persistImportedAppIcon` and `AppState.persistInstalledAppIcon`.
///
/// Both methods copied the extracted `.app` icon into a stable location
/// `Extracted/Icons/<baseName>/` because `ZipManager.unzip` recreates
/// `Extracted/<baseName>/` on every parse, which would invalidate the icon.
///
/// This service is the single source of truth; `AppState` now delegates to it.
enum IconPersistenceService {

    /// Persist an icon file at `iconPath` into `Extracted/Icons/<baseName>/`.
    /// - Parameters:
    ///   - iconPath: absolute path of the source icon (inside Extracted/<baseName>-<UUID>/Payload/...)
    ///   - baseName: directory name under Icons (typically IPA file name without extension)
    /// - Returns: stable path on success, `nil` on failure (caller keeps original path as fallback).
    static func persist(iconPath: String, baseName: String) -> String? {
        persist(iconPath: iconPath, baseName: baseName, label: nil)
    }

    /// Overload that allows an explicit file label (bundleID or display name) to name the
    /// persisted icon file. When `label` is nil or empty after sanitization, `baseName` is used.
    ///
    /// This mirrors `AppState.persistInstalledAppIcon` which used `bundleID ?? name` as label
    /// while still storing under `Icons/<baseName>/`.
    static func persist(iconPath: String, baseName: String, label: String?) -> String? {
        let source = URL(fileURLWithPath: iconPath)
        guard FileManager.default.fileExists(atPath: iconPath) else {
            Logger.warning("图标持久化失败: 源文件不存在 \(iconPath)")
            return nil
        }

        // File name sanitization: only alphanumeric + . _ - allowed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var effectiveLabel = label ?? baseName
        effectiveLabel = String(effectiveLabel.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        if effectiveLabel.isEmpty { effectiveLabel = baseName }
        // Extra safety: if still empty (baseName was all invalid), fallback
        if effectiveLabel.isEmpty { effectiveLabel = "icon" }

        let fileName = "\(effectiveLabel)-icon.\(source.pathExtension.lowercased())"
        let target = AppFileManager.shared.directoryURL(.extracted)
            .appendingPathComponent("Icons", isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
            .appendingPathComponent(fileName)
        do {
            try AppFileManager.shared.copyItem(from: source, to: target)
            Logger.info("图标持久化成功: \(target.path)")
            return target.path
        } catch {
            Logger.warning("图标持久化失败: \(fileName) - \(error.localizedDescription)")
            return nil
        }
    }

    /// Convenience for `AppInfo` context (installed app): uses bundleID or name as label.
    static func persist(iconPath: String, baseName: String, app: AppInfo) -> String? {
        let label: String = app.bundleID.isEmpty ? app.name : app.bundleID
        return persist(iconPath: iconPath, baseName: baseName, label: label)
    }
}
