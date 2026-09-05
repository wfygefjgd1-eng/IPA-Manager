import Foundation
import Security
import ZIPFoundation

protocol SigningEngineProtocol {
    func sign(
        sourcePath: String,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double, String) -> Void
    ) throws -> String
}

final class SigningEngine: SigningEngineProtocol {
    static let shared = SigningEngine()

    /// 全局 zsign 串行队列：zsign 桥接层并发不安全，自动签名（AppState 的
    /// 串行队列）只串行化了自动路径，手动签名与证书导入的 p12 解析
    /// （zsign_p12_info）此前走并发 global 队列，可与自动签名的 zsign 任务
    /// 并发执行 → 崩溃/产物损坏。所有桥接入口（zsign_sign / zsign_p12_info）
    /// 统一在此队列执行，进程级互斥。
    static let zsignQueue = DispatchQueue(label: "com.ipamanager.zsign", qos: .userInitiated)

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
        progress: @escaping (Double, String) -> Void
    ) throws -> String {
        progress(0.0, "开始准备…")

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

        // 证书凭据检查（Keychain 标识 / 密码读取 / p12 与 PEM 导出）全部前移到
        // 结构规范化之前：规范化是大 IO（整包解压 + 重打包，大 IPA 数十秒），
        // 证书不可用时先做完规范化纯属白费（fail-fast）。
        guard let keychainID = certificate.keychainIdentifier else {
            let reason = "证书缺少 Keychain 标识"
            Logger.error("签名失败: \(reason)")
            throw AppError.signFailed(reason)
        }

        // Keychain 密码读取失败与"无密码"不可区分的问题：受密码保护的证书读不到
        // 密码时（典型：设备锁定，WhenUnlockedThisDeviceOnly 条目锁屏不可读），
        // 旧实现用空密码静默继续，最终报 zsign 的"证书或私钥文件无效"，误导排障。
        let certPassword: String
        if certificate.isPasswordProtected {
            guard let stored = certManager.readPassword(for: certificate) else {
                let reason = "无法读取证书密码（设备可能已锁定），请解锁设备后重试"
                Logger.error("签名失败: \(reason)")
                throw AppError.signFailed(reason)
            }
            certPassword = stored
        } else {
            certPassword = ""
        }

        let p12URL = try exportP12(identifier: keychainID)
        defer {
            try? fileManager.deleteItem(at: p12URL)
        }

        // 首选：把 p12 里的私钥导出为 PEM 私钥文件（绕开 iOS 静态 OpenSSL 对
        // PBES2/AES p12 的 PKCS12_parse 失败问题）；返回 nil（EC 曲线不支持/
        // 系统解析失败）则回退直接用 p12 文件。zsign 的 ZSignAsset::Init 在 certPath
        // 为空时会自动从描述文件的 DeveloperCertificates 里找与私钥配对的证书。
        // 注意：这里必须传播 throw——exportPrivateKeyPEM 只对"确定性失败"抛错
        // （密码不正确：系统解不开，OpenSSL 用同一个密码同样解不开，早失败并
        // 给出精确中文诊断，而不是落到 zsign 的泛化错误）；其余失败在函数内部
        // 记日志后返回 nil 走回退（系统不支持的旧式加密 p12，OpenSSL 反而可能解析）。
        let keyFileURL = try exportPrivateKeyPEM(from: p12URL, password: certPassword)
        defer {
            if let keyFileURL = keyFileURL {
                try? fileManager.deleteItem(at: keyFileURL)
            }
        }
        let keyPath = (keyFileURL ?? p12URL).path

        // 源 IPA 结构规范化：标准 IPA 顶层必须是 Payload/<App>.app/。
        // 历史 CI 产物（ditto --keepParent 会把 .app 直接放压缩包根）和某些
        // 第三方来源的包不符合该结构，zsign 解压后报 "Can't find payload directory"。
        // 这里在签名前自动校验并修复：非标准结构解压 → 找 .app → 重打包为
        // Payload/ 标准结构再交给 zsign，任何来源的 IPA 都能签。
        // 注意：规范化失败（非标准结构且修复失败）不再静默回退到原路径签名
        // （那样会直接撞上 zsign 的英文报错），而是抛出中文错误直接终止签名；
        // nil 返回值只表示"已是标准结构"（含 Payload/），直接使用源文件。
        progress(0.02, "校验应用包结构…")
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
        progress(0.05, "准备证书与描述文件…")

        let outputURL = fileManager.directoryURL(.signed)
            .appendingPathComponent("\(URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent)-signed-\(UUID().uuidString.prefix(8)).ipa")

        // Bridge progress callback: pass a non-capturing C closure + context.
        // 进度平滑：zsign 只回调 5/20/85/100 四档，85% 之后是"重新打包"阶段
        // （Zip::Archive 压缩无进度回调），大 IPA 会长时间停在 85% 让用户误以为卡死。
        // 平滑器把真实进度作为目标值，用主线程定时器让展示进度在 85% 后缓慢蠕动
        // 逼近 98%（"仍在工作"的反馈），收到真实 100% 立即归正并停止。
        let smoother = ProgressSmoother(rawHandler: progress)
        let box = ProgressBox(handler: { p, phase in smoother.receive(p, phase: phase) })
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
            // 失败也要停蠕动定时器：85% 后失败是大 IPA 最常见的失败点（重新打包
            // 阶段），无人调用 complete/abort 会在主队列留下每 0.5s 空转一次、
            // 永不释放的定时器源（每次这类失败累积一个）。
            smoother.abort()

            let rawMessage = CertificateManager.safeZSignError(limit: 512)
            let userMessage = Self.localizedSignFailure(rawMessage, code: result)
            Logger.error("签名失败: \(sourcePath) - \(rawMessage)")
            throw AppError.signFailed(userMessage)
        }

        progress(1.0, "签名完成")
        // 显式收尾：zsign 可能只回调到 85% 就完成（不保证回调 100%），
        // 若不主动告知，smoother 的蠕动定时器会继续空转（泄漏 + UI 空转）。
        smoother.complete()
        Logger.info("签名完成: \(outputURL.path)")
        // 签名产物级校验（以最终 IPA 为准）：每个 PlugIns/*.appex 必须嵌入
        // embedded.mobileprovision——iOS 17+ 拒绝加载无描述文件的扩展（分享入口
        // 点了毫无反应的直接原因）。只读 zip 中央目录，毫秒级，不解压整包。
        Self.verifyAppexProvisioning(in: outputURL)
        return outputURL.path
    }

    /// 校验签名产物内每个顶层扩展都嵌入了描述文件；缺失说明签名引擎未带
    /// "扩展 profile 回退写入"修复（旧版 zsign 只给主 App 写 profile），
    /// 在日志与失败专区留下可操作记录而不是产出静默不可用的包。
    private static func verifyAppexProvisioning(in ipaURL: URL) {
        guard let entries = try? ZipManager.shared.listEntryPaths(archiveURL: ipaURL) else {
            Logger.warning("签名产物校验：无法读取 IPA 中央目录，跳过扩展描述文件检查")
            return
        }
        // 从任意条目推导扩展目录（zip 可能不含显式目录条目）：
        // "Payload/App.app/PlugIns/X.appex/Info.plist" → "Payload/App.app/PlugIns/X.appex/"
        var appexDirs = Set<String>()
        for path in entries {
            guard let range = path.range(of: ".appex/") else { continue }
            let dir = String(path[...range.upperBound])
            if dir.contains("/PlugIns/") {
                appexDirs.insert(dir)
            }
        }
        guard !appexDirs.isEmpty else {
            Logger.warning("签名产物校验：IPA 内未发现 PlugIns/*.appex（签名工具可能剥离了扩展，分享入口将不存在）")
            return
        }
        let entrySet = Set(entries)
        let missing = appexDirs.sorted().filter { !entrySet.contains($0 + "embedded.mobileprovision") }
        if missing.isEmpty {
            let note = "签名产物校验通过: \(appexDirs.count) 个扩展全部嵌入 embedded.mobileprovision"
            Logger.info(note)
            // 持久化到投递日志（Logger 的 INFO 是进程内存态，重装后即丢；
            // 校验结论必须跨启动可查，才能确认"扩展描述文件"修复在真机上生效）
            ExternalDeliveryJournal.record(note, level: .ok)
        } else {
            let names = missing.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: "、")
            let note = "签名产物校验: \(missing.count)/\(appexDirs.count) 个扩展缺少 embedded.mobileprovision（iOS 17+ 将拒绝加载该扩展）: \(names)"
            Logger.error(note)
            ExternalDeliveryJournal.record(note, level: .error)
        }
    }

    /// 用系统 Security 框架（SecPKCS12Import）解开 p12 并把私钥导出为 PEM 文件。
    /// iOS 静态 OpenSSL 对 PBES2/AES p12 的 PKCS12_parse 可能失败，而系统实现可靠。
    /// - Returns: PEM 文件 URL；nil 表示该私钥类型无法安全导出为合法 PEM
    ///   （未知曲线/未知 keyType），调用方应回退直接用 p12 文件。
    ///   绝不产出"头尾对但内容非法"的 PEM——旧实现把 EC 的 X9.63 原始字节
    ///   直接包上 SEC1 头尾，OpenSSL 解析必败，ECC 证书签名必然失败。
    private func exportPrivateKeyPEM(from p12URL: URL, password: String) throws -> URL? {
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
            if status == errSecAuthFailed {
                // 密码不正确是确定性失败：zsign 的 OpenSSL 用同一个密码同样解不开，
                // 早失败并给出精确诊断，而不是落到 zsign 的泛化错误让用户无从排查
                //（Keychain 中存的密码与 p12 实际密码不符，例如证书密码被重置过）。
                let reason = "证书密码不正确，无法解密证书（系统错误码 \(status)），请删除该证书后重新导入"
                Logger.error("导出 PEM 私钥失败: \(reason)")
                throw AppError.signFailed(reason)
            }
            // 其余解析失败（旧式 RC2/3DES 加密的 p12 系统不支持等）：记下具体状态码
            // 后回退 zsign/OpenSSL 直接解析 p12——那条路径反而可能成功
            Logger.warning("系统解析 p12 失败(错误码 \(status))，回退 OpenSSL 直接解析 p12")
            return nil
        }
        // SecIdentity 是 CoreFoundation 类型，不能对 CF 类型做条件转换（编译器报错
        // “conditional downcast to CoreFoundation type will always succeed”），
        // 与 ServerIdentityProvider 一致：CFGetTypeID 校验类型后用强制转换，
        // 类型不符时抛中文错误而非崩溃。
        guard CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            // 结构异常但 p12 文件本身在磁盘上：回退 OpenSSL 路径仍有机会解析
            Logger.warning("系统解析 p12 得到异常身份类型，回退 OpenSSL 直接解析 p12")
            return nil
        }
        let identity = rawIdentity as! SecIdentity

        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            // 典型场景：设备锁定时受保护私钥不可用（errSecInteractionNotAllowed）。
            // OpenSSL 直接读 p12 文件不经过 Keychain，回退后仍可完成签名。
            Logger.warning("系统导出私钥失败(错误码 \(keyStatus))，回退 OpenSSL 直接解析 p12")
            return nil
        }

        guard let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            // 私钥不可导出（安全策略限制）：p12 文件本身仍可由 OpenSSL 解析，回退
            Logger.warning("系统无法导出私钥数据，回退 OpenSSL 直接解析 p12")
            return nil
        }

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
            // SecKeyCopyExternalRepresentation 对 EC 返回 ANSI X9.63 原始字节
            // （04 || X || Y || privateScalar），不是任何 PEM 结构的载荷；
            // 必须重组为 PKCS#8（PrivateKeyInfo）DER 才能用 "BEGIN PRIVATE KEY"。
            guard let pkcs8 = Self.pkcs8DER(fromECRaw: keyData) else {
                Logger.warning("EC 私钥无法重组为 PKCS#8（曲线不支持或数据异常），回退 p12 路径")
                return nil
            }
            let url = try Self.writePEMFile(
                der: pkcs8,
                header: "-----BEGIN PRIVATE KEY-----",
                footer: "-----END PRIVATE KEY-----"
            )
            Logger.info("已导出 PEM 私钥: ECC (PKCS#8)")
            return url
        }
        if isRSA {
            // RSA 的 SecKeyCopyExternalRepresentation 就是 PKCS#1 DER，
            // 与 "BEGIN RSA PRIVATE KEY" 头直接匹配
            let url = try Self.writePEMFile(
                der: keyData,
                header: "-----BEGIN RSA PRIVATE KEY-----",
                footer: "-----END RSA PRIVATE KEY-----"
            )
            Logger.info("已导出 PEM 私钥: RSA (PKCS#1)")
            return url
        }
        // 其它/未知 keyType：外部表示与任何标准 PEM 结构都不对应，
        // 直接回退 p12 路径（zsign 的 OpenSSL 能解析 p12 时自行处理）
        Logger.info("私钥类型未知，跳过 PEM 导出，回退 p12 路径")
        return nil
    }

    /// 把 SecKeyCopyExternalRepresentation 的 EC 私钥原始数据（ANSI X9.63：
    /// 未压缩点 0x04 || X || Y || privateScalar，三段等长）重组为 PKCS#8
    /// PrivateKeyInfo DER。OpenSSL 的 PEM_read_bio_PrivateKey 可直接解析。
    private static func pkcs8DER(fromECRaw keyData: Data) -> Data? {
        // 常用曲线的 OID 内容字节（DER 编码去掉 tag/length 后的部分）
        func curveOIDContent(coordinateBytes: Int) -> [UInt8]? {
            switch coordinateBytes {
            case 32: return [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] // P-256: 1.2.840.10045.3.1.7
            case 48: return [0x2B, 0x81, 0x04, 0x00, 0x22]                   // P-384: 1.3.132.0.34
            case 66: return [0x2B, 0x81, 0x04, 0x00, 0x23]                   // P-521: 1.3.132.0.35
            default: return nil
            }
        }
        // X9.63 = 未压缩点标志(0x04) + X(n) + Y(n) + 私钥标量(n)
        guard keyData.count > 2, keyData[keyData.startIndex] == 0x04 else { return nil }
        let n = (keyData.count - 1) / 3
        guard n > 0, keyData.count == 1 + 3 * n,
              let curveOID = curveOIDContent(coordinateBytes: n) else { return nil }
        let scalar = keyData.suffix(n)

        func derLength(_ length: Int) -> Data {
            if length < 0x80 { return Data([UInt8(length)]) }
            var bytes: [UInt8] = []
            var value = length
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return Data([UInt8(0x80 | bytes.count)] + bytes)
        }
        func tlv(_ tag: UInt8, _ content: Data) -> Data {
            Data([tag]) + derLength(content.count) + content
        }
        func oid(_ content: [UInt8]) -> Data {
            tlv(0x06, Data(content))
        }

        // SEC1 ECPrivateKey: SEQUENCE { INTEGER 1, OCTET STRING scalar, [0] 曲线 OID }
        let sec1 = tlv(0x30,
                       tlv(0x02, Data([0x01]))
                        + tlv(0x04, Data(scalar))
                        + tlv(0xA0, oid(curveOID)))
        // AlgorithmIdentifier: SEQUENCE { OID id-ecPublicKey(1.2.840.10045.2.1), OID curve }
        let algorithm = tlv(0x30, oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]) + oid(curveOID))
        // PrivateKeyInfo: SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING sec1 }
        return tlv(0x30, tlv(0x02, Data([0x01])) + algorithm + tlv(0x04, sec1))
    }

    /// DER → base64 分行（64 字符/行）→ 包 PEM 头尾写盘（0600 权限）。
    private static func writePEMFile(der: Data, header: String, footer: String) throws -> URL {
        let base64 = der.base64EncodedString()
        var pem = header + "\n"
        var index = 0
        let step = 64
        while index < base64.count {
            let end = min(index + step, base64.count)
            pem += base64[base64.index(base64.startIndex, offsetBy: index)..<base64.index(base64.startIndex, offsetBy: end)] + "\n"
            index = end
        }
        pem += footer + "\n"

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
            Logger.error("导出 PEM 私钥失败: 无法写入 PEM 私钥文件 (\(error.localizedDescription))")
            throw AppError.signFailed("无法写入 PEM 私钥文件 (\(error.localizedDescription))")
        }
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

        // 失败清理：调用方的 defer 只清"成功返回后"才赋值的变量——本函数内任何
        // throw 路径（解压失败 / 找不到 .app / 换位失败 / 打包失败）都必须自行
        // 清理 workRoot（整包解压副本，可达数百 MB）与部分写成的半成品 outputURL
        //（tmp 目录无孤儿清扫，重试签名会持续累积）
        var success = false
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("normalized-\(UUID().uuidString).ipa")
        defer {
            if !success {
                try? disk.removeItem(at: workRoot)
                try? disk.removeItem(at: outputURL)
            }
        }

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
            try zipManager.zip(folderURL: workRoot, outputURL: outputURL)

            // 成功：workRoot 与 outputURL 移交调用方（签名结束后统一删除）
            success = true
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
        // 必须完整遍历中央目录再下结论：旧实现"遇到第一个非 Payload 条目即判非
        // 标准"依赖条目顺序——重签名流水线 / macOS 打包常把 __MACOSX/、META-INF/
        // 等排在 Payload 之前，标准 IPA 被误判为缺 Payload → 走整套"解压 + 找
        // .app + 重打包"规范化，大 IPA 白白多花数十秒与一倍临时磁盘。
        var hasPayload = false
        for entry in archive {
            let path = entry.path
            if path == "Payload" || path.hasPrefix("Payload/") {
                hasPayload = true
                break
            }
        }
        return hasPayload
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
        // 其余情况：含英文字母且不含汉字的底层错误加中文前缀；纯中文直接透传
        if raw.range(of: "[a-zA-Z]", options: .regularExpression) != nil
            && raw.range(of: #"[\u{4E00}-\u{9FFF}]"#, options: .regularExpression) == nil {
            return "签名内部错误：\(raw)"
        }
        return raw
    }
}

private final class ProgressBox {
    let handler: (Double, String) -> Void

    init(handler: @escaping (Double, String) -> Void) {
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
    private let rawHandler: (Double, String) -> Void
    private var target: Double = 0
    private var displayed: Double = 0
    /// 当前阶段文字：随真实回调更新，蠕动期间沿用（如"正在重新打包"）。
    private var currentPhase: String = "签名中…"
    /// 替换 Timer 为 DispatchSourceTimer：Timer 依赖 RunLoop，App 退后台 RunLoop 暂停
    /// 时蠕动卡死（85% 后停在 85% 不动），DispatchSourceTimer 走内核 timer，App
    /// 退后台继续触发（itms-services 安装期间 App 必然退后台，蠕动必须保持）。
    private var timer: DispatchSourceTimer?

    init(rawHandler: @escaping (Double, String) -> Void) {
        self.rawHandler = rawHandler
    }

    /// 收到 zsign 真实进度与阶段文字（主线程调用）。只前进不回退；
    /// 85% 定为"重打包阶段"开始——大 IPA 在此停留最久。
    func receive(_ p: Double, phase: String) {
        guard p >= target else { return }
        target = p
        displayed = max(displayed, p)
        if !phase.isEmpty { currentPhase = phase }
        if p >= 1.0 {
            stopSlither()
        } else if p >= 0.85 {
            startSlitherIfNeeded()
        }
        rawHandler(displayed, currentPhase)
    }

    /// 签名流程完成时的显式收尾：归正到 100% 并停止蠕动定时器。
    /// zsign 不保证回调 100%（可能 85% 后直接返回），调用方在成功后必须调用，
    /// 否则定时器空转（闭包引用 smoother 造成轻度泄漏 + UI 空转）。
    /// 注意：sign() 在后台线程被调用（AppState 把签名派发到全局队列），而
    /// receive/蠕动定时器事件都在主线程执行——complete() 也必须切回主线程，
    /// 旧版在调用线程直接写 target/displayed/timer，与主线程定时器并发读写
    /// 属数据竞争。强捕获 self：sign() 返回后由本闭包延续生命周期直到执行完毕。
    func complete() {
        DispatchQueue.main.async { [self] in
            stopSlither()
            target = 1.0
            displayed = 1.0
            currentPhase = "签名完成"
            rawHandler(1.0, currentPhase)
        }
    }

    /// 签名失败时的收尾：只停蠕动定时器，不改进度/阶段（失败态由调用方以
    /// alert 展示具体错误）。与 complete() 的区别：不把进度归正到 100%。
    func abort() {
        DispatchQueue.main.async { [self] in
            stopSlither()
        }
    }

    /// 85% 后启动蠕动定时器：每 0.5s 展示进度 +0.3%，最高逼近 98%。
    /// 收到真实 100%（receive(1.0)）即停表并归正。
    private func startSlitherIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.target < 1.0 else {
                self.stopSlither()
                return
            }
            if self.displayed < 0.98 {
                self.displayed = min(0.98, self.displayed + 0.003)
                self.rawHandler(self.displayed, self.currentPhase)
            }
        }
        timer = t
        t.resume()
    }

    private func stopSlither() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        // 双保险：libdispatch 要求 resume 过的 source 必须 cancel 才能释放，
        // 漏停的蠕动定时器（异常路径）在析构时兜底取消
        timer?.cancel()
    }
}

private let progressCallbackFunc: ZSignProgressCallback = { (context, percent, message) in
    guard let context = context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    let phase = message.map { String(cString: $0) } ?? "签名中…"
    DispatchQueue.main.async {
        box.handler(Double(percent) / 100.0, phase)
    }
}