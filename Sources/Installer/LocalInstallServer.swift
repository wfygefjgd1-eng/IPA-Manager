import Foundation
import Network

final class LocalInstallServer {
    static let shared = LocalInstallServer()

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingIPA: URL?
    private var manifestData: Data?

    func start(ipaLocalURL: URL) throws -> URL {
        stop()

        let port = UInt16.random(in: 49152...65535)
        // 用 HTTPS：Apple 企业部署文档要求 itms-services 的 manifest URL 必须是 HTTPS，
        // iOS 27 系统安装器会直接拒绝 http://127.0.0.1 明文（1.0.50 日志显示请求根本没
        // 到达服务器——不是响应问题，是 URL 协议被系统层拦截）。
        // 本服务器使用 iPhone Distribution 证书的 TLS 身份（已由传统 p12 重打包修复，
        // 证书由 Apple 根签发、系统信任），SpringBoard 可完成握手并下载 manifest/ipa。
        // 传输全程在 127.0.0.1 回环内，数据不出设备。
        let identityProvider = ServerIdentityProvider.shared
        let hasTLSIdentity = identityProvider.currentIdentity != nil || identityProvider.currentCertKey != nil
        let parameters: NWParameters
        if hasTLSIdentity {
            parameters = NWParameters(tls: identityProvider.tlsOptions())
        } else {
            parameters = NWParameters.tcp
            Logger.warning("TLS 身份不可用，回退明文 HTTP")
        }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

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
        Logger.info("本地安装服务器已启动: 127.0.0.1:\(port) (TLS=\(parameters.tls != nil))")
        // itms-services 打开后 App 将立即退到后台：启动静音音频保活，
        // 让进程不被挂起，SpringBoard 才能连上本地服务器下载 manifest/ipa 。
        BackgroundAudioKeepAlive.shared.start()
        return URL(string: "https://127.0.0.1:\(port)")!
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