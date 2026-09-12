import Testing

@testable import LosslessEngine
@testable import LosslessKit

@Suite("Action session")
struct ActionSessionTests {
    private func bookingGraph() -> RepairGraph {
        RepairEngine.analyze(
            TranscriptPair(
                raw: "Book a table for six, sorry, four.",
                clean: "Book a table for six."))
    }

    private func proposal(id: String, size: String, document: String = "doc-1") -> ActionProposal {
        ActionProposal(
            utteranceId: id,
            page: ActionPage(origin: "http://127.0.0.1:18764", document: document),
            tool: "reserveTable",
            fields: [ActionField(name: "partySize", value: size)],
            readOnly: false)
    }

    @Test("a rejected party size blocks before confirm")
    func rejectedValueBlocks() {
        var session = ActionSession()
        let id = session.heard(bookingGraph(), page: nil)
        let offer = session.consider(
            proposal(id: id, size: "6"), blocked: true, reason: "6 → 4")
        #expect(offer == .blocked)
        guard case .blocked(let reason) = session.phase else {
            Issue.record("expected blocked, got \(session.phase)")
            return
        }
        #expect(reason.contains("6 → 4"))
        #expect(session.confirm() == nil)
    }

    @Test("a chosen party size waits for confirm")
    func chosenValueConfirms() {
        var session = ActionSession()
        let id = session.heard(bookingGraph(), page: nil)
        let offer = session.consider(
            proposal(id: id, size: "4"), blocked: false, reason: "")
        guard case .confirm(let proposal) = offer else {
            Issue.record("expected confirm, got \(offer)")
            return
        }
        #expect(proposal.fields.first?.value == "4")
        #expect(session.confirm()?.utteranceId == id)
        guard case .executing(let running) = session.phase else {
            Issue.record("expected executing, got \(session.phase)")
            return
        }
        #expect(running == id)
    }

    @Test("a stale utterance id is rejected")
    func staleUtterance() {
        var session = ActionSession()
        _ = session.heard(bookingGraph(), page: nil)
        let offer = session.consider(
            proposal(id: "other", size: "4"), blocked: false, reason: "")
        #expect(offer == .stale)
    }

    @Test("a new page while planning rebinds")
    func attachDuringPlanningRebinds() {
        var session = ActionSession()
        let first = ActionPage(origin: "http://127.0.0.1:18764", document: "doc-1")
        let id = session.heard(bookingGraph(), page: first)
        #expect(
            session.attach(ActionPage(origin: "http://127.0.0.1:18764", document: "doc-2"))
                == nil)
        let offer = session.consider(
            proposal(id: id, size: "4", document: "doc-2"), blocked: false, reason: "")
        guard case .confirm = offer else {
            Issue.record("expected confirm, got \(offer)")
            return
        }
    }

    @Test("a new page during confirm returns to planning")
    func attachDuringConfirmRebinds() {
        var session = ActionSession()
        let page = ActionPage(origin: "http://127.0.0.1:18764", document: "doc-1")
        let id = session.heard(bookingGraph(), page: page)
        _ = session.consider(proposal(id: id, size: "4"), blocked: false, reason: "")
        #expect(
            session.attach(ActionPage(origin: "http://127.0.0.1:18764", document: "doc-2"))
                == nil)
        guard case .planning(let planning) = session.phase else {
            Issue.record("expected planning, got \(session.phase)")
            return
        }
        #expect(planning == id)
        #expect(session.confirm() == nil)
    }

    @Test("a page change cancels")
    func pageChangeCancels() {
        var session = ActionSession()
        let page = ActionPage(origin: "http://127.0.0.1:18764", document: "doc-1")
        let id = session.heard(bookingGraph(), page: page)
        let offer = session.consider(
            proposal(id: id, size: "4", document: "doc-2"), blocked: false, reason: "")
        #expect(offer == .pageChanged)
        guard case .failed(let reason) = session.phase else {
            Issue.record("expected failed, got \(session.phase)")
            return
        }
        #expect(reason.contains("Page changed"))
    }

    @Test("a read-only proposal executes without confirm")
    func readOnlySkipsConfirm() {
        var session = ActionSession()
        let id = session.heard(bookingGraph(), page: nil)
        var proposal = proposal(id: id, size: "4")
        proposal.readOnly = true
        let offer = session.consider(proposal, blocked: false, reason: "")
        guard case .execute = offer else {
            Issue.record("expected execute, got \(offer)")
            return
        }
        guard case .executing = session.phase else {
            Issue.record("expected executing, got \(session.phase)")
            return
        }
    }

    @Test("a stale planner can still be blocked after success")
    func stalePlannerAfterSuccess() {
        var session = ActionSession()
        let id = session.heard(bookingGraph(), page: nil)
        _ = session.consider(proposal(id: id, size: "4"), blocked: false, reason: "")
        _ = session.confirm()
        session.succeed("Reserved for 4.")
        let offer = session.consider(
            proposal(id: id, size: "6"), blocked: true, reason: "6 → 4")
        #expect(offer == .blocked)
    }

    @Test("a stale planner can replace a pending confirm")
    func stalePlannerReplacesConfirm() {
        var session = ActionSession()
        let id = session.heard(bookingGraph(), page: nil)
        _ = session.consider(proposal(id: id, size: "4"), blocked: false, reason: "")
        let offer = session.consider(
            proposal(id: id, size: "6"), blocked: true, reason: "6 → 4")
        #expect(offer == .blocked)
        guard case .blocked = session.phase else {
            Issue.record("expected blocked, got \(session.phase)")
            return
        }
    }

    @Test("booking speech with two numbers is allowed")
    func twoSlotHasNoClaim() {
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Book for six at 8, sorry, four at 7:30.",
                clean: "Book for six at 8."))
        #expect(graph.userFacingClaims.isEmpty)
    }
}
