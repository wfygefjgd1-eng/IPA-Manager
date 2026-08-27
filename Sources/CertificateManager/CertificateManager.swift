import Foundation
import Security
import CryptoKit
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
                var certificate = try self.readCertificate(from: url, password: password)
                // 稳定 keychain ID：基于 P12 文件内容（SHA256 前 8 字节）生成，
                // 同一证书（同一文件内容）重复导入会得到相同 ID，外层可按 ID
                // 去重 / 复用私钥，避免"重复导入同一证书产生 N 条记录"的历史 bug。
                // 旧版本用 UUID().uuidString，每次导入都新生成，重复导入会创建 N 条记录
                // + N 份 Keychain 私钥副本（按 identifier 各占一条）。
                if let p12Data = try? Data(contentsOf: url) {
                    let stableID = Self.stableKeychainID(for: p12Data, password: password, role: "cert")
                    certificate.keychainIdentifier = stableID
                    if !password.isEmpty {
                        certificate.passwordKeychainIdentifier =
                            Self.stableKeychainID(for: p12Data, password: password, role: "pwd")
                    }
                }
                let storeStatus = self.storePrivateKey(
                    from: url, password: password,
                    identifier: certificate.keychainIdentifier,
                    passwordIdentifier: certificate.passwordKeychainIdentifier
                )
                guard let storeStatus = storeStatus, storeStatus == errSecSuccess else {
                    let code = storeStatus ?? -1
                    let reason: String
                    switch code {
                    case errSecAuthFailed:
                        reason = "私钥写入失败：钥匙串验证失败，请检查设备锁屏密码设置后重试"
                    case errSecInteractionNotAllowed:
                        reason = "私钥写入失败：设备锁定时无法访问钥匙串，请解锁后重试"
                    default:
                        reason = "私钥写入失败，请检查设备钥匙串状态后重试 (错误码 \(code))"
                    }
                    Logger.error("私钥落库失败: \(reason)")
                    self.deliver(.failure(AppError.certificateInvalid(reason)), completion: completion)
                    return
                }
                self.deliver(.success(certificate), completion: completion)
            } catch {
                self.deliver(.failure(error), completion: completion)
            }
        }
    }

    /// 同一份 P12 多次导入应得到同一 keychain account——按"内容 SHA256 前 8 字节 +
    /// 密码 + 角色（cert / pwd）"做指纹。前 8 字节碰撞概率 1/2^64，密码不同则天然
    /// 区分（同一 P12 换密码会创建独立条目，不影响原条目）。
    private static func stableKeychainID(for p12Data: Data, password: String, role: String) -> String {
        var hasher = SHA256()
        hasher.update(data: p12Data)
        hasher.update(data: Data(password.utf8))
        hasher.update(data: Data(role.utf8))
        let digest = hasher.finalize()
        // 8 字节 hex = 16 字符 UUID 风格字符串（Keychain account 无格式约束）
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "kcid-\(hex)"
    }

    /// API 线程契约：completion 统一在主线程回调，调用方无需自行切主。
    private func deliver(
        _ result: Result<CertificateInfo, Error>,
        completion: @escaping (Result<CertificateInfo, Error>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async { completion(result) }
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

    // MARK: - 删除与查询

    /// 删除证书及其对应密码条目。返回是否成功（errSecItemNotFound 视为成功）。
    /// 密码条目按证书 identifier 反查删除，不依赖可能缺失的 passwordKeychainIdentifier，
    /// 顺带清除历史版本遗留的孤儿密码。
    @discardableResult
    func deleteCertificate(_ certificate: CertificateInfo) -> Bool {
        guard let identifier = certificate.keychainIdentifier else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.error("证书条目删除失败: \(status)")
        }

        // 删除对应密码条目：优先用记录的 passwordKeychainIdentifier，
        // 缺失时按证书 identifier 反查（兼容旧版本持久化的证书）
        let pwdIDs = [certificate.passwordKeychainIdentifier, identifier].compactMap { $0 }
        for pwdID in Set(pwdIDs) {
            let pwdQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainPasswordService,
                kSecAttrAccount as String: pwdID
            ]
            let pwdStatus = SecItemDelete(pwdQuery as CFDictionary)
            if pwdStatus != errSecSuccess && pwdStatus != errSecItemNotFound {
                Logger.warning("密码条目删除失败: \(pwdStatus)")
            }
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 本地服务器 TLS 身份遗留条目清理

    /// 清理本地服务器 TLS 身份写入钥匙串的孤儿条目（服务器已改明文 HTTP，不再使用这些身份）：
    /// - label 恰为 "IPA Manager Server Cert" 的证书条目（exportToKeychainOnce 写入）；
    /// - 所有 label 以 "IPA Manager Server Identity" 开头的证书/私钥/通用密码/身份条目
    ///   （loadIdentityViaKeychain 兜底路径写入，含 UUID 后缀）。
    /// App 卸载不会自动清除钥匙串条目，必须在启动时统一清理，避免长期累积。
    /// 全部为尽力而为：条目不存在视为成功，失败只记 warning。
    static func cleanupServerIdentityKeychainItems() {
        // 1) 固定 label 的服务器证书
        _ = deleteKeychainItem(class: kSecClassCertificate, label: "IPA Manager Server Cert")
        // 2) 前缀匹配的孤儿条目（证书/私钥/通用密码/身份）
        for itemClass in [kSecClassCertificate, kSecClassKey, kSecClassGenericPassword, kSecClassIdentity] {
            deleteKeychainItems(class: itemClass, labelPrefix: "IPA Manager Server Identity")
        }
    }

    /// 按 class + 精确 label 删除单个钥匙串条目（errSecItemNotFound 视为成功）。
    private static func deleteKeychainItem(class itemClass: CFString, label: String) -> OSStatus {
        let deleteQuery: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrLabel as String: label
        ]
        let status = SecItemDelete(deleteQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.warning("钥匙串条目删除失败 (class=\(itemClass), label=\(label), status=\(status))")
        }
        return status
    }

    /// 按 class + label 前缀查询后逐个清理（SecItemCopyMatching 拿全量属性，
    /// 再按 label 过滤出前缀匹配的条目逐个 SecItemDelete）。
    private static func deleteKeychainItems(class itemClass: CFString, labelPrefix: String) {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrLabel as String: labelPrefix,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                Logger.warning("钥匙串条目查询失败 (status=\(status), class=\(itemClass), labelPrefix=\(labelPrefix))")
            }
            return
        }
        for item in items {
            guard let label = item[kSecAttrLabel as String] as? String,
                  label.hasPrefix(labelPrefix) else { continue }
            _ = deleteKeychainItem(class: itemClass, label: label)
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
            // 统一改用 stableKeychainID（基于 P12 SHA256 前 8 字节 + 密码 + 角色），
            // 与 importCertificate 入口行为一致，避免同一证书从两条路径导入产生 N 条 Keychain 记录
            if let p12Data = try? Data(contentsOf: url) {
                let stableID = Self.stableKeychainID(for: p12Data, password: password, role: "cert")
                certInfo.keychainIdentifier = stableID
                if !password.isEmpty {
                    certInfo.passwordKeychainIdentifier =
                        Self.stableKeychainID(for: p12Data, password: password, role: "pwd")
                }
            } else {
                certInfo.keychainIdentifier = UUID().uuidString
            }
            return certInfo
        case -2:
            throw AppError.certificateInvalid("密码错误或证书格式不支持 (OpenSSL)")
        default:
            // zsign_last_error 返回 C 指针：先判空再用 strnlen 限定长度复制，避免越界读。
            let rawError = Self.safeZSignError(limit: 512)
            if rawError.isEmpty {
                throw AppError.certificateInvalid("证书读取失败 (错误码: \(result))")
            }
            // 底层英文进日志，用户只看到中文可操作提示
            Logger.error("OpenSSL p12 读取失败 (code \(result)): \(rawError)")
            throw AppError.certificateInvalid("证书文件无效或格式不受支持")
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
            // 把系统错误码映射成用户可操作的中文提示（底层数字/英文只进日志）
            let userMessage: String
            switch status {
            case errSecAuthFailed:
                userMessage = "密码错误，请重新输入"
            case errSecDecode:
                userMessage = "证书格式不支持或文件已损坏"
            case errSecPassphraseRequired:
                userMessage = "该证书需要密码，请输入密码后重试"
            default:
                userMessage = "证书读取失败，请确认文件有效后重试"
            }
            Logger.error("SecPKCS12Import 失败: status=\(status)")
            throw AppError.certificateInvalid(userMessage)
        }

        let certChain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []

        var info = CertificateInfo()
        info.name = first[kSecImportItemLabel as String] as? String ?? "P12 证书"
        info.isPasswordProtected = !password.isEmpty
        // 统一改用 stableKeychainID（基于 P12 SHA256 前 8 字节 + 密码 + 角色），
        // 与 OpenSSL 路径一致，避免同一证书从回退路径导入时仍产生 N 条 Keychain 记录
        //（与 readCertificateViaOpenSSL 中相同的处理逻辑）。
        if let p12Data = try? Data(contentsOf: url) {
            let stableID = Self.stableKeychainID(for: p12Data, password: password, role: "cert")
            info.keychainIdentifier = stableID
            if !password.isEmpty {
                info.passwordKeychainIdentifier = Self.stableKeychainID(for: p12Data, password: password, role: "pwd")
            }
        } else {
            info.keychainIdentifier = UUID().uuidString
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
        // ASN.1 时间基本范围校验：拒绝畸形的 month=0/13、day=0/32、hour=24 等无效值，
        // 避免 DateComponents 静默接受后构造出"1970-01-32"等不存在日期。DateComponents
        // 不会做语义校验，超界值会循环进位（如 month=14 → 次年 2 月），导致证书过期
        // 时间计算错误。
        guard (1...12).contains(values[0]),
              (1...31).contains(values[1]),
              (0...23).contains(values[2]),
              (0...59).contains(values[3]),
              (0...60).contains(values[4]) else { return nil }
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

    /// 安全读取 zsign_last_error()：判空 + strnlen 限定长度，避免依赖 C 侧
    /// 缓冲区生命周期/非 NUL 结尾导致越界读。
    /// 安全读取 zsign 错误信息：strnlen 限定长度，避免越界读取。
    /// internal：SigningEngine 在 zsign 命令失败时也用它读取桥接层错误。
    static func safeZSignError(limit: Int = 512) -> String {
        guard let ptr = zsign_last_error() else { return "" }
        let len = strnlen(ptr, limit)
        guard len > 0 else { return "" }
        return String(cString: ptr)
    }

    /// 把 P12 材料与密码写入 Keychain。返回 SecItemAdd 的最终状态码
    /// （errSecSuccess 表示成功；nil 表示参数缺失未执行）。
    /// 先按 class+service+account 精确删除旧条目，再写入；
    /// 若仍返回 -25299（errSecDuplicateItem，常见于旧条目 access 属性不一致
    /// 导致 delete 匹配不到），再强制 remove 一次并重试 Add。
    @discardableResult
    private func storePrivateKey(from url: URL, password: String, identifier: String?, passwordIdentifier: String?) -> OSStatus? {
        guard let identifier = identifier else { return nil }
        guard let data = try? Data(contentsOf: url) else { return errSecDecode }

        var status = upsertKeychain(
            service: keychainService,
            account: identifier,
            data: data
        )

        if let passwordIdentifier = passwordIdentifier, !password.isEmpty {
            let pwdData = Data(password.utf8)
            let pwdStatus = upsertKeychain(
                service: keychainPasswordService,
                account: passwordIdentifier,
                data: pwdData
            )
            Logger.info("密码存储状态: \(pwdStatus)")
            if pwdStatus != errSecSuccess {
                Logger.error("密码写入 Keychain 失败: \(pwdStatus)")
                status = pwdStatus
            }
        }

        Logger.info("私钥存储状态: \(status)")
        return status
    }

    /// 先删后写：精确匹配 class+service+account 删除旧条目（errSecItemNotFound 视为预期），
    /// 再写入数据。accessibility 优先用 WhenPasscodeSetThisDeviceOnly（要求设备密码的
    /// 最强数据保护），设备未设密码等失败场景自动降级 WhenUnlockedThisDeviceOnly；
    /// 若 Add 返回 -25299，再做一次 remove 并重试。
    private func upsertKeychain(service: String, account: String, data: Data) -> OSStatus {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let delStatus = SecItemDelete(match as CFDictionary)
        if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
            Logger.warning("Keychain 旧条目删除失败: \(delStatus)（继续尝试写入）")
        }

        // 最强保护优先：要求设备已设置密码口令，若该策略写入失败（如设备未设密码）
        // 自动降级为 WhenUnlockedThisDeviceOnly 再试一次。
        let passcodeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        ]
        var status = SecItemAdd(passcodeQuery as CFDictionary, nil)
        if status != errSecSuccess {
            let unlockQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            SecItemDelete(match as CFDictionary)
            status = SecItemAdd(unlockQuery as CFDictionary, nil)
        }
        if status == errSecDuplicateItem {
            // delete 匹配不到旧条目时 Add 报重复：强制再删一次并重试（用解锁策略）
            SecItemDelete(match as CFDictionary)
            let retryQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            status = SecItemAdd(retryQuery as CFDictionary, nil)
        }
        return status
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