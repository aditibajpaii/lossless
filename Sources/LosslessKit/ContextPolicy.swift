import Foundation

public enum ContextLevel: String, CaseIterable, Sendable, Codable {
    case off
    case appOnly
    case appAndWindow

    public var title: String {
        switch self {
        case .off: "Off"
        case .appOnly: "App name"
        case .appAndWindow: "App and window"
        }
    }

    public var detail: String {
        switch self {
        case .off: "Only your audio and Key Terms are sent."
        case .appOnly: "The name of the app you are dictating into is sent with your audio."
        case .appAndWindow:
            "The app name and the window title are sent with your audio. Window titles can "
                + "contain document names, subject lines and customer names."
        }
    }
}

public enum ContextPolicy {
    public static let neverSendWindowTitle: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
    ]

    public static let windowTitleLimit = 120

    public static func prompt(
        level: ContextLevel, application: String?, windowTitle: String?, bundleIdentifier: String?,
        blocked: Set<String> = []
    ) -> String? {
        guard level != .off, let application, !application.isEmpty else { return nil }
        if let bundleIdentifier, blocked.contains(bundleIdentifier) { return nil }

        let base = "The speaker is dictating into \(application)."
        guard level == .appAndWindow, let windowTitle else { return base }
        if let bundleIdentifier, neverSendWindowTitle.contains(bundleIdentifier) { return base }

        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != application else { return base }
        let capped =
            trimmed.count > windowTitleLimit
            ? String(trimmed.prefix(windowTitleLimit)) : trimmed
        return "\(base) The window is titled \"\(capped)\"."
    }

    public static func disclosureLines(level: ContextLevel, hasKeyTerms: Bool) -> [String] {
        var parts = ["Audio is sent to AssemblyAI for transcription."]
        switch level {
        case .off: break
        case .appOnly: parts.append("The name of the app you dictate into is sent with it.")
        case .appAndWindow:
            parts.append("The app name and window title are sent with it.")
        }
        if hasKeyTerms { parts.append("Your Key Terms are sent with it.") }
        return parts
    }

    public static func disclosure(level: ContextLevel, hasKeyTerms: Bool) -> String {
        disclosureLines(level: level, hasKeyTerms: hasKeyTerms).joined(separator: " ")
    }
}
