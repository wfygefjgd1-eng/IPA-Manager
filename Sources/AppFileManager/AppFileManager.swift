import Foundation

final class AppFileManager {
    static let shared = AppFileManager()

    private let fileManager = FileManager.default

    enum Directory: String {
        case downloads = "Downloads"
        case ipa = "IPA"
        case extracted = "Extracted"
        case certificates = "Certificates"
        case profiles = "Profiles"
        case signed = "Signed"
    }

    var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    var rootURL: URL {
        documentsURL
    }

    func directoryURL(_ directory: Directory) -> URL {
        let url = documentsURL.appendingPathComponent(directory.rawValue, isDirectory: true)
        createDirectoryIfNeeded(url)
        return url
    }

    func fileURL(in directory: Directory, name: String) -> URL {
        directoryURL(directory).appendingPathComponent(name)
    }

    func ensureDirectoryStructure() {
        for dir in Directory.allCases {
            createDirectoryIfNeeded(directoryURL(dir))
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                Logger.error("创建目录失败: \(url.path) - \(error)")
            }
        }
    }

    func contents(of directory: Directory) -> [URL] {
        let url = directoryURL(directory)
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
    }

    func deleteItem(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func moveItem(from source: URL, to destination: URL) throws {
        createDirectoryIfNeeded(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    func copyItem(from source: URL, to destination: URL) throws {
        createDirectoryIfNeeded(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func renameItem(at url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AppError.fileNotFound(url.path)
        }
        if fileManager.fileExists(atPath: destination.path) {
            throw AppError.operationFailed("目标文件已存在")
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }
}

extension AppFileManager.Directory: CaseIterable {}
