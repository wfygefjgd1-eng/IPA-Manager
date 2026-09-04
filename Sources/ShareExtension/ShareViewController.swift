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
            updateStatus("无法访问分享上下文", success: false)
            scheduleComplete(after: 2.5)
            return
        }
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let attachments = items.flatMap { $0.attachments ?? [] }
        // 三级载体匹配：本地文件 URL（文件类分享标准载体）→ 任意 data 系 UTI
        //（可取原始字节）→ public.url（部分来源以 URL 对象包裹本地文件路径）
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            receiveFile(from: provider, typeIdentifier: UTType.fileURL.identifier)
        } else if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.data.identifier) }) {
            // data 系载荷（QQ/微信可能不给 file-url，只给原始字节）：取文件表示，
            // 落盘时按 suggestedName/UTI/魔数补回后缀（主 App 按后缀路由，丢后缀必失败）。
            receiveFile(from: provider, typeIdentifier: UTType.data.identifier)
        } else if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
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
            updateStatus("未找到可导入的文件\n（请分享 .ipa / .zip / 证书文件）", success: false)
            scheduleComplete(after: 2.5)
        }
    }

    /// 用 loadFileRepresentation 取文件：回调块结束时临时 url 即失效，必须当场复制
    private func receiveFile(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self, provider] url, error in
            guard let self else { return }
            guard let url else {
                DispatchQueue.main.async {
                    self.updateStatus("读取文件失败：\(error?.localizedDescription ?? "未知错误")", success: false)
                    self.scheduleComplete(after: 3.0)
                }
                return
            }
            self.saveAndFinish(url: url, provider: provider)
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
        let fileName = Self.resolvedIncomingFileName(tempURL: url, provider: provider)
        do {
            let saved = try AppGroup.saveIncomingFile(at: url, preferredFileName: fileName)
            DispatchQueue.main.async {
                self.updateStatus(
                    "已接收「\(saved.lastPathComponent)」\n\n正在拉起 IPA Manager…",
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
            DispatchQueue.main.async {
                // App Group 不可用时给出明确中文提示
                if error.domain == "AppGroup" && error.code == 1 {
                    self.updateStatus(
                        "⚠️ 共享容器不可用\n\n当前签名描述文件未包含 App Group 权限，\n分享扩展无法交接文件给主 App。\n\n请使用包含 App Group 的描述文件重新签名本 App，\n或在「设置」→「证书」中导入描述文件。",
                        success: false
                    )
                    // 错误提示保持 6 秒，让用户有时间看清
                    self.scheduleComplete(after: 6.0)
                } else {
                    self.updateStatus("保存失败：\(error.localizedDescription)", success: false)
                    self.scheduleComplete(after: 4.0)
                }
            }
        } catch {
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
