import Foundation
import Security
import ZIPFoundation

protocol SigningEngineProtocol {
    func sign(
        sourcePath: String,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double) -> Void
    ) throws -> String
}

final class SigningEngine: SigningEngineProtocol {
    static let shared = SigningEngine()

    private let fileManager = AppFileManager.shared
    private let certManager = CertificateManager.shared
    private let zipManager = ZipManager.shared
    /// 底层文件系统操作（解压/移动/枚举等）统一走 FileManager.default，
    /// 与 AppFileManager（应用目录/持久化语义）区分开。
    private let disk = FileManager.default

    func sign(
        sourcePath: String,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double) -> Void
    ) throws -> String {
        progress(0.0)

        // 源文件可能已被删除/移动（列表记录还在但磁盘文件丢失）：
        // 若直接进入导出流程，zsign 桥接层会报 "Input file not found" 这类不友好的英文错误。
        // 在导出/签名任何操作之前先校验源文件是否存在，给出友好中文提示。
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            let reason = "源文件已被删除或移动，请返回列表重新导入该应用后再签名"
            Logger.error("签名失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        // 签名前置校验（在规范化之前）：证书/描述文件过期、Team ID 不匹配直接拒绝，
        // 避免 SignOptionsView 允许选择过期证书/描述文件后签名到一半才失败。
        // 过期字段以模型的计算属性 status 为准（expireDate 缺失时为 unknown，不判过期）。
        if certificate.status == .expired {
            let reason = "证书已过期，请更换证书"
            Logger.error("签名失败: \(reason) (\(certificate.name))")
            throw AppError.signFailed(reason)
        }
        if profile.status == .expired {
            let reason = "描述文件已过期"
            Logger.error("签名失败: \(reason) (\(profile.name))")
            throw AppError.signFailed(reason)
        }
        if !certificate.teamID.isEmpty && !profile.teamID.isEmpty && certificate.teamID != profile.teamID {
            let reason = "证书与描述文件的 Team ID 不匹配"
            Logger.error("签名失败: \(reason)（证书 \(certificate.teamID) / 描述文件 \(profile.teamID)）")
            throw AppError.signFailed(reason)
        }

        // 源 IPA 结构规范化：标准 IPA 顶层必须是 Payload/<App>.app/。
        // 历史 CI 产物（ditto --keepParent 会把 .app 直接放压缩包根）和某些
        // 第三方来源的包不符合该结构，zsign 解压后报 "Can't find payload directory"。
        // 这里在签名前自动校验并修复：非标准结构解压 → 找 .app → 重打包为
        // Payload/ 标准结构再交给 zsign，任何来源的 IPA 都能签。
        // 注意：规范化失败（非标准结构且修复失败）不再静默回退到原路径签名
        // （那样会直接撞上 zsign 的英文报错），而是抛出中文错误直接终止签名；
        // nil 返回值只表示"已是标准结构"（含 Payload/），直接使用源文件。
        let signingSourcePath: String
        var normalizedWorkDir: URL?
        var normalizedOutputURL: URL?
        if let normalized = try normalizeSourceIPAIfNeeded(sourcePath) {
            signingSourcePath = normalized.outputURL.path
            normalizedWorkDir = normalized.workRoot
            normalizedOutputURL = normalized.outputURL
        } else {
            signingSourcePath = sourcePath
        }
        defer {
            if let normalizedWorkDir = normalizedWorkDir {
                try? disk.removeItem(at: normalizedWorkDir)
            }
            if let normalizedOutputURL = normalizedOutputURL {
                try? disk.removeItem(at: normalizedOutputURL)
            }
        }

        Logger.info("开始签名: \(sourcePath)")
        progress(0.05)

        guard let keychainID = certificate.keychainIdentifier else {
            let reason = "证书缺少 Keychain 标识"
            Logger.error("签名失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        let certPassword = certManager.readPassword(for: certificate) ?? ""

        let p12URL = try exportP12(identifier: keychainID)
        defer {
            try? fileManager.deleteItem(at: p12URL)
        }

        // 首选：把 p12 里的私钥导出为 PEM 私钥文件（绕开 iOS 静态 OpenSSL 对
        // PBES2/AES p12 的 PKCS12_parse 失败问题）；失败则回退直接用 p12 文件。
        // zsign 的 ZSignAsset::Init 在 certPath 为空时会自动从描述文件的
        // DeveloperCertificates 里找与私钥配对的证书。
        let keyFileURL = try? exportPrivateKeyPEM(from: p12URL, password: certPassword)
        defer {
            if let keyFileURL = keyFileURL {
                try? fileManager.deleteItem(at: keyFileURL)
            }
        }
        let keyPath = (keyFileURL ?? p12URL).path

        let outputURL = fileManager.directoryURL(.signed)
            .appendingPathComponent("\(URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent)-signed-\(UUID().uuidString.prefix(8)).ipa")

        // Bridge progress callback: pass a non-capturing C closure + context.
        // 进度平滑：zsign 只回调 5/20/85/100 四档，85% 之后是"重新打包"阶段
        // （Zip::Archive 压缩无进度回调），大 IPA 会长时间停在 85% 让用户误以为卡死。
        // 平滑器把真实进度作为目标值，用主线程定时器让展示进度在 85% 后缓慢蠕动
        // 逼近 98%（"仍在工作"的反馈），收到真实 100% 立即归正并停止。
        let smoother = ProgressSmoother(rawHandler: progress)
        let box = ProgressBox(handler: smoother.receive)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        // 临时目录必须可写：iOS 沙箱内 NSTemporaryDirectory 保证可用（不能用 /tmp）
        let tempDir = NSTemporaryDirectory()

        let result: Int32 = signingSourcePath.withCString { inputCStr in
            outputURL.path.withCString { outputCStr in
                keyPath.withCString { p12CStr in
                    profile.path.withCString { provCStr in
                        certPassword.withCString { pwdCStr in
                            tempDir.withCString { tempDirCStr in
                                var options = ZSignOptions()
                                options.inputIpaPath = inputCStr
                                options.outputIpaPath = outputCStr
                                options.pkeyPath = p12CStr
                                options.provisionPath = provCStr
                                options.password = pwdCStr
                                options.tempFolder = tempDirCStr
                                options.zipLevel = 1
                                options.force = 1
                                options.enableDocuments = 1
                                options.context = context
                                options.progressCallback = progressCallbackFunc
                                return zsign_sign(&options)
                            }
                        }
                    }
                }
            }
        }

        if result != 0 {
            // 签名失败：先清理 Signed/ 下的半成品 .ipa，避免 refreshInstalledApps
            // 全量扫描时把残缺文件当成"已签应用"。
            try? fileManager.deleteItem(at: outputURL)

            let rawMessage = CertificateManager.safeZSignError(limit: 512)
            let userMessage = Self.localizedSignFailure(rawMessage, code: result)
            Logger.error("签名失败: \(sourcePath) - \(rawMessage)")
            throw AppError.signFailed(userMessage)
        }

        progress(1.0)
        // 显式收尾：zsign 可能只回调到 85% 就完成（不保证回调 100%），
        // 若不主动告知，smoother 的蠕动定时器会继续空转（泄漏 + UI 空转）。
        smoother.complete()
        Logger.info("签名完成: \(outputURL.path)")
        return outputURL.path
    }

    /// 用系统 Security 框架（SecPKCS12Import）解开 p12 并把私钥导出为 PEM 文件。
    /// iOS 静态 OpenSSL 对 PBES2/AES p12 的 PKCS12_parse 可能失败，而系统实现可靠。
    private func exportPrivateKeyPEM(from p12URL: URL, password: String) throws -> URL {
        guard let data = try? Data(contentsOf: p12URL) else {
            let reason = "无法读取证书数据"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let rawIdentity = first[kSecImportItemIdentity as String] else {
            let reason = "系统无法解析此证书 (错误码 \(status))"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }
        // SecIdentity 是 CoreFoundation 类型，不能对 CF 类型做条件转换（编译器报错
        // “conditional downcast to CoreFoundation type will always succeed”），
        // 与 ServerIdentityProvider 一致：CFGetTypeID 校验类型后用强制转换，
        // 类型不符时抛中文错误而非崩溃。
        guard CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            let reason = "证书数据格式异常（无法获取签名身份）"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }
        let identity = rawIdentity as! SecIdentity

        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            let reason = "证书中未找到私钥"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        guard let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            let reason = "无法导出私钥"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        // ECC 私钥是 SEC1 格式（BEGIN EC PRIVATE KEY）；RSA 是 PKCS#1 格式（BEGIN RSA PRIVATE KEY）
        var pemBlock = "-----BEGIN PRIVATE KEY-----\n"
        var isEC = false
        var isRSA = false
        if let attrs = SecKeyCopyAttributes(key) as? [String: Any],
           let keyType = attrs[kSecAttrKeyType as String] as? String {
            if keyType == (kSecAttrKeyTypeEC as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
                isEC = true
            } else if keyType == (kSecAttrKeyTypeRSA as String) {
                isRSA = true
            }
        }
        if isEC {
            pemBlock = "-----BEGIN EC PRIVATE KEY-----\n"
        } else if isRSA {
            pemBlock = "-----BEGIN RSA PRIVATE KEY-----\n"
        }

        let base64Lines = (keyData as Data).base64EncodedString()
        var pem = pemBlock
        var index = 0
        let step = 64
        while index < base64Lines.count {
            let end = min(index + step, base64Lines.count)
            pem += base64Lines[base64Lines.index(base64Lines.startIndex, offsetBy: index)..<base64Lines.index(base64Lines.startIndex, offsetBy: end)] + "\n"
            index = end
        }
        let footer: String
        if isEC {
            footer = "-----END EC PRIVATE KEY-----\n"
        } else if isRSA {
            footer = "-----END RSA PRIVATE KEY-----\n"
        } else {
            footer = "-----END PRIVATE KEY-----\n"
        }
        pem += footer

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sign-key-\(UUID().uuidString).pem")
        do {
            try pem.write(to: outputURL, atomically: true, encoding: .utf8)
            // 私钥 PEM 只允许当前用户读写（0600），避免同沙箱其他路径可读
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
        } catch {
            let reason = "无法写入 PEM 私钥文件 (\(error.localizedDescription))"
            Logger.error("导出 PEM 私钥失败: \(reason)")
            throw AppError.signFailed(reason)
        }
        Logger.info("已导出 PEM 私钥: \(isEC ? "ECC" : isRSA ? "RSA" : "PKCS8")")
        return outputURL
    }

    private func exportP12(identifier: String) throws -> URL {
        // 私钥材料写到系统临时目录，避免残留在 Documents 目录。
        // 文件名加 UUID：同一证书并发/紧邻两次签名时各自独立文件，
        // 避免互相覆盖或前一次 defer 删除恰好截断后一次正在读取的 p12。
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(identifier)-\(UUID().uuidString).p12")
        try certManager.exportP12(identifier: identifier, to: tempURL)
        return tempURL
    }

    // MARK: - 源 IPA 结构规范化

    /// 校验源 IPA 顶层是否为标准结构（含 Payload/ 目录）：
    /// 标准 IPA 必须形如 Payload/<App>.app/，zsign 签名依赖该结构。
    /// 历史 CI 产物（ditto --keepParent 把 .app 直接打进压缩包根）及部分第三方
    /// 打包工具生成的包顶层直接是 .app，缺 Payload 层，zsign 解压后报
    /// "Can't find payload directory"。签名前先做结构校验，非标准则就地修复。
    /// - Returns: 已是标准结构时 nil；否则返回 (workRoot, outputURL)——
    ///   workRoot 为规范化临时目录（调用方签名完成后统一删除），
    ///   outputURL 为修复后的标准结构 IPA，交给 zsign 签名。
    /// - Throws: 非标准结构且修复失败时抛出中文错误，调用方直接终止签名，
    ///   不再静默回退到原路径（回退必然触发 zsign 的英文报错）。
    private func normalizeSourceIPAIfNeeded(_ sourcePath: String) throws -> (workRoot: URL, outputURL: URL)? {
        let sourceURL = URL(fileURLWithPath: sourcePath)

        // 快速路径：直接读 zip 条目，检查顶层是否含 Payload/ 或 Payload 目录。
        if hasPayloadDirectory(in: sourceURL) {
            return nil
        }

        Logger.warning("源 IPA 顶层缺少 Payload/ 目录，签名前自动修复结构: \(sourcePath)")
        let workRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IPA-Normalize-\(UUID().uuidString)", isDirectory: true)

        do {
            // 解压源 IPA 到临时目录（校验 + zip-slip 防御由 ZipManager 统一负责）
            let extractDir = workRoot.appendingPathComponent("extract", isDirectory: true)
            try zipManager.unzip(archiveURL: sourceURL, destinationURL: extractDir)

            // 找到顶层 .app（兼容裸 .app 结构与极少数嵌套结构）
            guard let appURL = findAppBundle(in: extractDir) else {
                Logger.error("源 IPA 结构修复失败：未找到 .app 应用包")
                throw AppError.signFailed("应用包无法解析为可签名结构（未找到 .app 应用包）")
            }

            // 构造标准结构：workRoot/Payload/<App>.app
            let payloadDir = workRoot.appendingPathComponent("Payload", isDirectory: true)
            try disk.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            let targetApp = payloadDir.appendingPathComponent(appURL.lastPathComponent)
            try disk.moveItem(at: appURL, to: targetApp)

            // 清理残留解压文件（只保留 Payload/），再整体打包为标准 IPA。
            // 输出文件放在 workRoot 之外：zipItem 打包输入文件夹时若输出也在其中，
            // 会把自己当作待打包内容（异常/递归）。workRoot 与 outputURL 由调用方统一清理。
            try? disk.removeItem(at: extractDir)
            let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("normalized-\(UUID().uuidString).ipa")
            try zipManager.zip(folderURL: workRoot, outputURL: outputURL, shouldKeepParent: false)

            Logger.info("源 IPA 已规范化为标准结构（含 Payload/）: \(outputURL.path)")
            return (workRoot, outputURL)
        } catch let error as AppError {
            // AppError 已是面向用户的中文，直接透传
            throw error
        } catch {
            Logger.error("源 IPA 结构修复失败: \(error.localizedDescription)")
            throw AppError.signFailed("应用包无法解析为可签名结构（\(error.localizedDescription)）")
        }
    }

    /// 读 zip 条目判断顶层是否含 Payload/ 目录（只读中央目录，不解压实体，
    /// 对几百 MB 的 IPA 也足够快）。
    private func hasPayloadDirectory(in url: URL) -> Bool {
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            // 打不开按“未知结构”处理：交给 zsign 自身报错更准确
            return true
        }
        // Archive 由 deinit 自动关闭（与 ZipManager 一致，不调用 close()）
        for entry in archive {
            let path = entry.path
            if path == "Payload" || path.hasPrefix("Payload/") {
                return true
            }
            // 顶层第一条非 Payload 条目即可判定非标准（先到先得，避免全量遍历）
            if !path.isEmpty && !path.hasPrefix("Payload") {
                return false
            }
        }
        return false
    }

    /// 在解压目录中查找 .app 应用包（顶层优先，递归兜底）。
    private func findAppBundle(in rootURL: URL) -> URL? {
        // 顶层直接枚举（标准解压后 .app 应在 Payload/ 或根）
        if let items = try? disk.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for item in items {
                if item.pathExtension == "app" {
                    var isDir: ObjCBool = false
                    if disk.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        return item
                    }
                }
            }
        }
        // 递归兜底（zip 内嵌目录结构异常时）
        guard let enumerator = disk.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        while let element = enumerator.nextObject() as? URL {
            if element.pathExtension == "app",
               (try? element.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return element
            }
        }
        return nil
    }

    // MARK: - zsign 错误中文化

    /// 把 zsign 桥接层的英文错误映射为中文提示（中文优先）：
    /// 已知错误短语逐一映射；已是纯中文的桥接诊断原文透传；
    /// 其余含英文字符的底层错误包一层"签名内部错误："前缀。
    private static func localizedSignFailure(_ raw: String, code: Int32) -> String {
        if raw.isEmpty {
            return "签名失败 (错误码 \(code))"
        }
        if raw.contains("Can't find payload") {
            return "应用包结构异常（缺少 Payload 目录），已尝试自动修复但未成功，请删除后重新导入该应用"
        }
        if raw.contains("Input file") {
            return "源文件无法读取或不是有效的应用包"
        }
        if raw.contains("Failed to extract") {
            return "应用包解压失败"
        }
        if raw.contains("Failed to archive") {
            return "重新打包失败"
        }
        if raw.contains("Invalid temp folder") {
            return "临时目录不可用"
        }
        // 其余情况：含英文字符的底层错误加中文前缀；纯中文直接透传
        if raw.range(of: "[A-Za-z]", options: .regularExpression) != nil {
            return "签名内部错误：\(raw)"
        }
        return raw
    }
}

private final class ProgressBox {
    let handler: (Double) -> Void

    init(handler: @escaping (Double) -> Void) {
        self.handler = handler
    }
}

/// 签名进度平滑器：zsign 的真实进度只有 4~5 档（5/20/85/100），
/// 中间大段时间（尤其 85% 起的"重新打包"阶段）无任何回调。
/// 平滑器把真实进度作为"目标值"，用主线程定时器把展示值向目标逼近；
/// 目标停在 85% 时继续以极慢速率蠕动到 98%（给用户"仍在工作"的反馈），
/// 收到真实 100% 立即归正并停表。全部状态仅在主线程访问
/// （progressCallbackFunc 已 DispatchQueue.main.async），无数据竞争。
private final class ProgressSmoother {
    private let rawHandler: (Double) -> Void
    private var target: Double = 0
    private var displayed: Double = 0
    private var timer: Timer?

    init(rawHandler: @escaping (Double) -> Void) {
        self.rawHandler = rawHandler
    }

    /// 收到 zsign 真实进度（主线程调用）。只前进不回退；
    /// 90% 定为"重打包阶段"开始——大 IPA 在此停留最久。
    func receive(_ p: Double) {
        guard p >= target else { return }
        target = p
        displayed = max(displayed, p)
        if p >= 1.0 {
            stopSlither()
        } else if p >= 0.85 {
            startSlitherIfNeeded()
        }
        rawHandler(displayed)
    }

    /// 签名流程完成时的显式收尾：归正到 100% 并停止蠕动定时器。
    /// zsign 不保证回调 100%（可能 85% 后直接返回），调用方在成功后必须调用，
    /// 否则定时器空转（闭包引用 smoother 造成轻度泄漏 + UI 空转）。
    func complete() {
        stopSlither()
        target = 1.0
        displayed = 1.0
        rawHandler(1.0)
    }

    /// 85% 后启动蠕动定时器：每 0.5s 展示进度 +0.3%，最高逼近 98%。
    /// 收到真实 100%（receive(1.0)）即停表并归正。
    private func startSlitherIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.target < 1.0 else {
                self.stopSlither()
                return
            }
            if self.displayed < 0.98 {
                self.displayed = min(0.98, self.displayed + 0.003)
                self.rawHandler(self.displayed)
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopSlither() {
        timer?.invalidate()
        timer = nil
    }
}

private let progressCallbackFunc: ZSignProgressCallback = { (context, percent, message) in
    guard let context = context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        box.handler(Double(percent) / 100.0)
    }
    if let message = message {
        let text = String(cString: message)
        Logger.debug("zsign: \(text)")
    }
}