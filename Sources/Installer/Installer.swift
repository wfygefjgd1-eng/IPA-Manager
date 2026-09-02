import Foundation
import UIKit
import ZIPFoundation

protocol Installing {
    func install(ipaPath: String, certificate: CertificateInfo, onInstallOpened: (() -> Void)?) throws
}

final class Installer: Installing {
    static let shared = Installer()

    func install(ipaPath: String, certificate: CertificateInfo, onInstallOpened: (() -> Void)? = nil) throws {
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
            self?.performInstall(ipaPath: ipaPath, certificate: certificate, onInstallOpened: onInstallOpened)
        }
    }

    /// 后台执行完整安装流程（服务器启动/探测 + IPA 元数据解析 + manifest 生成），
    /// 出错时停掉本地服务器并记录错误日志；成功后再切回主线程打开 itms-services 链接。
    private func performInstall(ipaPath: String, certificate: CertificateInfo, onInstallOpened: (() -> Void)?) {
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
            if let info = IPAParser().lightweightAppInfo(from: ipaURL), !info.bundleID.isEmpty {
                bundleID = info.bundleID
                if !info.version.isEmpty { version = info.version }
                if !info.name.isEmpty { appName = info.name }
            } else if let appInfo = try? IPAParser().parseAppInfo(fileURL: ipaURL) {
                if !appInfo.bundleID.isEmpty { bundleID = appInfo.bundleID }
                if !appInfo.version.isEmpty { version = appInfo.version }
                if !appInfo.name.isEmpty { appName = appInfo.name }
            }

            let payloadURL = baseURL.appendingPathComponent(ipaURL.lastPathComponent)

            // 公网 manifest（api.palera.in /genPlist）可用性预检：URL 构造本身恒成功，
            // 真正的失败发生在 SpringBoard 拉 manifest 时（无外网 / DNS 污染 / 服务
            // 故障），那时已无法纠正。这里先做一次 2 秒超时的同步预检（后台线程），
            // 失败直接走本地 manifest（cacheManifest + 127.0.0.1 URL），保证无外网/
            // 被墙环境仍可安装。
            var manifestURL: URL?
            var isLocalFallback = false
            if Self.isExternalManifestServiceReachable() {
                manifestURL = try generateExternalManifestURL(
                    bundleID: bundleID, name: appName, version: version,
                    payloadURL: payloadURL
                )
                if manifestURL == nil {
                    throw AppError.installFailed("公网 manifest 生成返回 nil")
                }
            } else {
                Logger.warning("api.palera.in 预检不可达（2 秒超时），直接使用本地 manifest")
            }

            if manifestURL == nil {
                // 本地 fallback：生成 plist Data 并通过 LocalInstallServer.cacheManifest 缓存，
                // 返回本地 http URL（http://127.0.0.1:port/manifest.plist），确保打开 itms-services 前已缓存
                guard let localURL = generateLocalManifestURL(
                    bundleID: bundleID, name: appName, version: version,
                    payloadURL: payloadURL, baseURL: baseURL
                ) else {
                    throw AppError.installFailed("本地 manifest 生成失败")
                }
                manifestURL = localURL
                isLocalFallback = true
                Logger.info("已回退到本地 manifest: \(localURL.absoluteString)")
            }

            guard let finalManifestURL = manifestURL else {
                throw AppError.installFailed("manifest 生成失败")
            }
            if isLocalFallback {
                Logger.info("本地 manifest 已缓存，准备打开 itms-services (local fallback)")
            }

            // itms-services 链接的 url 参数编码，照抄 Feather 同款双重编码：
            // 第一次按 urlQueryAllowed 编码完整 manifest URL，第二次按 alphanumerics
            // 编码（作为 itms-services 的查询参数值），系统解码后得到原始 URL。
            let encodedBase = finalManifestURL.absoluteString
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let finalEncoded = encodedBase
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let installURLStr = "itms-services://?action=download-manifest&url=\(finalEncoded)"
            guard let installURL = URL(string: installURLStr) else {
                throw AppError.installFailed("安装链接生成失败")
            }

            DispatchQueue.main.async { [weak self] in
                if isLocalFallback {
                    Logger.info("打开安装链接: itms-services://?action=download-manifest&url=<本地HTTP manifest>")
                    Logger.info("本地 manifest: \(finalManifestURL.absoluteString) (fallback)")
                } else {
                    Logger.info("打开安装链接: itms-services://?action=download-manifest&url=<公网HTTPS manifest>")
                    Logger.info("公网 manifest: \(finalManifestURL.absoluteString)")
                }
                UIApplication.shared.open(installURL) { success in
                    if success {
                        // 记录"安装已发起"活动：回前台/保活超时据此识别安装仍在进行，
                        // 不停服务器（用户在系统安装弹窗停留时切回 App 是常见操作）
                        LocalInstallServer.shared.noteInstallOpened()
                        // open 成功后才通知调用方（如"自动回桌面"的调度锚点）：
                        // 主线程回调
                        onInstallOpened?()
                    } else {
                        Logger.error("无法打开 itms-services 链接")
                        // 后台失败同步抛不回去，补一条用户可见反馈
                        AppState.shared.showToast("安装失败：无法打开安装链接")
                        self?.stopServer()
                    }
                }
            }
        } catch {
            // 后台失败无法在此时同步抛给调用方（调用方在异步完成前已显示"安装请求已发出"），
            // 停掉本地服务器并记录详细错误，避免 NWListener/音频保活残留；
            // 同时用全局 toast 补一条用户可见反馈，避免"点了安装毫无反应"。
            LocalInstallServer.shared.stop()
            Logger.error("本地安装失败: \(error.localizedDescription)")
            AppState.shared.showToast("安装失败：\(error.localizedDescription)")
        }
    }

    /// api.palera.in 可达性预检：2 秒超时 HEAD，在后台线程同步执行
    /// （调用方 performInstall 已在后台队列）。状态码 <500 视为服务可达
    /// （4xx 说明服务器在正常应答，genPlist 端点的问题不是网络问题）。
    private static func isExternalManifestServiceReachable() -> Bool {
        guard let url = URL(string: "https://api.palera.in/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        // @Sendable 闭包不能直接捕获可变局部变量：用盒子承载结果
        final class ReachBox: @unchecked Sendable { var value = false }
        let box = ReachBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse, error == nil {
                box.value = (200..<500).contains(http.statusCode)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return box.value
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

    /// 本地 manifest Data 生成：使用 PropertyListSerialization 本地构建 OTA plist（XML），
    /// 不依赖外部网络。结构与 Apple OTA 标准一致，包含 software-package asset 与 metadata。
    private func generateLocalManifestData(
        bundleID: String, name: String, version: String, payloadURL: URL
    ) -> Data {
        let plist: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": payloadURL.absoluteString]
                    ],
                    "metadata": [
                        "bundle-identifier": bundleID,
                        "bundle-version": version,
                        "kind": "software",
                        "title": name
                    ]
                ]
            ]
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            return data
        } catch {
            Logger.error("本地 manifest 序列化失败: \(error.localizedDescription)")
            return Data()
        }
    }

    /// 本地 manifest URL 生成并缓存：先生成 Data 调用 LocalInstallServer.cacheManifest，
    /// 再返回本地 http URL（http://127.0.0.1:port/manifest.plist），确保 itms-services 打开前已缓存。
    /// - Parameters: baseURL 为 LocalInstallServer.start 返回的 http baseURL（含端口）
    private func generateLocalManifestURL(
        bundleID: String, name: String, version: String, payloadURL: URL, baseURL: URL
    ) -> URL? {
        let data = generateLocalManifestData(bundleID: bundleID, name: name, version: version, payloadURL: payloadURL)
        guard !data.isEmpty else { return nil }
        LocalInstallServer.shared.cacheManifest(data)
        let manifestURL = baseURL.appendingPathComponent("manifest.plist")
        Logger.info("本地 manifest 已生成并缓存: \(data.count) 字节 -> \(manifestURL.absoluteString)")
        return manifestURL
    }

    private func stopServer() {
        LocalInstallServer.shared.stop()
    }
}