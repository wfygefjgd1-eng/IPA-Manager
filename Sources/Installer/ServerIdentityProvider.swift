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
        // 改用 OpenSSL 直接导出证书/私钥 DER 构造 TLS 身份。
        let usedKeychainIdentity = try loadIdentityViaOpenSSL(p12URL: p12URL, password: password)
        if !usedKeychainIdentity {
            // OpenSSL 直连构造路径（身份存于 currentCertKey）；若上一轮残留了 Keychain 身份则清除。
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
    /// 返回 true 表示成功且身份来自 Keychain 兜底（currentIdentity 已设置）；
    /// 返回 false 表示成功且使用 SecKeyCreateWithData 直连构造（currentCertKey 已设置）。
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

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: isRSA != 0 ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil) else {
            // 私钥直连构造失败（iOS 对非同构的 PKCS#8 或其他格式可能挑剔）：
            // 先尝试 Keychain 兜底（证书+私钥配对成 SecIdentity），兜底也失败才抛错。
            Logger.error("SecKeyCreateWithData 失败 (isRSA=\(isRSA) keyLen=\(keyLen) keyFormat=\(formatDesc))，尝试 Keychain 导入兜底")
            if loadIdentityViaKeychain(cert: cert, keyData: keyData, isRSA: isRSA != 0) {
                return true
            }
            throw AppError.installFailed("无法加载证书私钥（系统拒绝该私钥格式）")
        }

        currentCertKey = (cert: cert, key: key)
        return false
    }

    /// Keychain 兜底：SecKeyCreateWithData 拒绝私钥 DER 时，把证书与私钥写入 Keychain 配对成 SecIdentity。
    /// 成功返回 true 并设置 currentIdentity；任何失败路径只记日志并清理本次条目，不抛错。
    private func loadIdentityViaKeychain(cert: SecCertificate, keyData: Data, isRSA: Bool) -> Bool {
        // 先清理上一次兜底产生的 Keychain 条目（避免多次安装累积）
        if let oldLabel = ServerIdentityProvider.lastFallbackLabel {
            removeKeychainIdentity(label: oldLabel)
            ServerIdentityProvider.lastFallbackLabel = nil
        }

        let label = "IPA Manager Server Identity \(UUID().uuidString)"

        // 1. 证书
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label
        ]
        let certStatus = SecItemAdd(certQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            Logger.error("Keychain 兜底失败：证书添加失败 (status=\(certStatus))")
            return false
        }

        // 2. 私钥（kSecValueData 要求 PKCS#8 DER；若实际为 PKCS#1/SEC1 系统可能拒绝，直接记日志并走失败路径）
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: isRSA ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            Logger.error("Keychain 兜底失败：私钥添加失败 (status=\(keyStatus), isRSA=\(isRSA), keyLen=\(keyData.count))")
            removeKeychainIdentity(label: label)
            return false
        }

        // 3. 按 label 取系统配对后的 SecIdentity（走原 tlsOptions 快路径）
        var identityRef: CFTypeRef?
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true
        ]
        let matchStatus = SecItemCopyMatching(matchQuery as CFDictionary, &identityRef)
        guard matchStatus == errSecSuccess, let ref = identityRef, CFGetTypeID(ref) == SecIdentityGetTypeID() else {
            Logger.error("Keychain 兜底失败：SecIdentity 配对失败 (status=\(matchStatus))")
            removeKeychainIdentity(label: label)
            return false
        }

        currentIdentity = (ref as! SecIdentity)
        currentCertKey = nil
        ServerIdentityProvider.lastFallbackLabel = label
        Logger.info("Keychain 兜底成功：已通过 SecIdentity 设置 TLS 身份")
        return true
    }

    /// 按 label 删除兜底写入的证书/私钥/身份条目（幂等，条目不存在视为成功）。
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