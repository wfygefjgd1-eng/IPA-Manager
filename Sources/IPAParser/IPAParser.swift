import Foundation

protocol IPAParsing {
    func parse(fileURL: URL) throws -> ParsedPackage
    func parseAppInfo(fileURL: URL) throws -> AppInfo
}

struct ParsedPackage {
    let appURL: URL
    let infoPlistURL: URL
    let rootURL: URL
}

final class IPAParser {
    private let fileManager = FileManager.default
    private let zipManager = ZipManager.shared
    private let infoParser = InfoPlistParser()

    func parse(fileURL: URL) throws -> ParsedPackage {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "ipa" || ext == "zip" else {
            throw AppError.operationFailed("不支持的格式: \(ext)")
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AppError.fileNotFound(fileURL.path)
        }

        let extractDir = extractedDirectory(for: fileURL)
        try zipManager.unzip(archiveURL: fileURL, destinationURL: extractDir)

        guard let appURL = findAppBundle(in: extractDir) else {
            throw AppError.operationFailed("未找到 .app 应用包")
        }

        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw AppError.operationFailed("未找到 Info.plist: \(appURL.lastPathComponent)")
        }

        return ParsedPackage(appURL: appURL, infoPlistURL: infoPlistURL, rootURL: extractDir)
    }

    func parseAppInfo(fileURL: URL) throws -> AppInfo {
        let package = try parse(fileURL: fileURL)
        var info = try infoParser.parse(at: package.infoPlistURL)
        info.path = package.appURL.path
        info.size = AppFileManager.shared.fileSize(at: fileURL)
        info.iconPath = try? infoParser.extractIcon(from: package.infoPlistURL, appURL: package.appURL)
        return info
    }

    func convertToIPAIfNeeded(fileURL: URL) throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "ipa" { return fileURL }

        let package = try parse(fileURL: fileURL)
        let payloadDir = package.rootURL.appendingPathComponent("Payload", isDirectory: true)

        if !fileManager.fileExists(atPath: payloadDir.path) {
            try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            try fileManager.moveItem(at: package.appURL, to: payloadDir.appendingPathComponent(package.appURL.lastPathComponent))
        }

        let outputURL = AppFileManager.shared.directoryURL(.ipa)
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".ipa")
        try zipManager.zip(folderURL: package.rootURL, outputURL: outputURL)
        return outputURL
    }

    func findAppBundle(in rootURL: URL) -> URL? {
        let candidates = [
            rootURL.appendingPathComponent("Payload", isDirectory: true),
            rootURL.appendingPathComponent("Archive/Products/Applications", isDirectory: true),
            rootURL
        ]

        for candidate in candidates {
            guard let items = try? fileManager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) else {
                continue
            }
            if let app = items.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    private func extractedDirectory(for fileURL: URL) -> URL {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return AppFileManager.shared.directoryURL(.extracted).appendingPathComponent(baseName, isDirectory: true)
    }
}