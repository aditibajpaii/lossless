import Foundation

public struct NodeFacts: Sendable, Equatable {
    public let role: String?
    public let subrole: String?
    public let publishedEditable: Bool?
    public let valueSettable: Bool?
    public let selectedTextSettable: Bool?
    public let focused: Bool

    public init(
        role: String?, subrole: String? = nil, publishedEditable: Bool? = nil,
        valueSettable: Bool? = nil, selectedTextSettable: Bool? = nil, focused: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.publishedEditable = publishedEditable
        self.valueSettable = valueSettable
        self.selectedTextSettable = selectedTextSettable
        self.focused = focused
    }

    public var isSecure: Bool { subrole == "AXSecureTextField" }
    public var isTextEntry: Bool { role == "AXTextArea" || role == "AXTextField" }
    public var hasSettableText: Bool { valueSettable == true || selectedTextSettable == true }
}

public struct EditabilityEvidence: Sendable, Equatable {
    public let focused: NodeFacts
    public let descendantTextFields: [NodeFacts]
    public let descendantSecureFields: [NodeFacts]

    public init(
        focused: NodeFacts, descendantTextFields: [NodeFacts] = [],
        descendantSecureFields: [NodeFacts] = []
    ) {
        self.focused = focused
        self.descendantTextFields = descendantTextFields
        self.descendantSecureFields = descendantSecureFields
    }
}

extension TargetSafety {
    public static func infer(_ evidence: EditabilityEvidence) -> TargetSafety {
        let focused = inferFocused(evidence.focused)
        switch focused {
        case .secure, .editable:
            return focused
        case .nonEditable, .unknown:
            return inferWebArea(focused, evidence)
        }
    }

    private static func inferFocused(_ node: NodeFacts) -> TargetSafety {
        if node.isSecure { return .secure }
        if node.role == "AXStaticText" || node.role == "AXButton" { return .nonEditable }
        if let editable = node.publishedEditable { return editable ? .editable : .nonEditable }
        if let settable = node.valueSettable {
            if settable { return .editable }
            if node.role == "AXWebArea" || node.role == "AXGroup",
                node.selectedTextSettable == true
            {
                return .editable
            }
            return .nonEditable
        }
        return node.role == nil ? .unknown : .nonEditable
    }

    private static func inferWebArea(
        _ fallback: TargetSafety, _ evidence: EditabilityEvidence
    ) -> TargetSafety {
        let role = evidence.focused.role
        guard role == "AXWebArea" || role == "AXGroup" else { return fallback }
        if evidence.descendantSecureFields.contains(where: \.focused) { return .secure }
        let text = evidence.descendantTextFields.filter(\.hasSettableText)
        guard !text.isEmpty else { return fallback }
        if text.contains(where: \.focused) { return .editable }
        if evidence.descendantSecureFields.isEmpty { return .editable }
        return fallback
    }
}
