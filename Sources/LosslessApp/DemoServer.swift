import AppKit
import Foundation
import LosslessEngine
import LosslessKit
import Network

final class DemoServer: @unchecked Sendable {
    static let shared = DemoServer()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lossless.demo")
    private let html: Data
    private let sessionSecret = UUID().uuidString
    private var utterance: LastUtterance?
    private var listener: NWListener?
    private var sockets: [NWConnection] = []
    private var pending: [Data] = []
    private var inbound: (@Sendable (ActionInbound) -> Void)?

    private init() {
        html = Self.loadHTML()
    }

    func start() {
        lock.lock()
        if listener != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let port = NWEndpoint.Port(rawValue: DemoBridge.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters) else {
            Diagnostics.note("demo listen failed on 127.0.0.1:\(DemoBridge.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        lock.lock()
        if self.listener != nil {
            lock.unlock()
            listener.cancel()
            return
        }
        self.listener = listener
        lock.unlock()
    }

    func publish(_ utterance: LastUtterance) {
        lock.lock()
        self.utterance = utterance
        lock.unlock()
        start()
    }

    func open() {
        start()
        DispatchQueue.main.async {
            guard let url = URL(string: "http://127.0.0.1:\(DemoBridge.port)/") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func onInbound(_ handler: @escaping @Sendable (ActionInbound) -> Void) {
        lock.lock()
        inbound = handler
        lock.unlock()
    }

    func send(_ message: ActionOutbound) {
        start()
        let payload = ActionWire.encode(message)
        lock.lock()
        let targets = sockets
        if targets.isEmpty {
            pending.append(payload)
            lock.unlock()
            return
        }
        lock.unlock()
        let frame = WebSocket.encode(.text(String(data: payload, encoding: .utf8) ?? ""))
        for socket in targets {
            write(socket, frame)
        }
    }

    private func currentUtterance() -> LastUtterance? {
        lock.lock()
        defer { lock.unlock() }
        return utterance
    }

    private func stampedHTML() -> Data {
        guard let text = String(data: html, encoding: .utf8) else { return html }
        return Data(
            text.replacingOccurrences(of: "__LOSSLESS_SESSION__", with: sessionSecret).utf8)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(from: connection, buffer: Data())
    }

    private func read(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            if Self.headersComplete(buffer) {
                self.respond(on: connection, request: buffer)
                return
            }
            if complete || error != nil {
                if buffer.isEmpty {
                    connection.cancel()
                } else {
                    self.respond(on: connection, request: buffer)
                }
                return
            }
            self.read(from: connection, buffer: buffer)
        }
    }

    private func respond(on connection: NWConnection, request: Data) {
        guard let (method, path) = Self.requestLine(request) else {
            connection.cancel()
            return
        }
        if method == "GET", WebSocket.isUpgrade(request, path: path) {
            upgrade(connection, request: request)
            return
        }
        let reply = DemoBridge.reply(path: path, utterance: currentUtterance(), html: stampedHTML())
        connection.send(
            content: Self.encode(reply, method: method),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    private func upgrade(_ connection: NWConnection, request: Data) {
        guard let (_, path) = Self.requestLine(request),
            WebSocket.query(path, "s") == sessionSecret,
            let origin = WebSocket.origin(request),
            WebSocket.loopbackOrigin(origin),
            let key = WebSocket.requestKey(request)
        else {
            connection.cancel()
            return
        }
        lock.lock()
        sockets.append(connection)
        let queued = pending
        pending.removeAll()
        lock.unlock()
        connection.send(
            content: WebSocket.handshake(key),
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                for payload in queued {
                    self.write(
                        connection,
                        WebSocket.encode(.text(String(data: payload, encoding: .utf8) ?? "")))
                }
                self.readFrames(from: connection, buffer: Data())
            })
    }

    private func readFrames(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            while let message = WebSocket.take(&buffer) {
                switch message {
                case .text(let text):
                    if let inbound = ActionWire.decode(Data(text.utf8)) {
                        self.dispatch(inbound)
                    }
                case .ping(let payload):
                    self.write(connection, WebSocket.encode(.pong(payload)))
                case .pong:
                    break
                case .close:
                    self.drop(connection)
                    return
                case .discarded:
                    break
                }
            }
            if complete || error != nil {
                self.drop(connection)
                return
            }
            self.readFrames(from: connection, buffer: buffer)
        }
    }

    private func dispatch(_ message: ActionInbound) {
        lock.lock()
        let handler = inbound
        lock.unlock()
        handler?(message)
    }

    private func write(_ connection: NWConnection, _ data: Data) {
        guard !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func drop(_ connection: NWConnection) {
        lock.lock()
        sockets.removeAll { $0 === connection }
        lock.unlock()
        connection.cancel()
    }

    private static func headersComplete(_ data: Data) -> Bool {
        data.range(of: Data("\r\n\r\n".utf8)) != nil
            || data.range(of: Data("\n\n".utf8)) != nil
    }

    private static func requestLine(_ data: Data) -> (String, String)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]).uppercased(), String(parts[1]))
    }

    private static func encode(_ reply: BridgeReply, method: String) -> Data {
        let options = method == "OPTIONS"
        let status = options ? 204 : reply.status
        let body = options ? Data() : reply.body
        var header = "HTTP/1.1 \(status) \(phrase(status))\r\n"
        header += "Content-Type: \(reply.contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (name, value) in reply.headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private static func phrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 404: "Not Found"
        default: "OK"
        }
    }

    private static func loadHTML() -> Data {
        if let url = Bundle.main.url(
            forResource: "index", withExtension: "html", subdirectory: "page"),
            let data = try? Data(contentsOf: url)
        {
            return data
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("demo/page/index.html")
        if let data = try? Data(contentsOf: cwd) { return data }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("demo/page/index.html")
            if let data = try? Data(contentsOf: candidate) { return data }
            directory.deleteLastPathComponent()
        }
        return Data()
    }
}
