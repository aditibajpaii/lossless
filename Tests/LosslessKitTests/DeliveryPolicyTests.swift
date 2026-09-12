import AppKit
import Foundation
import Testing

@testable import LosslessKit

private func preconditions(
    accessibility: Bool = true, postEvents: Bool = true, target: Bool = true,
    safety: TargetSafety = .editable, continuity: TargetContinuity = .intact,
    eventSource: Bool = true
) -> DeliveryPreconditions {
    DeliveryPreconditions(
        accessibilityTrusted: accessibility, canPostEvents: postEvents, hasTarget: target,
        safetyNow: safety, continuity: continuity, hasEventSource: eventSource)
}

@Suite("Delivery policy")
struct DeliveryPolicyTests {
    @Test("a verified editable target is pasted into")
    func pastes() {
        #expect(DeliveryPolicy.plan(preconditions()) == .paste)
    }

    @Test("a password field gets neither a paste nor a clipboard write")
    func secureField() {
        #expect(
            DeliveryPolicy.plan(preconditions(safety: .secure))
                == .withhold(reason: "Secure field"))
    }

    @Test("a password field is refused even when nothing else is provable")
    func secureFieldBeatsEverything() {
        #expect(
            DeliveryPolicy.plan(
                preconditions(
                    accessibility: false, postEvents: false, target: false, safety: .secure,
                    continuity: .vanished, eventSource: false))
                == .withhold(reason: "Secure field"))
    }

    @Test("a target that is readable but not editable is not pasted into")
    func nonEditable() {
        #expect(
            DeliveryPolicy.plan(preconditions(safety: .nonEditable))
                == .copy(reason: "Nothing to type into"))
    }

    @Test("a target whose safety cannot be established is treated as unsafe")
    func failsClosed() {
        #expect(
            DeliveryPolicy.plan(preconditions(safety: .unknown))
                == .copy(reason: "Target unavailable"))
    }

    @Test("a target the user walked away from gets the clipboard, not a stolen focus")
    func movedOn() {
        #expect(
            DeliveryPolicy.plan(preconditions(continuity: .movedOn))
                == .copy(reason: "Target changed"))
    }

    @Test("a target that quit gets the clipboard")
    func vanished() {
        #expect(
            DeliveryPolicy.plan(preconditions(continuity: .vanished))
                == .copy(reason: "Target closed"))
    }

    @Test("a vanished target is not pasted into")
    func noTarget() {
        #expect(DeliveryPolicy.plan(preconditions(target: false)) == .copy(reason: "No target app"))
    }

    @Test("a dropped keystroke is never reported as a paste")
    func noPostEventAccess() {
        #expect(
            DeliveryPolicy.plan(preconditions(postEvents: false))
                == .copy(reason: "Cannot post keystrokes"))
    }

    @Test("no Accessibility grant means no paste")
    func noAccessibility() {
        #expect(
            DeliveryPolicy.plan(preconditions(accessibility: false))
                == .copy(reason: "Accessibility not granted"))
    }

    @Test("no event source means no paste")
    func noEventSource() {
        #expect(
            DeliveryPolicy.plan(preconditions(eventSource: false))
                == .copy(reason: "No event source"))
    }

    @Test("exactly one combination pastes, and no secure combination writes anywhere")
    func onlyOnePathPastes() {
        var pasted = 0
        var secureWrites = 0
        for accessibility in [true, false] {
            for postEvents in [true, false] {
                for target in [true, false] {
                    for safety in [
                        TargetSafety.editable, .nonEditable, .secure, .unknown,
                    ] {
                        for continuity in [
                            TargetContinuity.intact, .movedOn, .vanished,
                        ] {
                            for eventSource in [true, false] {
                                let plan = DeliveryPolicy.plan(
                                    preconditions(
                                        accessibility: accessibility, postEvents: postEvents,
                                        target: target, safety: safety, continuity: continuity,
                                        eventSource: eventSource))
                                if plan == .paste { pasted += 1 }
                                if safety == .secure, plan != .withhold(reason: "Secure field") {
                                    secureWrites += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(pasted == 1)
        #expect(secureWrites == 0)
    }
}

@Suite("Clipboard restore")
struct ClipboardTests {
    @Test("the previous clipboard comes back when nothing else claimed it")
    func restores() {
        #expect(
            DeliveryPolicy.shouldRestoreClipboard(ourChangeCount: 7, currentChangeCount: 7))
    }

    @Test("a copy made during the paste wins over the restore")
    func userCopyWins() {
        #expect(
            !DeliveryPolicy.shouldRestoreClipboard(ourChangeCount: 7, currentChangeCount: 8))
    }

    @Test("back to back dictations never restore each other's text")
    func backToBack() {
        let first = DeliveryPolicy.shouldRestoreClipboard(
            ourChangeCount: 10, currentChangeCount: 11)
        #expect(!first, "the second dictation bumped the count, so the first must not restore")
        let second = DeliveryPolicy.shouldRestoreClipboard(
            ourChangeCount: 11, currentChangeCount: 11)
        #expect(second)
    }

    @Test("a snapshot with no text still restores its other representations")
    func nonTextClipboard() {
        let snapshot = ClipboardSnapshot(
            items: [.init(representations: ["public.png": Data([0x89, 0x50, 0x4E, 0x47])])],
            changeCount: 4, isPartial: false)
        #expect(!snapshot.isEmpty)
    }

    @MainActor
    @Test("an originally empty clipboard is restored to empty")
    func restoresEmptyClipboard() {
        let pasteboard = NSPasteboard(name: .init("lossless.empty.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let snapshot = Clipboard.capture(pasteboard)
        let ours = Clipboard.write("dictation", to: pasteboard)

        #expect(Clipboard.restore(snapshot, ourChangeCount: ours, to: pasteboard))
        #expect(pasteboard.pasteboardItems?.isEmpty != false)
    }
}
