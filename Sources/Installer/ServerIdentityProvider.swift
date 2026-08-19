import Foundation
import Security
import Network

final class ServerIdentityProvider {
    static let shared = ServerIdentityProvider()

    private(set) var currentIdentity: SecIdentity?

    func setIdentity(from p12URL: URL, password: String) throws {
        var info = ZSignP12Info()
        let result = p12URL.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_info(p12Path, pwd, &info)
            }
        }

        switch result {
        case 0:
            break
        case -2:
            throw AppError.certificateInvalid("密码错误")
        default:
            throw AppError.certificateInvalid("证书解析失败")
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
            throw AppError.installFailed("此证书的加密格式(PBES2)无法用于本地安装，请更换 P12")
        }

        guard let rawIdentity = first[kSecImportItemIdentity as String],
              CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw AppError.certificateInvalid("证书中未找到身份")
        }
        let identity = rawIdentity as! SecIdentity

        currentIdentity = identity
        exportToKeychain(identity: identity)
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

    private func exportToKeychain(identity: SecIdentity) {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let cert = certificate else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "IPA Manager Server Cert"
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
}