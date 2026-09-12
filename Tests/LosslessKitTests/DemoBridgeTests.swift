import Foundation
import Testing

@testable import LosslessEngine
@testable import LosslessKit

@Suite("Demo bridge")
struct DemoBridgeTests {
    @Test("the page is the index")
    func servesThePage() {
        let html = Data("<html></html>".utf8)
        let reply = DemoBridge.reply(path: "/", utterance: nil, html: html)
        #expect(reply.status == 200)
        #expect(reply.contentType.hasPrefix("text/html"))
        #expect(reply.body == html)
    }

    @Test("no utterance yet is JSON null")
    func emptyUtteranceIsNull() {
        let reply = DemoBridge.reply(path: "/last-utterance", utterance: nil, html: Data())
        #expect(reply.status == 200)
        #expect(String(data: reply.body, encoding: .utf8) == "null")
    }

    @Test("a published utterance is the JSON the page polls")
    func publishedUtterance() throws {
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Book a table for six, sorry, four.",
                clean: "Book a table for six."))
        let utterance = LastUtterance(
            graph: graph, compiled: graph.compiled, cleanupDegraded: false)
        let reply = DemoBridge.reply(
            path: "/last-utterance?ts=1", utterance: utterance, html: Data())
        #expect(reply.status == 200)
        let decoded = try JSONDecoder().decode(LastUtterance.self, from: reply.body)
        #expect(decoded.claims.contains { $0.before == "six" && $0.after == "four" })
    }

    @Test("unknown paths 404")
    func unknownPath() {
        let reply = DemoBridge.reply(path: "/secret", utterance: nil, html: Data())
        #expect(reply.status == 404)
    }
}
