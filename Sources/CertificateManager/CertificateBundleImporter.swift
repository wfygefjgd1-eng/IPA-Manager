import Foundation

final class CertificateBundleImporter {
    static let shared = CertificateBundleImporter()

    private let zipManager = ZipManager.shared
    private let fileManager = AppFileManager.shared

    struct BundleContent {
        let p12URL: URL?
        let profileURL: URL?
        /// 本次解压目录根（bundle-extract-<uuid>）：调用方据此精确清理明文 P12
        /// 残留。旧实现靠 p12URL 的直接父目录反推——p12 在子目录时推错根、
        /// zip 只含描述文件时直接为 nil，都会让明文私钥残留 Documents。
        let extractDir: URL
    }

    func extract(from zipURL: URL) throws -> BundleContent {
        let accessed = zipURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                zipURL.stopAccessingSecurityScopedResource()
            }
        }

        let extractDir = fileManager.directoryURL(.certificates)
            .appendingPathComponent("bundle-extract-\(UUID().uuidString)", isDirectory: true)

        try zipManager.unzip(archiveURL: zipURL, destinationURL: extractDir)

        // p12 与 pfx 都要找：分类器（classifyArchivedContent）把 .pfx 也算作证书包，
        // 但旧实现递归查找只匹配 p12——pfx-only 的 zip 必然导入失败，且错误文案
        // （"未找到 .p12/.pfx 证书"）声称支持 pfx，自相矛盾。两者都找，p12 优先。
        let p12Path = Self.findFileRecursively(extension: "p12", in: extractDir)
            ?? Self.findFileRecursively(extension: "pfx", in: extractDir)
        let provPath = Self.findFileRecursively(extension: "mobileprovision", in: extractDir)
        guard p12Path != nil || provPath != nil else {
            // 与分类器（AppState.classifyArchivedContent 的全深度枚举）查找深度一致后
            // 仍两样皆无：抛明确错误。旧实现静默返回 (nil, nil)，上层"无任何反馈地
            // 完成导入"，用户以为导入成功但列表为空。
            throw AppError.operationFailed("压缩包内未找到 .p12/.pfx 证书或 .mobileprovision 描述文件")
        }

        return BundleContent(
            p12URL: p12Path.map { URL(fileURLWithPath: $0) },
            profileURL: provPath.map { URL(fileURLWithPath: $0) },
            extractDir: extractDir
        )
    }

    func moveToManagedLocation(p12URL: URL?, profileURL: URL?) throws -> (p12URL: URL?, profileURL: URL?) {
        var resultP12: URL?
        var resultProfile: URL?

        if let url = p12URL {
            let dest = fileManager.directoryURL(.certificates)
                .appendingPathComponent("cert-\(UUID().uuidString).p12")
            try fileManager.copyItem(from: url, to: dest)
            resultP12 = dest
        }
        if let url = profileURL {
            let dest = fileManager.directoryURL(.profiles)
                .appendingPathComponent("profile-\(UUID().uuidString).mobileprovision")
            try fileManager.copyItem(from: url, to: dest)
            resultProfile = dest
        }
        return (resultP12, resultProfile)
    }

    func cleanup(extractDir: URL) {
        try? fileManager.deleteItem(at: extractDir)
    }

    /// 删除已复制到 Documents 的敏感 P12 副本（私钥材料不应明文常驻 Documents）。
    /// 证书一旦导入 Keychain，其 P12 明文副本即无用且危险（iTunes 文件共享/备份可导出）。
    func deleteManagedP12(_ url: URL?) {
        guard let url = url else { return }
        let dir = fileManager.directoryURL(.certificates).path
        // 只清理位于托管目录内的 cert-*.p12 副本，避免误删用户原始文件
        if url.path.hasPrefix(dir) {
            try? fileManager.deleteItem(at: url)
        }
    }

    /// 启动清扫证书导入残留：删除 Certificates/ 下所有 cert-*.p12 托管副本与
    /// bundle-extract-* 解压目录。正常路径这些副本在导入完成（无论成败）后即被
    /// 精确清理；导入中途进程被杀/崩溃时无人清理，明文私钥材料会永久残留
    /// Documents。启动时无任何证书导入进行中，残留副本必然无用（私钥已入
    /// Keychain，或导入根本未发生）。
    func sweepOrphanManagedArtifacts() {
        let certDir = fileManager.directoryURL(.certificates)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: certDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var swept = 0
        for item in items {
            let name = item.lastPathComponent
            let isManagedP12 = name.hasPrefix("cert-") && name.hasSuffix(".p12")
            let isBundleExtract = name.hasPrefix("bundle-extract-")
            guard isManagedP12 || isBundleExtract else { continue }
            try? fileManager.deleteItem(at: item)
            swept += 1
        }
        if swept > 0 {
            Logger.info("启动清扫证书导入残留: 删除 \(swept) 项（cert-*.p12 / bundle-extract-*）")
        }
    }

    /// 递归查找指定扩展名的文件（与 AppState.classifyArchivedContent 的全深度
    /// 枚举对齐）。旧实现只查顶层 + 一层子目录，证书埋在更深目录（GitHub release
    /// 常见的 release/ios/cert/my.p12 结构）时静默找不到，导入静默失败。
    private static func findFileRecursively(extension ext: String, in directory: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let target = ext.lowercased()
        while let element = enumerator.nextObject() as? URL {
            // 与分类器语义对齐：.app 包内部的 embedded.mobileprovision 不算证书
            // 材料（每个已签应用都带一份；"应用包+顶层描述文件"混合包的深度优先
            // 枚举可能在顶层描述文件之前先命中 Payload 内嵌的那份，抓错文件）
            if element.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
                continue
            }
            let isRegular = (try? element.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            if element.pathExtension.lowercased() == target {
                return element.path
            }
        }
        return nil
    }
}