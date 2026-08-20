import Foundation
import Network
import Darwin

final class LocalInstallServer {
    static let shared = LocalInstallServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingIPA: URL?
    private var manifestData: Data?

    /// 枚举设备全部可路由 IPv4 地址（Wi-Fi en0/en1、蜂窝 pdp_ip0、个人热点
    /// bridge100/172.20.x.x 等，等），排除回环和链路本地。Feather 同款做法。
    private static func allLocalIPAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") || name.hasPrefix("bridge") || name.hasPrefix("utun") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !result.contains(ip) {
                        result.append(ip)
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return result
    }

    func isReachable() async -> Bool {
        guard let base = lastBaseURL else { return false }
        var request = URLRequest(url: base, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // manifest 尚未缓存时根路径可能 404：只要服务器返回了 HTTP 响应（连接成功）
            // 就算可达，连接级失败（-1004/-1009 等）才判为不可达。
            Logger.info("安装服务器自检: HEAD \(base.absoluteString) -> HTTP \(status)")
            return status >= 200 && status < 600
        } catch {
            Logger.error("安装服务器自检失败: \(error.localizedDescription)")
            return false
        }
    }

    private var lastBaseURL: URL?

    /// 同步探测某个 URL 是否可达（App 自己的网络栈发起 HEAD 请求）。
    /// 返回 nil 表示不可达；可达时返回 HTTP 状态码。
    /// 本地回环/局域网响应通常毫秒级，1s 超时足够区分“可达”与“不可达”，
    /// 避免蜂窝网络下不可达地址把安装提示拖慢数秒（此前 4s+1s×N 个候选）。
    private static func probe(_ url: URL, timeout: TimeInterval = 1) -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        var result: Int?
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            result = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        task.cancel()
        return result
    }

    func start(ipaLocalURL: URL) throws -> URL {
        stop()

        let port = UInt16.random(in: 49152...65535)
        // 监听全部接口（不限定 loopback），让 SpringBoard 经任意可路由地址可达。
        // 明文 HTTP 是本地安装器（AltStore 等）的标准，127.0.0.1/局域网流量不出设备；
        // 不用 https：iPhone Distribution 证书 EKU 缺 serverAuth，系统会拒绝握手。
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        self.listener = listener
        self.servingIPA = ipaLocalURL

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        // start 是异步的：listener 需要进入 .ready 状态才会接受连接。
        // 若不等待就立刻打开 itms-services，SpringBoard 的连接请求会落在
        // 未就绪的监听器上被丢弃（日志表现为"没有收到任何请求"）。
        // 同时记录实际 listener 状态用于失败判定：.failed（端口被占用/权限不足）
        // 与 .waiting（网络路径不可用）都会造成"安装假成功"。
        let readyGroup = DispatchGroup()
        var becameReady = false
        var listenerState: NWListener.State?
        readyGroup.enter()
        listener.stateUpdateHandler = { state in
            listenerState = state
            switch state {
            case .ready:
                becameReady = true
                readyGroup.leave()
            case .waiting(let error):
                // .waiting 单独提示：等待网络路径（通常会自动转为 .ready，仅记日志）
                Logger.warning("本地服务器等待网络路径…: \(error.localizedDescription)")
            case .failed(let error):
                Logger.error("本地服务器监听失败: \(error)")
                readyGroup.leave()
            default:
                break
            }
        }
        listener.start(queue: ServerQueue.shared.queue)
        let waitResult = readyGroup.wait(timeout: .now() + 5)
        // 等待超时或最终状态非 .ready（端口占用 / 权限问题 / 一直等待网络路径）：
        // 一律视为启动失败并抛中文错误，绝不继续走"安装假成功"流程。
        guard waitResult == .success, becameReady else {
            let detail: String
            switch listenerState {
            case .some(.waiting(let error)):
                detail = "正在等待网络路径…（\(error.localizedDescription)）"
            case .some(.failed(let error)):
                detail = "监听器启动失败（\(error.localizedDescription)）"
            case .some(.ready):
                detail = "监听器未能在 5 秒内进入就绪状态"
            default:
                detail = "监听器未进入就绪状态"
            }
            stop()
            Logger.error("本地安装服务器启动失败: \(detail)")
            throw AppError.installFailed("本地安装服务器启动失败：\(detail)")
        }

        // 候选地址：回环优先，然后是所有接口 IP（Wi-Fi/蜂窝/热点）。
        // 注意：蜂窝 CGNAT 的 10.x IP 在设备上不可自访问（流量路由到运营商 NAT
        // 回不到本机）；个人热点模式下 handoff 接口（bridge100/172.20.x.x）通常
        // 可自访问。逐一同步探测，自动选第一个能返回 HTTP 响应的地址。
        // 最多探测 3 个候选（回环 + 前两个接口 IP）：本地安装场景响应毫秒级，
        // 遍历全部接口在蜂窝不可达时会逐个等超时（每个 2s），拖慢"是否安装"提示。
        var candidates: [String] = ["127.0.0.1"]
        candidates.append(contentsOf: Self.allLocalIPAddresses().prefix(2))
        var chosenHost: String? = nil
        var probeLogs: [String] = []
        for host in candidates {
            let url = URL(string: "http://\(host):\(port)")!
            if let status = Self.probe(url) {
                chosenHost = host
                probeLogs.append("\(host) -> HTTP \(status) ✅ 可达")
                break
            } else {
                probeLogs.append("\(host) -> 不可达 ❌")
            }
        }
        let host = chosenHost ?? "127.0.0.1"
        let baseURL = URL(string: "http://\(host):\(port)")!
        self.lastBaseURL = baseURL
        Logger.info("本地安装服务器已启动: \(host):\(port) (协议=HTTP明文) | 候选探测: \(probeLogs.joined(separator: ", "))")
        // itms-services 打开后 App 将立即退到后台：启动静音音频保活，
        // 让进程不被挂起，SpringBoard 才能连上本地服务器下载 manifest/ipa 。
        BackgroundAudioKeepAlive.shared.start()

        Task { [weak self] in
            // 自检只报告可达性，不再要求用户改网络：manifest 走公网 HTTPS（palera.in），
            // 回环 127.0.0.1 在任何网络（蜂窝/VPN 代理）下都对本机可达，
            // 只有回环都不可达才说明服务器本身异常。
            let ok = await self?.isReachable() ?? false
            if ok {
                Logger.info("安装服务器自检结果: 可达（本机 HTTP 正常，可配合公网 manifest 安装）")
            } else {
                Logger.error("安装服务器自检结果: 不可达（本机 HTTP 失败，服务器可能未正常启动）")
            }
        }
        return baseURL
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

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        // 关键诊断分界线：newConnectionHandler 在 TCP accept 时触发。
        // 加这条日志可以区分：TCP 连接到底到没到服务器——
        // 有"收到新连接" → 说明网络可达，问题在后继的 HTTP 请求/安装进程；
        // 没有 → 说明 SpringBoard 根本没连过来（URL 被系统拦截 / 后台监听被挂起）。
        Logger.info("本地服务器收到新连接: \(connection.endpoint.debugDescription)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                Logger.info("本地服务器连接就绪 (.ready)")
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