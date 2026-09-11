import Foundation

public struct RepairLabel: Hashable, Sendable {
    public let before: String
    public let after: String
    public let resolution: RepairResolution
    public let kind: RepairKind?

    public init(before: String, after: String, resolution: RepairResolution) {
        self.before = before
        self.after = after
        self.resolution = resolution
        kind = nil
    }

    public var transition: String { "\(before) \u{2192} \(after)" }

    public var problemText: String {
        switch resolution {
        case .dropped: "\(kind?.title ?? "Meaning") dropped"
        case .altered: "\(kind?.title ?? "Meaning") altered"
        case .inverted: "Reversed: \(transition)"
        default: "\(transition) wasn't applied"
        }
    }

    public init?(_ event: RepairEvent) {
        if let before = event.before, let after = event.after, !before.isEmpty, !after.isEmpty {
            self.before = before
            self.after = after
            resolution = event.resolution
            kind = event.kind
            return
        }
        guard event.resolution == .dropped || event.resolution == .altered else { return nil }
        before = event.kind.title
        after = event.after ?? event.before ?? ""
        resolution = event.resolution
        kind = event.kind
    }
}

public enum DeliveryRoute: Hashable, Sendable {
    case pasted
    case copied(reason: String)
    case withheld(reason: String)

    public var isPasted: Bool { self == .pasted }

    public var copyReason: String? {
        if case .copied(let reason) = self { return reason }
        return nil
    }

    public var withheldReason: String? {
        if case .withheld(let reason) = self { return reason }
        return nil
    }
}

public struct DeliverySummary: Hashable, Sendable {
    public let route: DeliveryRoute
    public let destination: String?
    public let cleanupDegraded: Bool
    public let verified: Bool
    public let applied: [RepairLabel]
    public let problems: [RepairLabel]

    public init(
        route: DeliveryRoute, destination: String?, cleanupDegraded: Bool = false,
        verified: Bool = true, applied: [RepairLabel] = [], problems: [RepairLabel] = []
    ) {
        self.route = route
        self.destination = destination
        self.cleanupDegraded = cleanupDegraded
        self.verified = verified
        self.applied = applied
        self.problems = problems
    }

    public var needsAttention: Bool {
        cleanupDegraded || route.copyReason != nil || route.withheldReason != nil
            || !problems.isEmpty
    }

    public var offersCopy: Bool { route.withheldReason != nil }
}

public struct FailureSummary: Hashable, Sendable {
    public let reason: String
    public let canRetry: Bool

    public init(reason: String, canRetry: Bool) {
        self.reason = reason
        self.canRetry = canRetry
    }
}

public enum PipelinePhase: Hashable, Sendable {
    case idle
    case arming
    case listening(level: Double)
    case transcribing
    case delivered(DeliverySummary)
    case blocked([String])
    case failed(FailureSummary)
    case refusedSecureField
    case acting(ActionBanner)
}

public struct ActionBanner: Hashable, Sendable {
    public var symbol: String
    public var label: String
    public var persistent: Bool
    public var showsMeter: Bool
    public var level: Double

    public init(
        symbol: String, label: String, persistent: Bool, showsMeter: Bool = false,
        level: Double = 0
    ) {
        self.symbol = symbol
        self.label = label
        self.persistent = persistent
        self.showsMeter = showsMeter
        self.level = level
    }
}

public enum PillVisibility: Hashable, Sendable {
    case hidden
    case transient(TimeInterval)
    case persistent
}

extension PipelinePhase {
    public var visibility: PillVisibility {
        switch self {
        case .idle:
            .hidden
        case .arming, .listening, .transcribing:
            .persistent
        case .failed:
            .persistent
        case .blocked:
            .transient(5)
        case .refusedSecureField:
            .transient(2.5)
        case .delivered(let summary):
            if summary.needsAttention {
                .persistent
            } else if summary.applied.isEmpty {
                .transient(0.7)
            } else {
                .transient(1.4)
            }
        case .acting(let banner):
            banner.persistent ? .persistent : .transient(1.6)
        }
    }
}

public struct PhasePresentation: Hashable, Sendable {
    public let symbol: String
    public let label: String
    public let showsMeter: Bool
    public let emphasised: Bool
    public let offersReview: Bool

    public init(
        symbol: String, label: String, showsMeter: Bool, emphasised: Bool,
        offersReview: Bool = false
    ) {
        self.symbol = symbol
        self.label = label
        self.showsMeter = showsMeter
        self.emphasised = emphasised
        self.offersReview = offersReview
    }
}

extension PipelinePhase {
    public var presentation: PhasePresentation {
        switch self {
        case .idle:
            PhasePresentation(
                symbol: "mic", label: "Hold to speak", showsMeter: false, emphasised: false)
        case .arming:
            PhasePresentation(
                symbol: "mic", label: "Starting", showsMeter: false, emphasised: false)
        case .listening:
            PhasePresentation(
                symbol: "waveform", label: "Listening", showsMeter: true, emphasised: false)
        case .transcribing:
            PhasePresentation(
                symbol: "waveform", label: "Transcribing", showsMeter: false, emphasised: false)
        case .refusedSecureField:
            PhasePresentation(
                symbol: "lock.fill", label: "Dictation paused \u{00B7} secure field",
                showsMeter: false, emphasised: true)
        case .delivered(let summary):
            PhasePresentation(
                symbol: Self.deliveredSymbol(summary),
                label: Self.deliveredLabel(summary),
                showsMeter: false,
                emphasised: summary.needsAttention,
                offersReview: !summary.problems.isEmpty)
        case .blocked(let blockers):
            PhasePresentation(
                symbol: "lock", label: Self.blockedLabel(blockers), showsMeter: false,
                emphasised: true)
        case .failed(let failure):
            PhasePresentation(
                symbol: "exclamationmark.triangle",
                label: failure.canRetry ? "\(failure.reason) \u{00B7} Retry" : failure.reason,
                showsMeter: false, emphasised: true)
        case .acting(let banner):
            PhasePresentation(
                symbol: banner.symbol, label: banner.label, showsMeter: banner.showsMeter,
                emphasised: true)
        }
    }

    private static func deliveredSymbol(_ summary: DeliverySummary) -> String {
        if summary.cleanupDegraded || summary.route.copyReason != nil {
            return "exclamationmark.triangle"
        }
        if summary.problems.contains(where: { $0.resolution == .inverted }) {
            return "arrow.uturn.backward"
        }
        return summary.problems.isEmpty ? "checkmark" : "exclamationmark"
    }

    private static func blockedLabel(_ blockers: [String]) -> String {
        guard let first = blockers.first else { return "Not ready" }
        return blockers.count == 1
            ? "\(first) needed" : "\(first) and \(blockers.count - 1) more needed"
    }

    private static func deliveredLabel(_ summary: DeliverySummary) -> String {
        if summary.cleanupDegraded {
            return summary.route.isPasted
                ? "Cleanup unavailable \u{00B7} pasted verbatim"
                : "Cleanup unavailable \u{00B7} copied verbatim"
        }
        if let reason = summary.route.copyReason { return "\(reason) \u{00B7} Copied" }
        if let reason = summary.route.withheldReason { return "\(reason) \u{00B7} Copy available" }
        if let problem = summary.problems.first {
            let extra = summary.problems.count - 1
            let body = problem.problemText
            return extra > 0 ? "\(body) \u{00B7} +\(extra) more" : body
        }
        if let applied = summary.applied.first {
            let extra = summary.applied.count - 1
            return extra > 0 ? "\(applied.transition) \u{00B7} +\(extra) more" : applied.transition
        }
        return summary.route.isPasted ? "Pasted" : "Copied"
    }
}

public struct RepairOutlineNode: Identifiable, Hashable, Sendable {
    public let event: RepairEvent
    public let children: [RepairEvent]
    public var id: UUID { event.id }
}

extension RepairGraph {
    public var problemLabels: [RepairLabel] {
        problemClaims.compactMap(RepairLabel.init)
    }

    public var appliedLabels: [RepairLabel] {
        appliedClaims.compactMap(RepairLabel.init)
    }

    public var outline: [RepairOutlineNode] {
        let children = Dictionary(grouping: events.filter { !$0.relatedIDs.isEmpty }) {
            $0.relatedIDs[0]
        }
        return
            events
            .filter { $0.relatedIDs.isEmpty && $0.resolution != .cosmetic }
            .map { RepairOutlineNode(event: $0, children: children[$0.id] ?? []) }
    }
}

public enum RibbonStyle: String, Hashable, Sendable {
    case normal
    case removed
    case replaced
    case kept
}

public struct RibbonRun: Hashable, Sendable {
    public let text: String
    public let style: RibbonStyle
}

extension RepairGraph {
    public var ribbon: [RibbonRun] {
        let characters = Array(raw)
        var styles = [RibbonStyle](repeating: .normal, count: characters.count)

        func paint(_ span: TextSpan, _ style: RibbonStyle) {
            guard span.start >= 0, span.end <= characters.count else { return }
            for index in span.start..<span.end where priority(styles[index]) < priority(style) {
                styles[index] = style
            }
        }

        for event in events {
            switch event.kind {
            case .filler, .repetition:
                event.evidence.rawSpans.forEach { paint($0, .removed) }
            case .correction, .valueChange, .entityChange, .reassignment,
                .rejectedAlternative, .abandonedIdea:
                let spans = event.evidence.rawSpans
                if spans.count == 3 {
                    paint(spans[0], .replaced)
                    paint(spans[1], .removed)
                    paint(spans[2], .kept)
                }
            case .rationale, .constraint, .uncertainty, .formattingOnly:
                continue
            }
        }

        var runs: [RibbonRun] = []
        var index = 0
        while index < characters.count {
            let style = styles[index]
            var end = index
            while end < characters.count, styles[end] == style { end += 1 }
            runs.append(RibbonRun(text: String(characters[index..<end]), style: style))
            index = end
        }
        return runs
    }

    private func priority(_ style: RibbonStyle) -> Int {
        switch style {
        case .normal: 0
        case .removed: 1
        case .replaced: 2
        case .kept: 3
        }
    }
}

extension RepairKind {
    public var showsTransition: Bool {
        switch self {
        case .correction, .valueChange, .entityChange, .reassignment, .rejectedAlternative,
            .abandonedIdea:
            true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .filler: "Filler"
        case .repetition: "Repetition"
        case .correction: "Correction"
        case .valueChange: "Value change"
        case .entityChange: "Entity change"
        case .reassignment: "Reassignment"
        case .rejectedAlternative: "Rejected"
        case .rationale: "Reason"
        case .constraint: "Constraint"
        case .uncertainty: "Uncertainty"
        case .abandonedIdea: "Abandoned"
        case .formattingOnly: "Formatting"
        }
    }
}

extension RepairResolution {
    public var isProblem: Bool {
        self == .unresolved || self == .inverted || self == .dropped || self == .altered
    }

    public var title: String {
        switch self {
        case .cosmetic: "noise"
        case .resolved: "applied"
        case .unresolved: "still ambiguous"
        case .inverted: "reversed"
        case .indeterminate: "unclear"
        case .carried: "kept"
        case .dropped: "dropped"
        case .altered: "altered"
        }
    }
}
