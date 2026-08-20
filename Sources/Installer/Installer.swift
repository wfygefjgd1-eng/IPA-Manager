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
        // 本地服务器只负责流式提供 IPA；manifest 走公网 HTTPS
        // （api.palera.in /genPlist 生成，Feather 同款），绕开 iOS 27
        // 系统安装进程拒绝本地 HTTP manifest、以及蜂窝 CGNAT IP 本机
        // 不可自访问两个问题。
        let baseURL = try LocalInstallServer.shared.start(ipaLocalURL: ipaURL)

        // 解析安装元数据（bundle-identifier / 名称 / 版本）
        var bundleID = "com.ipamanager.installed"
        var appName = ipaURL.deletingPathExtension().lastPathComponent
        var version = "1.0"
        if let appInfo = try? IPAParser().parseAppInfo(fileURL: ipaURL) {
            if !appInfo.bundleID.isEmpty { bundleID = appInfo.bundleID }
            if !appInfo.version.isEmpty { version = appInfo.version }
        }

        guard let manifestURL = try generateExternalManifestURL(
            bundleID: bundleID, name: appName, version: version,
            payloadURL: baseURL.appendingPathComponent(ipaURL.lastPathComponent)
        ) else {
            LocalInstallServer.shared.stop()
            throw AppError.installFailed("公网 manifest 生成失败")
        }

        // itms-services 链接的 url 参数编码，照抄 Feather 同款双重编码：
        // 第一次按 urlQueryAllowed 编码完整 manifest URL，第二次按 alphanumerics
        // 编码（作为 itms-services 的查询参数值），系统解码后得到原始 URL。
        let encodedBase = manifestURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let finalEncoded = encodedBase
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let installURLStr = "itms-services://?action=download-manifest&url=\(finalEncoded)"
        guard let installURL = URL(string: installURLStr) else {
            LocalInstallServer.shared.stop()
            throw AppError.installFailed("安装链接生成失败")
        }

        Logger.info("打开安装链接: itms-services://?action=download-manifest&url=<公网HTTPS manifest>")
        Logger.info("公网 manifest: \(manifestURL.absoluteString)")
        UIApplication.shared.open(installURL) { [weak self] success in
            if !success {
                Logger.error("无法打开 itms-services 链接")
                self?.stopServer()
            }
        }
    }

    /// 用公网 HTTPS 服务生成 manifest（Feather 同款：api.palera.in/genPlist）。
    /// manifest 由公网托管 → 系统安装进程可正常 HTTPS 获取（不依赖本地服务器、
    /// 不被 VPN/代理拦截）；manifest 内的 software-package 指向本地服务器
    /// 的 IPA URL（AltStore/Esign 标准做法）。
    private func generateExternalManifestURL(
        bundleID: String, name: String, version: String, payloadURL: URL
    ) throws -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.palera.in"
        comps.path = "/genPlist"
        comps.queryItems = [
            URLQueryItem(name: "bundleid", value: bundleID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "version", value: version),
            // fetchurl 必须是百分号编码后的完整 IPA URL
            URLQueryItem(name: "fetchurl", value: payloadURL.absoluteString),
        ]
        return comps.url
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
        // 从已签名的 IPA 中解析真实包信息，避免硬编码 bundle-identifier/version
        var metadata: [String: Any] = [
            "kind": "software",
            "title": ipaURL.deletingPathExtension().lastPathComponent
        ]
        if let appInfo = try? IPAParser().parseAppInfo(fileURL: ipaURL) {
            if !appInfo.bundleID.isEmpty {
                metadata["bundle-identifier"] = appInfo.bundleID
            }
            if !appInfo.version.isEmpty {
                metadata["bundle-version"] = appInfo.version
            }
        }
        // 兜底：解析失败时给占位，避免 manifest 缺键导致安装直接失败
        if metadata["bundle-identifier"] == nil {
            metadata["bundle-identifier"] = "com.ipamanager.installed"
        }
        if metadata["bundle-version"] == nil {
            metadata["bundle-version"] = "1.0"
        }

        let softwareURL = baseURL.appendingPathComponent(ipaName).absoluteString
        let manifestDict: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": softwareURL]
                    ],
                    "metadata": metadata
                ]
            ]
        ]

        return try? PropertyListSerialization.data(fromPropertyList: manifestDict, format: .xml, options: 0)
    }
}