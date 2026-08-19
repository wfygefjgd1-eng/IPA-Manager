import Foundation
import Security

protocol SigningEngineProtocol {
    func sign(
        sourcePath: String,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double) -> Void
    ) throws -> String
}

final class SigningEngine: SigningEngineProtocol {
    static let shared = SigningEngine()

    private let fileManager = AppFileManager.shared
    private let certManager = CertificateManager.shared

    func sign(
        sourcePath: String,
        certificate: CertificateInfo,
        profile: ProvisioningInfo,
        progress: @escaping (Double) -> Void
    ) throws -> String {
        progress(0.0)

        // 源文件可能已被删除/移动（列表记录还在但磁盘文件丢失）：
        // 若直接进入导出流程，zsign 桥接层会报 "Input file not found" 这类不友好的英文错误。
        // 在导出/签名任何操作之前先校验源文件是否存在，给出友好中文提示。
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw AppError.signFailed("源文件已被删除或移动，请返回列表重新导入该应用后再签名")
        }

        Logger.info("开始签名: \(sourcePath)")

        guard let keychainID = certificate.keychainIdentifier else {
            throw AppError.signFailed("证书缺少 Keychain 标识")
        }

        let certPassword = certManager.readPassword(for: certificate) ?? ""

        let p12URL = try exportP12(identifier: keychainID)
        defer {
            try? fileManager.deleteItem(at: p12URL)
        }

        // 首选：把 p12 里的私钥导出为 PEM 私钥文件（绕开 iOS 静态 OpenSSL 对
        // PBES2/AES p12 的 PKCS12_parse 失败问题）；失败则回退直接用 p12 文件。
        // zsign 的 ZSignAsset::Init 在 certPath 为空时会自动从描述文件的
        // DeveloperCertificates 里找与私钥配对的证书。
        let keyFileURL = try? exportPrivateKeyPEM(from: p12URL, password: certPassword)
        defer {
            if let keyFileURL = keyFileURL {
                try? fileManager.deleteItem(at: keyFileURL)
            }
        }
        let keyPath = (keyFileURL ?? p12URL).path

        let outputURL = fileManager.directoryURL(.signed)
            .appendingPathComponent("\(URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent)-signed-\(Int(Date().timeIntervalSince1970)).ipa")

        // Bridge progress callback: pass a non-capturing C closure + context
        let box = ProgressBox(handler: progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        // 临时目录必须可写：iOS 沙箱内 NSTemporaryDirectory 保证可用（不能用 /tmp）
        let tempDir = NSTemporaryDirectory()

        let result: Int32 = sourcePath.withCString { inputCStr in
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
                                options.zipLevel = 6
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
            let message = zsign_last_error().map { String(cString: $0) } ?? "未知错误"
            throw AppError.signFailed(message)
        }

        progress(1.0)
        Logger.info("签名完成: \(outputURL.path)")
        return outputURL.path
    }

    /// 用系统 Security 框架（SecPKCS12Import）解开 p12 并把私钥导出为 PEM 文件。
    /// iOS 静态 OpenSSL 对 PBES2/AES p12 的 PKCS12_parse 可能失败，而系统实现可靠。
    private func exportPrivateKeyPEM(from p12URL: URL, password: String) throws -> URL {
        guard let data = try? Data(contentsOf: p12URL) else {
            throw AppError.signFailed("无法读取证书数据")
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
            throw AppError.signFailed("系统无法解析此证书 (错误码 \(status))")
        }
        let identity = rawIdentity as! SecIdentity

        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyStatus == errSecSuccess, let key = privateKey else {
            throw AppError.signFailed("证书中未找到私钥")
        }

        guard let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw AppError.signFailed("无法导出私钥")
        }

        // ECC 私钥是 SEC1 格式（BEGIN EC PRIVATE KEY）；RSA 是 PKCS#1 格式（BEGIN RSA PRIVATE KEY）
        var pemBlock = "-----BEGIN PRIVATE KEY-----\n"
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
            pemBlock = "-----BEGIN EC PRIVATE KEY-----\n"
        } else if isRSA {
            pemBlock = "-----BEGIN RSA PRIVATE KEY-----\n"
        }

        let base64Lines = (keyData as Data).base64EncodedString()
        var pem = pemBlock
        var index = 0
        let step = 64
        while index < base64Lines.count {
            let end = min(index + step, base64Lines.count)
            pem += base64Lines[base64Lines.index(base64Lines.startIndex, offsetBy: index)..<base64Lines.index(base64Lines.startIndex, offsetBy: end)] + "\n"
            index = end
        }
        let footer: String
        if isEC {
            footer = "-----END EC PRIVATE KEY-----\n"
        } else if isRSA {
            footer = "-----END RSA PRIVATE KEY-----\n"
        } else {
            footer = "-----END PRIVATE KEY-----\n"
        }
        pem += footer

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sign-key-\(UUID().uuidString).pem")
        try pem.write(to: outputURL, atomically: true, encoding: .utf8)
        Logger.info("已导出 PEM 私钥: \(isEC ? "ECC" : isRSA ? "RSA" : "PKCS8")")
        return outputURL
    }

    private func exportP12(identifier: String) throws -> URL {
        // 私钥材料写到系统临时目录，避免残留在 Documents 目录
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-\(identifier).p12")
        try certManager.exportP12(identifier: identifier, to: tempURL)
        return tempURL
    }
}

private final class ProgressBox {
    let handler: (Double) -> Void

    init(handler: @escaping (Double) -> Void) {
        self.handler = handler
    }
}

private let progressCallbackFunc: ZSignProgressCallback = { (context, percent, message) in
    guard let context = context else { return }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        box.handler(Double(percent) / 100.0)
    }
    if let message = message {
        let text = String(cString: message)
        Logger.debug("zsign: \(text)")
    }
}