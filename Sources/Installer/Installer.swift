import Foundation
import UIKit

protocol Installing {
    func install(ipaPath: String, certificate: CertificateInfo) throws
}

final class Installer: Installing {
    static let shared = Installer()

    func install(ipaPath: String, certificate: CertificateInfo) throws {
        Logger.info("开始本地安装: \(ipaPath)")
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw AppError.fileNotFound(ipaPath)
        }

        guard let keychainID = certificate.keychainIdentifier else {
            throw AppError.installFailed("证书缺少 Keychain 标识")
        }

        let p12URL = try exportP12(identifier: keychainID)
        defer {
            try? FileManager.default.removeItem(at: p12URL)
        }

        let password = CertificateManager.shared.readPassword(for: certificate) ?? ""
        try ServerIdentityProvider.shared.setIdentity(from: p12URL, password: password)

        let ipaURL = URL(fileURLWithPath: ipaPath)
        let baseURL = try LocalInstallServer.shared.start(ipaLocalURL: ipaURL)

        guard let manifest = try generateManifest(ipaURL: ipaURL, baseURL: baseURL) else {
            LocalInstallServer.shared.stop()
            throw AppError.installFailed("manifest 生成失败")
        }

        LocalInstallServer.shared.cacheManifest(manifest)

        let installURLStr = "itms-services://?action=download-manifest&url=\(baseURL.absoluteString)/manifest.plist"
        guard let installURL = URL(string: installURLStr) else {
            LocalInstallServer.shared.stop()
            throw AppError.installFailed("安装链接生成失败")
        }

        Logger.info("打开安装链接: \(installURLStr)")
        UIApplication.shared.open(installURL) { [weak self] success in
            if !success {
                Logger.error("无法打开 itms-services 链接")
                self?.stopServer()
            }
        }
    }

    private func stopServer() {
        LocalInstallServer.shared.stop()
    }

    private func exportP12(identifier: String) throws -> URL {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("install-\(identifier).p12")
        try CertificateManager.shared.exportP12(identifier: identifier, to: tempURL)
        return tempURL
    }

    private func generateManifest(ipaURL: URL, baseURL: URL) throws -> Data? {
        let ipaName = ipaURL.lastPathComponent
        let manifestDict: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": "\(baseURL.absoluteString)/\(ipaName)"],
                        ["kind": "display-image", "url": "\(baseURL.absoluteString)/icon.png"]
                    ],
                    "metadata": [
                        "bundle-identifier": "com.example.installed",
                        "bundle-version": "1.0",
                        "kind": "software",
                        "title": ipaURL.deletingPathExtension().lastPathComponent
                    ]
                ]
            ]
        ]

        return try? PropertyListSerialization.data(fromPropertyList: manifestDict, format: .xml, options: 0)
    }
}