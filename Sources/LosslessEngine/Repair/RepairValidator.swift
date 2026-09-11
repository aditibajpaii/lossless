import Foundation

public enum RepairValidator {
    public static func validate(_ events: [RepairEvent], raw: String, clean: String)
        -> [RepairEvent]
    {
        let rawCharacters = Array(raw)
        let cleanCharacters = Array(clean)
        let checked = events.filter { event in
            guard !event.evidence.rawSpans.isEmpty || !event.evidence.cleanSpans.isEmpty else {
                return false
            }
            let rawGrounded = event.evidence.rawSpans.allSatisfy { grounded($0, rawCharacters) }
            let cleanGrounded = event.evidence.cleanSpans.allSatisfy {
                grounded($0, cleanCharacters)
            }
            guard rawGrounded, cleanGrounded else { return false }
            return derivable(event)
        }
        return withoutContradictions(withResolvedParents(checked))
    }

    private static func withResolvedParents(_ events: [RepairEvent]) -> [RepairEvent] {
        let known = Set(events.map(\.id))
        return events.filter { $0.relatedIDs.allSatisfy { known.contains($0) } }
    }

    private static func withoutContradictions(_ events: [RepairEvent]) -> [RepairEvent] {
        let primaries = events.filter { $0.relatedIDs.isEmpty && $0.resolution != .cosmetic }
        var claimed: [RepairEvent] = []
        var rejected: Set<UUID> = []

        for event in primaries.sorted(by: strongerFirst) {
            if claimed.contains(where: { overlaps($0, event) }) {
                rejected.insert(event.id)
            } else {
                claimed.append(event)
            }
        }
        guard !rejected.isEmpty else { return events }
        return events.filter {
            !rejected.contains($0.id) && !$0.relatedIDs.contains(where: rejected.contains)
        }
    }

    private static func strongerFirst(_ lhs: RepairEvent, _ rhs: RepairEvent) -> Bool {
        if lhs.grade != rhs.grade { return lhs.grade > rhs.grade }
        if lhs.resolution.isClaim != rhs.resolution.isClaim { return lhs.resolution.isClaim }
        return (lhs.evidence.rawSpans.first?.start ?? 0) < (rhs.evidence.rawSpans.first?.start ?? 0)
    }

    private static func overlaps(_ lhs: RepairEvent, _ rhs: RepairEvent) -> Bool {
        for left in lhs.evidence.rawSpans {
            for right in rhs.evidence.rawSpans
            where left.start < right.end && right.start < left.end {
                return true
            }
        }
        return false
    }

    private static func grounded(_ span: TextSpan, _ characters: [Character]) -> Bool {
        guard span.start >= 0, span.end <= characters.count, span.start < span.end else {
            return false
        }
        return String(characters[span.start..<span.end]) == span.text
    }

    private static func derivable(_ event: RepairEvent) -> Bool {
        switch event.kind {
        case .valueChange, .entityChange, .reassignment, .rejectedAlternative, .correction,
            .abandonedIdea:
            guard let before = event.before, let after = event.after else { return false }
            guard !before.isEmpty, !after.isEmpty, before != after else { return false }
            guard event.evidence.rawSpans.count == 3 else { return false }
            return event.evidence.rawSpans[0].text.contains(before)
                && event.evidence.rawSpans[2].text.contains(after)
        case .rationale:
            return event.after?.isEmpty == false && !event.relatedIDs.isEmpty
        case .constraint:
            return !event.evidence.rawSpans.isEmpty
        default:
            return true
        }
    }
}
