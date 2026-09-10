import Foundation

public enum RepairKind: String, Codable, CaseIterable, Sendable {
    case filler
    case repetition
    case correction
    case valueChange
    case entityChange
    case reassignment
    case rejectedAlternative
    case rationale
    case constraint
    case uncertainty
    case abandonedIdea
    case formattingOnly
}

public enum RepairResolution: String, Codable, CaseIterable, Sendable {
    case cosmetic
    case resolved
    case unresolved
    case inverted
    case indeterminate
    case carried
    case dropped
    case altered
}

public enum PreservationOutcome: String, Codable, CaseIterable, Sendable {
    case preserved
    case dropped
    case altered
    case unknown
}

public enum SemanticOutcome: Codable, Hashable, Sendable {
    case repair(RepairResolution)
    case preservation(PreservationOutcome)
    case cosmetic
}

public enum EvidenceGrade: String, Codable, CaseIterable, Sendable, Comparable {
    case explicit
    case structural
    case ambiguous

    private var rank: Int {
        switch self {
        case .ambiguous: 0
        case .structural: 1
        case .explicit: 2
        }
    }

    public static func < (lhs: EvidenceGrade, rhs: EvidenceGrade) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum EvidenceSignal: String, Codable, CaseIterable, Sendable {
    case explicitMarker
    case strongMarker
    case ambiguousMarker
    case opensClause
    case anchorsCompatible
    case parallelFrame
    case alignedFrame
    case slotIsFragment
    case lexicalAnchor
    case alignmentProvenRemoval
    case alignmentProvenSurvival
    case chosenValueAbsent
}

public struct RepairEvidence: Codable, Hashable, Sendable {
    public let rawSpans: [TextSpan]
    public let cleanSpans: [TextSpan]

    public init(rawSpans: [TextSpan], cleanSpans: [TextSpan]) {
        self.rawSpans = rawSpans
        self.cleanSpans = cleanSpans
    }
}

public struct RepairEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: RepairKind
    public let outcome: SemanticOutcome
    public let before: String?
    public let after: String?
    public let evidence: RepairEvidence
    public let grade: EvidenceGrade
    public let signals: Set<EvidenceSignal>
    public let relatedIDs: [UUID]

    public init(
        id: UUID = UUID(),
        kind: RepairKind,
        outcome: SemanticOutcome,
        before: String?,
        after: String?,
        evidence: RepairEvidence,
        grade: EvidenceGrade,
        signals: Set<EvidenceSignal> = [],
        relatedIDs: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.before = before
        self.after = after
        self.evidence = evidence
        self.grade = grade
        self.signals = signals
        self.relatedIDs = relatedIDs
    }

    public var resolution: RepairResolution {
        switch outcome {
        case .repair(let resolution): resolution
        case .preservation(.preserved): .carried
        case .preservation(.dropped): .dropped
        case .preservation(.altered): .altered
        case .preservation(.unknown): .indeterminate
        case .cosmetic: .cosmetic
        }
    }

    public var signalSummary: String {
        signals.map(\.rawValue).sorted().joined(separator: " ")
    }
}

public struct RepairGraph: Codable, Hashable, Sendable {
    public let raw: String
    public let clean: String
    public let events: [RepairEvent]
    public let scope: AnalysisScope

    public init(
        raw: String, clean: String, events: [RepairEvent], scope: AnalysisScope = .english
    ) {
        self.raw = raw
        self.clean = clean
        self.events = events
        self.scope = scope
    }

    public var userFacingClaims: [RepairEvent] {
        events.filter {
            guard $0.grade >= .structural else { return false }
            switch $0.outcome {
            case .repair(.resolved), .repair(.unresolved), .repair(.inverted):
                return $0.relatedIDs.isEmpty
            case .preservation(.dropped), .preservation(.altered):
                return $0.kind != .rationale
            default:
                return false
            }
        }
    }

    public var unresolvedClaims: [RepairEvent] {
        userFacingClaims.filter { $0.resolution == .unresolved }
    }

    public var invertedClaims: [RepairEvent] {
        userFacingClaims.filter { $0.resolution == .inverted }
    }

    public var appliedClaims: [RepairEvent] {
        userFacingClaims.filter {
            if case .repair(.resolved) = $0.outcome { return true }
            return false
        }
    }

    public var problemClaims: [RepairEvent] {
        userFacingClaims.filter {
            switch $0.outcome {
            case .repair(.inverted), .repair(.unresolved), .preservation(.dropped),
                .preservation(.altered):
                true
            default:
                false
            }
        }
    }

    public var indeterminate: [RepairEvent] {
        events.filter { $0.resolution == .indeterminate && $0.relatedIDs.isEmpty }
    }
}

extension RepairResolution {
    public var isClaim: Bool {
        switch self {
        case .resolved, .unresolved, .inverted, .dropped, .altered: true
        case .cosmetic, .indeterminate, .carried: false
        }
    }
}
