import Foundation
import Network
import Darwin

final class LocalInstallServer {
    static let shared = LocalInstallServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingIPA: URL?
    private var manifestData: Data?

    /// 持有并发探测结果的盒子，避免在并发 Task 中直接捕获可变变量（Sendable 警告）。
    private final class ProbeHolder: @unchecked Sendable {
        var chosen: String?
        var logs: [String] = []
    }

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
        var request = URLRequest(url: base, timeoutInterval: Timeouts.isReachable)
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
    /// 已保留为兼容兜底；新代码优先使用 probeAsync + TaskGroup 并发探测。
    private static func probe(_ url: URL, timeout: TimeInterval = Timeouts.serverProbe) -> Int? {
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

    /// 异步可取消的探测（Swift Concurrency）：支持 TaskGroup 并发与取消，不阻塞调用线程。
    /// 使用 URLSession 异步 API，支持 Task 取消与超时；本地回环通常毫秒级返回。
    private static func probeAsync(_ url: URL, timeout: TimeInterval = Timeouts.serverProbe) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        do {
            // URLSession.shared.data(for:) 支持异步与取消；超时由 timeoutInterval 控制
            let (_, response) = try await URLSession.shared.data(for: request)
            if Task.isCancelled { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            // 取消或网络失败均视为不可达，保持与同步版本一致语义
            if Task.isCancelled { return nil }
            return nil
        }
    }

    /// 并发探测候选列表，返回首个可达的 host 与日志。使用 TaskGroup 实现并发，
    /// 每个候选使用 0.5s 超时，避免单个蜂窝 CGNAT 地址阻塞；首个成功即取消其余任务。
    /// - Returns: (chosen, logs) chosen 为首个可达的 host（回环优先），logs 为各候选结果
    private static func probeCandidatesConcurrently(candidates: [String], port: UInt16) async -> (chosen: String?, logs: [String]) {
        let perCandidateTimeout: TimeInterval = 0.5
        var logs = Array(repeating: "", count: candidates.count)
        var chosen: String? = nil

        await withTaskGroup(of: (Int, String, Int?).self) { group in
            for (idx, host) in candidates.enumerated() {
                group.addTask {
                    let url = URL(string: "http://\(host):\(port)")!
                    let status = await probeAsync(url, timeout: perCandidateTimeout)
                    return (idx, host, status)
                }
            }
            // 按完成顺序收集；首个成功即记为 chosen 并取消剩余任务
            for await (idx, host, status) in group {
                if Task.isCancelled { break }
                if let status = status {
                    logs[idx] = "\(host) -> HTTP \(status) ✅ 可达"
                    if chosen == nil {
                        chosen = host
                        group.cancelAll()
                        // 仍需让已完成的日志保留，break 前已写入当前项
                        // 为保持“回环优先”语义，稍后会强制回环覆盖
                        break
                    }
                } else {
                    logs[idx] = "\(host) -> 不可达 ❌"
                }
            }
        }
        // 填充被取消未写入的条目
        for i in 0..<logs.count where logs[i].isEmpty {
            logs[i] = "\(candidates[i]) -> 未完成/已取消"
        }
        // 回环优先：若 127.0.0.1 可达，无论其它地址谁先完成都强制选用回环
        if let loopbackIdx = candidates.firstIndex(of: "127.0.0.1"),
           logs[loopbackIdx].contains("✅") {
            chosen = "127.0.0.1"
        }
        let filteredLogs = logs.filter { !$0.isEmpty }
        return (chosen, filteredLogs)
    }

    func start(ipaLocalURL: URL) throws -> URL {
        stop()

        let port = UInt16.random(in: 49152...65535)
        // SECURITY: 默认监听全部接口（0.0.0.0:port，.init(rawValue:) 即 unspecified）
        // 以便 SpringBoard 经任意本地路由可达；明文 HTTP 是本地安装器（AltStore/Feather/Esign）
        // 的标准，127.0.0.1/局域网流量不出设备。更安全的替代方案是显式仅绑定回环：
        //   let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        //   let listener = try NWListener(using: parameters, on: endpoint)
        // 或 parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: ...)
        // 当前保留全接口监听以兼容历史链路，但候选探测仅限 127.0.0.1 + 2 个接口 IP，
        // 默认 chosenHost 回退到 127.0.0.1，避免将 pdp_ip0/utun 等蜂窝地址广泛暴露。
        // iOS 无传统防火墙，端口仅限本地进程与 SpringBoard 访问，切勿转发到公网。
        // 不用 https：iPhone Distribution 证书 EKU 缺 serverAuth，系统会拒绝 TLS 握手。
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 如需强制仅回环，取消下一行注释并替换 listener 初始化为 hostPort 绑定：
        // parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)

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
        let waitResult = readyGroup.wait(timeout: .now() + Timeouts.readyWait)
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
        // 可自访问。并发探测首个可达地址，默认 127.0.0.1。
        // 最多 3 个候选（回环 + 前两个接口 IP），通过 TaskGroup 并发探测（0.5s/候选），
        // 总耗时约 0.5-1.5s，不再串行阻塞 3×(1+1)s，且支持取消。
        var candidates: [String] = ["127.0.0.1"]
        candidates.append(contentsOf: Self.allLocalIPAddresses().prefix(2))
        // 并发探测（TaskGroup）：由于 start 是同步方法，用 semaphore 桥接异步结果，
        // 等待上限仅 1.5s，远小于串行版本，且可取消；超时或全部不可达则回退到 127.0.0.1 + 同步兜底
        let holder = ProbeHolder()
        let probeSemaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await Self.probeCandidatesConcurrently(candidates: candidates, port: port)
            holder.chosen = result.chosen
            holder.logs = result.logs
            probeSemaphore.signal()
        }
        _ = probeSemaphore.wait(timeout: .now() + 1.5)
        var chosenHost = holder.chosen
        var probeLogs = holder.logs
        // Fallback：若并发探测未完成或日志为空（超时/极端调度），同步单点探测 127.0.0.1 兜底
        if chosenHost == nil && probeLogs.isEmpty {
            if let status = Self.probe(URL(string: "http://127.0.0.1:\(port)")!, timeout: 0.5) {
                chosenHost = "127.0.0.1"
                probeLogs = ["127.0.0.1 -> HTTP \(status) ✅ 可达 (fallback)"]
            } else {
                probeLogs = ["127.0.0.1 -> 不可达 ❌ (fallback)"]
            }
        } else if probeLogs.isEmpty {
            probeLogs = candidates.map { "\($0) -> 未探测" }
        }
        // SECURITY: 确保默认回环，即使并发结果异常也绝不暴露 0.0.0.0 或未探测地址
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

        // 64KB 缓冲：HTTP GET 请求（带 Host/UA/Referer 等多 Header）单条请求可能超 8KB，
        // 旧值 8192 在长 Header 时截断 → requestPath 解析失败 → fallback 到 /manifest.plist，
        // 表现为"IPA 下载链接没响应"。64KB 单次能覆盖所有真实 HTTP 请求首部。
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
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