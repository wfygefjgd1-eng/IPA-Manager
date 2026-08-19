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
            throw ZipError.corrupted("ZIP 文件已损坏或下载不完整，请删除后重新下载")
        }

        Logger.info("解压完成: \(destinationURL.path)")
    }

    func zip(folderURL: URL, outputURL: URL) throws {
        Logger.info("打包开始: \(outputURL.lastPathComponent)")

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        do {
            try fileManager.zipItem(at: folderURL, to: outputURL)
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

    /// 校验 ZIP 文件头（前 4 字节）。非 PK 头时进一步判断是否为 HTML 网页错误页。
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