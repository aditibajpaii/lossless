import Foundation

public struct TranscriptPair: Codable, Hashable, Sendable {
    public let raw: String
    public let clean: String

    public init(raw: String, clean: String) {
        self.raw = raw
        self.clean = clean
    }
}

public enum RepairEngine {
    public static func analyze(_ pair: TranscriptPair) -> RepairGraph {
        let scope = LanguageScope.of(pair.raw)
        guard scope.verifiesRepairs else {
            return RepairGraph(raw: pair.raw, clean: pair.clean, events: [], scope: scope)
        }

        let rawTokens = Tokenizer.tokenize(pair.raw)
        let cleanTokens = Tokenizer.tokenize(pair.clean)
        let rawCharacters = Array(pair.raw)
        let cleanCharacters = Array(pair.clean)
        let alignment = TokenAligner.align(raw: rawTokens, clean: cleanTokens)

        var events: [RepairEvent] = []

        for repair in SelfRepairScanner.scan(rawTokens) {
            events.append(
                contentsOf: selfRepairEvents(
                    repair, rawTokens: rawTokens, cleanTokens: cleanTokens,
                    rawCharacters: rawCharacters, cleanCharacters: cleanCharacters,
                    alignment: alignment))
        }

        let windows = alignment.windows
        if let filler = aggregate(
            .filler, windows.filter { isAllFiller($0, rawTokens) }, rawTokens, rawCharacters)
        {
            events.append(filler)
        }
        if let repetition = aggregate(
            .repetition, windows.filter { isRepetition($0, rawTokens) }, rawTokens, rawCharacters)
        {
            events.append(repetition)
        }

        events.append(
            contentsOf: constraintEvents(
                rawTokens: rawTokens, cleanTokens: cleanTokens, rawCharacters: rawCharacters,
                cleanCharacters: cleanCharacters, alignment: alignment))

        let validated = deduplicated(
            RepairValidator.validate(events, raw: pair.raw, clean: pair.clean))
        return RepairGraph(
            raw: pair.raw, clean: pair.clean, events: ranked(validated), scope: scope)
    }

    private static func deduplicated(_ events: [RepairEvent]) -> [RepairEvent] {
        var seen: Set<[String]> = []
        return events.filter { event in
            let signature = [
                event.kind.rawValue, event.before ?? "", event.after ?? "",
                String(event.evidence.rawSpans.first?.start ?? -1),
            ]
            return seen.insert(signature).inserted
        }
    }

    private static func ranked(_ events: [RepairEvent]) -> [RepairEvent] {
        let order: [RepairResolution: Int] = [
            .inverted: 0, .unresolved: 1, .indeterminate: 2, .resolved: 3, .carried: 4,
            .cosmetic: 5,
        ]
        return events.sorted { lhs, rhs in
            let left = order[lhs.resolution] ?? 6
            let right = order[rhs.resolution] ?? 6
            if left != right { return left < right }
            return lhs.evidence.rawSpans.first?.start ?? 0 < rhs.evidence.rawSpans.first?.start ?? 0
        }
    }

    private static func selfRepairEvents(
        _ repair: SelfRepair,
        rawTokens: [Token], cleanTokens: [Token],
        rawCharacters: [Character], cleanCharacters: [Character],
        alignment: TokenAlignment
    ) -> [RepairEvent] {
        let markerSpan = span(rawTokens, repair.markerRange, rawCharacters)

        guard repair.intent != .hedge else {
            return [
                RepairEvent(
                    kind: .uncertainty,
                    outcome: .preservation(
                        preservation(alignment.survival(ofRaw: repair.markerRange))),
                    before: markerSpan.text.trimmedForDisplay, after: nil,
                    evidence: RepairEvidence(rawSpans: [markerSpan], cleanSpans: []),
                    grade: .structural, signals: [.ambiguousMarker])
            ]
        }

        guard let reparandum = repair.reparandum, let reparans = repair.reparans,
            let evidence = repair.evidence
        else { return [] }
        let beforeSpan = span(rawTokens, reparandum.range, rawCharacters)
        let afterSpan = span(rawTokens, reparans.range, rawCharacters)

        let rejectedKeys = distinguishing(reparandum, from: reparans, rawTokens)
        let chosenKeys = distinguishing(reparans, from: reparandum, rawTokens)
        let rejectedSurvival = alignment.survival(ofRawTokens: rejectedKeys)
        let chosenSurvival = alignment.survival(ofRawTokens: chosenKeys)
        let chosenKeysPresent = chosenKeys.contains {
            let key = rawTokens[$0].key
            return !key.isEmpty && cleanTokens.contains { $0.key == key }
        }
        let resolution = resolution(
            rejected: rejectedSurvival, chosen: chosenSurvival, chosenKeysPresent: chosenKeysPresent)

        let beforeRationale = rationaleClause(
            rawTokens, after: reparandum.range.upperBound - 1, before: repair.markerRange.lowerBound
        )
        let afterRationale = rationaleClause(
            rawTokens, after: reparans.range.upperBound - 1, before: rawTokens.count)

        let kind = kind(
            repair, reparandum: reparandum, reparans: reparans, rawTokens: rawTokens,
            hasRationale: beforeRationale != nil || afterRationale != nil)

        var cleanSpans: [TextSpan] = []
        if case .survived(let range) = chosenSurvival {
            cleanSpans.append(span(cleanTokens, range, cleanCharacters))
        }
        if case .survived(let range) = rejectedSurvival {
            cleanSpans.append(span(cleanTokens, range, cleanCharacters))
        }

        var signals = evidence.signals
        if case .removed = rejectedSurvival { signals.insert(.alignmentProvenRemoval) }
        if case .survived = chosenSurvival { signals.insert(.alignmentProvenSurvival) }
        if !chosenKeysPresent { signals.insert(.chosenValueAbsent) }

        let primary = RepairEvent(
            kind: kind,
            outcome: .repair(resolution),
            before: beforeSpan.text.trimmedForDisplay, after: afterSpan.text.trimmedForDisplay,
            evidence: RepairEvidence(
                rawSpans: [beforeSpan, markerSpan, afterSpan], cleanSpans: cleanSpans),
            grade: evidence.grade, signals: signals)

        var events = [primary]
        for (clause, subject) in [
            (beforeRationale, beforeSpan.text), (afterRationale, afterSpan.text),
        ] {
            guard let clause else { continue }
            let clauseSpan = span(rawTokens, clause, rawCharacters)
            events.append(
                RepairEvent(
                    kind: .rationale,
                    outcome: .preservation(preservation(alignment.survival(ofRaw: clause))),
                    before: subject.trimmedForDisplay,
                    after: clauseSpan.text.trimmedForDisplay,
                    evidence: RepairEvidence(rawSpans: [clauseSpan], cleanSpans: []),
                    grade: .structural, signals: [.anchorsCompatible],
                    relatedIDs: [primary.id]))
        }
        return events
    }

    private static func resolution(
        rejected: Survival, chosen: Survival, chosenKeysPresent: Bool
    ) -> RepairResolution {
        switch (rejected, chosen) {
        case (.removed, .survived):
            return .resolved
        case (.survived, .survived):
            return .unresolved
        case (.survived, _) where !chosenKeysPresent:
            return .inverted
        default:
            return .indeterminate
        }
    }

    private static func kind(
        _ repair: SelfRepair, reparandum: Anchor, reparans: Anchor, rawTokens: [Token],
        hasRationale: Bool
    ) -> RepairKind {
        switch repair.intent {
        case .abandonment:
            return .abandonedIdea
        case .hedge:
            return .uncertainty
        case .correction:
            if reparandum.category == .numeric, reparans.category == .numeric {
                return .valueChange
            }
            guard reparandum.category == .proper, reparans.category == .proper else {
                return .correction
            }
            if isAgentive(rawTokens, reparandum, reparans) { return .reassignment }
            return hasRationale ? .rejectedAlternative : .entityChange
        }
    }

    private static func isAgentive(_ tokens: [Token], _ before: Anchor, _ after: Anchor) -> Bool {
        for anchor in [before, after] {
            let beforeKeys = tokens[max(0, anchor.range.lowerBound - 4)..<anchor.range.lowerBound]
                .filter(\.isWord).map(\.key)
            let afterKeys = tokens[
                anchor.range.upperBound..<min(tokens.count, anchor.range.upperBound + 3)
            ].filter(\.isWord).map(\.key)

            if let previous = beforeKeys.last,
                ["ask", "email", "ping", "page", "notify", "tell", "cc"].contains(previous)
            {
                return true
            }
            if beforeKeys.last == "to",
                beforeKeys.dropLast().suffix(3).contains(where: {
                    ["assign", "send", "sent", "delegate", "hand", "forward", "escalate"]
                        .contains($0)
                })
            {
                return true
            }
            if beforeKeys.suffix(2).elementsEqual(["loop", "in"]) { return true }
            if beforeKeys.suffix(2).elementsEqual(["owner", "is"])
                || beforeKeys.suffix(2).elementsEqual(["reviewer", "is"])
            {
                return true
            }
            if let next = afterKeys.first, ["should", "will", "can", "must"].contains(next),
                afterKeys.dropFirst().first == "review"
            {
                return true
            }
        }
        return false
    }

    private static func distinguishing(_ anchor: Anchor, from other: Anchor, _ tokens: [Token])
        -> [Int]
    {
        let shared = Set(tokens[other.range].map(\.key))
        let distinct = anchor.range.filter { !shared.contains(tokens[$0].key) }
        return distinct.isEmpty ? Array(anchor.range) : distinct
    }

    private static func preservation(_ survival: Survival) -> PreservationOutcome {
        switch survival {
        case .survived: .preserved
        case .removed: .dropped
        case .indeterminate: .unknown
        }
    }

    private static func rationaleClause(
        _ tokens: [Token], after index: Int, before limit: Int
    ) -> Range<Int>? {
        var cursor = index + 1
        let ceiling = min(limit, tokens.count, index + 12)
        while cursor < ceiling {
            if Lexicon.rationaleOpeners.contains(tokens[cursor].key) {
                var end = cursor + 1
                while end < min(tokens.count, cursor + 10) {
                    if let last = tokens[end].text.last, last == "." || last == "?" || last == "!" {
                        end += 1
                        break
                    }
                    end += 1
                }
                guard end > cursor + 1 else { return nil }
                return cursor..<end
            }
            if let last = tokens[cursor].text.last, last == "." || last == "?" || last == "!" {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    private static func constraintEvents(
        rawTokens: [Token], cleanTokens: [Token], rawCharacters: [Character],
        cleanCharacters: [Character], alignment: TokenAlignment
    ) -> [RepairEvent] {
        var events: [RepairEvent] = []
        var index = 0
        while index < rawTokens.count {
            guard SelfRepairScanner.markerMatch(rawTokens, at: index) == nil,
                let head = directiveHead(rawTokens, at: index)
            else {
                index += 1
                continue
            }
            var objectIndex = index + head.count
            while objectIndex < rawTokens.count,
                grammaticalBridge(after: head, token: rawTokens[objectIndex].key)
            {
                objectIndex += 1
            }
            guard objectIndex < rawTokens.count else { break }
            let object = rawTokens[objectIndex]
            guard object.isWord, !Lexicon.functionWords.contains(object.key),
                !Lexicon.isSkippable(rawTokens, at: objectIndex)
            else {
                index += 1
                continue
            }
            var end = objectIndex
            while end < rawTokens.count {
                if let last = rawTokens[end].text.last, last == "." || last == "?" || last == "!" {
                    end += 1
                    break
                }
                end += 1
            }
            let clause = index..<end
            let rawSpan = span(rawTokens, clause, rawCharacters)
            var cleanSpans: [TextSpan] = []
            if case .survived(let range) = alignment.survival(ofRaw: clause) {
                cleanSpans.append(span(cleanTokens, range, cleanCharacters))
            }
            events.append(
                RepairEvent(
                    kind: .constraint,
                    outcome: .preservation(
                        preservation(alignment.survival(ofRaw: clause))),
                    before: nil, after: rawSpan.text.trimmedForDisplay,
                    evidence: RepairEvidence(rawSpans: [rawSpan], cleanSpans: cleanSpans),
                    grade: .structural, signals: [.opensClause]))
            index = end
        }
        return events
    }

    private static func directiveHead(_ tokens: [Token], at index: Int) -> [String]? {
        Lexicon.directiveHeads.first { head in
            guard index + head.count <= tokens.count else { return false }
            return zip(head, tokens[index..<(index + head.count)]).allSatisfy { $0 == $1.key }
        }
    }

    private static func grammaticalBridge(after head: [String], token: String) -> Bool {
        if head == ["no", "need"] { return token == "to" }
        if head == ["refrain"] { return token == "from" }
        return token == "ever"
    }

    private static func isAllFiller(_ window: EditWindow, _ tokens: [Token]) -> Bool {
        window.isDeletion && window.rawTokens.allSatisfy { Lexicon.isSkippable(tokens, at: $0) }
    }

    private static func isRepetition(_ window: EditWindow, _ tokens: [Token]) -> Bool {
        guard window.isDeletion else { return false }
        let deleted = window.rawTokens.filter { !Lexicon.isSkippable(tokens, at: $0) }
            .map { tokens[$0].key }
        guard !deleted.isEmpty else { return false }
        let after = window.rawTokens.upperBound
        let following = tokens[after..<min(tokens.count, after + deleted.count)].map(\.key)
        let before = window.rawTokens.lowerBound
        let preceding = tokens[max(0, before - deleted.count)..<before].map(\.key)
        if deleted == following || deleted == preceding { return true }
        guard Set(deleted).count == 1, let stem = deleted.first else { return false }
        return following.first == stem || preceding.last == stem
    }

    private static func aggregate(
        _ kind: RepairKind, _ windows: [EditWindow], _ tokens: [Token], _ characters: [Character]
    ) -> RepairEvent? {
        guard !windows.isEmpty else { return nil }
        let spans = windows.map { span(tokens, $0.rawTokens, characters) }
        return RepairEvent(
            kind: kind, outcome: .cosmetic,
            before: spans.map(\.text).joined(separator: " "), after: nil,
            evidence: RepairEvidence(rawSpans: spans, cleanSpans: []),
            grade: .explicit, signals: [.alignmentProvenRemoval])
    }

    static func span(_ tokens: [Token], _ range: Range<Int>, _ characters: [Character]) -> TextSpan
    {
        guard !range.isEmpty, range.upperBound <= tokens.count else {
            return TextSpan(start: 0, end: 0, text: "")
        }
        let start = tokens[range.lowerBound].start
        let end = tokens[range.upperBound - 1].end
        return TextSpan(start: start, end: end, text: String(characters[start..<end]))
    }
}

extension String {
    var trimmedForDisplay: String {
        var value = Substring(self)
        while let last = value.last, last.isPunctuation || last.isWhitespace {
            value = value.dropLast()
        }
        while let first = value.first, first.isWhitespace { value = value.dropFirst() }
        return String(value)
    }
}
