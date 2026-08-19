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

        // 解压源压缩包并定位 .app（找不到会抛出“未找到 .app 应用包”）
        let package = try parse(fileURL: fileURL)

        // 构造干净的临时目录，只包含 Payload/<应用名>.app，
        // 保证打包出的 .ipa 无论源结构（Payload/、Archive/ 或裸 .app）都合法
        let stagingRoot = AppFileManager.shared.directoryURL(.extracted)
            .appendingPathComponent("IPA-Build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let payloadDir = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: package.appURL,
            to: payloadDir.appendingPathComponent(package.appURL.lastPathComponent)
        )

        // 输出到 .ipa 目录；同名文件已存在时 ZipManager.zip 会先移除再覆盖
        let outputURL = AppFileManager.shared.directoryURL(.ipa)
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".ipa")
        try zipManager.zip(folderURL: stagingRoot, outputURL: outputURL)
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