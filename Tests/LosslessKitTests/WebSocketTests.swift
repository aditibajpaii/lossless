import Foundation
import Testing

@testable import LosslessKit

@Suite("WebSocket frames")
struct WebSocketTests {
    @Test("a short buffer leaves the bytes alone")
    func shortFrameIsIncomplete() {
        var buffer = Data([0x81])
        #expect(WebSocket.take(&buffer) == nil)
        #expect(buffer == Data([0x81]))
    }

    @Test("an unmasked text frame decodes")
    func unmaskedText() {
        var buffer = Data([0x81, 0x02, 0x68, 0x69])
        #expect(WebSocket.take(&buffer) == .text("hi"))
        #expect(buffer.isEmpty)
    }

    @Test("a masked text frame unmasks without trapping")
    func maskedText() {
        let mask: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let payload: [UInt8] = [0x68 ^ 0x01, 0x69 ^ 0x02]
        var buffer = Data([0x81, 0x82] + mask + payload)
        #expect(WebSocket.take(&buffer) == .text("hi"))
        #expect(buffer.isEmpty)
    }

    @Test("a slice with a nonzero start index still unmasks")
    func nonzeroStartIndex() {
        let mask: [UInt8] = [0x0A, 0x0B, 0x0C, 0x0D]
        let payload: [UInt8] = [0x68 ^ 0x0A, 0x69 ^ 0x0B]
        let raw = Data([0xFF, 0x81, 0x82] + mask + payload)
        var buffer = raw[1..<raw.endIndex]
        #expect(buffer.startIndex == 1)
        #expect(WebSocket.take(&buffer) == .text("hi"))
    }

    @Test("a ping frame comes back as ping")
    func ping() {
        var buffer = Data([0x89, 0x00])
        #expect(WebSocket.take(&buffer) == .ping(Data()))
    }

    @Test("an upgrade on /actions is accepted")
    func upgradePath() {
        let request = Data(
            """
            GET /actions?s=secret HTTP/1.1\r
            Upgrade: websocket\r
            Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
            Origin: http://127.0.0.1:18764\r
            \r

            """.utf8)
        #expect(WebSocket.isUpgrade(request, path: "/actions?s=secret"))
        #expect(WebSocket.query("/actions?s=secret", "s") == "secret")
        #expect(WebSocket.loopbackOrigin("http://127.0.0.1:18764"))
        #expect(!WebSocket.loopbackOrigin("https://example.com"))
        #expect(WebSocket.origin(request) == "http://127.0.0.1:18764")
    }
}
