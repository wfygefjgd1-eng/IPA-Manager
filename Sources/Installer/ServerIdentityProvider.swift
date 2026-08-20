import Foundation
import Security
import Network

final class ServerIdentityProvider {
    static let shared = ServerIdentityProvider()

    private(set) var currentIdentity: SecIdentity?
    /// OpenSSL 回退路径构造的身份（证书 + 私钥），仅在 SecPKCS12Import 不支持新式 p12 时使用。
    private var currentCertKey: (cert: SecCertificate, key: SecKey)?
    /// 上一次 Keychain 兜底成功写入的条目 label；下次兜底前先清理，避免 Keychain 累积。
    private static var lastFallbackLabel: String?

    func setIdentity(from p12URL: URL, password: String) throws {
        // 先用 OpenSSL 解析做个无害的预检查（拿不到信息不阻塞，仅作日志）
        var info = ZSignP12Info()
        let parseResult = p12URL.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_info(p12Path, pwd, &info)
            }
        }
        if parseResult != 0 {
            Logger.warning("OpenSSL 解析 P12 失败(\(parseResult))，改用系统导入器")
        }

        guard let data = try? Data(contentsOf: p12URL) else {
            throw AppError.certificateInvalid("无法读取证书数据")
        }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        // 快路径：传统加密格式的 p12 交给系统导入器，保持原有逻辑不变
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        if status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first {
            guard let rawIdentity = first[kSecImportItemIdentity as String],
                  CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
                throw AppError.certificateInvalid("证书中未找到身份")
            }
            let identity = rawIdentity as! SecIdentity

            currentIdentity = identity
            currentCertKey = nil
            exportToKeychainOnce(identity: identity)
            Logger.info("已设置本地服务器 TLS 身份")
            return
        }

        // OpenSSL 3 的 PBES2/AES 新式 p12 系统导入器不支持（status != errSecSuccess），
        // 改用 OpenSSL 回退：三条子路径——SecKeyCreateWithData 直连 / Keychain 兜底
        // （成功都设置 currentCertKey）、传统加密 p12 重打包后 SecPKCS12Import
        // （成功设置 currentIdentity）。loadIdentityViaOpenSSL 返回 false 仅表示直连构造成功
        // （currentCertKey 已设置），此时清除可能残留的 identity；Keychain / 传统 p12 路径
        // 返回 true，内部已设置好各自的身份状态，不能在这里统一清掉。
        if !loadIdentityViaOpenSSL(p12URL: p12URL, password: password) {
            currentIdentity = nil
        }
        Logger.info("已通过 OpenSSL 设置本地服务器 TLS 身份")
    }

    func clear() {
        currentIdentity = nil
        currentCertKey = nil
    }

    func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        if let identity = currentIdentity {
            IPMSetTLSIdentity(secOptions, identity)
        } else if let certKey = currentCertKey {
            IPMSetTLSIdentityFromCertKey(secOptions, certKey.cert, certKey.key)
        }
        return options
    }

    /// OpenSSL 回退：从 p12 导出证书 DER + 私钥 DER，再交给 Security framework 构造 TLS 身份。
    /// 成功时 currentCertKey 或 currentIdentity 已设置（三条子路径：SecKeyCreateWithData 直连 /
    /// Keychain 兜底 / 传统加密 p12 重打包后走 SecPKCS12Import）。
    @discardableResult
    private func loadIdentityViaOpenSSL(p12URL: URL, password: String) throws -> Bool {
        Logger.info("开始 OpenSSL 导出证书/私钥 DER")

        var certDER: UnsafeMutablePointer<UInt8>?
        var certLen: Int32 = 0
        var keyDER: UnsafeMutablePointer<UInt8>?
        var keyLen: Int32 = 0
        var isRSA: Int32 = 0
        var keyFormat: Int32 = 0

        let result = p12URL.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_export_identity(p12Path, pwd, &certDER, &certLen, &keyDER, &keyLen, &isRSA, &keyFormat)
            }
        }

        // DER 缓冲由 C 侧 malloc 分配，拷贝进 Data 后必须释放，否则泄漏
        defer {
            if let p = certDER { free(p) }
            if let p = keyDER { free(p) }
        }

        guard result == 0 else {
            if result == -2 {
                Logger.error("OpenSSL 导出身份失败：密码错误")
                throw AppError.certificateInvalid("密码错误")
            }
            var detail = ""
            if let errPtr = zsign_last_error() {
                detail = String(cString: errPtr)
            }
            Logger.error("OpenSSL 导出身份失败(result=\(result)): \(detail)")
            throw AppError.installFailed("无法解析证书（格式不受支持），请重新导入证书后重试")
        }

        guard let certPtr = certDER, let keyPtr = keyDER, certLen > 0, keyLen > 0 else {
            Logger.error("OpenSSL 导出证书/私钥 DER 为空: certLen=\(certLen) keyLen=\(keyLen) keyFormat=\(keyFormat)")
            throw AppError.installFailed("无法加载证书私钥（导出为空）")
        }

        let certData = Data(bytes: certPtr, count: Int(certLen))
        let keyData = Data(bytes: keyPtr, count: Int(keyLen))

        let formatDesc: String
        switch keyFormat {
        case 1: formatDesc = "PKCS#8"
        case 2: formatDesc = "PKCS#1/SEC1"
        default: formatDesc = "未知(\(keyFormat))"
        }
        Logger.info("OpenSSL 导出成功: certLen=\(certLen) keyLen=\(keyLen) isRSA=\(isRSA) keyFormat=\(formatDesc)")

        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            Logger.error("SecCertificateCreateWithData 失败 (certLen=\(certLen))")
            throw AppError.installFailed("无法加载证书（创建失败）")
        }

        var keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: isRSA != 0 ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: "IPA Manager TLS Key \(UUID().uuidString)"
        ]
        // 关键修复：SecKeyCreateWithData 在多数 iOS 版本上要求显式给出 kSecAttrKeySizeInBits，
        // 否则对 RSA 私钥直接返回失败（"系统拒绝该私钥格式"的常见根因之一）。
        // 本机密钥为 RSA 2048（PKCS#8 DER 约 1218 字节，已按诊断日志验证）；EC 分支不设置该属性。
        var keySizeInBitsApplied = "未设置"
        if isRSA != 0 {
            keyAttributes[kSecAttrKeySizeInBits as String] = 2048
            keySizeInBitsApplied = "2048"
        }
        Logger.info("尝试 SecKeyCreateWithData 直连构造私钥 (isRSA=\(isRSA) keyLen=\(keyLen) keyFormat=\(formatDesc) keySizeInBits=\(keySizeInBitsApplied))")
        guard let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil) else {
            // 私钥直连构造失败（iOS 对非同构的 PKCS#8 或其他格式可能挑剔）：
            // 先尝试 Keychain 兜底（证书+私钥配对成 SecIdentity），兜底也失败则走最后一招：
            // 用 OpenSSL 把原 p12 重打包成"传统加密" p12（PBE-SHA1-3DES/RC2-40，iOS 原生支持），
            // 再交给 SecPKCS12Import 导入，得到真正配对的 SecIdentity。
            Logger.error("SecKeyCreateWithData 失败 (isRSA=\(isRSA) keyLen=\(keyLen) keyFormat=\(formatDesc) keySizeInBits=\(keySizeInBitsApplied))，尝试 Keychain 导入兜底")
            if loadIdentityViaKeychain(cert: cert, keyData: keyData, isRSA: isRSA != 0) {
                return true
            }
            if loadIdentityViaLegacyP12(p12URL: p12URL, password: password) {
                return true
            }
            // 各条兜底路径的 status 与阶段已在上方 Logger 记录；最终抛出的文案面向用户，
            // 完整诊断以诊断报告中的日志为准。
            Logger.error("SecKeyCreateWithData、Keychain 兜底与传统 p12 重打包均失败：无法加载私钥（详见上面各阶段 status 日志）")
            throw AppError.installFailed("无法加载证书私钥（系统拒绝该私钥格式，Keychain 兜底与传统 p12 重打包均失败，详见诊断日志）")
        }

        currentCertKey = (cert: cert, key: key)
        return false
    }

    /// Keychain 兜底：SecKeyCreateWithData 拒绝私钥 DER 时，把证书与私钥写入 Keychain 配对成 SecIdentity。
    /// 成功返回 true 并设置 currentIdentity；任何失败路径只记日志（每步带 status 与阶段）并清理本次条目，不抛错。
    private func loadIdentityViaKeychain(cert: SecCertificate, keyData: Data, isRSA: Bool) -> Bool {
        // 先清理上一次兜底产生的 Keychain 条目（避免多次安装累积）
        if let oldLabel = ServerIdentityProvider.lastFallbackLabel {
            removeKeychainIdentity(label: oldLabel)
            ServerIdentityProvider.lastFallbackLabel = nil
        }

        let label = "IPA Manager Server Identity \(UUID().uuidString)"

        // 1. 证书（带唯一 label，供后续与私钥同标签配对）
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label
        ]
        let certStatus = SecItemAdd(certQuery as CFDictionary, nil)
        Logger.info("Keychain 兜底：证书添加 (status=\(certStatus))")
        guard certStatus == errSecSuccess else {
            Logger.error("Keychain 证书添加失败 (status=\(certStatus))")
            return false
        }

        // 2. 私钥：与证书使用完全相同的 label；RSA 分支与直连构造一致补 kSecAttrKeySizeInBits。
        //    注意：个别 iOS 版本不允许把 kSecAttrAccessible 放到 key 条目上（-50 errSecParam），
        //    失败时去掉 kSecAttrAccessible 重试一次，仍失败才记日志。
        var keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: isRSA ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if isRSA {
            keyQuery[kSecAttrKeySizeInBits as String] = 2048
        }
        var keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
        Logger.info("Keychain 兜底：私钥添加 (status=\(keyStatus), isRSA=\(isRSA), keyLen=\(keyData.count), keySizeInBits=\(isRSA ? "2048" : "未设置"))")
        if keyStatus != errSecSuccess {
            Logger.warning("Keychain 私钥添加失败 (status=\(keyStatus))，去掉 kSecAttrAccessible 重试一次")
            keyQuery.removeValue(forKey: kSecAttrAccessible as String)
            keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
            Logger.info("Keychain 兜底：私钥添加重试（无 kSecAttrAccessible）(status=\(keyStatus))")
            guard keyStatus == errSecSuccess else {
                Logger.error("Keychain 私钥添加失败 (status=\(keyStatus), isRSA=\(isRSA), keyLen=\(keyData.count))")
                removeKeychainIdentity(label: label)
                return false
            }
        }

        // 3. 从 Keychain 按 label 读回刚写入的私钥 SecKey，与证书一起用
        //    sec_identity_create_with_certificates（iOS 15+，IPMSetTLSIdentityFromCertKey）
        //    直接构造 TLS 身份。这是关键修复：用原始 DER 添加的私钥在 Keychain 里
        //    不会自动与证书配对成 SecIdentity（kSecClassIdentity 查询返回 -25300），
        //    但证书 + 私钥直连构造不依赖配对，两条独立条目就能用。
        var keyRef: CFTypeRef?
        let readKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let readStatus = SecItemCopyMatching(readKeyQuery as CFDictionary, &keyRef)
        Logger.info("Keychain 兜底：读回私钥 SecKey (status=\(readStatus))")
        guard readStatus == errSecSuccess, let ref = keyRef,
              CFGetTypeID(ref) == SecKeyGetTypeID() else {
            Logger.error("Keychain 兜底：读回私钥失败 (status=\(readStatus))，已清理本次条目")
            removeKeychainIdentity(label: label)
            return false
        }
        let key = unsafeBitCast(ref, to: SecKey.self)

        // 直连构造路径（cert + key）：tlsOptions() 会走 IPMSetTLSIdentityFromCertKey。
        currentCertKey = (cert: cert, key: key)
        currentIdentity = nil
        ServerIdentityProvider.lastFallbackLabel = label
        Logger.info("Keychain 兜底成功：证书 + 私钥直连构造 TLS 身份（sec_identity_create_with_certificates）")
        return true
    }

    /// 最后一招：用 OpenSSL 把原 p12 中的证书+私钥重打包成"传统加密" p12
    /// （PBE-SHA1-3DES/RC2-40，iOS SecPKCS12Import 原生支持的格式），写临时文件后走与
    /// 快路径完全相同的 SecPKCS12Import 导入，得到的 SecIdentity 证书与私钥天然配对。
    /// 成功返回 true 并设置 currentIdentity；失败只记日志（含 zsign_last_error 与
    /// SecPKCS12Import status），不抛错；临时文件无论成败都由 defer 删除。
    private func loadIdentityViaLegacyP12(p12URL: URL, password: String) -> Bool {
        let legacyPath = NSTemporaryDirectory() + "legacy-\(UUID().uuidString).p12"
        var pathBuf = Array(legacyPath.utf8CString)

        // 目标文件路径由调用方填入 pathBuf，C 侧还会按 outPathLen 用 snprintf 回写
        // （保证缓冲区内以 \0 结尾、不越界）；defer 保证无论成败都删除临时文件。
        var outURL: URL?
        defer {
            if let url = outURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let result = p12URL.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_recreate_legacy(p12Path, pwd, &pathBuf, Int32(pathBuf.count))
            }
        }

        var cError = ""
        if let errPtr = zsign_last_error() {
            cError = String(cString: errPtr)
        }

        guard result == 0 else {
            Logger.error("传统 p12 重打包失败(result=\(result)): \(cError)")
            return false
        }

        let outPath = String(cString: pathBuf)
        guard FileManager.default.fileExists(atPath: outPath) else {
            Logger.error("传统 p12 文件不存在: \(outPath) (\(cError))")
            return false
        }
        outURL = URL(fileURLWithPath: outPath)

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)) else {
            Logger.error("传统 p12 读取失败: \(outPath) (\(cError))")
            return false
        }

        // 与 setIdentity 快路径完全一致的解析：SecPKCS12Import 成功即拿到真正配对的 SecIdentity
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else {
            Logger.error("传统 p12 SecPKCS12Import 失败(status=\(status)): \(cError)")
            return false
        }
        guard let rawIdentity = first[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            Logger.error("传统 p12 导入结果中未找到 SecIdentity 身份")
            return false
        }

        let identity = rawIdentity as! SecIdentity
        currentIdentity = identity
        currentCertKey = nil
        exportToKeychainOnce(identity: identity)
        Logger.info("传统 p12 重打包成功：SecPKCS12Import 导入得到 SecIdentity（证书与私钥天然配对）")
        return true
    }

    /// 按 label 删除兜底写入的证书/私钥条目（幂等，条目不存在视为成功）。
    private func removeKeychainIdentity(label: String) {
        for itemClass in [kSecClassCertificate, kSecClassKey, kSecClassIdentity] {
            let deleteQuery: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrLabel as String: label
            ]
            let status = SecItemDelete(deleteQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                Logger.warning("Keychain 兜底条目清理失败 (status=\(status))")
            }
        }
    }

    private func exportToKeychainOnce(identity: SecIdentity) {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let cert = certificate else { return }

        // 先删除同名旧条目，再添加，避免每次安装都往钥匙串累积
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "IPA Manager Server Cert"
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "IPA Manager Server Cert"
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
}