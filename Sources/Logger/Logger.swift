import Foundation
import os.log
import UIKit

enum Logger {
    static let subsystem = "com.ipamanager.app"

    struct LogEntry: Codable {
        let timestamp: Date
        let level: String
        let message: String
    }

    private static let maxEntries = Limits.maxLogEntries
    private static let maxFailureEntries = Limits.maxFailureEntries
    /// 失败专区的持久化键：跨启动保留（旧版纯内存，用户"遇到失败 → 重开 App 导出
    /// 报告"的时序下报告永远"（无失败记录）"）
    private static let failureStorageKey = "logger_failure_entries"
    // os_unfair_lock：相比 NSLock 轻量（不自旋、不绑定 pthread），且不会在等锁线程
    // 持有 Send 权限上出问题；关键修复点：NSLock 是阻塞锁，若 os_log 内部触发 KVO/
    // NotificationCenter → 再调 Logger.log → 同线程可重入 NSLock 直接死锁。
    // os_unfair_lock 显式标 _checking(Foundation,Swift) 即可在 Swift 6 strict-concurrency
    // 下安全使用。
    private static let lock = OSAllocatedUnfairLock()
    private(set) static var recentEntries: [LogEntry] = []
    /// 失败与异常专区：只收集 ERROR / warning（DEFAULT）等非 INFO/DEBUG 的消息，供诊断报告使用。
    private(set) static var failureEntries: [LogEntry] = []
    /// OSLog 对象可复用：每次调用都新建会白白浪费一次对象构造开销（签名/下载
    /// 进度类高频日志尤其明显），提升为单一 static 实例。
    private static let log = OSLog(subsystem: subsystem, category: "IPA Manager")

    static func log(_ message: String, level: OSLogType = .info, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        // 提前求值 level.description 为本地常量：避免直接传入 OSLogType 临时
        // 描述字符串作为 os_log 的 %@ vararg（C 字符串约定下生命周期不显式，
        // Swift 6 strict-concurrency 下需要明确 ownership）
        let levelDesc = level.description
        os_log("%@ [%@:%d] %@", log: log, type: level, levelDesc, fileName, line, message)
        #if DEBUG
        print("[\(levelDesc)] \(fileName):\(line) \(message)")
        #endif

        lock.lock()
        defer { lock.unlock() }
        let entry = LogEntry(timestamp: Date(), level: levelDesc, message: "[\(fileName):\(line)] \(message)")
        recentEntries.append(entry)
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
        }
        // 错误类消息（error / warning，即非 info/debug）自动进入失败专区
        if level != .info && level != .debug {
            failureEntries.append(entry)
            if failureEntries.count > maxFailureEntries {
                failureEntries.removeFirst(failureEntries.count - maxFailureEntries)
            }
            persistFailuresLocked()
        }
    }

    /// 启动时载入持久化的失败记录（AppDelegate 冷启动调用一次；本会话已有记录时不动）
    static func loadPersistedFailures() {
        lock.lock()
        defer { lock.unlock() }
        guard failureEntries.isEmpty,
              let data = UserDefaults.standard.data(forKey: failureStorageKey),
              let stored = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        failureEntries = stored
    }

    /// 清空全部诊断缓冲（设置页"清除诊断缓存"）：内存最近日志、失败专区
    /// 与其持久化副本一并清空；投递日志由 ExternalDeliveryJournal.clear() 负责
    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        recentEntries.removeAll()
        failureEntries.removeAll()
        UserDefaults.standard.removeObject(forKey: failureStorageKey)
    }

    /// 失败专区落盘（调用方必须已持锁；环形上限与内存一致）
    private static func persistFailuresLocked() {
        if let data = try? JSONEncoder().encode(failureEntries) {
            UserDefaults.standard.set(data, forKey: failureStorageKey)
        }
    }

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .info, file: file, line: line)
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .error, file: file, line: line)
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .default, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(message, level: .debug, file: file, line: line)
    }

    static func diagnosticsReport() -> String {
        // 诊断报告导出是低频操作（设置页手动触发）：在这里新建局部 formatter，
        // 不与其它路径共享 DateFormatter 实例（DateFormatter 非线程安全，
        // 共享实例在报告生成与并发日志写入之间是潜伏的数据竞争）。
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        // 时间戳带日期：失败常发生在上一次会话，只有 HH:mm:ss 会让跨天记录无法排序
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "MM-dd HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let device = UIDevice.current
        let bundle = Bundle.main.infoDictionary
        let version = bundle?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = bundle?["CFBundleVersion"] as? String ?? "未知"

        lock.lock()
        let recent = Array(recentEntries.suffix(Limits.maxRecentInReport).reversed())
        let failures = Array(failureEntries.reversed())
        lock.unlock()

        var lines: [String] = []
        lines.append("IPA Manager 诊断报告")
        lines.append("")
        lines.append("===== 基本信息 =====")
        lines.append("时间：\(timestampFormatter.string(from: Date()))")
        lines.append("设备型号：\(device.model)")
        lines.append("系统版本：\(device.systemName) \(device.systemVersion)")
        lines.append("App 版本：\(version) (构建 \(build))")
        lines.append("")
        lines.append("===== 失败与异常（按时间倒序）=====")

        if failures.isEmpty {
            lines.append("（无失败记录）")
        } else {
            for entry in failures {
                lines.append("[\(timeFormatter.string(from: entry.timestamp))][\(entry.level)] \(entry.message)")
            }
        }

        lines.append("")
        lines.append("===== 最近日志（最近 100 条含 INFO）=====")

        if recent.isEmpty {
            lines.append("（无日志记录）")
        } else {
            for entry in recent {
                lines.append("[\(timeFormatter.string(from: entry.timestamp))][\(entry.level)] \(entry.message)")
            }
        }

        lines.append("")
        lines.append("===== 外部投递追踪（持久化，跨启动保留，最多 \(ExternalDeliveryJournal.maxEntries) 条）=====")
        lines.append(ExternalDeliveryJournal.reportText())

        lines.append("")
        lines.append("===== 共享容器与投递通道自检 =====")
        // 组候选来源、逐组可写探针、各容器收件箱状态一站汇总（主 App 与扩展共用
        // 同一份摘要逻辑；容器"可用"结论必须经写入探针实测，仅 containerURL 非 nil
        // 不能证明可写）
        for line in AppGroup.diagnosticsSummary() {
            lines.append(line)
        }

        lines.append("")
        lines.append("===== 分享扩展状态（逐个拆解）=====")
        let appexURLs = Bundle.main.urls(forResourcesWithExtension: "appex", subdirectory: "PlugIns") ?? []
        if appexURLs.isEmpty {
            lines.append("分享扩展：未随包安装（IPA 内无 PlugIns/*.appex——签名工具可能剥离了扩展，请用支持扩展的签名方式重签，例如用本 App 的签名引擎签本 App）")
        } else {
            lines.append("分享扩展：已安装 \(appexURLs.count) 个")
        }
        let mainGroup = AppGroup.resolvedIdentifier()
        // 主 App 自身描述文件里的组（与扩展的逐个比对，揪出“组错位”）
        let mainProfileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        let mainProfileGroups = Self.groupsInMobileProvisionFile(mainProfileURL)
        lines.append("主 App 描述文件组：\(mainProfileGroups.isEmpty ? "读不到" : mainProfileGroups.joined(separator: "、"))")
        // 主 App 自身描述文件 AppID：只查组不够——主包也可能被塞错描述文件
        // （进站投递要求系统往本容器拷文件，包络异常时出站自分享正常、进站全灭，
        // 与“txt 能出去、zip/pdf 全进不来”吻合；只看组看不出来，必须核 AppID）
        if let mainProfileURL {
            let ident = Self.provisionIdentityInfo(mainProfileURL)
            if let appID = ident.appID {
                lines.append("主 App 描述文件AppID：\(appID)\(Self.appexAppIDVerdict(profileAppID: appID, appexBid: Bundle.main.bundleIdentifier))")
            } else {
                lines.append("主 App 描述文件AppID：读不到（描述文件损坏或非标准结构！）")
            }
            if let exp = ident.expiresText {
                lines.append("主 App 描述文件有效期至：\(exp)\(ident.expired == true ? "（⚠️已过期！）" : "")")
            }
        } else {
            lines.append("主 App 描述文件：无 embedded.mobileprovision（侧载注入缺失，扩展与进站投递均会异常！）")
        }
        // 沙盒落点自证：进站拷贝的目的地是且仅是这个 Inbox，用户在文件 App 里
        // 看到的位置必须与它对应；不存在/不可写则系统拷贝无处可落
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDir) && isDir.boolValue
            let count = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.count
            lines.append("沙盒 Documents：\(docs.path)")
            lines.append("Inbox 落点：\(inbox.path)（\(exists ? "存在" : "不存在")\(count.map { "，\($0) 个文件" } ?? "")）")
        }
        for appexURL in appexURLs {
            lines.append("── \(appexURL.lastPathComponent)")
            // 1) Info.plist：扩展点 / 主类 / 激活规则（原样打印，排查生成期写错）
            var appexBid: String?
            if let data = try? Data(contentsOf: appexURL.appendingPathComponent("Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any] {
                appexBid = dict["CFBundleIdentifier"] as? String
                lines.append("  BundleID：\(appexBid ?? "?")")
                lines.append("  显示名：\(dict["CFBundleDisplayName"] as? String ?? "?")")
                if let ext = dict["NSExtension"] as? [String: Any] {
                    lines.append("  扩展点：\(ext["NSExtensionPointIdentifier"] as? String ?? "缺失！")")
                    lines.append("  主类：\(ext["NSExtensionPrincipalClass"] as? String ?? "缺失！")")
                    if let rule = ext["NSExtensionActivationRule"] {
                        lines.append("  激活规则：\(Self.compactActivationRule(rule))")
                    } else {
                        lines.append("  激活规则：缺失！（iOS 不会显示该入口）")
                    }
                } else {
                    lines.append("  NSExtension：缺失！（该 appex 不是合法扩展）")
                }
            } else {
                lines.append("  Info.plist：读取失败")
            }
            // 2) 签名：_CodeSignature 缺失则 iOS 拒绝加载扩展（点图标无反应/直接开主 App 的嫌疑之一）
            let hasSig = FileManager.default.fileExists(
                atPath: appexURL.appendingPathComponent("_CodeSignature").path)
            let hasCodeRes = FileManager.default.fileExists(
                atPath: appexURL.appendingPathComponent("_CodeSignature/CodeResources").path)
            lines.append("  签名：\(hasSig ? "有 _CodeSignature" : "无 _CodeSignature（未签名，iOS 会拒绝加载！）")\(hasSig ? (hasCodeRes ? "" : "（缺 CodeResources，签名不完整，iOS 会拒载！）") : "")")
            // 3) 扩展自身描述文件里的组：与主 App 的组交叉比对
            let extProfileURL = appexURL.appendingPathComponent("embedded.mobileprovision")
            let extGroups = Self.groupsInMobileProvisionFile(extProfileURL)
            lines.append("  描述文件组：\(extGroups.isEmpty ? "无/读不到" : extGroups.joined(separator: "、"))")
            // 4) 描述文件身份与有效期：AppID 与扩展 BundleID 不匹配（第三方重签常把主 App
            //    的描述文件塞进扩展）或已过期，iOS 在安装期即拒收该 appex——表现为
            //    分享面板里扩展入口压根不出现（与本次“只有 App 行”吻合）。存在≠有效，
            //    必须逐项核对。
            let ident = Self.provisionIdentityInfo(extProfileURL)
            if let appID = ident.appID {
                lines.append("  描述文件AppID：\(appID)\(Self.appexAppIDVerdict(profileAppID: appID, appexBid: appexBid))")
            } else if FileManager.default.fileExists(atPath: extProfileURL.path) {
                lines.append("  描述文件AppID：读不到（描述文件损坏或非标准结构，iOS 会拒载！）")
            }
            if let exp = ident.expiresText {
                lines.append("  描述文件有效期至：\(exp)\(ident.expired == true ? "（⚠️已过期，iOS 会拒载！）" : "")")
            }
            if extGroups.isEmpty {
                lines.append("  ⚠️ 扩展内没有 embedded.mobileprovision：iOS 17+ 会拒绝加载无描述文件的扩展（分享入口点了毫无反应的直接原因）。zsign 旧版只给主 App 写描述文件，用修复后的本引擎重签即可把描述文件补进每个扩展。")
            }
            if let mainGroup, !extGroups.isEmpty, !extGroups.contains(mainGroup) {
                lines.append("  ⚠️组错位：该扩展的描述文件里没有主 App 正在用的组，主 App 永远读不到它存的文件！")
            }
        }

        lines.append("")
        lines.append("===== 分享扩展日志（共享容器 ExtensionLog.txt）=====")
        if let extLog = AppGroup.readAllExtensionLogs() {
            lines.append(extLog)
        } else {
            lines.append("（无扩展日志——扩展从未成功写入共享容器。按可能性排查：")
            lines.append("1) 分享时点的是「拷贝到 IPA Manager」入口：该入口走文档投递、不经过扩展，无扩展日志属正常——请改点分享面板里的「IPA Manager」扩展面板入口（或动作区「IPA Manager・接收」）再试；")
            lines.append("2) 扩展被系统拒绝加载：见上方逐个 appex 的「签名」「描述文件组」检查，任一「无 _CodeSignature」「描述文件组：无/读不到」或「组错位」都会让入口不可用——请用保留扩展的签名方式重签（例如用本 App 的签名引擎签本 App）；")
            lines.append("3) 共享容器整体不可用：见上方「共享容器与投递通道自检」的逐组探针结果。")
            lines.append("）")
        }

        lines.append("")
        lines.append("由 IPA Manager 诊断功能导出")

        return lines.joined(separator: "\n")
    }

    /// 从 mobileprovision 文件提取 group.* 组名（解析逻辑在 AppGroup.groupsInProvisionData，
    /// 与运行时候选组发现同源；仅诊断展示用）
    private static func groupsInMobileProvisionFile(_ url: URL?) -> [String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return AppGroup.groupsInProvisionData(data)
    }

    /// 描述文件身份信息：mobileprovision 是 CMS 包裹的 plist，但 AppID/Team/有效期
    /// 均为 ASCII 明文，正则直取即可（与组名提取同源，无需 CMS 解析；诊断展示用）。
    private static func provisionIdentityInfo(_ url: URL) -> (appID: String?, expiresText: String?, expired: Bool?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return (nil, nil, nil) }
        let text = String(decoding: data, as: UTF8.self)
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        let appID = first("application-identifier</key>\\s*<string>([^<]+)</string>")
        let expText = first("ExpirationDate</key>\\s*<date>([^<]+)</date>")
        var expired: Bool?
        if let expText {
            let fmt = ISO8601DateFormatter()
            if let date = fmt.date(from: expText) {
                expired = date < Date()
            }
        }
        return (appID, expText, expired)
    }

    /// 核对描述文件 AppID 与扩展 BundleID 是否一致（精确匹配或通配符覆盖）。
    /// 描述文件 AppID 形如 TEAM.com.ipamanager.app.Share（首段为 TeamID）。
    private static func appexAppIDVerdict(profileAppID: String, appexBid: String?) -> String {
        guard let appexBid, !appexBid.isEmpty else { return "" }
        let parts = profileAppID.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return "（⚠️AppID 结构异常，iOS 会拒载！）" }
        let bidPart = String(parts[1])
        if bidPart == appexBid { return "（与扩展一致）" }
        if bidPart.hasSuffix(".*"),
           appexBid.hasPrefix(String(bidPart.dropLast(2)) + ".") || String(bidPart.dropLast(2)) == appexBid {
            return "（通配符覆盖）"
        }
        // 主 App 的描述文件被塞进扩展是最常见的第三方重签失误：组可能碰巧一致
        // 但 AppID 不对，iOS 照样拒载，且“描述文件组”检查完全看不出来
        return "（⚠️与扩展 BundleID \(appexBid) 不匹配，iOS 会拒载该扩展！）"
    }

    /// 激活规则摘要：字符串谓词原样打印；字典只列键（全量打印太长）。
    private static func compactActivationRule(_ rule: Any) -> String {
        if let s = rule as? String { return s }
        if let dict = rule as? [String: Any] {
            return "字典{\(dict.keys.sorted().joined(separator: ","))}"
        }
        return "\(type(of: rule))"
    }
}

private extension OSLogType {
    var description: String {
        switch self {
        case .info: return "INFO"
        case .error: return "ERROR"
        case .debug: return "DEBUG"
        case .fault: return "FAULT"
        default: return "DEFAULT"
        }
    }
}