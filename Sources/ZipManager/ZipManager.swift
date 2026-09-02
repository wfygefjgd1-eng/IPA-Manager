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
        // 单次 Archive 打开完成 zip-slip + symlink + zip-bomb 校验，并返回可复用的 Archive
        // （校验与解压共用一次 Archive 打开，避免多次遍历）。
        let (archive, _) = try validateAndGetArchive(at: archiveURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        do {
            for entry in archive {
                // 关键：ZIPFoundation 的 extract(entry, to:) 中 to 是"条目自身的完整
                // 目标路径"（FileManager.unzipItem 内部就是 destination + entry.path），
                // 不是解压根目录！若直接把根目录传给 extract，第一个文件条目会在
                // "已存在的目录路径"上 createFile → NSFileWriteFileExistsError（516）
                // → 被误判为"ZIP 文件已损坏或下载不完整"。
                let targetURL = destinationURL.appendingPathComponent(entry.path)
                do {
                    try archive.extract(entry, to: targetURL)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // 条目目标已存在（重复条目/目录与文件同名）：unzipItem 内部
                    // createFile 对已存在文件是覆盖、createDirectory 幂等，不会抛；
                    // 这里显式跳过兜底，不视为归档损坏。
                    Logger.debug("跳过已存在条目（不视为损坏）: \(entry.path)")
                }
            }
        } catch let error as ZipManager.ZipError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            // 文件头是 PK 却仍解压失败 → 归档结构已损坏（典型如：下载被截断、
            // 缺少中央目录记录 "End of central directory"），归类为 corrupted。
            Logger.error("ZIP 解压失败（底层原因）: \(error)")
            // 清理半成品，避免残留不完整文件
            try? fileManager.removeItem(at: destinationURL)
            if Self.isDiskFull(error) {
                throw ZipError.unknown("磁盘空间不足，无法完成解压。请清理存储空间后重试")
            }
            throw ZipError.corrupted("ZIP 文件已损坏或下载不完整，请删除后重新下载")
        }

        Logger.info("解压完成: \(destinationURL.path)")
    }

    /// 列出压缩包全部条目路径（不解压任何实体，仅遍历中央目录，几百 MB 的包也是
    /// 毫秒级）。供"只需按文件名/路径形状分类内容"的场景使用（下载自动导入的
    /// 证书包/应用包/内嵌 ipa 分类），替代旧实现的全量解压后扫目录——2GB 包的
    /// 自动导入不再为看一眼文件名付整包解压的 IO 与磁盘峰值。
    /// 条目级安全校验与 unzip 一致（复用 validateAndGetArchive：zip-slip/symlink/
    /// 反斜杠/体积上限），含非法条目的包直接抛 ZipError。
    func listEntryPaths(archiveURL: URL) throws -> [String] {
        try validateZipHeader(at: archiveURL)
        let (archive, _) = try validateAndGetArchive(at: archiveURL)
        return archive.map { $0.path }
    }

    /// 把压缩包中指定路径的单个条目解出到目标 URL（其余条目不落盘）。
    /// 供内嵌 .ipa 抽取等"只取一个条目"的场景：旧实现（分类全量解压）要付整包
    /// 解压的 IO/磁盘峰值才能拿到一个 .ipa。目标 URL 由调用方构造（调用方负责
    /// 唯一化与合法性）；entryPath 必须来自 listEntryPaths 的返回值（已经过
    /// 安全校验，穿越/符号链接条目在 validateAndGetArchive 中已被拒绝）。
    func extractEntry(archiveURL: URL, entryPath: String, to targetURL: URL) throws {
        try validateZipHeader(at: archiveURL)
        let (archive, _) = try validateAndGetArchive(at: archiveURL)
        guard let entry = archive.first(where: { $0.path == entryPath }) else {
            throw ZipError.corrupted("压缩包内未找到条目: \(entryPath)")
        }
        guard entry.type == .file else {
            throw ZipError.corrupted("压缩包条目不是文件: \(entryPath)")
        }
        let parent = targetURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        do {
            try archive.extract(entry, to: targetURL)
        } catch {
            try? fileManager.removeItem(at: targetURL)
            if Self.isDiskFull(error) {
                throw ZipError.unknown("磁盘空间不足，无法完成解压。请清理存储空间后重试")
            }
            throw ZipError.corrupted("条目解压失败（\(entryPath)）：文件可能已损坏")
        }
    }

    /// 磁盘满（NSFileWriteOutOfSpace = 640）单独归因：把"解压时空间不足"误报成
    /// "ZIP 已损坏"会诱导用户重新下载——重新下载必然在相同位置再失败，且下载
    /// 目录还会再多一份 IPA 占位，进一步压缩空间。
    private static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpace
    }

    /// 单次 Archive 打开完成全部条目级安全校验，并返回已校验的 Archive 与总解压体积。
    /// 合并 zip-slip / symlink / 数量与体积上限检查，同时计算 totalBytes，
    /// 避免校验与解压各自再开一次 Archive 的多次遍历。
    private func validateAndGetArchive(at archiveURL: URL) throws -> (Archive, UInt64) {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw ZipError.corrupted("ZIP 文件无法读取")
        }
        // Archive 由 deinit 自动关闭（部分 ZIPFoundation 版本无公开 close()，
        // 不调用可避免编译差异；只读遍历在函数作用域内完成）。

        var totalBytes: UInt64 = 0
        var entryCount = 0
        let maxEntries = Limits.maxEntries
        let maxTotalBytes: UInt64 = Limits.maxTotalBytes // 4GB 上限，防 zip bomb 撑爆沙箱

        for entry in archive {
            entryCount += 1
            if entryCount > maxEntries {
                throw ZipError.corrupted("ZIP 条目数量超出安全上限，已停止解压")
            }
            let path = entry.path
            // 少数 Windows 工具用反斜杠作条目分隔符：POSIX 下会解压成一整层
            // 含 "\" 的平面文件名，解压"成功"但找不到 .app，误报"未找到 .app
            // 应用包"。直接拒绝并给出可操作的中文提示。
            if path.contains("\\") {
                Logger.error("ZIP 条目路径含反斜杠分隔符（非标准打包），已拒绝: \(path)")
                throw ZipError.corrupted("该 ZIP 使用了非标准的反斜杠路径分隔（Windows 工具打包），请用标准工具重新打包后再试")
            }
            // 拒绝路径穿越/绝对路径：含 ".." 组件、以 "/" 开头、或含冒号（驱动符）
            let components = path.split(separator: "/").map(String.init)
            if components.contains("..") || path.hasPrefix("/") || path.contains(":") {
                Logger.error("ZIP 含不安全条目路径，已拒绝: \(path)")
                throw ZipError.corrupted("ZIP 含非法文件路径，已拦截")
            }
            // 拒绝符号链接（IPA 内无需符号链接，恶意压缩包常用其越界写文件）
            // ZIPFoundation 的 entry.type 对非 Unix OS 类型可能回落为 .file，需用
            // externalFileAttributes 兜底检测 S_IFLNK。
            if isSymlink(entry) {
                Logger.error("ZIP 含符号链接条目，已拒绝: \(path)")
                throw ZipError.corrupted("ZIP 含符号链接条目，已拦截")
            }
            // 用 addingReportingOverflow 防御 zip64：条目未压缩体积是 8 字节字段，
            // 值完全由压缩包作者控制（ZIPFoundation 0.9.19+ 支持 zip64）。普通加法
            // 溢出会运行时直接 trap 崩溃；改用回绕检测后溢出即视为超出安全上限
            // 拒绝解压（若改用 &+ 回绕，体积检查会被绕过，deflate 炸弹可无限解压）。
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
            if overflow {
                Logger.error("ZIP 条目体积合计溢出（zip64 伪造字段），已拒绝")
                throw ZipError.corrupted("ZIP 解压体积超出安全上限，已停止解压")
            }
            totalBytes = newTotal
            if totalBytes > maxTotalBytes {
                throw ZipError.corrupted("ZIP 解压体积超出安全上限，已停止")
            }
        }
        return (archive, totalBytes)
    }

    /// 符号链接检测：优先使用 ZIPFoundation 的 entry.type，失败时回落到
    /// externalFileAttributes 的 Unix mode 位。S_IFLNK = 0xA000 (0120000)，位于
    /// externalFileAttributes 的高 16 位。部分 ZIP 以 MSDOS OS 类型存储但仍
    /// 携带 Unix symlink 位，此时 entry.type 会误判为 .file，需此兜底。
    private func isSymlink(_ entry: Entry) -> Bool {
        if entry.type == .symlink {
            return true
        }
        // Fallback via externalFileAttributes >> 16 & 0xA000 == 0xA000
        // centralDirectoryStructure 为 internal，需用 Mirror 反射读取以保持编译兼容
        // （0.9.19 未公开 externalFileAttributes 属性，直接访问会编译失败）。
        let mirror = Mirror(reflecting: entry)
        if let cdsValue = mirror.children.first(where: { $0.label == "centralDirectoryStructure" })?.value {
            let cdsMirror = Mirror(reflecting: cdsValue)
            if let raw = cdsMirror.children.first(where: { $0.label == "externalFileAttributes" })?.value {
                let attrs: UInt32
                if let v = raw as? UInt32 {
                    attrs = v
                } else if let v = raw as? UInt {
                    attrs = UInt32(v)
                } else if let v = raw as? Int {
                    attrs = UInt32(bitPattern: Int32(v))
                } else {
                    return false
                }
                let mode = attrs >> 16
                // 0xA000 == S_IFLNK；任务描述要求 ((attrs>>16) & 0xA000) == 0xA000
                if (mode & 0xA000) == 0xA000 {
                    return true
                }
                // 更严格的 S_IFMT 掩码校验亦视为 symlink（0xF000 == S_IFMT）
                if (mode & 0xF000) == 0xA000 {
                    return true
                }
            }
        }
        return false
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
            // 透传底层原因（对比 unzip 路径），排查"打包失败"时不缺关键信息
            throw AppError.operationFailed("打包失败: \(outputURL.lastPathComponent)（\(error.localizedDescription)）")
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
        // 单次 Archive 打开完成校验并获取 totalBytes，避免多次遍历，
        // 且复用同一 Archive 实例直接进入提取循环（单次 open）。
        let (archive, totalBytes) = try validateAndGetArchive(at: archiveURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        do {
            var processed: UInt64 = 0
            for entry in archive {
                // 关键：ZIPFoundation 的 extract(entry, to:) 中 to 是"条目自身的完整
                // 目标路径"（FileManager.unzipItem 内部就是 destination + entry.path），
                // 不是解压根目录！若直接把根目录传给 extract，第一个文件条目会在
                // "已存在的目录路径"上 createFile → NSFileWriteFileExistsError（516）
                // → 被误判为"ZIP 文件已损坏或下载不完整"。
                let targetURL = destinationURL.appendingPathComponent(entry.path)
                do {
                    try archive.extract(entry, to: targetURL)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // 条目目标已存在（重复条目/目录与文件同名）：unzipItem 内部
                    // createFile 对已存在文件是覆盖、createDirectory 幂等，不会抛；
                    // 这里显式跳过兜底，不视为归档损坏。
                    Logger.debug("跳过已存在条目（不视为损坏）: \(entry.path)")
                }
                // 校验通过后 processed 有界（≤ totalBytes ≤ 4GB），普通加法不会溢出
                processed += entry.uncompressedSize
                // totalBytes 为 0（仅空文件/目录条目的 zip）时跳过除法避免 NaN
                if totalBytes > 0 {
                    progress(min(Double(processed) / Double(totalBytes), 1.0))
                }
            }
            // 全零字节 zip（仅空文件/目录条目）也要报完成：旧实现直接 return 不解压
            // 任何条目（目录条目也不建），且进度报 100% 误导调用方"已完成"
            progress(1.0)
        } catch let error as ZipManager.ZipError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            Logger.error("ZIP 解压失败（底层原因）: \(error)")
            try? fileManager.removeItem(at: destinationURL)
            if Self.isDiskFull(error) {
                throw ZipError.unknown("磁盘空间不足，无法完成解压。请清理存储空间后重试")
            }
            throw ZipError.corrupted("ZIP 文件已损坏或下载不完整，请删除后重新下载")
        }
    }

    private func validateZipHeader(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.notAZipFile("该文件不是有效的 ZIP 压缩包")
        }
        defer { try? handle.close() }

        let header = [UInt8](handle.readData(ofLength: Limits.zipHeaderReadLength))
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

        // HTML 检测：仅匹配完整标签起首（含括号/换行/空白），避免把"not found"、
        // "404" 等常见正常文本误判为 HTML 错误页（如 file_not_found.txt、v2.0.4 等）。
        let markers = ["<!doctype html", "<html", "<head>", "<body", "<!doctype"]
        return markers.contains { lowercased.contains($0) }
    }
}
