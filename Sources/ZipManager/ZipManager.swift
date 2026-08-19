import Foundation
import ZIPFoundation

final class ZipManager {
    static let shared = ZipManager()

    private let fileManager = FileManager.default

    func unzip(archiveURL: URL, destinationURL: URL) throws {
        Logger.info("解压开始: \(archiveURL.lastPathComponent)")

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        do {
            try fileManager.unzipItem(at: archiveURL, to: destinationURL)
        } catch {
            throw AppError.operationFailed("解压失败: \(archiveURL.lastPathComponent)")
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
}