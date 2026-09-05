import Foundation
import Network
import Darwin

final class LocalInstallServer {
    static let shared = LocalInstallServer()

    // 线程约定：以下全部可变状态仅允许在 ServerQueue.shared.queue（串行队列）上读写。
    // NWListener / NWConnection 的所有回调都运行在该队列上，天然一致；
    // 外部入口（start / stop / cacheManifest / isReachable / 活动查询）用 queue.sync
    // 把状态读写收敛进该队列。历史版本在主线程（回前台 stop）、GCD 全局队列
    // （performInstall 的 start/cacheManifest）与服务器队列三方无同步访问同一批
    // 数组/引用，属于未定义行为（大 IPA 传输中回前台即可触发数组并发写崩溃）。
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingIPA: URL?
    private var manifestData: Data?
    private var lastBaseURL: URL?
    /// 服务器是否处于运行状态（start 就绪到 stop 之间）：stop 的幂等判定与日志降噪
    private var isRunning = false
    /// 启动进行中（startOnce 进入到 ready 等待结束之间）：此窗口内 isRunning 尚为
    /// false，"等空闲"判定若只看 isRunning，并发安装会误判空闲并抢先 startOnce，
    /// 其入口 stop() 会取消本会话刚就绪的监听器（互杀）。
    private var isStarting = false
    /// 本次服务器启动时刻：安装确认弹窗可能停留任意久（期间无任何连接活动），
    /// 回前台/保活超时除活动时间外还看会话时长，避免弹窗停留较久的用户
    /// 回 App 后服务器被误停
    private var startedDate: Date?
    /// 最近一次安装活动时间（itms-services 打开成功 / 新连接 / 收到请求）：
    /// 回前台与保活超时据此判断安装是否仍在进行，绝不打断进行中的安装下载
    private var lastActivityDate: Date?
    /// 上一个会话的 IPA 是否已完整发出（EOF）及发完时刻：连续安装的"等空闲"
    /// 判定依据——整个 IPA 发完后 SpringBoard 不再需要旧服务器，可安全重启。
    /// 仅在服务器串行队列读写（sendFileChunks 及其 send 完成回调运行在该队列）。
    private var transferCompletedDate: Date?

    /// 持有并发探测结果的盒子，避免在并发 Task 中直接捕获可变变量（Sendable 警告）。
    private final class ProbeHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _logs: [String] = []
        /// 等待超时后调用线程仍会读取：读写在锁内完成，否则对非原子数组的
        /// 无同步读写是 UB（Task 写 vs 调用线程读）。
        var logs: [String] {
            get { lock.lock(); defer { lock.unlock() }; return _logs }
            set { lock.lock(); defer { lock.unlock() }; _logs = newValue }
        }
    }

    /// ready 等待结果盒子：stateUpdateHandler 在服务器队列写入，调用线程在
    /// semaphore.wait 返回后读取，用锁保证可见性与枚举关联值读取安全。
    private final class ReadyBox: @unchecked Sendable {
        let lock = NSLock()
        var becameReady = false
        var failureDetail: String?
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
        let base: URL? = ServerQueue.shared.queue.sync { lastBaseURL }
        guard let base = base else { return false }
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

    /// 并发探测候选地址（仅用于诊断日志）：每个候选 0.5s 超时，汇总各地址可达性。
    /// 注意：fetchurl 一律固定使用 127.0.0.1（见 start）——回环对本机监听器必然可达，
    /// 不再按"首个可达者当选"。旧实现里若回环探测恰好被取消（其余地址先成功触发
    /// cancelAll），日志被填成"已取消"、回环覆盖条件不成立，会误选 utun/VPN 接口地址，
    /// SpringBoard 对该地址不可达，安装概率性失败。
    private static func probeCandidatesConcurrently(candidates: [String], port: UInt16) async -> [String] {
        let perCandidateTimeout: TimeInterval = 0.5
        var logs = Array(repeating: "", count: candidates.count)

        await withTaskGroup(of: (Int, String).self) { group in
            for (idx, host) in candidates.enumerated() {
                group.addTask {
                    let url = URL(string: "http://\(host):\(port)")!
                    let status = await probeAsync(url, timeout: perCandidateTimeout)
                    let log = status.map { "\(host) -> HTTP \($0) ✅ 可达" } ?? "\(host) -> 不可达 ❌"
                    return (idx, log)
                }
            }
            for await (idx, log) in group {
                logs[idx] = log
            }
        }
        return logs.filter { !$0.isEmpty }
    }

    /// 等待上一个安装会话空闲（连续/批量安装防互踩）。满足其一即空闲：
    /// 1) 服务器既未运行也未在启动中（从未启动 / 已 stop）——启动中的会话
    ///    （ready 等待，最长 5 秒）isRunning 仍为 false，不能据此判空闲；
    /// 2) 上一个会话的 IPA 已完整发出（EOF / 传输中止）且距今超过 5 秒——
    ///    SpringBoard 下载完成后（或已断开）不再需要旧服务器，可安全重启；
    /// 3) 等待超过 15 分钟硬上限：用户把系统安装确认弹窗无限期挂着时放弃等待，
    ///    由调用方给出明确错误（而不是掐死上一个安装）。
    /// 期间并发 stop() 会把 isRunning 置 false，循环随即退出。
    private func waitForPreviousInstallIdle() throws {
        let hardCap: TimeInterval = 15 * 60
        let began = Date()
        while true {
            var idle = false
            ServerQueue.shared.queue.sync {
                idle = (!isRunning && !isStarting)
                    || (transferCompletedDate.map { Date().timeIntervalSince($0) >= 5 } ?? false)
            }
            if idle { return }
            if Date().timeIntervalSince(began) >= hardCap {
                throw AppError.installFailed("上一次安装仍在进行（已等待 15 分钟），请先完成或取消该安装再试")
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    func start(ipaLocalURL: URL) throws -> URL {
        try waitForPreviousInstallIdle()

        // 端口重试：49152-65535 与系统临时源端口同段，偶发 EADDRINUSE
        // （.failed 在 ready 等待中报告）。换随机端口重试最多 3 次，而不是
        // 一次失败就让整个安装挂掉。
        var lastDetail = "监听器未能在 \(Int(Timeouts.readyWait)) 秒内进入就绪状态"
        for attempt in 1...3 {
            do {
                return try startOnce(ipaLocalURL: ipaLocalURL)
            } catch let error as AppError {
                lastDetail = error.localizedDescription
                Logger.warning("本地安装服务器启动失败（第 \(attempt) 次尝试）: \(lastDetail)")
            }
        }
        throw AppError.installFailed("本地安装服务器启动失败：\(lastDetail)")
    }

    /// 单次启动尝试（stop 旧会话 → 随机端口监听 → 等 ready → 探测 → 保活）。
    /// 抛出的 AppError 描述为具体原因（无"启动失败"前缀），由 start 统一包装。
    private func startOnce(ipaLocalURL: URL) throws -> URL {
        // 先于入口 stop() 登记启动状态：从现在到 isRunning 置 true 之间是"启动中"
        // 窗口，必须让并发安装的"等空闲"判定看到忙（详见 isStarting 注释）。
        // defer 复位覆盖全部退出路径（就绪成功 / ready 超时抛错 / 异常），且在
        // isRunning 置 true 之后才执行，两标志之间不存在同时为 false 的空窗。
        ServerQueue.shared.queue.sync { isStarting = true }
        defer { ServerQueue.shared.queue.sync { isStarting = false } }
        stop()

        let port = UInt16.random(in: 49152...65535)
        // SECURITY: 默认监听全部接口（0.0.0.0:port，.init(rawValue:) 即 unspecified）
        // 以便 SpringBoard 经任意本地路由可达；明文 HTTP 是本地安装器（AltStore/Feather/Esign）
        // 的标准，127.0.0.1/局域网流量不出设备。更安全的替代方案是显式仅绑定回环：
        //   let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        //   let listener = try NWListener(using: parameters, on: endpoint)
        // 或 parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: ...)
        // 当前保留全接口监听以兼容历史链路，但 manifest 的 fetchurl 固定 127.0.0.1，
        // 避免将 pdp_ip0/utun 等蜂窝地址广泛暴露。
        // 不用 https：iPhone Distribution 证书 EKU 缺 serverAuth，系统会拒绝 TLS 握手。
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        // 状态写入收敛到服务器串行队列（先登记再 start：并发 stop() 随时可以取消它）
        ServerQueue.shared.queue.sync {
            self.listener = listener
            self.servingIPA = ipaLocalURL
            // 新会话：清空上一会话的传输完成标记（本会话的 EOF 由 sendFileChunks 重新写入）
            self.transferCompletedDate = nil
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        // start 是异步的：listener 需要进入 .ready 状态才会接受连接。
        // 若不等待就立刻打开 itms-services，SpringBoard 的连接请求会落在
        // 未就绪的监听器上被丢弃（日志表现为"没有收到任何请求"）。
        // 同时记录实际 listener 状态用于失败判定：.failed（端口被占用/权限不足）
        // 与 .waiting（网络路径不可用）都会造成"安装假成功"。
        // 用 semaphore 替代 DispatchGroup：.cancelled（并发 stop 触发）等状态
        // 可能多次触发，signal 幂等不会像多 leave() 一样崩溃。
        let readySemaphore = DispatchSemaphore(value: 0)
        let readyBox = ReadyBox()
        listener.stateUpdateHandler = { state in
            readyBox.lock.lock()
            defer { readyBox.lock.unlock() }
            switch state {
            case .ready:
                readyBox.becameReady = true
                readySemaphore.signal()
            case .waiting(let error):
                // .waiting 单独提示：等待网络路径（通常会自动转为 .ready，仅记日志）
                readyBox.failureDetail = "正在等待网络路径…（\(error.localizedDescription)）"
                Logger.warning("本地服务器等待网络路径…: \(error.localizedDescription)")
            case .failed(let error):
                readyBox.failureDetail = "监听器启动失败（\(error.localizedDescription)）"
                Logger.error("本地服务器监听失败: \(error)")
                readySemaphore.signal()
            case .cancelled:
                // 被并发 stop() 取消：同样唤醒等待者，避免白等满 5 秒
                if readyBox.failureDetail == nil {
                    readyBox.failureDetail = "监听器被取消"
                }
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: ServerQueue.shared.queue)
        let waitResult = readySemaphore.wait(timeout: .now() + Timeouts.readyWait)
        // 等待超时或最终状态非 .ready（端口占用 / 权限问题 / 一直等待网络路径）：
        // 一律视为启动失败并抛中文错误，绝不继续走"安装假成功"流程。
        readyBox.lock.lock()
        let becameReady = readyBox.becameReady
        let failureDetail = readyBox.failureDetail
        readyBox.lock.unlock()
        guard waitResult == .success, becameReady else {
            let detail: String
            switch failureDetail {
            case .some(let message):
                detail = (waitResult == .success) ? message : "\(message)（或未能在 \(Int(Timeouts.readyWait)) 秒内就绪）"
            case .none:
                detail = waitResult == .success ? "监听器未进入就绪状态" : "监听器未能在 \(Int(Timeouts.readyWait)) 秒内进入就绪状态"
            }
            stop()
            Logger.error("本地安装服务器启动失败: \(detail)")
            throw AppError.installFailed(detail)
        }

        // 候选地址探测仅用于日志诊断（回环 + 前两个接口 IP，0.5s 并发）。
        // fetchurl 固定使用 127.0.0.1：回环对本机监听器必然可达（同设备 loopback
        // 不经外部路由，不受 Wi-Fi/VPN/蜂窝接口变化影响），且不会把蜂窝 CGNAT /
        // utun 地址暴露进 manifest。
        let candidates: [String] = ["127.0.0.1"] + Array(Self.allLocalIPAddresses().prefix(2))
        let holder = ProbeHolder()
        let probeSemaphore = DispatchSemaphore(value: 0)
        Task {
            let logs = await Self.probeCandidatesConcurrently(candidates: candidates, port: port)
            holder.logs = logs
            probeSemaphore.signal()
        }
        _ = probeSemaphore.wait(timeout: .now() + 0.8)
        let probeLogs = holder.logs.isEmpty ? candidates.map { "\($0) -> 未探测" } : holder.logs

        let host = "127.0.0.1"
        let baseURL = URL(string: "http://\(host):\(port)")!
        ServerQueue.shared.queue.sync {
            self.lastBaseURL = baseURL
            self.isRunning = true
            self.startedDate = Date()
        }
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
        ServerQueue.shared.queue.sync { manifestData = data }
    }

    /// 记录一次"安装已发起"活动（itms-services 打开成功后调用，任意线程安全）：
    /// 回前台/保活超时据此识别"用户还在安装确认弹窗/下载进行中"，不停服务器。
    func noteInstallOpened() {
        ServerQueue.shared.queue.sync { lastActivityDate = Date() }
    }

    /// 最近 interval 秒内是否有安装相关活动（itms-services 打开 / 新连接 / 收到请求 /
    /// 分块传输）。供回前台生命周期与保活超时判断：安装链路进行中绝不能停服务器。
    func hasRecentInstallActivity(within interval: TimeInterval) -> Bool {
        ServerQueue.shared.queue.sync {
            guard let last = lastActivityDate else { return false }
            return Date().timeIntervalSince(last) < interval
        }
    }

    /// 服务器是否处于"安装会话"中（已就绪且本次 start 距今不超过 window）：
    /// 与 hasRecentInstallActivity 互补——安装确认弹窗停留期间没有任何活动事件，
    /// 仅靠活动窗口会掐断"弹窗停留较久后用户才回 App"的场景。
    func isInstallSessionActive(within window: TimeInterval) -> Bool {
        ServerQueue.shared.queue.sync {
            guard isRunning, let started = startedDate else { return false }
            return Date().timeIntervalSince(started) < window
        }
    }

    func stop() {
        var wasRunning = false
        ServerQueue.shared.queue.sync {
            wasRunning = isRunning
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            servingIPA = nil
            manifestData = nil
            lastBaseURL = nil
            isRunning = false
            startedDate = nil
            transferCompletedDate = nil
        }
        if wasRunning {
            Logger.info("本地安装服务器已停止")
        }
        BackgroundAudioKeepAlive.shared.stop()
    }

    private func handleConnection(_ connection: NWConnection) {
        // 本方法由 newConnectionHandler 触发，运行在 ServerQueue 上：
        // connections / lastActivityDate 的读写都在同一串行队列，无并发。
        connections.append(connection)
        lastActivityDate = Date()
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

        // TCP 不保证请求头一次到达：循环累积直到出现 "\r\n\r\n"（请求头结束标记）
        // 再解析请求行。旧实现单次 receive（≥1 字节即回调）会把半包请求
        // （如首包只有 "GET /man"）解析成错误路径 → 404 → 安装静默失败。
        receiveRequest(connection: connection, buffer: Data())
    }

    /// 循环累积接收请求头，直到出现 "\r\n\r\n" 或连接关闭。
    private func receiveRequest(connection: NWConnection, buffer: Data) {
        // 请求头上限 64KB：正常 HTTP GET 请求远小于该值，超出视为异常直接断开
        guard buffer.count <= 65536 else {
            Logger.info("本地服务器请求头超限，断开连接")
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                Logger.error("本地服务器连接错误: \(error)")
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data = data, !data.isEmpty {
                nextBuffer.append(data)
            }
            if let headerEnd = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = nextBuffer.subdata(in: nextBuffer.startIndex..<headerEnd.lowerBound)
                if let request = String(data: headerData, encoding: .utf8) {
                    self.respond(request: request, connection: connection)
                } else {
                    connection.cancel()
                }
                return
            }
            if isComplete {
                // 对端半关闭且请求头不完整：旧实现会合成 "GET /manifest.plist"，
                // 若客户端实际请求的是 .ipa 会把 XML manifest 当 IPA 发回（语义错误）。
                // 改为直接断开。
                connection.cancel()
                return
            }
            self.receiveRequest(connection: connection, buffer: nextBuffer)
        }
    }

    private func respond(request: String, connection: NWConnection) {
        let path = requestPath(from: request)
        lastActivityDate = Date()
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
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else {
                // 头部发送失败（对端已断开/连接被取消）：关闭句柄并断开，
                // 绝不进入分块发送循环
                try? handle.close()
                connection.cancel()
                // 与 sendFileChunks 失败分支同理：对端断开即本会话已死亡，
                // 须记录传输结束时刻，否则批量安装的下一个"等空闲"会空转到
                // 15 分钟硬上限。完成回调运行在服务器串行队列，直接写安全。
                if error != nil {
                    self?.transferCompletedDate = Date()
                }
                return
            }
            self.sendFileChunks(from: handle, connection: connection)
        })
    }

    private func sendFileChunks(from handle: FileHandle, connection: NWConnection) {
        // 流式发送也是安装活动：SpringBoard 对 .ipa 只发一次 GET，整个下载期间
        // 不再产生任何新请求——不在分块循环里刷新活动时间戳的话，超过活动窗口
        // 的大包传输会被回前台判定/保活超时误判为"无活动"而中断（多 GB 包、
        // 慢速磁盘即可超过 150/240 秒）。本方法运行在服务器串行队列，直接写。
        lastActivityDate = Date()
        let chunkSize = 256 * 1024
        // read(upToCount:) 是 throwing API（iOS 13.4+）：I/O 错误（非 EOF）时抛错，
        // 旧实现 readData(ofLength:) 对 I/O 错误直接抛 ObjC 异常且未捕获 → 进程崩溃
        // （EOF 返回 nil）。这里把"错误"与"EOF"统一折叠为空 Data → 走下方
        // 收尾分支（关句柄 + 断开），一次失败的安装好过整个 App 闪退。
        let data = (try? handle.read(upToCount: chunkSize)) ?? Data()
        if data.isEmpty {
            // 整个 IPA 已完整发出：记录 EOF 时刻。连续安装的下一个 start()
            // 据此判定"上一个会话已空闲"（见 waitForPreviousInstallIdle）。
            transferCompletedDate = Date()
            try? handle.close()
            self.connections.removeAll { $0 === connection }
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else {
                // 发送失败（用户在系统弹窗取消安装 / 连接被 stop() 取消 / 网络切换）：
                // 立即停止读取。旧实现忽略 error 继续递归，会把整个 IPA 从磁盘读完、
                // 发起几百次注定失败的 send（耗 IO/CPU/电量，句柄也迟迟不关）。
                // 注意：此处 self 可能已释放，不触碰 connections（连接取消后由
                // stateUpdateHandler 的 .cancelled 分支在服务器队列上移除）。
                try? handle.close()
                connection.cancel()
                // 对端断开即本次安装会话已死亡：与 EOF 分支同样记录传输结束时刻，
                // 否则连续安装的下一个"等空闲"永远等不到标记，空转到 15 分钟硬上限。
                // 仅在真发送失败时写（weak self 失效但未出错时无事可做）；完成回调
                // 运行在服务器串行队列，与 EOF 分支一致直接写。连接被本方 stop()
                // 取消时多写一次无害：stop 已置 isRunning=false，判定照样视为空闲。
                if error != nil {
                    self?.transferCompletedDate = Date()
                }
                return
            }
            self.sendFileChunks(from: handle, connection: connection)
        })
    }

    private func sendAndClose(_ response: Data, connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self = self else {
                connection.cancel()
                return
            }
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
