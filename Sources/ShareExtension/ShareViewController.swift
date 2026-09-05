import UIKit
import UniformTypeIdentifiers

/// 分享扩展主界面：接收分享面板投递的文件，保存到 App Group 共享 Inbox，
/// 提示用户回主 App 自动完成「导入 → 签名 → 安装」。
/// 扩展进程独立于主 App，不能访问主 App 沙盒/Keychain，文件交接只能经
/// App Group 共享容器（描述文件未授权该能力时给出明确提示）。
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didRequestComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        // 跨进程可见性：扩展启动即在共享容器落一条日志，主 App 诊断可读。
        // 主 App 的投递日志看不到扩展进程，这是之前“日志永远不变”的盲区。
        AppGroup.appendExtensionLog("扩展启动（\(Bundle.main.bundleIdentifier ?? "?")）")
        receiveSharedFile()
    }

    // MARK: - UI

    private func setupUI() {
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "IPA Manager"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        let doneButton = UIButton(type: .system)
        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17)
        doneButton.addAction(UIAction { [weak self] _ in self?.completeAndClose() }, for: .touchUpInside)

        let topBar = UIStackView(arrangedSubviews: [UIView(), titleLabel, doneButton])
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 12

        statusLabel.text = "正在接收文件…"
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        spinner.startAnimating()
        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [topBar, UIView(), spinner, statusLabel, UIView()])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(28, after: topBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - 接收

    private func receiveSharedFile() {
        guard let context = extensionContext else {
            AppGroup.appendExtensionLog("失败：无 extensionContext")
            updateStatus("无法访问分享上下文", success: false)
            scheduleComplete(after: 2.5)
            return
        }
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let attachments = items.flatMap { $0.attachments ?? [] }
        // 收集全部可处理载体（支持一次多选分享：fileURL 优先，其次 data；同一 provider 只处理一次）。
        // 一次选 N 个文件是常见操作，只取第一个会导致“点了没反应”的误解；
        // 且文档直达在多文件时可能直接空手打开主 App，扩展侧必须自己全收。
        var seen = Set<ObjectIdentifier>()
        var jobs: [(NSItemProvider, String)] = []
        for provider in attachments where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            seen.insert(ObjectIdentifier(provider))
            jobs.append((provider, UTType.fileURL.identifier))
        }
        for provider in attachments where !seen.contains(ObjectIdentifier(provider))
            && provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            seen.insert(ObjectIdentifier(provider))
            jobs.append((provider, UTType.data.identifier))
        }
        if !jobs.isEmpty {
            // data 系载荷（QQ/微信可能不给 file-url，只给原始字节）：落盘时按
            // suggestedName/UTI/魔数补回后缀（主 App 按后缀路由，丢后缀必失败）。
            AppGroup.appendExtensionLog("待接收 \(jobs.count) 个文件")
            receiveFiles(jobs)
            return
        }
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            AppGroup.appendExtensionLog("载体=url")
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self, provider] item, error in
                guard let self else { return }
                let url = item as? URL
                    ?? (item as? String).flatMap { URL(string: $0) }
                if let url, url.isFileURL {
                    self.saveAndFinish(url: url, provider: provider)
                } else {
                    DispatchQueue.main.async {
                        self.updateStatus("未找到可导入的文件\n（URL 载荷不是本地文件）", success: false)
                        self.scheduleComplete(after: 3.0)
                    }
                }
            }
        } else {
            AppGroup.appendExtensionLog("失败：无匹配载体（attachments=\(attachments.count)）")
            updateStatus("未找到可导入的文件\n（请分享 .ipa / .zip / 证书文件）", success: false)
            scheduleComplete(after: 2.5)
        }
    }

    /// 逐个取文件表示并保存（串行：扩展内存/IO 配额有限，大包并发复制易被系统杀掉；
    /// 每一步都是新的异步回调，不占用调用栈，文件再多也不会栈溢出）。
    /// 用 loadFileRepresentation 取文件：回调块结束时临时 url 即失效，必须当场复制。
    /// 失败原因逐条收集（failures），最终汇总进结束页 UI——共享容器不可用时扩展
    /// 日志同样写不出去，UI 是当时唯一可靠的诊断出口，必须把细节直接给用户。
    private func receiveFiles(
        _ jobs: [(NSItemProvider, String)], index: Int = 0,
        saved: [String] = [], failed: Int = 0, failures: [String] = []
    ) {
        guard index < jobs.count else {
            finishReceiving(saved: saved, failed: failed, total: jobs.count, failures: failures)
            return
        }
        let (provider, typeIdentifier) = jobs[index]
        AppGroup.appendExtensionLog("[provider] typeIdentifier=\(typeIdentifier) suggestedName=\(provider.suggestedName ?? "无")")
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self, provider] url, error in
            guard let self else { return }
            var saved = saved
            var failed = failed
            var failures = failures
            if let url {
                // 临时文件信息：loadFileRepresentation 回调返回后临时 URL 随时可能
                // 失效，这里当场取大小留痕（复制在回调内同步完成，绝不延迟）
                let tempSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? -1
                AppGroup.appendExtensionLog("[provider] 临时文件 URL=\(url.lastPathComponent) 大小=\(tempSize)B")
                // 安全作用域：文件 Provider 投递的临时 URL 可能需要显式授权，
                // 沙盒严格时无作用域直接拷贝会 POSIX EPERM；非作用域 URL 调用
                // 返回 false，成对 stop 无副作用
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let fileName = Self.resolvedIncomingFileName(tempURL: url, provider: provider)
                do {
                    // 接收三步：复制（UUID 命名）→ 创建任务 JSON → 读回验证。
                    // 三步全部成功才算接收完成；任务未持久化绝不结束请求，
                    // 否则会出现"有时候能用有时候没反应/主 App 找不到文件"
                    let (dest, storedName) = try AppGroup.saveIncomingFile(at: url, preferredFileName: fileName)
                    let taskType = (fileName as NSString).pathExtension.lowercased()
                    let task = ImportTask(originalFileName: fileName, storedFileName: storedName, type: taskType)
                    guard ImportTaskStore.create(task) else {
                        throw NSError(domain: "ImportTask", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "任务记录写入失败（任务未持久化，拒绝结束请求）"])
                    }
                    AppGroup.appendExtensionLog("[task] created id=\(task.id.uuidString.prefix(8)) file=\(storedName) type=\(taskType)")
                    saved.append(fileName)
                } catch {
                    AppGroup.appendExtensionLog("失败：保存失败（\(error.localizedDescription)）")
                    failed += 1
                    failures.append("\(fileName)：\(error.localizedDescription)")
                }
            } else {
                let reason = error?.localizedDescription ?? "未知错误"
                AppGroup.appendExtensionLog("失败：读取文件失败（\(reason)）")
                failed += 1
                failures.append(reason)
            }
            self.receiveFiles(jobs, index: index + 1, saved: saved, failed: failed, failures: failures)
        }
    }

    /// 全部收完后统一展示汇总并拉起主 App（只拉起一次，避免多文件连跳）。
    private func finishReceiving(saved: [String], failed: Int, total: Int, failures: [String] = []) {
        DispatchQueue.main.async {
            guard !saved.isEmpty else {
                var text = "接收失败，共 \(total) 个文件均未保存"
                if let first = failures.first {
                    text += "\n\n\(first)"
                    if failures.count > 1 { text += "\n（共 \(failures.count) 条失败）" }
                }
                self.updateStatus(text, success: false)
                self.scheduleComplete(after: 8.0)
                return
            }
            let shown = saved.prefix(3).joined(separator: "、")
            let more = saved.count > 3 ? " 等 \(saved.count) 个" : ""
            var text = "已接收「\(shown)\(more)」\n\n正在拉起 IPA Manager…"
            if failed > 0 { text += "\n（\(failed) 个失败：\(failures.prefix(2).joined(separator: "；"))）" }
            self.updateStatus(text, success: true)
            self.scheduleComplete(after: 5.0)
            // 尝试拉起主 App：历史系统版本对分享扩展不支持 open（失败无副作用）；
            // 若系统支持则直接回到 App，回前台扫描随即开始导入
            if let appURL = URL(string: "ipamanager://import") {
                self.extensionContext?.open(appURL, completionHandler: nil)
            }
        }
    }

    /// 解析落盘文件名：优先用系统给的 suggestedName；缺后缀时按 UTI/文件魔数补 .zip/.ipa。
    /// QQ/微信等来源的 data 载荷经常没有文件名，主 App 按后缀路由（zip 走分类、其余走 IPA 解析），
    /// 后缀丢失会导致“能收到但报解析失败”。这里尽量保住后缀。
    private static func resolvedIncomingFileName(tempURL: URL, provider: NSItemProvider) -> String {
        var base = (provider.suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = tempURL.lastPathComponent }
        base = (base as NSString).lastPathComponent
        if base.isEmpty { base = "shared-file" }
        if !(base as NSString).pathExtension.isEmpty { return base }
        let ids = provider.registeredTypeIdentifiers.map { $0.lowercased() }
        if ids.contains(where: { $0.contains("zip") }) { return base + ".zip" }
        if ids.contains(where: { $0.contains("ipa") }) { return base + ".ipa" }
        // 兜底：读前 4 字节魔数，PK 开头即 zip（含 ipa，本体都是 zip，主 App 会再分类/转换）
        if isZipMagic(tempURL) { return base + ".zip" }
        return base
    }

    private static func isZipMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let b2 = data[data.startIndex + 2]
        let b3 = data[data.startIndex + 3]
        return b0 == 0x50 && b1 == 0x4B
            && (b2 == 0x03 || b2 == 0x05 || b2 == 0x07)
            && (b3 == 0x04 || b3 == 0x06 || b3 == 0x08)
    }

    /// 复制进共享收件箱并展示结果（任意线程可调，UI 更新自动回主线程）
    private func saveAndFinish(url: URL, provider: NSItemProvider) {
        // 安全作用域：文件 Provider 投递的 URL 可能需要显式授权，无作用域拷贝
        // 会 POSIX EPERM；非作用域 URL 调用返回 false，成对 stop 无副作用
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let fileName = Self.resolvedIncomingFileName(tempURL: url, provider: provider)
        do {
            // 接收三步：复制（UUID 命名）→ 创建任务 JSON → 读回验证（见 receiveFiles）
            let (dest, storedName) = try AppGroup.saveIncomingFile(at: url, preferredFileName: fileName)
            let taskType = (fileName as NSString).pathExtension.lowercased()
            let task = ImportTask(originalFileName: fileName, storedFileName: storedName, type: taskType)
            guard ImportTaskStore.create(task) else {
                throw NSError(domain: "ImportTask", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "任务记录写入失败（任务未持久化，拒绝结束请求）"])
            }
            AppGroup.appendExtensionLog("[task] created id=\(task.id.uuidString.prefix(8)) file=\(storedName) type=\(taskType)")
            DispatchQueue.main.async {
                self.updateStatus(
                    "已接收「\(fileName)」\n\n正在拉起 IPA Manager…",
                    success: true
                )
                // 延长成功提示显示时间（5秒），让用户看清状态
                self.scheduleComplete(after: 5.0)
                // 尝试拉起主 App：历史系统版本对分享扩展不支持 open（失败无副作用）；
                // 若系统支持则直接回到 App，回前台扫描随即开始导入
                if let appURL = URL(string: "ipamanager://import") {
                    self.extensionContext?.open(appURL, completionHandler: nil)
                }
            }
        } catch let error as NSError {
            AppGroup.appendExtensionLog("失败：保存失败（\(error.localizedDescription)）")
            DispatchQueue.main.async {
                // App Group 域错误（容器不可用/全部写入失败）的 localizedDescription
                // 已内嵌完整诊断（声明组/描述文件授予组/逐组探针结果/解决办法），
                // 直接展示——共享容器不可用时扩展日志也写不出去，UI 是唯一诊断出口
                if error.domain == "AppGroup" {
                    self.updateStatus(error.localizedDescription, success: false)
                    // 诊断文字长，多留几秒让用户看清/截图
                    self.scheduleComplete(after: 12.0)
                } else {
                    self.updateStatus("保存失败：\(error.localizedDescription)", success: false)
                    self.scheduleComplete(after: 4.0)
                }
            }
        } catch {
            AppGroup.appendExtensionLog("失败：保存失败（\(error.localizedDescription)）")
            DispatchQueue.main.async {
                self.updateStatus("保存失败：\(error.localizedDescription)", success: false)
                self.scheduleComplete(after: 4.0)
            }
        }
    }

    // MARK: - 状态与关闭

    private func updateStatus(_ text: String, success: Bool) {
        statusLabel.text = text
        statusLabel.textColor = success ? .label : .secondaryLabel
        spinner.stopAnimating()
    }

    /// 延迟自动收起分享面板（给用户看清结果；主 App 未被拉起时用户手动打开即可）
    private func scheduleComplete(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.completeAndClose()
        }
    }

    private func completeAndClose() {
        guard !didRequestComplete else { return }
        didRequestComplete = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
