import Foundation
import LosslessEngine

public struct BridgeReply: Equatable, Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }
}

public enum DemoBridge {
    public static let port: UInt16 = 18764

    public static func reply(path: String, utterance: LastUtterance?, html: Data) -> BridgeReply {
        switch resource(path) {
        case "/", "/index.html":
            return BridgeReply(
                status: 200, contentType: "text/html; charset=utf-8", body: html,
                headers: cors)
        case "/last-utterance":
            return json(utterance)
        case "/health":
            return BridgeReply(
                status: 200, contentType: "text/plain; charset=utf-8",
                body: Data("ok\n".utf8), headers: cors)
        default:
            return BridgeReply(
                status: 404, contentType: "text/plain; charset=utf-8",
                body: Data("not found\n".utf8), headers: cors)
        }
    }

    private static func resource(_ path: String) -> String {
        let cut = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let raw = cut.first.map(String.init) ?? "/"
        return raw.isEmpty ? "/" : raw
    }

    private static func json(_ utterance: LastUtterance?) -> BridgeReply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(utterance)) ?? Data("null".utf8)
        return BridgeReply(
            status: 200, contentType: "application/json; charset=utf-8", body: data,
            headers: cors)
    }

    private static let cors: [String: String] = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
        "Cache-Control": "no-store",
    ]
}
