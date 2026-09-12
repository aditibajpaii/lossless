import AppKit
import CoreGraphics
import LosslessEngine
import LosslessKit

struct InsertionReceipt: Sendable {
    let bundleIdentifier: String?
    let text: String
    let createdAt: Date
}

enum Injector {
    enum Outcome: Sendable {
        case pasted(InsertionReceipt)
        case copied(reason: String)
        case withheld(reason: String)

        var route: DeliveryRoute {
            switch self {
            case .pasted: .pasted
            case .copied(let reason): .copied(reason: reason)
            case .withheld(let reason): .withheld(reason: reason)
            }
        }
    }

    private static let pasteVirtualKey: CGKeyCode = 9

    @MainActor
    static func copy(_ text: String, reason: String) -> Outcome {
        guard Clipboard.write(text) != nil else {
            return .withheld(reason: "Clipboard unavailable")
        }
        return .copied(reason: reason)
    }

    @MainActor
    static func deliver(_ text: String, into context: FocusContext) async -> Outcome {
        let identity = context.identity
        let trusted = Focus.accessibilityTrusted
        let canPostEvents = CGPreflightPostEventAccess()

        var safetyNow = TargetSafety.unknown
        var continuity = TargetContinuity.vanished
        if let identity, trusted {
            (continuity, safetyNow) = Focus.verify(identity)
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let plan = DeliveryPolicy.plan(
            DeliveryPreconditions(
                accessibilityTrusted: trusted, canPostEvents: canPostEvents,
                hasTarget: identity != nil, safetyNow: safetyNow, continuity: continuity,
                hasEventSource: source != nil))

        switch plan {
        case .withhold(let reason):
            Diagnostics.note("delivery withheld: \(reason)")
            return .withheld(reason: reason)
        case .copy(let reason):
            Diagnostics.note("delivery fell back to clipboard: \(reason)")
            return copy(text, reason: reason)
        case .paste:
            break
        }

        guard let identity, let source else { return .copied(reason: "Target unavailable") }

        guard
            let down = CGEvent(
                keyboardEventSource: source, virtualKey: pasteVirtualKey, keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source, virtualKey: pasteVirtualKey, keyDown: false)
        else {
            guard Clipboard.write(text) != nil else {
                return .withheld(reason: "Clipboard unavailable")
            }
            return .copied(reason: "Cannot create paste event")
        }

        let restore = Clipboard.capture()
        if restore.isPartial {
            Diagnostics.note("clipboard holds a representation that cannot be reproduced")
        }
        guard let ours = Clipboard.write(text) else {
            return .withheld(reason: "Clipboard unavailable")
        }

        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        try? await Task.sleep(for: .milliseconds(220))
        Clipboard.restore(restore, ourChangeCount: ours)

        return .pasted(
            InsertionReceipt(
                bundleIdentifier: identity.bundleIdentifier, text: text, createdAt: Date()))
    }
}
