import Foundation

public enum AnalysisScope: String, Codable, Hashable, Sendable {
    case english
    case unsupported

    public var verifiesRepairs: Bool { self == .english }
}

public enum LanguageScope {
    public static func of(_ text: String) -> AnalysisScope {
        var latin = 0
        var other = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) {
                latin += 1
            } else {
                other += 1
            }
        }
        guard latin + other >= 8 else { return .english }
        return other > latin ? .unsupported : .english
    }
}
