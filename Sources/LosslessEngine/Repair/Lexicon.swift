public enum MarkerIntent: String, Codable, Sendable {
    case correction
    case abandonment
    case hedge
}

public enum MarkerTier: Sendable {
    case explicit
    case strong
    case ambiguous
    case epistemic
}

public struct RepairMarker: Hashable, Sendable {
    public let keys: [String]
    public let intent: MarkerIntent
    public let tier: MarkerTier

    public static func == (lhs: RepairMarker, rhs: RepairMarker) -> Bool { lhs.keys == rhs.keys }
    public func hash(into hasher: inout Hasher) { hasher.combine(keys) }
}

public enum Lexicon {
    public static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "erm", "ah", "ahh", "hmm", "mm", "mhm",
    ]

    public static let discourseParticles: Set<String> = [
        "oh", "ohh", "ooh", "well", "okay", "ok", "anyway", "yeah", "yup", "yep",
    ]

    public static let markers: [RepairMarker] = [
        RepairMarker(keys: ["scratch", "that"], intent: .abandonment, tier: .explicit),
        RepairMarker(keys: ["never", "mind"], intent: .abandonment, tier: .explicit),
        RepairMarker(keys: ["nevermind"], intent: .abandonment, tier: .explicit),
        RepairMarker(keys: ["forget", "that"], intent: .abandonment, tier: .explicit),
        RepairMarker(keys: ["make", "that"], intent: .correction, tier: .explicit),
        RepairMarker(keys: ["no", "wait"], intent: .correction, tier: .explicit),
        RepairMarker(keys: ["wait", "no"], intent: .correction, tier: .explicit),
        RepairMarker(keys: ["correction"], intent: .correction, tier: .explicit),
        RepairMarker(keys: ["i", "mean"], intent: .correction, tier: .strong),
        RepairMarker(keys: ["or", "rather"], intent: .correction, tier: .strong),
        RepairMarker(keys: ["excuse", "me"], intent: .correction, tier: .strong),
        RepairMarker(keys: ["sorry"], intent: .correction, tier: .strong),
        RepairMarker(keys: ["actually"], intent: .correction, tier: .ambiguous),
        RepairMarker(keys: ["rather"], intent: .correction, tier: .ambiguous),
        RepairMarker(keys: ["i", "think"], intent: .hedge, tier: .epistemic),
        RepairMarker(keys: ["maybe"], intent: .hedge, tier: .epistemic),
        RepairMarker(keys: ["probably"], intent: .hedge, tier: .epistemic),
        RepairMarker(keys: ["not", "sure"], intent: .hedge, tier: .epistemic),
    ]

    public static let additiveCues: Set<String> = [
        "too", "also", "either", "both", "besides", "additionally", "plus",
    ]

    public static let additivePhrases: [[String]] = [["as", "well"], ["in", "addition"]]

    public static let subjectPronouns: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "there", "that", "this", "who",
    ]

    public static let determiners: Set<String> = ["the", "a", "an", "my", "our", "their", "its"]

    public static let modals: Set<String> = [
        "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "wont", "won't", "cant", "can't", "shouldnt", "shouldn't",
    ]

    public static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "be", "been", "being",
        "has", "have", "had", "do", "does", "did", "gets", "got",
    ]

    public static let directiveHeads: [[String]] = [
        ["dont"], ["don't"], ["do", "not"], ["must", "not"], ["mustn't"], ["cannot"],
        ["cant"], ["can't"], ["never"], ["avoid"], ["refrain"], ["shouldn't"],
        ["shouldnt"], ["should", "not"], ["won't"], ["wont"], ["no", "need"],
    ]

    public static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million",
        "once", "twice", "thrice", "half", "double", "triple", "quarter",
    ]

    public static let temporal: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "today", "tomorrow", "yesterday",
    ]

    public static let agentiveWords: Set<String> = [
        "assign", "assigned", "ask", "asked", "cc", "notify", "send", "sent", "tell",
        "told", "review", "reviewed", "reviewer", "owner", "owns", "owned", "escalate",
        "email", "ping", "page", "delegate", "hand", "forward", "loop", "call",
    ]

    public static let slotTerminators: Set<String> = ["because", "since", "cos", "cause"]

    public static let rationaleOpeners: Set<String> = ["because", "since", "cos", "cause"]

    public static let functionWords: Set<String> = [
        "the", "a", "an", "to", "of", "and", "or", "but", "is", "are", "be", "it",
        "we", "i", "you", "they", "he", "she", "this", "that", "for", "on", "in",
        "with", "at", "use", "using", "set", "make", "let", "just", "so", "then",
        "no", "not", "should", "would", "could", "will", "can", "do", "does",
    ]

    public static func isFiller(_ key: String) -> Bool { fillers.contains(key) }

    public static func isDiscourseParticle(_ tokens: [Token], at index: Int) -> Bool {
        guard tokens.indices.contains(index),
            discourseParticles.contains(tokens[index].key),
            opensClause(tokens, index)
        else { return false }

        if let last = tokens[index].text.last, last.isPunctuation || last.isSymbol { return true }
        let next = index + 1
        guard next < tokens.count else { return false }
        if isFiller(tokens[next].key) { return true }
        if discourseParticles.contains(tokens[next].key) { return true }
        return markerKeys(tokens, at: next) != nil
    }

    public static func isSkippable(_ tokens: [Token], at index: Int) -> Bool {
        guard tokens.indices.contains(index) else { return false }
        return isFiller(tokens[index].key) || isDiscourseParticle(tokens, at: index)
    }

    public static func opensClause(_ tokens: [Token], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = tokens[index - 1]
        if isFiller(previous.key) { return true }
        if markerKeys(tokens, at: index - 1) != nil { return true }
        guard let last = previous.text.last else { return true }
        return last.isPunctuation || last.isSymbol
    }

    static func markerKeys(_ tokens: [Token], at index: Int) -> RepairMarker? {
        markers.first { marker in
            guard index + marker.keys.count <= tokens.count else { return false }
            return zip(marker.keys, tokens[index..<(index + marker.keys.count)])
                .allSatisfy { $0 == $1.key }
        }
    }

    public static func headsPredicate(_ token: Token) -> Bool {
        let key = token.key
        if modals.contains(key) || auxiliaries.contains(key) { return true }
        if agentiveWords.contains(key) { return true }
        guard !functionWords.contains(key), token.text.first?.isLowercase == true, key.count > 3
        else { return false }
        if key.hasSuffix("ed") { return true }
        return key.hasSuffix("s") && !key.hasSuffix("ss") && !key.hasSuffix("us")
    }
}
