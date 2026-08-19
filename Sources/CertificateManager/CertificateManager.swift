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
    }

    private func readCertificate(from url: URL, password: String) throws -> CertificateInfo {
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
            }
            let (start, expire) = parseValidity(for: cert)
            info.startDate = start
            info.expireDate = expire
            info = parseCertificateDetails(cert, into: info)
        }

        if !info.teamID.isEmpty {
            info.name = "\(info.name) (\(info.teamID))"
        }

        return info
    }

    private func parseValidity(for certificate: SecCertificate) -> (start: Date?, expire: Date?) {
        let data = SecCertificateCopyData(certificate) as Data
        return Self.parseCertificateValidityDER(data)
    }

    private static func parseCertificateValidityDER(_ data: Data) -> (start: Date?, expire: Date?) {
        var parser = DERParser(data: data)
        guard let tbs = parser.readSequence() else { return (nil, nil) }
        let tbsParser = DERParser(data: tbs)

        var inner = tbsParser
        if inner.peekTag() == 0xA0 { _ = inner.readElement() }

        guard let serial = inner.readElement() else { return (nil, nil) }
        guard serial.first == 0x02 else { return (nil, nil) }

        guard let sig = inner.readElement() else { return (nil, nil) }
        guard let issuer = inner.readElement() else { return (nil, nil) }

        guard let validity = inner.readElement(),
              validity.first == 0x30 else { return (nil, nil) }

        let validityPayload = Array(validity.dropFirst(2))
        guard let notBefore = parseDERTime(validityPayload) else { return (nil, nil) }
        let notAfterPayload = skipDERElement(validityPayload)
        guard let notAfter = parseDERTime(notAfterPayload) else { return (nil, nil) }

        return (notBefore, notAfter)
    }

    private static func parseDERTime(_ data: [UInt8]) -> Date? {
        guard !data.isEmpty else { return nil }
        let tag = data[0]
        guard tag == 0x17 || tag == 0x18 else { return nil }
        guard data.count >= 2 else { return nil }
        let length = Int(data[1])
        guard data.count >= 2 + length else { return nil }
        guard let timeString = String(bytes: data[2..<(2 + length)], encoding: .ascii) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if tag == 0x17 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: timeString)
        } else {
            guard timeString.hasSuffix("Z") else { return nil }
            let base = String(timeString.dropLast())
            if base.contains(".") {
                formatter.dateFormat = "yyyyMMddHHmmss.SSS"
            } else {
                formatter.dateFormat = "yyyyMMddHHmmss"
            }
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: base)
        }
    }

    private static func skipDERElement(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        let tag = data[0]
        _ = tag
        guard data.count >= 2 else { return [] }
        let lengthByte = data[1]
        if lengthByte < 0x80 {
            let total = 2 + Int(lengthByte)
            guard data.count >= total else { return [] }
            return Array(data[total...])
        } else {
            let numBytes = Int(lengthByte & 0x7F)
            guard data.count >= 2 + numBytes else { return [] }
            var length: Int = 0
            for i in 0..<numBytes {
                length = (length << 8) | Int(data[2 + i])
            }
            let total = 2 + numBytes + length
            guard data.count >= total else { return [] }
            return Array(data[total...])
        }
    }

    private func parseCertificateDetails(_ certificate: SecCertificate, into info: CertificateInfo) -> CertificateInfo {
        var updated = info

        // iOS-safe subject parsing: extract CN and O from the localized subject summary
        if let summary = SecCertificateCopySubjectSummary(certificate) as String? {
            if updated.commonName.isEmpty {
                updated.commonName = summary
            }
            updated = extractSubjectInfo(from: summary, into: updated)
        }

        return updated
    }

    private func extractSubjectInfo(from summary: String, into info: CertificateInfo) -> CertificateInfo {
        var updated = info

        // Summary like "Apple Distribution: Company Name (TEAMID)" or "/CN=.../O=..."
        if updated.commonName.isEmpty {
            updated.commonName = summary
        }

        // Team ID: 10-char uppercase alphanumeric inside parentheses
        if let teamRange = summary.range(of: #"\(\s*([A-Z0-9]{10})\s*\)"#, options: .regularExpression) {
            let candidate = summary[teamRange]
            let digits = candidate.filter { $0.isNumber || $0.isUppercase }
            updated.teamID = String(digits)
        }

        // Organization: text after "Company:" or between "O=" markers
        if let orgMarker = summary.range(of: "Company:") {
            let orgStart = summary.index(orgMarker.upperBound, offsetBy: 1)
            if let orgEnd = summary[orgStart...].firstIndex(of: "(") {
                updated.organization = String(summary[orgStart..<orgEnd]).trimmingCharacters(in: .whitespaces)
            }
        }

        return updated
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

private struct DERParser {
    let data: Data
    var index = 0

    init(data: Data) {
        self.data = data
    }

    mutating func peekTag() -> UInt8? {
        guard index < data.count else { return nil }
        return data[index]
    }

    mutating func readElement() -> Data? {
        guard index < data.count else { return nil }
        let tag = data[index]
        index += 1
        guard index < data.count else { return nil }
        let lengthByte = data[index]
        index += 1
        var length: Int
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else {
            let numBytes = Int(lengthByte & 0x7F)
            guard index + numBytes <= data.count else { return nil }
            length = 0
            for _ in 0..<numBytes {
                length = (length << 8) | Int(data[index])
                index += 1
            }
        }
        guard index + length <= data.count else { return nil }
        let element = data.subdata(in: index..<(index + length))
        index += length
        var result = Data([tag])
        result.append(lengthByte)
        result.append(element)
        return result
    }

    mutating func readSequence() -> Data? {
        guard let element = readElement() else { return nil }
        guard element.first == 0x30 else { return nil }
        let tagLength = 2
        return element.subdata(in: tagLength..<element.count)
    }
}