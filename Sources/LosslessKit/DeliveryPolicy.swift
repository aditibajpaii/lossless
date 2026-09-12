import Foundation

public enum TargetSafety: Sendable, Equatable {
    case editable
    case nonEditable
    case secure
    case unknown

    public var allowsPaste: Bool { self == .editable }

    public var allowsDictation: Bool { self != .secure }
}

public enum TargetContinuity: Sendable, Equatable {
    case intact
    case movedOn
    case vanished
}

public struct DeliveryPreconditions: Sendable {
    public let accessibilityTrusted: Bool
    public let canPostEvents: Bool
    public let hasTarget: Bool
    public let safetyNow: TargetSafety
    public let continuity: TargetContinuity
    public let hasEventSource: Bool

    public init(
        accessibilityTrusted: Bool, canPostEvents: Bool, hasTarget: Bool,
        safetyNow: TargetSafety, continuity: TargetContinuity, hasEventSource: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.canPostEvents = canPostEvents
        self.hasTarget = hasTarget
        self.safetyNow = safetyNow
        self.continuity = continuity
        self.hasEventSource = hasEventSource
    }
}

public enum DeliveryPlan: Equatable, Sendable {
    case paste
    case copy(reason: String)
    case withhold(reason: String)
}

public enum DeliveryPolicy {
    public static func plan(_ preconditions: DeliveryPreconditions) -> DeliveryPlan {
        if preconditions.safetyNow == .secure {
            return .withhold(reason: "Secure field")
        }
        guard preconditions.accessibilityTrusted else {
            return .copy(reason: "Accessibility not granted")
        }
        guard preconditions.canPostEvents else { return .copy(reason: "Cannot post keystrokes") }
        guard preconditions.hasTarget else { return .copy(reason: "No target app") }
        switch preconditions.continuity {
        case .vanished: return .copy(reason: "Target closed")
        case .movedOn: return .copy(reason: "Target changed")
        case .intact: break
        }
        switch preconditions.safetyNow {
        case .secure: return .withhold(reason: "Secure field")
        case .nonEditable: return .copy(reason: "Nothing to type into")
        case .unknown: return .copy(reason: "Target unavailable")
        case .editable: break
        }
        guard preconditions.hasEventSource else { return .copy(reason: "No event source") }
        return .paste
    }

    public static func shouldRestoreClipboard(ourChangeCount: Int, currentChangeCount: Int) -> Bool
    {
        ourChangeCount == currentChangeCount
    }
}
