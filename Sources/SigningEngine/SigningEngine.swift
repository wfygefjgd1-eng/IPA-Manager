import Foundation

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
        Logger.info("开始签名: \(sourcePath)")

        guard let keychainID = certificate.keychainIdentifier else {
            throw AppError.signFailed("证书缺少 Keychain 标识")
        }

        let p12URL = try exportP12(identifier: keychainID)
        defer {
            try? fileManager.deleteItem(at: p12URL)
        }

        let outputURL = fileManager.directoryURL(.signed)
            .appendingPathComponent("\(URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent)-signed-\(Int(Date().timeIntervalSince1970)).ipa")

        let certPassword = certManager.readPassword(for: certificate) ?? ""

        // Bridge progress callback: pass a non-capturing C closure + context
        let box = ProgressBox(handler: progress)
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        // 临时目录必须可写：iOS 沙箱内 NSTemporaryDirectory 保证可用（不能用 /tmp）
        let tempDir = NSTemporaryDirectory()

        let result: Int32 = sourcePath.withCString { inputCStr in
            outputURL.path.withCString { outputCStr in
                p12URL.path.withCString { p12CStr in
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