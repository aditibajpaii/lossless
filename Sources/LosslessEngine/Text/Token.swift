import Foundation

public struct TextSpan: Codable, Hashable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Token: Hashable, Sendable {
    public let text: String
    public let start: Int
    public let end: Int
    public let key: String

    public var isWord: Bool { !key.isEmpty }
    public var isNumeric: Bool { key.first?.isNumber ?? false }
    public var isCapitalised: Bool { text.first?.isUppercase ?? false }
}

public enum Tokenizer {
    private static let splitters: Set<Character> = [
        ",", ";", ":", ".", "!", "?", "\u{2014}", "\u{2013}", "/", "\u{2026}",
    ]

    private static let alwaysSeparates: Set<Character> = ["\u{2014}", "\u{2013}", "/", "\u{2026}"]

    public static func tokenize(_ source: String) -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            guard !characters[index].isWhitespace else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, !characters[index].isWhitespace {
                index += 1
            }
            appendSplit(characters, start..<index, into: &tokens)
        }
        return tokens
    }

    private static func appendSplit(
        _ characters: [Character], _ chunk: Range<Int>, into tokens: inout [Token]
    ) {
        var start = chunk.lowerBound
        var index = chunk.lowerBound
        while index < chunk.upperBound {
            guard splitters.contains(characters[index]) else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < chunk.upperBound, splitters.contains(characters[runEnd]) { runEnd += 1 }
            guard runEnd < chunk.upperBound, runEnd > start,
                characters[runEnd].isLetter
                    || characters[index..<runEnd].contains(where: alwaysSeparates.contains)
            else {
                index = runEnd
                continue
            }
            append(characters, start..<runEnd, into: &tokens)
            start = runEnd
            index = runEnd
        }
        append(characters, start..<chunk.upperBound, into: &tokens)
    }

    private static func append(
        _ characters: [Character], _ range: Range<Int>, into tokens: inout [Token]
    ) {
        guard !range.isEmpty else { return }
        let text = String(characters[range])
        tokens.append(
            Token(
                text: text, start: range.lowerBound, end: range.upperBound,
                key: comparisonKey(text)))
    }

    public static func comparisonKey(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let kept = folded.filter { $0.isLetter || $0.isNumber || $0 == "'" }
        return String(
            kept.drop(while: { $0 == "'" }).reversed().drop(while: { $0 == "'" }).reversed())
    }
}
