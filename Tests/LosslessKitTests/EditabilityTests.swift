import Testing

@testable import LosslessKit

@Suite("Editability")
struct EditabilityTests {
    @Test("a native text area with a settable value is editable")
    func nativeTextArea() {
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(role: "AXTextArea", valueSettable: true)))
                == .editable)
    }

    @Test("a button is not editable")
    func button() {
        #expect(
            TargetSafety.infer(EditabilityEvidence(focused: NodeFacts(role: "AXButton")))
                == .nonEditable)
    }

    @Test("a password field is secure even when its value is settable")
    func secureField() {
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(
                        role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true)))
                == .secure)
    }

    @Test("a web area with no settable text is not editable")
    func readOnlyWebArea() {
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(
                        role: "AXWebArea", valueSettable: false, selectedTextSettable: false,
                        focused: true)))
                == .nonEditable)
    }

    @Test("a Chromium composer hiding inside a web area is editable")
    func chromiumComposer() {
        let composer = NodeFacts(
            role: "AXTextArea", valueSettable: true, selectedTextSettable: true)
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(
                        role: "AXWebArea", valueSettable: false, selectedTextSettable: false,
                        focused: true),
                    descendantTextFields: [composer]))
                == .editable)
    }

    @Test("a login page with an unfocused password field is not guessed")
    func mixedSecurePage() {
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(
                        role: "AXWebArea", valueSettable: false, selectedTextSettable: false,
                        focused: true),
                    descendantTextFields: [NodeFacts(role: "AXTextField", valueSettable: true)],
                    descendantSecureFields: [
                        NodeFacts(role: "AXTextField", subrole: "AXSecureTextField")
                    ]))
                == .nonEditable)
    }

    @Test("a focused password inside a web area is secure")
    func focusedSecureDescendant() {
        #expect(
            TargetSafety.infer(
                EditabilityEvidence(
                    focused: NodeFacts(
                        role: "AXWebArea", valueSettable: false, selectedTextSettable: false,
                        focused: true),
                    descendantSecureFields: [
                        NodeFacts(
                            role: "AXTextField", subrole: "AXSecureTextField", focused: true)
                    ]))
                == .secure)
    }

    @Test("an unread focused element stays unknown")
    func unknown() {
        #expect(TargetSafety.infer(EditabilityEvidence(focused: NodeFacts(role: nil))) == .unknown)
    }
}
