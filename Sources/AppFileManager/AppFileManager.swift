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

    /// Documents 根目录的用户说明文件。「文件」App 只在 Documents 内存在真实文件时
    /// 才在「浏览/我的 iPhone」显示本应用入口（仅空子目录不满足显示条件）——
    /// 新装用户 Documents 只有空的分类子目录，完全找不到「IPA Manager」文件夹。
    /// 保留这个几 KB 的说明文件保证文件夹始终可见；被用户删除会在下次启动重建。
    private static let documentsReadmeFileName = "使用说明.txt"

    private static let documentsReadmeContent = """
    IPA Manager 工作文件夹（随应用一起出现）

    · 把 IPA / ZIP 文件放进本文件夹（或它的子文件夹），再打开 IPA Manager 会自动导入。
    · 文件夹说明：
      IPA      未签名应用包（可在应用内签名安装）
      Signed   已签名产物
      Downloads 应用内浏览器下载的文件
      Extracted / Certificates / Profiles / Icons  应用内部使用的目录，请勿改动
    · Inbox 是其他应用「拷贝到 IPA Manager」的收件箱，导入完成后会自动清空。
    · 「文件」App 只有在文件夹里存在文件时才显示本应用入口，因此这里保留了一个
      说明文件，请勿删除所有文件，以免本文件夹从「我的 iPhone」中消失。
    """

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
        ensureDocumentsReadmeIfNeeded()
    }

    /// Documents 根目录说明文件：缺失即重建（幂等；文件 App 的入口显示依赖它存在）
    private func ensureDocumentsReadmeIfNeeded() {
        let markerURL = documentsURL.appendingPathComponent(Self.documentsReadmeFileName)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: markerURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return
        }
        do {
            try Data(Self.documentsReadmeContent.utf8).write(to: markerURL, options: .atomic)
        } catch {
            Logger.error("写入 Documents 说明文件失败: \(error.localizedDescription)")
        }
    }

    /// 清扫本 App tmp 内系统文件选择器 Copy 模式的代拷残留目录（命名为
    /// "<bundleID>-Inbox"，系统把选中文件先拷进这里再回调导入）。
    /// 正常一次导入会把这份系统副本 move 走；选择流被打断（点开没导入/取消）或
    /// 系统拷贝半途失败时会留下 GB 级残留——既占空间又在磁盘紧张时拖垮下一次
    /// 代拷（拷贝失败时代表器无声无息，不回调任何环节）。打开选择器前按目录
    /// 清空：代拷目录由系统独占使用、内容即用即弃，且本入口打开时必然无并发导入
    /// （导入进行中按钮已禁用），清空绝对安全。
    func sweepPickerInboxResidue() {
        let tmpDirectory = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tmpDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasSuffix("-Inbox") {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let residue = (try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for item in residue {
                try? fileManager.removeItem(at: item)
            }
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
}

extension AppFileManager.Directory: CaseIterable {}
