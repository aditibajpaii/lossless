import CryptoKit
import Foundation

public enum WebSocket {
    public static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public enum Message: Equatable, Sendable {
        case text(String)
        case ping(Data)
        case pong(Data)
        case close
        case discarded
    }

    public static func accept(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    public static func handshake(_ key: String) -> Data {
        var header = "HTTP/1.1 101 Switching Protocols\r\n"
        header += "Upgrade: websocket\r\n"
        header += "Connection: Upgrade\r\n"
        header += "Sec-WebSocket-Accept: \(accept(key))\r\n"
        header += "\r\n"
        return Data(header.utf8)
    }

    public static func requestKey(_ request: Data) -> String? {
        header(request, "sec-websocket-key")
    }

    public static func origin(_ request: Data) -> String? {
        header(request, "origin")
    }

    public static func header(_ request: Data, _ name: String) -> String? {
        guard let text = String(data: request, encoding: .utf8) else { return nil }
        let needle = name.lowercased() + ":"
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix(needle) {
                return trimmed.dropFirst(needle.count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    public static func query(_ path: String, _ name: String) -> String? {
        let cut = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard cut.count == 2 else { return nil }
        for pair in cut[1].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == name else { continue }
            return parts.count == 2 ? String(parts[1]) : ""
        }
        return nil
    }

    public static func isUpgrade(_ request: Data, path: String) -> Bool {
        let resource =
            path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? "/"
        guard resource == "/actions" else { return false }
        guard requestKey(request) != nil else { return false }
        let lower = String(data: request, encoding: .utf8)?.lowercased() ?? ""
        return lower.contains("upgrade: websocket")
    }

    public static func loopbackOrigin(_ origin: String) -> Bool {
        origin == "http://127.0.0.1:\(DemoBridge.port)"
            || origin == "http://localhost:\(DemoBridge.port)"
    }

    public static func encode(_ message: Message) -> Data {
        switch message {
        case .text(let text):
            frame(opcode: 0x1, payload: Data(text.utf8))
        case .ping(let payload):
            frame(opcode: 0x9, payload: payload)
        case .pong(let payload):
            frame(opcode: 0xA, payload: payload)
        case .close:
            frame(opcode: 0x8, payload: Data())
        case .discarded:
            Data()
        }
    }

    public static func take(_ buffer: inout Data) -> Message? {
        guard buffer.count >= 2 else { return nil }
        let start = buffer.startIndex
        let b0 = buffer[start]
        let b1 = buffer[start + 1]
        let opcode = b0 & 0x0F
        let masked = b1 & 0x80 != 0
        var length = Int(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for index in 0..<8 {
                length = (length << 8) | Int(buffer[start + 2 + index])
            }
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        let header = offset + maskLength
        guard buffer.count >= header, length <= buffer.count - header else { return nil }
        let payloadStart = start + header
        let payloadEnd = payloadStart + length
        var payload = [UInt8](buffer[payloadStart..<payloadEnd])
        if masked {
            let mask = [UInt8](buffer[(start + offset)..<(start + offset + 4)])
            for index in payload.indices {
                payload[index] ^= mask[index % 4]
            }
        }
        buffer.removeSubrange(start..<payloadEnd)
        let body = Data(payload)
        switch opcode {
        case 0x1:
            return .text(String(data: body, encoding: .utf8) ?? "")
        case 0x8:
            return .close
        case 0x9:
            return .ping(body)
        case 0xA:
            return .pong(body)
        default:
            return .discarded
        }
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 0xFFFF {
            out.append(126)
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(127)
            var length = UInt64(count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        }
        out.append(payload)
        return out
    }
}
