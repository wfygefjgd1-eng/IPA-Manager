import Foundation
import Security
import Network

final class ServerIdentityProvider {
    static let shared = ServerIdentityProvider()

    private(set) var currentIdentity: SecIdentity?

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

        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else {
            if status == errSecAuthFailed {
                throw AppError.certificateInvalid("密码错误")
            }
            throw AppError.installFailed("本地安装无法加载此证书，请重新导入证书后重试")
        }

        guard let rawIdentity = first[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw AppError.certificateInvalid("证书中未找到身份")
        }
        let identity = rawIdentity as! SecIdentity

        currentIdentity = identity
        exportToKeychainOnce(identity: identity)
        Logger.info("已设置本地服务器 TLS 身份")
    }

    func clear() {
        currentIdentity = nil
    }

    func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        guard let identity = currentIdentity else { return options }

        let secOptions = options.securityProtocolOptions
        IPMSetTLSIdentity(secOptions, identity)
        return options
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