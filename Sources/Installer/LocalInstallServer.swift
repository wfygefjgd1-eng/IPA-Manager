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
        let parameters = NWParameters(tls: Self.tlsOptions())
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        self.listener = listener
        self.servingIPA = ipaLocalURL

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: ServerQueue.shared.queue)
        Logger.info("本地安装服务器已启动: 127.0.0.1:\(port)")
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
        Logger.info("本地安装服务器已停止")
    }

    private static func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        if let identity = ServerIdentityProvider.shared.currentIdentity {
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        }
        return options
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
        Logger.debug("本地服务器请求: \(path)")

        let response: Data
        if path == "/manifest.plist" {
            let manifest = manifestData ?? Data()
            response = httpResponse(status: 200, contentType: "application/xml", body: manifest)
        } else if path.hasSuffix(".ipa") {
            if let ipaURL = servingIPA, let body = try? Data(contentsOf: ipaURL) {
                response = httpResponse(status: 200, contentType: "application/octet-stream", body: body)
            } else {
                response = httpResponse(status: 404, contentType: "text/plain", body: Data("IPA not found".utf8))
            }
        } else {
            response = httpResponse(status: 404, contentType: "text/plain", body: Data("Not found".utf8))
        }

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