import Foundation
import Security

final class CertificateManager {
    static let shared = CertificateManager()

    private let keychainService = "com.ipamanager.app.certificates"
    private let keychainPasswordService = "com.ipamanager.app.certificates.password"

    func importCertificate(
        from url: URL,
        password: String,
        completion: @escaping (Result<CertificateInfo, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let certificate = try self.readCertificate(from: url, password: password)
                self.storePrivateKey(from: url, password: password, identifier: certificate.keychainIdentifier, passwordIdentifier: certificate.passwordKeychainIdentifier)
                completion(.success(certificate))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func exportP12(identifier: String, to url: URL) throws {
        guard let data = self.readP12Data(identifier: identifier) else {
            throw AppError.certificateInvalid("未找到私钥数据")
        }
        try data.write(to: url)
    }

    func readPassword(for certificate: CertificateInfo) -> String? {
        guard let passwordID = certificate.passwordKeychainIdentifier else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainPasswordService,
            kSecAttrAccount as String: passwordID,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func listCertificates() -> [CertificateInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let identifier = item[kSecAttrAccount as String] as? String else { return nil }
            var cert = CertificateInfo()
            cert.keychainIdentifier = identifier
            cert.name = identifier
            return cert
        }
    }

    func deleteCertificate(_ certificate: CertificateInfo) {
        guard let identifier = certificate.keychainIdentifier else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier
        ]
        SecItemDelete(query as CFDictionary)

        // 同时删除对应的密码条目
        if let passwordID = certificate.passwordKeychainIdentifier {
            let pwdQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainPasswordService,
                kSecAttrAccount as String: passwordID
            ]
            SecItemDelete(pwdQuery as CFDictionary)
        }
    }

    private func readCertificate(from url: URL, password: String) throws -> CertificateInfo {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 优先用 OpenSSL 解析（支持 PBES2/AES 等新式 P12）；失败再回退系统 SecPKCS12Import，
        // 保证 bundled 证书（密码 “1”）与用户自己的 P12 都能导入。
        if let info = try? readCertificateViaOpenSSL(from: url, password: password) {
            return info
        }

        return try readCertificateViaSecurityFramework(from: url, password: password)
    }

    private func readCertificateViaOpenSSL(from url: URL, password: String) throws -> CertificateInfo {
        var info = ZSignP12Info()

        let result = url.path.withCString { p12Path in
            password.withCString { pwd in
                zsign_p12_info(p12Path, pwd, &info)
            }
        }

        switch result {
        case 0:
            var certInfo = CertificateInfo()
            certInfo.name = Self.cString(from: info.name)
            certInfo.teamID = Self.cString(from: info.teamID)
            certInfo.commonName = Self.cString(from: info.commonName)
            certInfo.organization = Self.cString(from: info.organization)
            if info.startTime > 0 {
                certInfo.startDate = Date(timeIntervalSince1970: TimeInterval(info.startTime))
            }
            if info.endTime > 0 {
                certInfo.expireDate = Date(timeIntervalSince1970: TimeInterval(info.endTime))
            }
            certInfo.isPasswordProtected = !password.isEmpty
            certInfo.keychainIdentifier = UUID().uuidString
            if !password.isEmpty {
                certInfo.passwordKeychainIdentifier = UUID().uuidString
            }
            return certInfo
        case -2:
            throw AppError.certificateInvalid("密码错误或证书格式不支持 (OpenSSL)")
        default:
            let message = zsign_last_error().map { String(cString: $0) } ?? "证书读取失败 (错误码: \(result))"
            throw AppError.certificateInvalid(message)
        }
    }

    private func readCertificateViaSecurityFramework(from url: URL, password: String) throws -> CertificateInfo {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.certificateInvalid("无法读取 P12 文件")
        }

        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first else {
            if status == errSecAuthFailed {
                throw AppError.certificateInvalid("密码错误")
            }
            throw AppError.certificateInvalid("证书读取失败 (错误码: \(status))")
        }

        let certChain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []

        var info = CertificateInfo()
        info.name = first[kSecImportItemLabel as String] as? String ?? "P12 证书"
        info.isPasswordProtected = !password.isEmpty
        info.keychainIdentifier = UUID().uuidString
        if !password.isEmpty {
            info.passwordKeychainIdentifier = UUID().uuidString
        }

        if let cert = certChain.first {
            if let summary = SecCertificateCopySubjectSummary(cert) as String? {
                info.commonName = summary
                if info.name == "P12 证书" {
                    info.name = summary
                }
            }
            let (start, expire) = parseValidity(for: cert)
            info.startDate = start
            info.expireDate = expire
        }

        if !info.teamID.isEmpty {
            info.name = "\(info.name) (\(info.teamID))"
        }

        return info
    }

    private func parseValidity(for certificate: SecCertificate) -> (start: Date?, expire: Date?) {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1ValidityNotBefore as String, kSecOIDX509V1ValidityNotAfter as String] as CFArray,
            nil
        ) as? [CFString: Any] else {
            return (nil, nil)
        }
        let startDate = (values[kSecOIDX509V1ValidityNotBefore as CFString] as? [CFString: Any])?[kSecPropertyKeyValue as String] as? Date
        let endDate = (values[kSecOIDX509V1ValidityNotAfter as CFString] as? [CFString: Any])?[kSecPropertyKeyValue as String] as? Date
        return (startDate, endDate)
    }

    private static func cString<T>(from field: T) -> String {
        var value = field
        return withUnsafeBytes(of: &value) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }

    private func storePrivateKey(from url: URL, password: String, identifier: String?, passwordIdentifier: String?) {
        guard let identifier = identifier else { return }
        guard let data = try? Data(contentsOf: url) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)

        if let passwordIdentifier = passwordIdentifier, !password.isEmpty {
            let pwdData = Data(password.utf8)
            let pwdQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainPasswordService,
                kSecAttrAccount as String: passwordIdentifier,
                kSecValueData as String: pwdData,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            SecItemDelete(pwdQuery as CFDictionary)
            let pwdStatus = SecItemAdd(pwdQuery as CFDictionary, nil)
            Logger.info("密码存储状态: \(pwdStatus)")
        }

        Logger.info("私钥存储状态: \(status)")
    }

    private func readP12Data(identifier: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}