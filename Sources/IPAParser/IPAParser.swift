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
        do {
            try zipManager.unzip(archiveURL: fileURL, destinationURL: extractDir)
        } catch let error as ZipManager.ZipError {
            // ZipError 的 errorDescription 已经是面向用户的中文
            // （“不是有效的 ZIP / 下载到的是网页 / 已损坏或下载不完整”），直接透传保留全部细节。
            throw error
        } catch {
            // 其它解压失败（如临时目录创建失败）：把底层原因拼进中文错误，便于定位解压哪一步出错。
            throw AppError.operationFailed("解压失败：\(error.localizedDescription)")
        }

        guard let appURL = findAppBundle(in: extractDir) else {
            // 解压成功但找不到 .app：列出压缩包顶层实际内容，
            // 让用户/我们一眼看出这是源码包、证书包、空包还是结构异常的 ZIP。
            throw AppError.operationFailed(noAppBundleMessage(for: extractDir))
        }

        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw AppError.operationFailed("未找到 Info.plist: \(appURL.lastPathComponent)")
        }

        return ParsedPackage(appURL: appURL, infoPlistURL: infoPlistURL, rootURL: extractDir)
    }

    /// 生成“未找到 .app”的详细中文原因：列出解压目录顶层的实际内容（最多 5 个 +
    /// 总数），帮助区分压缩包是源码包、证书包、空包还是结构异常的 ZIP。
    private func noAppBundleMessage(for extractDir: URL) -> String {
        var message = "未找到 .app 应用包"
        guard let items = try? fileManager.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: nil
        ) else {
            // 解压目录不存在或不可读 → 视为空
            return message + "。解压目录为空或无法读取"
        }
        if items.isEmpty {
            return message + "。解压目录为空（压缩包内没有任何内容）"
        }
        let names = items.map { $0.lastPathComponent }
        let shown = names.prefix(5).joined(separator: "、")
        if names.count > 5 {
            message += "。压缩包内包含：\(shown) 等 \(names.count) 个条目"
        } else {
            message += "。压缩包内包含：\(shown)"
        }
        return message
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