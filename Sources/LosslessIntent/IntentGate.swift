import Foundation
import LosslessEngine

public struct ProposedField: Hashable, Sendable, Codable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ProposedAction: Hashable, Sendable, Codable {
    public let tool: String
    public let fields: [ProposedField]
    public let isConsequential: Bool

    public init(tool: String, fields: [ProposedField], isConsequential: Bool = true) {
        self.tool = tool
        self.fields = fields
        self.isConsequential = isConsequential
    }

    public init(tool: String, fields: [ProposedField], readOnly: Bool) {
        self.init(tool: tool, fields: fields, isConsequential: !readOnly)
    }
}

public enum IntentVerdict: String, Hashable, Sendable, Codable {
    case allow
    case block
    case confirm
}

public struct IntentFinding: Hashable, Sendable, Codable {
    public let field: String
    public let rejected: String
    public let chosen: String
    public let explanation: String
}

public struct IntentDecision: Hashable, Sendable, Codable {
    public let verdict: IntentVerdict
    public let findings: [IntentFinding]

    public var summary: String {
        switch verdict {
        case .allow: "Allowed"
        case .block, .confirm:
            findings.map { "\($0.field) carries \($0.rejected); the speaker said \($0.chosen)." }
                .joined(separator: " ")
        }
    }

    public var actionReason: String {
        if let finding = findings.first {
            return "\(finding.rejected) \u{2192} \(finding.chosen)"
        }
        return summary
    }
}

public enum IntentGate {
    public static func check(_ action: ProposedAction, against graph: RepairGraph)
        -> IntentDecision
    {
        guard graph.scope.verifiesRepairs else {
            return IntentDecision(verdict: .allow, findings: [])
        }

        var findings: [IntentFinding] = []
        for claim in graph.userFacingClaims {
            guard let rejected = claim.before, let chosen = claim.after,
                !rejected.isEmpty, !chosen.isEmpty, rejected != chosen
            else { continue }
            for field in action.fields
            where carries(field.value, rejected)
                && !carries(field.value, chosen)
            {
                findings.append(
                    IntentFinding(
                        field: field.name, rejected: rejected, chosen: chosen,
                        explanation: "\(rejected) \u{2192} \(chosen)"))
            }
        }

        guard !findings.isEmpty else { return IntentDecision(verdict: .allow, findings: []) }
        return IntentDecision(
            verdict: action.isConsequential ? .block : .confirm, findings: findings)
    }

    private static func carries(_ value: String, _ phrase: String) -> Bool {
        let haystack = keys(value)
        let needle = keys(phrase)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.indices.dropLast(needle.count - 1).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }

    private static func keys(_ text: String) -> [String] {
        Tokenizer.tokenize(text).map(\.key).filter { !$0.isEmpty }.map { key in
            Self.digits[key] ?? key
        }
    }

    private static let digits: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
        "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    ]
}
