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
        // 保证用户导入的各类 P12 都能识别。
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
        // iOS 无 SecCertificateCopyValues（macOS only），改为从证书 DER 中解析有效期
        let data = SecCertificateCopyData(certificate) as Data
        return Self.parseValidity(fromDER: data)
    }

    /// 最小 DER 解析：从 X.509 证书中提取 notBefore / notAfter（UTCTime / GeneralizedTime）
    private static func parseValidity(fromDER data: Data) -> (start: Date?, expire: Date?) {
        // 顶层必须是 SEQUENCE
        var offset = 0
        guard let top = readDERElement(data, at: &offset),
              top.tag == 0x30 else {
            return (nil, nil)
        }
        let topContent = top.content

        var inner = 0
        // [0] version（可选）
        if inner < topContent.count, topContent[topContent.startIndex + inner] == 0xA0 {
            _ = readDERElement(topContent, at: &inner)
        }
        // INTEGER serial
        guard readDERElement(topContent, at: &inner) != nil else { return (nil, nil) }
        // SEQUENCE signature algorithm
        guard readDERElement(topContent, at: &inner) != nil else { return (nil, nil) }
        // SEQUENCE issuer
        guard readDERElement(topContent, at: &inner) != nil else { return (nil, nil) }
        // SEQUENCE validity
        guard let validity = readDERElement(topContent, at: &inner) else { return (nil, nil) }

        var v = 0
        guard let notBefore = readDERElement(validity.content, at: &v),
              let notAfter = readDERElement(validity.content, at: &v) else {
            return (nil, nil)
        }
        return (Self.parseASN1Time(notBefore.content, tag: notBefore.tag),
                Self.parseASN1Time(notAfter.content, tag: notAfter.tag))
    }

    /// 读取一个 DER TLV 元素，offset 前进到下一个元素
    private static func readDERElement(_ data: Data, at offset: inout Int) -> (tag: UInt8, content: Data)? {
        guard offset < data.count else { return nil }
        let tag = data[data.startIndex + offset]
        offset += 1
        guard offset < data.count else { return nil }

        var length = Int(data[data.startIndex + offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= data.count else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(data[data.startIndex + offset])
                offset += 1
            }
            length = value
        }
        guard offset + length <= data.count else { return nil }
        let content = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
        offset += length
        return (tag, content)
    }

    /// 解析 ASN.1 时间：UTCTime(0x17) "YYMMDDHHMMSSZ" / GeneralizedTime(0x18) "YYYYMMDDHHMMSSZ"
    private static func parseASN1Time(_ bytes: Data, tag: UInt8) -> Date? {
        guard tag == 0x17 || tag == 0x18 else { return nil }
        guard let text = String(data: bytes, encoding: .ascii) else { return nil }
        let s = text.trimmingCharacters(in: .whitespaces)
        guard s.last == "Z" else { return nil }
        let digits = s.dropLast()

        let year: Int
        let rest: Substring
        if tag == 0x17, digits.count == 12 { // UTCTime
            let yy = Int(digits.prefix(2)) ?? 0
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            rest = digits.dropFirst(2)
        } else if tag == 0x18, digits.count == 14 { // GeneralizedTime
            year = Int(digits.prefix(4)) ?? 0
            rest = digits.dropFirst(4)
        } else {
            return nil
        }

        // rest 是 10 位数字 MMDDHHMMSS，必须两位一组解析（逐字符会导致 month=0 等错误）
        var values = [Int]()
        var idx = rest.startIndex
        while idx < rest.endIndex {
            let next = rest.index(idx, offsetBy: 2)
            guard next <= rest.endIndex, let v = Int(rest[idx..<next]) else { return nil }
            values.append(v)
            idx = next
        }
        guard values.count == 5 else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = values[0]
        components.day = values[1]
        components.hour = values[2]
        components.minute = values[3]
        components.second = values[4]
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
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