import AppKit
import SwiftUI

final class PillPanel: NSPanel {
    init<Content: View>(@ViewBuilder content: () -> Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: content())
        contentView?.wantsLayer = true
    }

    override var canBecomeKey: Bool { false }

    func position(near target: CGRect? = nil) {
        guard let screen = screen(for: target) else { return }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.visibleFrame.minY + Metrics.pillBottomInset)
        setFrameOrigin(origin)
    }

    private func screen(for target: CGRect?) -> NSScreen? {
        if let target,
            let match = NSScreen.screens.max(by: { overlap($0, target) < overlap($1, target) }),
            overlap(match, target) > 0
        {
            return match
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func overlap(_ screen: NSScreen, _ target: CGRect) -> CGFloat {
        guard let height = NSScreen.screens.first?.frame.maxY else { return 0 }
        let flipped = CGRect(
            x: target.minX, y: height - target.maxY, width: target.width, height: target.height)
        let intersection = screen.frame.intersection(flipped)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

@MainActor
func makeWindow<Content: View>(
    title: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered, defer: false)
    window.title = title
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: content())
    window.center()
    return window
}
