import LosslessEngine
import Testing

@testable import LosslessIntent

private func graph(_ raw: String, _ clean: String) -> RepairGraph {
    RepairEngine.analyze(TranscriptPair(raw: raw, clean: clean))
}

@Suite("Intent gate")
struct IntentGateTests {
    @Test("a consequential action carrying a rejected value is blocked")
    func blocksRejectedValues() {
        let transcript = graph("Book a table for six, sorry, four.", "Book a table for six.")
        let action = ProposedAction(
            tool: "reserveTable", fields: [ProposedField(name: "partySize", value: "6")])
        let decision = IntentGate.check(action, against: transcript)
        #expect(decision.verdict == .block)
        #expect(decision.findings.contains { $0.field == "partySize" })
    }

    @Test("the corrected action is allowed")
    func allowsCorrectedValues() {
        let transcript = graph("Book a table for six, sorry, four.", "Book a table for six.")
        let action = ProposedAction(
            tool: "reserveTable", fields: [ProposedField(name: "partySize", value: "four")])
        #expect(IntentGate.check(action, against: transcript).verdict == .allow)
    }

    @Test("unpaired speech is allowed")
    func staysQuietOnAmbiguousRepairs() {
        let transcript = graph(
            "Book for six at 8, sorry, four at 7:30.", "Book for six at 8.")
        let action = ProposedAction(
            tool: "reserveTable",
            fields: [
                ProposedField(name: "partySize", value: "6"),
                ProposedField(name: "time", value: "20:00"),
            ])
        #expect(IntentGate.check(action, against: transcript).verdict == .allow)
    }

    @Test("a reversible action asks instead of blocking")
    func confirmsReversibleActions() {
        let transcript = graph("Send it to Rahul, make that Meera.", "Send it to Rahul.")
        let action = ProposedAction(
            tool: "draftMessage",
            fields: [ProposedField(name: "to", value: "Rahul")], isConsequential: false)
        #expect(IntentGate.check(action, against: transcript).verdict == .confirm)
    }

    @Test("an action with nothing to do with the repair is allowed")
    func ignoresUnrelatedFields() {
        let transcript = graph("Set the timeout to 60, sorry, 30.", "Set the timeout to 60.")
        let action = ProposedAction(
            tool: "reserveTable", fields: [ProposedField(name: "partySize", value: "4")])
        #expect(IntentGate.check(action, against: transcript).verdict == .allow)
    }

    @Test("a value is matched on whole tokens, not substrings")
    func matchesWholeTokens() {
        let transcript = graph("Set the retries to 3, no wait, 5.", "Set the retries to 3.")
        let action = ProposedAction(
            tool: "configure", fields: [ProposedField(name: "retries", value: "30")])
        #expect(IntentGate.check(action, against: transcript).verdict == .allow)
    }

    @Test("a proposal maps readOnly onto consequence")
    func mapsReadOnly() {
        let consequential = ProposedAction(
            tool: "reserveTable",
            fields: [ProposedField(name: "partySize", value: "4")],
            readOnly: false)
        #expect(consequential.isConsequential)
        let reversible = ProposedAction(
            tool: "listTables",
            fields: [ProposedField(name: "partySize", value: "4")],
            readOnly: true)
        #expect(!reversible.isConsequential)
    }

    @Test("a blocked decision names the rejected value first")
    func blockedReason() {
        let transcript = graph("Book a table for six, sorry, four.", "Book a table for six.")
        let action = ProposedAction(
            tool: "reserveTable",
            fields: [ProposedField(name: "partySize", value: "6")],
            readOnly: false)
        let decision = IntentGate.check(action, against: transcript)
        #expect(decision.verdict == .block)
        #expect(decision.actionReason == "six \u{2192} four")
        #expect(decision.summary != "verified correct")
    }

    @Test("an allow decision is short")
    func allowReason() {
        let transcript = graph("Book a table for six, sorry, four.", "Book a table for six.")
        let action = ProposedAction(
            tool: "reserveTable",
            fields: [ProposedField(name: "partySize", value: "4")],
            readOnly: false)
        let decision = IntentGate.check(action, against: transcript)
        #expect(decision.verdict == .allow)
        #expect(decision.actionReason == "Allowed")
    }

    @Test("an unverified language produces no verdict of its own")
    func staysQuietOutsideEnglish() {
        let transcript = graph(
            "\u{092F}\u{0939} \u{092C}\u{0939}\u{0941}\u{0924} \u{0905}\u{091A}\u{094D}\u{091B}\u{093E} \u{0939}\u{0948} \u{0914}\u{0930} \u{0915}\u{093E}\u{092E}",
            "\u{092F}\u{0939} \u{092C}\u{0939}\u{0941}\u{0924} \u{0905}\u{091A}\u{094D}\u{091B}\u{093E} \u{0939}\u{0948}"
        )
        let action = ProposedAction(
            tool: "reserveTable", fields: [ProposedField(name: "partySize", value: "6")])
        #expect(IntentGate.check(action, against: transcript).verdict == .allow)
    }
}
