public enum AnchorCategory: String, Sendable {
    case numeric
    case proper
    case word
}

public struct Anchor: Hashable, Sendable {
    public let range: Range<Int>
    public let category: AnchorCategory

    public var index: Int { range.lowerBound }
}

public struct FrameSignature: Hashable, Sendable {
    public let left: [String]
    public let right: [String]

    public var isEmpty: Bool { left.isEmpty && right.isEmpty }
}

public enum FrameMatch: Int, Hashable, Sendable, Comparable {
    case none
    case partial
    case aligned

    public static func < (lhs: FrameMatch, rhs: FrameMatch) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct CorrectionEvidence: Hashable, Sendable {
    public let tier: MarkerTier
    public let category: AnchorCategory
    public let opensClause: Bool
    public let anchorsCompatible: Bool
    public let frame: FrameMatch
    public let slotIsFragment: Bool
    public let additiveCue: Bool
    public let freshSubject: Bool
    public let ambiguousSlot: Bool

    public var parallelFrame: Bool { frame >= .partial }

    public var admitsCorrection: Bool {
        guard anchorsCompatible, !ambiguousSlot else { return false }
        switch tier {
        case .explicit:
            return opensClause || category != .word
        case .strong, .ambiguous:
            guard opensClause, !additiveCue, !freshSubject else { return false }
            return category == .word ? parallelFrame : (parallelFrame || slotIsFragment)
        case .epistemic:
            return false
        }
    }

    public var grade: EvidenceGrade {
        switch tier {
        case .explicit: .explicit
        case .strong: .structural
        case .ambiguous: (frame >= .aligned || category != .word) ? .structural : .ambiguous
        case .epistemic: .structural
        }
    }

    public var signals: Set<EvidenceSignal> {
        var signals: Set<EvidenceSignal> = []
        switch tier {
        case .explicit: signals.insert(.explicitMarker)
        case .strong: signals.insert(.strongMarker)
        case .ambiguous, .epistemic: signals.insert(.ambiguousMarker)
        }
        if opensClause { signals.insert(.opensClause) }
        if anchorsCompatible { signals.insert(.anchorsCompatible) }
        if frame >= .partial { signals.insert(.parallelFrame) }
        if frame >= .aligned { signals.insert(.alignedFrame) }
        if slotIsFragment { signals.insert(.slotIsFragment) }
        if category != .word { signals.insert(.lexicalAnchor) }
        return signals
    }

    public var summary: String {
        let notes = [
            opensClause ? "opensClause" : nil, anchorsCompatible ? "anchorsCompatible" : nil,
            frame == .none ? nil : "frame(\(frame))", slotIsFragment ? "slotIsFragment" : nil,
            additiveCue ? "additiveCue(veto)" : nil, freshSubject ? "freshSubject(veto)" : nil,
            ambiguousSlot ? "ambiguousSlot(veto)" : nil,
        ]
        return
            "\(tier)/\(grade.rawValue) \(category) [\(notes.compactMap(\.self).joined(separator: " "))]"
    }
}

public struct SelfRepair: Hashable, Sendable {
    public let markerRange: Range<Int>
    public let intent: MarkerIntent
    public let tier: MarkerTier
    public let reparandum: Anchor?
    public let reparans: Anchor?
    public let evidence: CorrectionEvidence?
}

public enum SelfRepairScanner {
    private static let forwardLimit = 8
    private static let backwardLimit = 24
    private static let retraceWindow = 6
    private static let fragmentLimit = 4
    private static let frameWidth = 3

    public static func scan(_ tokens: [Token]) -> [SelfRepair] {
        var repairs: [SelfRepair] = []
        var index = 0

        while index < tokens.count {
            guard let match = markerMatch(tokens, at: index) else {
                index += 1
                continue
            }
            var end = index + match.keys.count
            var tier = match.tier
            while let next = markerMatch(tokens, at: end), next.intent == match.intent {
                end += next.keys.count
                tier = stronger(tier, next.tier)
            }
            while end < tokens.count, Lexicon.isSkippable(tokens, at: end) { end += 1 }

            let range = index..<end
            if match.intent == .hedge {
                repairs.append(
                    SelfRepair(
                        markerRange: range, intent: .hedge, tier: tier,
                        reparandum: nil, reparans: nil, evidence: nil))
                index = end
                continue
            }

            let reparans = forwardAnchor(
                tokens, from: end, retraced: retracedFrame(tokens, before: index))
            let reparandum = reparans.flatMap {
                backwardAnchor(tokens, before: index, matching: $0)
            }
            let evidence = evidence(
                tokens, tier: tier, markerStart: index, slotStart: end,
                reparandum: reparandum, reparans: reparans)

            guard evidence.admitsCorrection else {
                index += 1
                continue
            }
            repairs.append(
                SelfRepair(
                    markerRange: range, intent: match.intent, tier: tier,
                    reparandum: reparandum, reparans: reparans, evidence: evidence))
            index = end
        }
        return repairs
    }

    private static func stronger(_ lhs: MarkerTier, _ rhs: MarkerTier) -> MarkerTier {
        let order: [MarkerTier: Int] = [.epistemic: 0, .ambiguous: 1, .strong: 2, .explicit: 3]
        return (order[lhs] ?? 0) >= (order[rhs] ?? 0) ? lhs : rhs
    }

    private static func evidence(
        _ tokens: [Token], tier: MarkerTier, markerStart: Int, slotStart: Int,
        reparandum: Anchor?, reparans: Anchor?
    ) -> CorrectionEvidence {
        let slot = slot(tokens, from: slotStart)
        let category = reparans?.category ?? .word
        return CorrectionEvidence(
            tier: tier,
            category: category,
            opensClause: Lexicon.opensClause(tokens, markerStart),
            anchorsCompatible: reparandum != nil && reparandum?.category == category,
            frame: frameMatch(tokens, reparandum, reparans),
            slotIsFragment: contentCount(tokens, slot) <= fragmentLimit,
            additiveCue: hasAdditiveCue(tokens, slot),
            freshSubject: opensWithSubject(tokens, slot),
            ambiguousSlot: category != .word && anchorCount(tokens, slot, category) > 1)
    }

    private static func slot(_ tokens: [Token], from start: Int) -> Range<Int> {
        var end = start
        let ceiling = min(tokens.count, start + forwardLimit)
        while end < ceiling {
            if end > start, markerMatch(tokens, at: end) != nil { break }
            if end > start, Lexicon.slotTerminators.contains(tokens[end].key) { break }
            if endsSlot(tokens[end]) {
                end += 1
                break
            }
            end += 1
        }
        return start..<end
    }

    private static func anchorCount(
        _ tokens: [Token], _ range: Range<Int>, _ category: AnchorCategory
    ) -> Int {
        var count = 0
        var inRun = false
        for index in range {
            let isAnchor =
                tokens[index].isWord && !Lexicon.isSkippable(tokens, at: index)
                && markerMatch(tokens, at: index) == nil
                && self.category(tokens, index) == category
            if isAnchor, !inRun { count += 1 }
            inRun = isAnchor
        }
        return count
    }

    private static func contentCount(_ tokens: [Token], _ range: Range<Int>) -> Int {
        range.filter { isContent(tokens, $0) }.count
    }

    private static func isContent(_ tokens: [Token], _ index: Int) -> Bool {
        let token = tokens[index]
        return token.isWord && !Lexicon.isSkippable(tokens, at: index)
            && !Lexicon.functionWords.contains(token.key)
    }

    private static func hasAdditiveCue(_ tokens: [Token], _ range: Range<Int>) -> Bool {
        for index in range where Lexicon.additiveCues.contains(tokens[index].key) { return true }
        for phrase in Lexicon.additivePhrases {
            for index in range where index + phrase.count <= tokens.count {
                if zip(phrase, tokens[index..<(index + phrase.count)]).allSatisfy({ $0 == $1.key })
                {
                    return true
                }
            }
        }
        return false
    }

    private static func opensWithSubject(_ tokens: [Token], _ range: Range<Int>) -> Bool {
        let meaningful = range.filter { tokens[$0].isWord && !Lexicon.isSkippable(tokens, at: $0) }
        guard let first = meaningful.first else { return false }
        let head = tokens[first]
        if Lexicon.subjectPronouns.contains(head.key) { return true }

        let rest = meaningful.dropFirst()
        if head.isCapitalised, !Lexicon.functionWords.contains(head.key),
            let next = rest.first, Lexicon.headsPredicate(tokens[next])
        {
            return true
        }
        if Lexicon.determiners.contains(head.key), rest.count >= 2,
            Lexicon.headsPredicate(tokens[rest.dropFirst().first ?? first])
        {
            return true
        }
        return false
    }

    static func frameMatch(_ tokens: [Token], _ before: Anchor?, _ after: Anchor?) -> FrameMatch {
        guard let before, let after else { return .none }
        let left = signature(tokens, of: before)
        let right = signature(tokens, of: after)
        guard !left.isEmpty, !right.isEmpty else { return .none }

        let leftAgreement = agreement(left.left, right.left)
        let rightAgreement = agreement(left.right, right.right)
        if leftAgreement >= 2 || rightAgreement >= 2 { return .aligned }
        if leftAgreement >= 1 && rightAgreement >= 1 { return .aligned }
        if leftAgreement >= 1 || rightAgreement >= 1 { return .partial }
        return .none
    }

    private static func agreement(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    static func signature(_ tokens: [Token], of anchor: Anchor) -> FrameSignature {
        FrameSignature(
            left: neighbours(tokens, from: anchor.range.lowerBound - 1, step: -1),
            right: neighbours(tokens, from: anchor.range.upperBound, step: 1))
    }

    private static func neighbours(_ tokens: [Token], from start: Int, step: Int) -> [String] {
        var keys: [String] = []
        var cursor = start
        while cursor >= 0, cursor < tokens.count, keys.count < frameWidth {
            let token = tokens[cursor]
            if step < 0, endsClause(token) { break }
            if !token.isWord || Lexicon.isSkippable(tokens, at: cursor)
                || isMarkerToken(tokens, cursor)
            {
                cursor += step
                continue
            }
            keys.append(token.key)
            if step > 0, endsClause(token) { break }
            cursor += step
        }
        return keys
    }

    private static func isMarkerToken(_ tokens: [Token], _ index: Int) -> Bool {
        for start in max(0, index - 1)...index {
            guard let marker = markerMatch(tokens, at: start) else { continue }
            if index < start + marker.keys.count { return true }
        }
        return false
    }

    static func markerMatch(_ tokens: [Token], at index: Int) -> RepairMarker? {
        Lexicon.markerKeys(tokens, at: index)
    }

    private static func forwardAnchor(_ tokens: [Token], from start: Int, retraced: Set<String>)
        -> Anchor?
    {
        var fallback: Anchor?
        for index in start..<min(tokens.count, start + forwardLimit) {
            let token = tokens[index]
            guard token.isWord, !Lexicon.isSkippable(tokens, at: index),
                markerMatch(tokens, at: index) == nil, !retraced.contains(token.key)
            else { continue }
            let category = category(tokens, index)
            if category != .word {
                return Anchor(range: phrase(tokens, around: index, category), category: category)
            }
            if fallback == nil, !Lexicon.functionWords.contains(token.key) {
                fallback = Anchor(range: index..<(index + 1), category: .word)
            }
            if endsClause(token) { break }
        }
        return fallback
    }

    private static func backwardAnchor(
        _ tokens: [Token], before end: Int, matching reparans: Anchor
    ) -> Anchor? {
        var fallback: Anchor?
        let lowerBound = max(0, end - backwardLimit)
        for index in stride(from: end - 1, through: lowerBound, by: -1) {
            let token = tokens[index]
            guard token.isWord, !Lexicon.isSkippable(tokens, at: index),
                markerMatch(tokens, at: index) == nil
            else { continue }
            guard token.key != tokens[reparans.index].key else { continue }
            let category = category(tokens, index)
            if category == reparans.category {
                return Anchor(range: phrase(tokens, around: index, category), category: category)
            }
            if fallback == nil, reparans.category == .word,
                !Lexicon.functionWords.contains(token.key)
            {
                fallback = Anchor(range: index..<(index + 1), category: .word)
            }
        }
        return fallback
    }

    private static func phrase(_ tokens: [Token], around index: Int, _ category: AnchorCategory)
        -> Range<Int>
    {
        guard category != .word else { return index..<(index + 1) }
        var lower = index
        while lower > 0, continues(tokens, lower - 1, category), !opensSentence(tokens, lower - 1),
            !endsSlot(tokens[lower - 1])
        {
            lower -= 1
        }
        var upper = index + 1
        while upper < tokens.count, !endsSlot(tokens[upper - 1]),
            continues(tokens, upper, category),
            !opensSentence(tokens, upper)
        {
            upper += 1
        }
        return lower..<upper
    }

    private static func continues(_ tokens: [Token], _ index: Int, _ category: AnchorCategory)
        -> Bool
    {
        let token = tokens[index]
        guard token.isWord, !Lexicon.isSkippable(tokens, at: index),
            markerMatch(tokens, at: index) == nil
        else { return false }
        switch category {
        case .proper:
            return token.isCapitalised && !token.isNumeric
                && !Lexicon.functionWords.contains(token.key)
        case .numeric:
            return self.category(tokens, index) == .numeric
        case .word:
            return false
        }
    }

    private static func opensSentence(_ tokens: [Token], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let last = tokens[index - 1].text.last else { return true }
        return last == "." || last == "!" || last == "?" || last == ";"
    }

    private static func retracedFrame(_ tokens: [Token], before index: Int) -> Set<String> {
        let lowerBound = max(0, index - retraceWindow)
        guard lowerBound < index else { return [] }
        return Set(tokens[lowerBound..<index].filter(\.isWord).map(\.key))
    }

    static func category(_ tokens: [Token], _ index: Int) -> AnchorCategory {
        let token = tokens[index]
        if token.isNumeric || Lexicon.temporal.contains(token.key)
            || Lexicon.numberWords.contains(token.key)
        {
            return .numeric
        }
        if token.isCapitalised, !Lexicon.functionWords.contains(token.key) { return .proper }
        return .word
    }

    private static func endsSlot(_ token: Token) -> Bool {
        guard let last = token.text.last else { return false }
        return last == "." || last == "!" || last == "?" || last == ";" || last == ","
            || last == ":"
    }

    static func endsClause(_ token: Token) -> Bool {
        guard let last = token.text.last else { return false }
        return last == "." || last == "!" || last == "?" || last == ";"
    }
}
