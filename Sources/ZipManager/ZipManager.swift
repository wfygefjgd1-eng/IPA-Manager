import Foundation
import ZIPFoundation

final class ZipManager {
    static let shared = ZipManager()

    /// ZIP 相关错误的统一分类，`errorDescription` 均为面向用户的中文提示，
    /// 避免把底层英文错误（如 "End of central directory"）直接暴露给用户。
    enum ZipError: Error, LocalizedError {
        /// 文件头不是 ZIP：可能是网页错误页、其它格式，或根本不是文件
        case notAZipFile(String)
        /// ZIP 结构损坏或下载不完整（解压过程底层报错）
        case corrupted(String)
        /// 其它未知错误兜底
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .notAZipFile(let message),
                 .corrupted(let message),
                 .unknown(let message):
                return message
            }
        }
    }

    private let fileManager = FileManager.default

    func unzip(archiveURL: URL, destinationURL: URL) throws {
        Logger.info("解压开始: \(archiveURL.lastPathComponent)")

        // 解压前先校验文件头，把“根本不是 zip / 下载到的是网页错误页”的情况
        // 挡在解压之前，给出可操作的中文提示（替代底层英文报错）。
        try validateZipHeader(at: archiveURL)
        // zip-slip 纵深防御：解压前遍历全部条目，拒绝路径穿越条目
        try validateEntryPaths(at: archiveURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        do {
            try fileManager.unzipItem(at: archiveURL, to: destinationURL)
        } catch {
            // 文件头是 PK 却仍解压失败 → 归档结构已损坏（典型如：下载被截断、
            // 缺少中央目录记录 "End of central directory"），归类为 corrupted。
            Logger.error("ZIP 解压失败（底层原因）: \(error)")
            // 清理半成品，避免残留不完整文件
            try? fileManager.removeItem(at: destinationURL)
            throw ZipError.corrupted("ZIP 文件已损坏或下载不完整，请删除后重新下载")
        }

        Logger.info("解压完成: \(destinationURL.path)")
    }

    /// zip-slip 防御：逐条目校验路径是否安全（拒绝绝对路径、.. 越界、含冒号驱动符）。
    /// ZIPFoundation 0.9.19 已内置词法包含性检查，这里在 App 侧再加一道保险，
    /// 并显式拒绝符号链接条目（IPA 极少需要符号链接，恶意压缩包常用其越界写文件）。
    private func validateEntryPaths(at archiveURL: URL) throws {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw ZipError.corrupted("ZIP 文件无法读取")
        }
        // Archive 由 deinit 自动关闭（部分 ZIPFoundation 版本无公开 close()，
        // 不调用可避免编译差异；只读遍历在函数作用域内完成）。

        var totalBytes: UInt64 = 0
        var entryCount = 0
        let maxEntries = 50_000
        let maxTotalBytes: UInt64 = 4 * 1024 * 1024 * 1024 // 4GB 上限，防 zip bomb 撑爆沙箱

        for entry in archive {
            entryCount += 1
            if entryCount > maxEntries {
                throw ZipError.corrupted("ZIP 条目数量超出安全上限，已停止解压")
            }
            let path = entry.path
            // 拒绝路径穿越/绝对路径：含 ".." 组件、以 "/" 开头、或含冒号（驱动符）
            let components = path.split(separator: "/").map(String.init)
            if components.contains("..") || path.hasPrefix("/") || path.contains(":") {
                Logger.error("ZIP 含不安全条目路径，已拒绝: \(path)")
                throw ZipError.corrupted("ZIP 含非法文件路径，已拦截")
            }
            // 拒绝符号链接（IPA 内无需符号链接，恶意压缩包常用其越界写文件）
            if entry.type == .symlink {
                Logger.error("ZIP 含符号链接条目，已拒绝: \(path)")
                throw ZipError.corrupted("ZIP 含符号链接条目，已拦截")
            }
            totalBytes += entry.uncompressedSize
            if totalBytes > maxTotalBytes {
                throw ZipError.corrupted("ZIP 解压体积超出安全上限，已停止")
            }
        }
    }

    func zip(folderURL: URL, outputURL: URL, shouldKeepParent: Bool = false) throws {
        Logger.info("打包开始: \(outputURL.lastPathComponent)")

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        do {
            // shouldKeepParent=false：把文件夹内容（Payload/）直接打到压缩包根，
            // 否则 ZIPFoundation 会把 staging 目录名作为前缀（IPA-Build-<UUID>/Payload/...），
            // 生成的 ".ipa" 顶层不是 Payload，后续解析/签名/安装全部不可用。
            // zipItem 内部默认 deflate 压缩：转换产物必须压缩，避免 2~4 倍体积膨胀
            // （不使用带 compressionMethod 的重载与 ZipArchive/CompressionMethod 类型名，
            // 这些在部分 ZIPFoundation 版本不存在；默认压缩方法即 deflate）。
            try fileManager.zipItem(
                at: folderURL,
                to: outputURL,
                shouldKeepParent: shouldKeepParent
            )
        } catch {
            throw AppError.operationFailed("打包失败: \(outputURL.lastPathComponent)")
        }

        Logger.info("打包完成: \(outputURL.path)")
    }

    // MARK: - ZIP 头校验

    /// 普通 ZIP 的本地文件头签名 "PK\x03\x04"
    private static let localFileHeaderSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    /// 空 ZIP 的签名 "PK\x05\x06"（仅含中央目录结束记录，无任何条目）
    private static let emptyArchiveSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    // MARK: - 带进度的解压（逐条目提取，按已解压字节/总字节上报 0~1）

    /// 逐条目解压并按已处理字节上报进度（供导入进度条展示真实百分比）。
    /// 与 unzip 的完整校验（文件头 + zip-slip 条目校验）一致，只是改为
    /// 逐条目 extract 以便计算进度。progress 在主调用线程回调（调用方负责切主线程）。
    func unzipWithProgress(
        archiveURL: URL,
        destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        try validateZipHeader(at: archiveURL)
        try validateEntryPaths(at: archiveURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        do {
            guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
                throw ZipError.corrupted("ZIP 文件无法读取")
            }
            let totalBytes = archive.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
            guard totalBytes > 0 else {
                // 空 zip：直接完成
                progress(1.0)
                return
            }
            var processed: UInt64 = 0
            for entry in archive {
                try archive.extract(entry, to: destinationURL)
                processed += entry.uncompressedSize
                progress(Double(processed) / Double(totalBytes))
            }
        } catch let error as ZipManager.ZipError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            Logger.error("ZIP 解压失败（底层原因）: \(error)")
            try? fileManager.removeItem(at: destinationURL)
            throw ZipError.corrupted("ZIP 文件已损坏或下载不完整，请删除后重新下载")
        }
    }

    private func validateZipHeader(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.notAZipFile("该文件不是有效的 ZIP 压缩包")
        }
        defer { try? handle.close() }

        let header = [UInt8](handle.readData(ofLength: 4))
        let isZipHeader = header == Self.localFileHeaderSignature
            || header == Self.emptyArchiveSignature

        guard isZipHeader else {
            if hasHTMLPageContent(at: url) {
                throw ZipError.notAZipFile("下载到的是网页而不是文件（链接可能失效或被拦截），请检查链接后重试")
            }
            throw ZipError.notAZipFile("该文件不是有效的 ZIP 压缩包")
        }
    }

    /// 读取文件前 ~512 字节，判断内容是否像 HTML 网页 / 常见错误页文本
    /// （弱网或直连环境下，GitHub 等站点常返回 HTML 错误页而非真实文件）。
    private func hasHTMLPageContent(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 512)
        let text = (String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1))?.lowercased()
        guard let lowercased = text else { return false }

        let markers = ["<!doctype html", "<html", "<head", "not found", "404", "access denied"]
        return markers.contains { lowercased.contains($0) }
    }
}