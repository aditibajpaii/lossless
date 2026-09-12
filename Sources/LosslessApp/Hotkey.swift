import AppKit
import CoreGraphics

@MainActor
final class HotkeyTap {
    enum Edge: Sendable { case pressed(action: Bool), released, cancelled }

    var isAwaitingConfirm: () -> Bool = { false }
    var onConfirm: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var isDown = false
    private let onEdge: @MainActor (Edge) -> Void

    static let escapeKeyCode: Int64 = 53
    static var triggerLabel: String { Trigger.current.label }

    private var trigger: Trigger

    init(trigger: Trigger = .current, onEdge: @escaping @MainActor (Edge) -> Void) {
        self.trigger = trigger
        self.onEdge = onEdge
    }

    func use(_ trigger: Trigger) {
        guard trigger != self.trigger else { return }
        self.trigger = trigger
        if isDown {
            isDown = false
            onEdge(.cancelled)
        }
    }

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask =
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<HotkeyTap>.fromOpaque(context).takeUnretainedValue()
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags
                    MainActor.assumeIsolated {
                        tap.handle(type: type, keyCode: keyCode, flags: flags)
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: context)
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        let notifications = NSWorkspace.shared.notificationCenter
        wakeObserver = notifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetStuckState() }
        }
        sleepObserver = notifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetStuckState() }
        }
        return true
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            resetStuckState()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if isAwaitingConfirm() {
                if keyCode == 36 {
                    onConfirm?()
                    return
                }
                if keyCode == Self.escapeKeyCode { onEdge(.cancelled) }
                return
            }
            if isDown {
                isDown = false
                return onEdge(.cancelled)
            }
            if keyCode == Self.escapeKeyCode { onEdge(.cancelled) }
        case .flagsChanged:
            guard keyCode == trigger.keyCode else { return }
            let down = flags.contains(trigger.flag)
            guard down != isDown else { return }
            isDown = down
            onEdge(down ? .pressed(action: flags.contains(.maskShift)) : .released)
        default:
            return
        }
    }

    private func resetStuckState() {
        guard isDown else { return }
        isDown = false
        onEdge(.cancelled)
    }
}
