import Foundation
import Testing

@testable import LosslessEngine
@testable import LosslessKit

@Suite("Action wire")
struct ActionWireTests {
    @Test("a propose frame becomes an ActionProposal")
    func decodesPropose() {
        let json = """
            {"type":"propose","utteranceId":"u1","origin":"http://127.0.0.1:18764","document":"doc-1","tool":"reserveTable","fields":[{"name":"partySize","value":"4"}],"readOnly":false}
            """
        let parsed = ActionWire.decode(Data(json.utf8))
        guard case .propose(let proposal) = parsed else {
            Issue.record("expected propose, got \(String(describing: parsed))")
            return
        }
        #expect(proposal.utteranceId == "u1")
        #expect(proposal.tool == "reserveTable")
        #expect(proposal.fields.first?.value == "4")
        #expect(!proposal.readOnly)
    }

    @Test("hello, noTools, executed and error decode")
    func decodesOtherInbound() {
        #expect(
            ActionWire.decode(
                Data(
                    #"{"type":"hello","origin":"http://127.0.0.1:18764","document":"doc"}"#.utf8))
                == .hello(origin: "http://127.0.0.1:18764", document: "doc"))
        #expect(
            ActionWire.decode(Data(#"{"type":"noTools","utteranceId":"u1"}"#.utf8))
                == .noTools(utteranceId: "u1"))
        #expect(
            ActionWire.decode(
                Data(#"{"type":"executed","utteranceId":"u1","result":"Reserved for 4."}"#.utf8))
                == .executed(utteranceId: "u1", result: "Reserved for 4."))
        #expect(
            ActionWire.decode(Data(#"{"type":"error","message":"no table"}"#.utf8))
                == .error(message: "no table"))
    }

    @Test("an execute frame carries tool arguments")
    func encodesExecute() throws {
        let data = ActionWire.encode(
            .execute(
                utteranceId: "u1", tool: "reserveTable", arguments: ["partySize": "4"]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "execute")
        #expect(object?["tool"] as? String == "reserveTable")
        let arguments = object?["arguments"] as? [String: String]
        #expect(arguments?["partySize"] == "4")
    }

    @Test("a decision frame names the verdict")
    func encodesDecision() throws {
        let data = ActionWire.encode(
            .decision(utteranceId: "u1", verdict: "block", reason: "six → four"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "decision")
        #expect(object?["verdict"] as? String == "block")
        #expect(object?["reason"] as? String == "six → four")
    }
}
