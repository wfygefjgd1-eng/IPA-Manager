import Foundation
import Network
import Darwin

final class LocalInstallServer {
    static let shared = LocalInstallServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingIPA: URL?
    private var manifestData: Data?

    /// 获取设备局域网 IPv4 地址（如 192.168.x.x）。iOS 27 的系统安装进程
    /// 不连接 127.0.0.1 回环（1.0.53 实测：服务器监听正常但 SpringBoard 的
    /// TCP 连接从未到达），必须用设备可路由的局域网 IP 供 itms-services 下载。
    /// AltStore/Esign/Feather 等本地安装工具在其上也用局域网 IP 或回环成功；
    /// iOS 27 + 明文 HTTP 回环被系统层忽略，因此这里改走局域网 IP。
    private static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0/en1 = Wi-Fi，pdp_ip0 = 蜂窝。两者都可被 SpringBoard 路由。
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        return ip
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return nil
    }

    func start(ipaLocalURL: URL) throws -> URL {
        stop()

        let port = UInt16.random(in: 49152...65535)
        // iOS 27 的系统安装进程不连接 127.0.0.1 回环（1.0.53 实测：服务器监听正常、
        // 保活正常、无 TLS，但 SpringBoard 的 TCP 连接从未到达）。因此：
        //  1. 监听全部接口（不限定 loopback），让 SpringBoard 经局域网 IP 可达；
        //  2. manifest URL 用设备局域网 IP（192.168.x.x / 蜂窝 IP）。
        // 明文 HTTP 是整个 iOS 版本线都可用的做法（AltStore 等本地安装器标准），
        // 127.0.0.1/局域网流量数据均不出错网络（若用蜂窝 IP 才出设备）。
        // 不用 https：iPhone Distribution 证书 EKU 缺 serverAuth，系统会拒绝握手。
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 不设置 requiredInterfaceType，默认监听所有可达接口（含 Wi-Fi/蜂窝）。

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        self.listener = listener
        self.servingIPA = ipaLocalURL

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        // start 是异步的：listener 需要进入 .ready 状态才会接受连接。
        // 若不等待就立刻打开 itms-services，SpringBoard 的连接请求会落在
        // 未就绪的监听器上被丢弃（日志表现为"没有收到任何请求"）。
        let readyGroup = DispatchGroup()
        readyGroup.enter()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readyGroup.leave()
            case .failed(let error):
                Logger.error("本地服务器监听失败: \(error)")
                readyGroup.leave()
            default:
                break
            }
        }
        listener.start(queue: ServerQueue.shared.queue)
        let waitResult = readyGroup.wait(timeout: .now() + 5)
        if waitResult != .success {
            Logger.error("本地服务器 5 秒内未就绪，安装可能失败")
        }

        // 局域网 IP 优先；拿不到时回退 127.0.0.1（旧 iOS 仍可用）。
        let host = Self.localIPAddress() ?? "127.0.0.1"
        Logger.info("本地安装服务器已启动: \(host):\(port) (协议=HTTP明文, 局域网IP=\(host != "127.0.0.1"))")
        // itms-services 打开后 App 将立即退到后台：启动静音音频保活，
        // 让进程不被挂起，SpringBoard 才能连上本地服务器下载 manifest/ipa 。
        BackgroundAudioKeepAlive.shared.start()
        return URL(string: "http://\(host):\(port)")!
    }

    func cacheManifest(_ data: Data) {
        manifestData = data
    }

    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        servingIPA = nil
        manifestData = nil
        BackgroundAudioKeepAlive.shared.stop()
        Logger.info("本地安装服务器已停止")
    }

    private static func tlsOptions() -> NWProtocolTLS.Options {
        ServerIdentityProvider.shared.tlsOptions()
    }

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        // 关键诊断分界线：newConnectionHandler 在 TCP accept 时触发，此时 TLS 握手尚未开始。
        // 加这条日志可以区分：TCP 连接到底到没到服务器——
        // 有"收到新连接" → 说明网络可达，问题在 TLS 握手/证书；
        // 没有 → 说明 SpringBoard 根本没连过来（URL 被系统拦截 / 后台监听被挂起）。
        Logger.info("本地服务器收到新连接: \(connection.endpoint.debugDescription)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                Logger.info("本地服务器连接就绪 (.ready) — TLS 握手成功")
            case .failed(let error):
                Logger.error("本地服务器连接失败: \(error.localizedDescription)")
                self.connections.removeAll { $0 === connection }
            case .cancelled:
                self.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: ServerQueue.shared.queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty, let request = String(data: data, encoding: .utf8) {
                self.respond(request: request, connection: connection)
            } else if let error = error {
                Logger.error("本地服务器连接错误: \(error)")
                connection.cancel()
            } else if isComplete {
                connection.cancel()
            } else {
                self.respond(request: "GET /manifest.plist", connection: connection)
            }
        }
    }

    private func respond(request: String, connection: NWConnection) {
        let path = requestPath(from: request)
        // 用 INFO 级别记录请求路径：诊断报告只包含 ERROR/INFO，debug 级日志看不到，
        // 无法判断 SpringBoard 是否真的连上了本地服务器、请求了哪个路径。
        Logger.info("本地服务器收到请求: \(path) (来自 \(connection.endpoint.debugDescription))")

        if path == "/manifest.plist" {
            let manifest = manifestData ?? Data()
            Logger.info("响应 manifest.plist: \(manifest.count) 字节")
            let response = httpResponse(status: 200, contentType: "application/xml", body: manifest)
            sendAndClose(response, connection: connection)
        } else if path.hasSuffix(".ipa") {
            Logger.info("开始流式发送 IPA: \(servingIPA?.lastPathComponent ?? "unknown")")
            streamIPA(connection: connection)
        } else {
            Logger.info("未知路径 404: \(path)")
            let response = httpResponse(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
            sendAndClose(response, connection: connection)
        }
    }

    /// 分块流式发送 IPA，避免把整个文件读入内存（常见 IPA 数百 MB）
    private func streamIPA(connection: NWConnection) {
        guard let ipaURL = servingIPA,
              let handle = try? FileHandle(forReadingFrom: ipaURL) else {
            let response = httpResponse(status: 404, contentType: "text/plain", body: Data("IPA not found".utf8))
            sendAndClose(response, connection: connection)
            return
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\n"
        header += "Content-Length: \(AppFileManager.shared.fileSize(at: ipaURL))\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self = self else {
                connection.cancel()
                return
            }
            self.sendFileChunks(from: handle, connection: connection)
        })
    }

    private func sendFileChunks(from handle: FileHandle, connection: NWConnection) {
        let chunkSize = 256 * 1024
        let data = handle.readData(ofLength: chunkSize)
        if data.isEmpty {
            try? handle.close()
            self.connections.removeAll { $0 === connection }
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self = self else {
                connection.cancel()
                return
            }
            self.sendFileChunks(from: handle, connection: connection)
        })
    }

    private func sendAndClose(_ response: Data, connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.connections.removeAll { $0 === connection }
            connection.cancel()
        })
    }

    private func requestPath(from request: String) -> String {
        let lines = request.components(separatedBy: "\r\n")
        guard let target = lines.first else { return "/" }
        let components = target.components(separatedBy: " ")
        guard components.count >= 2 else { return "/" }
        var path = components[1]
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }
        return path
    }

    private func httpResponse(status: Int, contentType: String, body: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

final class ServerQueue {
    static let shared = ServerQueue()
    let queue: DispatchQueue

    init() {
        queue = DispatchQueue(label: "com.ipamanager.server.queue", qos: .userInitiated)
    }
}