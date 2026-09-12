import AppKit
import ApplicationServices
import CoreGraphics
import LosslessKit

struct TargetFingerprint: Equatable, Sendable {
    let windowTitle: String?
    let document: String?
    let elementRole: String?
    let elementIdentifier: String?
    let elementOrigin: CGPoint?

    func matches(_ other: TargetFingerprint) -> Bool {
        func agree<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
            guard let lhs, let rhs else { return true }
            return lhs == rhs
        }
        return agree(windowTitle, other.windowTitle) && agree(document, other.document)
            && agree(elementRole, other.elementRole)
            && agree(elementIdentifier, other.elementIdentifier)
            && agree(elementOrigin, other.elementOrigin)
    }
}

struct TargetIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String?
    let windowTitle: String?
    let windowFrame: CGRect?
    let fingerprint: TargetFingerprint
}

struct FocusContext: Sendable {
    let identity: TargetIdentity?
    let safety: TargetSafety

    var applicationName: String? { identity?.applicationName }
    var bundleIdentifier: String? { identity?.bundleIdentifier }
    var windowTitle: String? { identity?.windowTitle }
    var windowFrame: CGRect? { identity?.windowFrame }

    static let unknown = FocusContext(identity: nil, safety: .unknown)
}

enum Focus {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case microphone = "Privacy_Microphone"
    }

    static func requestInputMonitoring() -> Bool {
        CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    }

    static func openSettings(_ pane: SettingsPane) {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func capture() -> FocusContext {
        guard let application = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let pid = application.processIdentifier
        let window = focusedWindow(pid)
        let identity = TargetIdentity(
            processIdentifier: pid,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName,
            windowTitle: window.title, windowFrame: window.frame,
            fingerprint: fingerprint(pid, window: window))
        return FocusContext(identity: identity, safety: safety(of: pid))
    }

    @MainActor
    static func verify(_ identity: TargetIdentity) -> (
        continuity: TargetContinuity, safety: TargetSafety
    ) {
        guard
            let application = NSRunningApplication(processIdentifier: identity.processIdentifier),
            !application.isTerminated
        else { return (.vanished, .unknown) }
        if let expected = identity.bundleIdentifier, let actual = application.bundleIdentifier,
            expected != actual
        {
            return (.vanished, .unknown)
        }

        let safety = safety(of: identity.processIdentifier)
        guard application.isActive,
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == identity.processIdentifier
        else { return (.movedOn, safety) }

        let window = focusedWindow(identity.processIdentifier)
        guard
            fingerprint(identity.processIdentifier, window: window)
                .matches(identity.fingerprint)
        else { return (.movedOn, safety) }
        return (.intact, safety)
    }

    private static func safety(of pid: pid_t) -> TargetSafety {
        guard accessibilityTrusted else { return .unknown }
        guard let element = focusedElement(pid) else { return .unknown }
        let focused = facts(element)
        var textFields: [NodeFacts] = []
        var secureFields: [NodeFacts] = []
        if focused.role == "AXWebArea" || focused.role == (kAXGroupRole as String) {
            collect(element, depth: 0, textFields: &textFields, secureFields: &secureFields)
        }
        return TargetSafety.infer(
            EditabilityEvidence(
                focused: focused, descendantTextFields: textFields,
                descendantSecureFields: secureFields))
    }

    private static func facts(_ element: AXUIElement) -> NodeFacts {
        var valueSettable = DarwinBoolean(false)
        let valueKnown =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
            == .success
        var rangeSettable = DarwinBoolean(false)
        let rangeKnown =
            AXUIElementIsAttributeSettable(
                element, kAXSelectedTextAttribute as CFString, &rangeSettable) == .success
        return NodeFacts(
            role: string(element, kAXRoleAttribute),
            subrole: string(element, kAXSubroleAttribute),
            publishedEditable: boolean(element, "AXIsEditable"),
            valueSettable: valueKnown ? valueSettable.boolValue : nil,
            selectedTextSettable: rangeKnown ? rangeSettable.boolValue : nil,
            focused: boolean(element, kAXFocusedAttribute as String) == true)
    }

    private static func collect(
        _ element: AXUIElement, depth: Int, textFields: inout [NodeFacts],
        secureFields: inout [NodeFacts]
    ) {
        guard depth < 24, textFields.count + secureFields.count < 400 else { return }
        if depth > 0 {
            let node = facts(element)
            if node.isSecure {
                secureFields.append(node)
            } else if node.isTextEntry, node.hasSettableText {
                textFields.append(node)
            }
        }
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
                == .success, let children = raw as? [AXUIElement]
        else { return }
        for child in children {
            collect(child, depth: depth + 1, textFields: &textFields, secureFields: &secureFields)
        }
    }

    private static func fingerprint(_ pid: pid_t, window: (title: String?, frame: CGRect?))
        -> TargetFingerprint
    {
        let element = focusedElement(pid)
        return TargetFingerprint(
            windowTitle: window.title,
            document: focusedWindowDocument(pid),
            elementRole: element.flatMap { string($0, kAXRoleAttribute) },
            elementIdentifier: element.flatMap { string($0, "AXIdentifier") },
            elementOrigin: element.flatMap(origin))
    }

    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        guard accessibilityTrusted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        if let focused = copyElement(application, kAXFocusedUIElementAttribute) { return focused }
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return copyElement(application, kAXFocusedUIElementAttribute)
    }

    private static func focusedWindowElement(_ pid: pid_t) -> AXUIElement? {
        guard accessibilityTrusted else { return nil }
        return copyElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    private static func focusedWindowDocument(_ pid: pid_t) -> String? {
        guard let window = focusedWindowElement(pid) else { return nil }
        return string(window, kAXDocumentAttribute) ?? string(window, "AXURL")
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
            let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        if let text = raw as? String { return text }
        if let url = raw as? URL { return url.absoluteString }
        return nil
    }

    private static func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
            let value = raw, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private static func origin(_ element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw)
                == .success, let value = raw, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func focusedWindow(_ pid: pid_t) -> (title: String?, frame: CGRect?) {
        guard let focused = focusedWindowElement(pid) else { return (nil, nil) }
        let title = string(focused, kAXTitleAttribute)

        var size = CGSize.zero
        var sizeValue: CFTypeRef?
        guard let point = origin(focused),
            AXUIElementCopyAttributeValue(focused, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID(),
            AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return (title, nil) }
        return (title, CGRect(origin: point, size: size))
    }
}
