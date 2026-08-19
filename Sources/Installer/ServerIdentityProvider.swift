import Foundation
import Security
import Network

final class ServerIdentityProvider {
    static let shared = ServerIdentityProvider()

    private(set) var currentIdentity: SecIdentity?
    /// OpenSSL 回退路径构造的身份（证书 + 私钥），仅在 SecPKCS12Import 不支持新式 p12 时使用。
    private var currentCertKey: (cert: SecCertificate, key: SecKey)?

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
        try loadIdentityViaOpenSSL(p12URL: p12URL, password: password)
        currentIdentity = nil
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
    private func loadIdentityViaOpenSSL(p12URL: URL, password: String) throws {
        var certDER: UnsafeMutablePointer<UInt8>?
        var certLen: Int32 = 0
        var keyDER: UnsafeMutablePointer<UInt8>?
        var keyLen: Int32 = 0
        var isRSA: Int32 = 0

        let result = p12URL.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_export_identity(p12Path, pwd, &certDER, &certLen, &keyDER, &keyLen, &isRSA)
            }
        }

        // DER 缓冲由 C 侧 malloc 分配，拷贝进 Data 后必须释放，否则泄漏
        defer {
            if let p = certDER { free(p) }
            if let p = keyDER { free(p) }
        }

        guard result == 0 else {
            if result == -2 {
                throw AppError.certificateInvalid("密码错误")
            }
            throw AppError.installFailed("无法解析证书（格式不受支持），请重新导入证书后重试")
        }

        guard let certPtr = certDER, let keyPtr = keyDER, certLen > 0, keyLen > 0 else {
            throw AppError.installFailed("无法加载证书私钥")
        }

        let certData = Data(bytes: certPtr, count: Int(certLen))
        let keyData = Data(bytes: keyPtr, count: Int(keyLen))

        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw AppError.installFailed("无法加载证书私钥")
        }

        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: isRSA != 0 ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil) else {
            throw AppError.installFailed("无法加载证书私钥")
        }

        currentCertKey = (cert: cert, key: key)
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