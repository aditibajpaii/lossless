import Foundation

public enum PatchProof: String, Codable, Hashable, Sendable {
    case exactStaleDeletion
    case parallelSlotReplacement
    case exactDuplicateCollapse
}

public struct RepairPatch: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let range: TextSpan
    public let replacement: String
    public let sourceEventID: UUID
    public let proof: PatchProof

    public init(
        id: UUID = UUID(), range: TextSpan, replacement: String, sourceEventID: UUID,
        proof: PatchProof
    ) {
        self.id = id
        self.range = range
        self.replacement = replacement
        self.sourceEventID = sourceEventID
        self.proof = proof
    }
}

public struct CompiledTranscript: Hashable, Sendable {
    public let text: String
    public let patches: [RepairPatch]
    public let unpatched: [RepairEvent]

    public var isVerbatim: Bool { patches.isEmpty }
    public var appliedProofs: [PatchProof] { patches.map(\.proof) }

    public init(text: String, patches: [RepairPatch], unpatched: [RepairEvent]) {
        self.text = text
        self.patches = patches
        self.unpatched = unpatched
    }
}

public enum RepairCompiler {
    public static func compile(_ graph: RepairGraph) -> CompiledTranscript {
        let characters = Array(graph.clean)
        var patches: [RepairPatch] = []
        var unpatched: [RepairEvent] = []
        var claimed: [Range<Int>] = []

        for event in graph.problemClaims {
            let candidates = patchCandidates(event, graph, characters)
            guard !candidates.isEmpty,
                candidates.allSatisfy({ patch in
                    !claimed.contains { $0.overlaps(patch.range.start..<patch.range.end) }
                })
            else {
                unpatched.append(event)
                continue
            }
            claimed.append(contentsOf: candidates.map { $0.range.start..<$0.range.end })
            patches.append(contentsOf: candidates)
        }

        guard !patches.isEmpty else {
            return CompiledTranscript(text: graph.clean, patches: [], unpatched: unpatched)
        }
        return CompiledTranscript(
            text: apply(patches, to: characters), patches: patches, unpatched: unpatched)
    }

    private static func apply(_ patches: [RepairPatch], to characters: [Character]) -> String {
        var result = characters
        for patch in patches.sorted(by: { $0.range.start > $1.range.start }) {
            result.replaceSubrange(
                patch.range.start..<patch.range.end, with: Array(patch.replacement))
        }
        return String(result)
    }

    private static func patchCandidates(
        _ event: RepairEvent, _ graph: RepairGraph, _ characters: [Character]
    ) -> [RepairPatch] {
        switch event.resolution {
        case .unresolved:
            if let collapse = duplicateCollapse(event, characters) { return collapse }
            if let deletion = staleDeletion(event, characters) { return [deletion] }
            return []
        case .inverted:
            if let replacement = slotReplacement(event, characters) { return [replacement] }
            return []
        default:
            return []
        }
    }

    private static func staleDeletion(_ event: RepairEvent, _ characters: [Character])
        -> RepairPatch?
    {
        guard event.evidence.cleanSpans.count == 2 else { return nil }
        let survivor = event.evidence.cleanSpans[0]
        let obsolete = event.evidence.cleanSpans[1]
        guard adjacent(obsolete, survivor, characters) else { return nil }

        var end = obsolete.end
        while end < characters.count, characters[end] == " " { end += 1 }
        return RepairPatch(
            range: TextSpan(
                start: obsolete.start, end: end,
                text: String(characters[obsolete.start..<end])),
            replacement: "", sourceEventID: event.id, proof: .exactStaleDeletion)
    }

    private static func slotReplacement(_ event: RepairEvent, _ characters: [Character])
        -> RepairPatch?
    {
        guard event.grade >= .structural, sameSlot(event),
            let chosen = event.after, !chosen.isEmpty,
            let survivor = event.evidence.cleanSpans.first,
            grounded(survivor, characters)
        else { return nil }
        return RepairPatch(
            range: survivor, replacement: chosen + trailingPunctuation(survivor.text),
            sourceEventID: event.id, proof: .parallelSlotReplacement)
    }

    private static func duplicateCollapse(_ event: RepairEvent, _ characters: [Character])
        -> [RepairPatch]?
    {
        guard event.evidence.cleanSpans.count == 2, let chosen = event.after, !chosen.isEmpty
        else { return nil }
        let chosenSpan = event.evidence.cleanSpans[0]
        let rejectedSpan = event.evidence.cleanSpans[1]
        guard rejectedSpan.end <= chosenSpan.start else { return nil }

        let clauses = clauseRanges(characters)
        guard let rejectedClause = clauses.firstIndex(where: { $0.contains(rejectedSpan.start) }),
            let chosenClause = clauses.firstIndex(where: { $0.contains(chosenSpan.start) }),
            chosenClause == rejectedClause + 1
        else { return nil }

        let rejectedTail = keys(characters, clauses[rejectedClause], after: rejectedSpan.end)
        let chosenTail = keys(characters, clauses[chosenClause], after: chosenSpan.end)
        guard chosenTail.count >= 2, rejectedTail == chosenTail else { return nil }
        guard keys(characters, clauses[chosenClause], before: chosenSpan.start).isEmpty else {
            return nil
        }

        let deletion = clauses[rejectedClause].upperBound..<clauses[chosenClause].upperBound
        return [
            RepairPatch(
                range: rejectedSpan, replacement: chosen + trailingPunctuation(rejectedSpan.text),
                sourceEventID: event.id, proof: .exactDuplicateCollapse),
            RepairPatch(
                range: TextSpan(
                    start: deletion.lowerBound, end: deletion.upperBound,
                    text: String(characters[deletion])),
                replacement: "", sourceEventID: event.id, proof: .exactDuplicateCollapse),
        ]
    }

    private static func clauseRanges(_ characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, character) in characters.enumerated() where ".!?".contains(character) {
            ranges.append(start..<(index + 1))
            start = index + 1
        }
        if start < characters.count { ranges.append(start..<characters.count) }
        return ranges
    }

    private static func keys(_ characters: [Character], _ clause: Range<Int>, after start: Int)
        -> [String]
    {
        guard start <= clause.upperBound else { return [] }
        return Tokenizer.tokenize(String(characters[start..<clause.upperBound]))
            .map(\.key).filter { !$0.isEmpty }
    }

    private static func keys(_ characters: [Character], _ clause: Range<Int>, before end: Int)
        -> [String]
    {
        guard clause.lowerBound <= end else { return [] }
        return Tokenizer.tokenize(String(characters[clause.lowerBound..<end]))
            .map(\.key).filter { !$0.isEmpty }
    }

    private static func sameSlot(_ event: RepairEvent) -> Bool {
        event.signals.contains(.parallelFrame)
    }

    private static func trailingPunctuation(_ text: String) -> String {
        String(text.reversed().prefix { $0.isPunctuation }.reversed())
    }

    private static func grounded(_ span: TextSpan, _ characters: [Character]) -> Bool {
        span.start >= 0 && span.end <= characters.count && span.start < span.end
            && String(characters[span.start..<span.end]) == span.text
    }

    private static func adjacent(_ lhs: TextSpan, _ rhs: TextSpan, _ characters: [Character])
        -> Bool
    {
        let first = lhs.start <= rhs.start ? lhs : rhs
        let second = lhs.start <= rhs.start ? rhs : lhs
        guard first.end <= second.start, second.start <= characters.count else { return false }
        return characters[first.end..<second.start].allSatisfy {
            $0.isWhitespace || $0.isPunctuation
        }
    }
}

extension RepairGraph {
    public var compiled: CompiledTranscript { RepairCompiler.compile(self) }
}
