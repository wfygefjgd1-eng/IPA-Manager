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

        // 优先级不变：zip 里同时存在 .app 时仍按标准应用包解析
        if let appURL = findAppBundle(in: extractDir) {
            return try makePackage(appURL: appURL, extractDir: extractDir)
        }

        // zip 内嵌 .ipa（GitHub release 常见格式：zip 包着 ipa + 校验 txt）：
        // 没有 .app 时在解压目录里找独立的 .ipa，把其中的 .app 提取到当前解压目录再解析。
        if ext == "zip", let ipaURL = findEmbeddedIPA(in: extractDir),
           let appURL = try extractAppFromEmbeddedIPA(ipaURL, into: extractDir) {
            return try makePackage(appURL: appURL, extractDir: extractDir)
        }

        // 解压成功但既找不到 .app 也找不到 .ipa：列出压缩包顶层实际内容，
        // 让用户/我们一眼看出这是源码包、证书包、空包还是结构异常的 ZIP。
        throw AppError.operationFailed(noAppBundleMessage(for: extractDir))
    }

    /// 从 zip 内嵌的 .ipa 中提取 .app，移入当前解压目录：
    /// - 内嵌 .ipa 解压到独立命名（UUID）的临时目录，避免与当前 extractDir 重名冲突
    ///   （典型场景是 zip 与内嵌 ipa 同名：如 "EPICKLE-VR.6.19-IOS.zip" 内含
    ///   "EPICKLE-VR.6.19-IOS.ipa"，若复用同名目录会互相覆盖）；
    /// - 找到 .app 后移动到 extractDir：返回的 ParsedPackage 必须指向持久位置，
    ///   与普通解析的生命周期一致（调用方在 parse 返回后仍会立即读取 appURL）；
    /// - defer 清理临时目录，只保留移出的 .app。
    /// 返回 nil 表示内嵌 .ipa 不是有效的 IPA 结构（解压后无 .app），由调用方回落错误处理。
    private func extractAppFromEmbeddedIPA(_ ipaURL: URL, into extractDir: URL) throws -> URL? {
        let tempDir = AppFileManager.shared.directoryURL(.extracted)
            .appendingPathComponent("IPA-Embedded-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        do {
            try zipManager.unzip(archiveURL: ipaURL, destinationURL: tempDir)
        } catch {
            // 外层 zip 正常，但内嵌的 .ipa 本身损坏/截断（如 release 未上传完整）：
            // 单独给出“内嵌 .ipa”提示，避免误报为外层 zip 损坏。
            throw AppError.operationFailed(
                "压缩包内嵌的 .ipa 无法解压（\(ipaURL.lastPathComponent)）：\(error.localizedDescription)"
            )
        }

        guard let innerApp = findAppBundle(in: tempDir) else { return nil }

        let movedAppURL = extractDir.appendingPathComponent(innerApp.lastPathComponent)
        if fileManager.fileExists(atPath: movedAppURL.path) {
            try? fileManager.removeItem(at: movedAppURL)
        }
        try fileManager.moveItem(at: innerApp, to: movedAppURL)
        return movedAppURL
    }

    /// 在解压目录中查找独立的 .ipa 文件（顶层或任意子目录，排除 .app 内部的），
    /// 用于 zip 内嵌 .ipa 的解析。zip 中不可能有多个有效的内嵌 ipa，取第一个即可。
    private func findEmbeddedIPA(in rootURL: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        while let element = enumerator.nextObject() as? URL {
            guard element.pathExtension.lowercased() == "ipa",
                  !isInsideAppBundle(element) else { continue }
            let isDirectory = (try? element.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDirectory else { continue }
            return element
        }
        return nil
    }

    private func isInsideAppBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasSuffix(".app") }
    }

    /// 校验 .app 内 Info.plist 存在并构造 ParsedPackage（普通 .app 与内嵌 .ipa 解析共用统一出口）。
    private func makePackage(appURL: URL, extractDir: URL) throws -> ParsedPackage {
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