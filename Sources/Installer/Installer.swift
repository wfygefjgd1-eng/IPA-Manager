import Foundation
import UIKit
import ZIPFoundation

protocol Installing {
    func install(ipaPath: String, certificate: CertificateInfo) throws
}

final class Installer: Installing {
    static let shared = Installer()

    func install(ipaPath: String, certificate: CertificateInfo) throws {
        Logger.info("开始本地安装: \(ipaPath)")

        // 轻量同步校验（快速失败，错误可直接同步抛给调用方弹窗展示）：
        // 源文件是否存在、证书是否带 Keychain 标识。
        guard FileManager.default.fileExists(atPath: ipaPath) else {
            throw AppError.fileNotFound(ipaPath)
        }
        guard certificate.keychainIdentifier != nil else {
            throw AppError.installFailed("证书缺少 Keychain 标识")
        }

        // 重活全部移入后台队列：LocalInstallServer.start 内部有 readyGroup.wait(5s)
        // + 逐接口同步探测（各 4s+），IPA 元数据解析涉及整包解压（数百 MB），
        // 若留在 UI 主线程同步执行会卡死数秒~数分钟，有被看门狗杀进程的风险。
        // 完成后回主线程执行 UIApplication.shared.open。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performInstall(ipaPath: ipaPath, certificate: certificate)
        }
    }

    /// 后台执行完整安装流程（服务器启动/探测 + IPA 元数据解析 + manifest 生成），
    /// 出错时停掉本地服务器并记录错误日志；成功后再切回主线程打开 itms-services 链接。
    private func performInstall(ipaPath: String, certificate: CertificateInfo) {
        do {
            let ipaURL = URL(fileURLWithPath: ipaPath)
            // 本地服务器只负责流式提供 IPA；manifest 走公网 HTTPS
            // （api.palera.in /genPlist 生成，Feather 同款），绕开 iOS 27
            // 系统安装进程拒绝本地 HTTP manifest、以及蜂窝 CGNAT IP 本机
            // 不可自访问两个问题。
            let baseURL = try LocalInstallServer.shared.start(ipaLocalURL: ipaURL)

            // 解析安装元数据（bundle-identifier / 名称 / 版本）。
            // 优先轻量读取 zip 中央目录里的 Payload/<App>.app/Info.plist 单个条目
            // （ZIPFoundation 不解压实体，几百 MB 的 IPA 也只要毫秒级）；
            // 读取失败（异常结构）才回退完整解析（整包解压，在后台执行不阻塞 UI）。
            var bundleID = "com.ipamanager.installed"
            var appName = ipaURL.deletingPathExtension().lastPathComponent
            var version = "1.0"
            if let info = lightweightAppInfo(from: ipaURL), !info.bundleID.isEmpty {
                bundleID = info.bundleID
                if !info.version.isEmpty { version = info.version }
                if !info.name.isEmpty { appName = info.name }
            } else if let appInfo = try? IPAParser().parseAppInfo(fileURL: ipaURL) {
                if !appInfo.bundleID.isEmpty { bundleID = appInfo.bundleID }
                if !appInfo.version.isEmpty { version = appInfo.version }
                if !appInfo.name.isEmpty { appName = appInfo.name }
            }

            guard let manifestURL = try generateExternalManifestURL(
                bundleID: bundleID, name: appName, version: version,
                payloadURL: baseURL.appendingPathComponent(ipaURL.lastPathComponent)
            ) else {
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
                throw AppError.installFailed("安装链接生成失败")
            }

            DispatchQueue.main.async { [weak self] in
                Logger.info("打开安装链接: itms-services://?action=download-manifest&url=<公网HTTPS manifest>")
                Logger.info("公网 manifest: \(manifestURL.absoluteString)")
                UIApplication.shared.open(installURL) { success in
                    if !success {
                        Logger.error("无法打开 itms-services 链接")
                        self?.stopServer()
                    }
                }
            }
        } catch {
            // 后台失败无法在此时同步抛给调用方（调用方在异步完成前已显示"安装请求已发出"），
            // 停掉本地服务器并记录详细错误，避免 NWListener/音频保活残留。
            LocalInstallServer.shared.stop()
            Logger.error("本地安装失败: \(error.localizedDescription)")
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

    /// 轻量读取 IPA 元数据：只读 zip 中央目录里 Payload/<App>.app/Info.plist 的
    /// 单个条目数据并解析（ZIPFoundation Archive 不解压实体），避免安装时整包解压。
    /// 返回 nil 表示读取/解析失败，调用方回退到完整解析。
    private func lightweightAppInfo(from ipaURL: URL) -> (bundleID: String, version: String, name: String)? {
        guard let archive = try? Archive(url: ipaURL, accessMode: .read) else { return nil }
        // 只匹配顶层 .app 的 Info.plist（Payload/A.app/Info.plist 或裸 A.app/Info.plist），
        // 不匹配 .framework/.appex 等嵌套结构里的 Info.plist。
        guard let entry = archive.first(where: { entry in
            guard entry.type == .file, entry.path.hasSuffix("/Info.plist") else { return false }
            let components = entry.path.components(separatedBy: "/")
            return (components.count == 3 && components[0] == "Payload" && components[1].hasSuffix(".app"))
                || (components.count == 2 && components[0].hasSuffix(".app"))
        }) else { return nil }

        var plistData = Data()
        do {
            try archive.extract(entry, consumer: { plistData.append($0) })
        } catch {
            return nil
        }
        guard let dict = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        return (
            bundleID: dict["CFBundleIdentifier"] as? String ?? "",
            version: (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String) ?? "",
            name: (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? ""
        )
    }

    private func stopServer() {
        LocalInstallServer.shared.stop()
    }
}