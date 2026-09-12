import AppKit
import LosslessEngine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var hotkey: HotkeyTap?
    private var pill: PillPanel?
    private var inspector: NSWindow?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private var onboarding: NSWindow?
    private var readinessTimer: Timer?
    private var update: Updates.Release?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = self.model
        let pill = PillPanel {
            PillObserver(
                model: model,
                onOpen: { [weak self] in self?.showInspector() },
                onFixBlockers: { [weak self] in self?.showSettings() },
                onRetry: { model.retry() },
                onCopyWithheld: { model.copyWithheld() },
                onDismiss: { model.dismiss() })
        }
        self.pill = pill

        model.onPhaseChange = { [weak self] phase in self?.present(phase) }
        model.onGraphReady = { [weak self] in self?.refreshInspector() }
        model.onTriggerChange = { [weak self] trigger in self?.hotkey?.use(trigger) }

        let hotkey = HotkeyTap { [weak self] edge in
            Diagnostics.trigger(String(describing: edge))
            switch edge {
            case .pressed(let action):
                if action {
                    self?.model.beginAction()
                } else {
                    self?.model.beginUtterance()
                }
            case .released:
                self?.model.endUtterance()
            case .cancelled:
                if self?.model.isAwaitingConfirm == true {
                    self?.model.cancelAction()
                } else {
                    self?.model.cancelUtterance()
                }
            }
        }
        hotkey.isAwaitingConfirm = { [weak model] in model?.isAwaitingConfirm == true }
        hotkey.onConfirm = { [weak model] in model?.confirmAction() }
        DemoServer.shared.onInbound { [weak model] message in
            Task { @MainActor in
                model?.handleAction(message)
            }
        }
        let tapInstalled = hotkey.install()
        self.hotkey = hotkey
        Diagnostics.report(
            Diagnostics.readiness(hasAPIKey: model.isConfigured), tapInstalled: tapInstalled)

        installStatusItem()
        if CommandLine.arguments.contains("--demo") {
            model.loadFixture(Fixture.booking, destination: "Demo")
            model.seedActionUtterance()
            DemoServer.shared.open()
        }
        if CommandLine.arguments.contains("--settings") {
            NSApp.setActivationPolicy(.regular)
            showSettings()
        }
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { model.refreshReadiness() }
        }
        if let readinessTimer { RunLoop.main.add(readinessTimer, forMode: .common) }

        present(model.phase)
        model.prepare()
        Task { [weak self] in
            guard let release = await Updates.check() else { return }
            self?.update = release
        }
        if !UserDefaults.standard.bool(forKey: "onboarded") { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        readinessTimer?.invalidate()
        model.shutdown()
    }

    private func present(_ phase: PipelinePhase) {
        if case .hidden = phase.visibility {
            pill?.orderOut(nil)
        } else {
            show()
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: model.readiness.blockers.isEmpty
                ? "waveform" : "waveform.badge.exclamationmark",
            accessibilityDescription: "Lossless")
    }

    private func show() {
        pill?.position(near: model.targetWindowFrame)
        pill?.orderFrontRegardless()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Lossless")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(
            withTitle: "Last dictation", action: #selector(showInspector), keyEquivalent: "l")
        menu.addItem(
            withTitle: "Copy last transcript", action: #selector(copyLast), keyEquivalent: "c")

        let recents = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if model.recents.isEmpty {
            submenu.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "")
        }
        for (index, utterance) in model.recents.enumerated() {
            let prefix = utterance.problems > 0 ? "\u{26A0} " : ""
            let title = prefix + utterance.text.prefix(60)
            let entry = NSMenuItem(
                title: String(title), action: #selector(copyRecent(_:)), keyEquivalent: "")
            entry.tag = index
            entry.target = self
            submenu.addItem(entry)
        }
        recents.submenu = submenu
        menu.addItem(recents)

        menu.addItem(.separator())
        let triggers = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for (index, option) in Trigger.allCases.enumerated() {
            let entry = NSMenuItem(
                title: option.label, action: #selector(chooseTrigger(_:)), keyEquivalent: "")
            entry.tag = index
            entry.state = option == model.trigger ? .on : .off
            entry.target = self
            triggerMenu.addItem(entry)
        }
        triggers.submenu = triggerMenu
        menu.addItem(triggers)

        if let update {
            menu.addItem(
                withTitle: "Version \(update.version) is available",
                action: #selector(openUpdate), keyEquivalent: "")
        }
        menu.addItem(
            withTitle: "Demo…", action: #selector(openIntentDemo), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lossless", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { if $0.target == nil { $0.target = self } }
    }

    @objc func copyLast() { model.copyLastTranscript() }

    @objc func copyRecent(_ sender: NSMenuItem) {
        guard model.recents.indices.contains(sender.tag) else { return }
        model.copyToPasteboard(model.recents[sender.tag].text)
    }

    @objc func chooseTrigger(_ sender: NSMenuItem) {
        guard Trigger.allCases.indices.contains(sender.tag) else { return }
        model.trigger = Trigger.allCases[sender.tag]
    }

    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = makeWindow(title: "Welcome", width: 460, height: 620) {
                OnboardingView(model: model) { [weak self] in
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    self?.onboarding?.close()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.makeKeyAndOrderFront(nil)
    }

    @objc func showInspector() {
        if inspector == nil {
            inspector = makeWindow(title: "Lossless", width: 620, height: 560) {
                InspectorObserver(model: model)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        inspector?.makeKeyAndOrderFront(nil)
    }

    private func refreshInspector() {
        guard inspector?.isVisible == true else { return }
        inspector?.contentView?.needsDisplay = true
    }

    @objc func openIntentDemo() {
        model.loadFixture(Fixture.booking, destination: "Demo")
        model.seedActionUtterance()
        DemoServer.shared.open()
    }

    @objc func showSettings() {
        if settings == nil {
            settings = makeWindow(title: "Settings", width: 400, height: 660) {
                SettingsView(model: model)
            }
            if let view = settings?.contentView {
                view.layoutSubtreeIfNeeded()
                let fitted = view.fittingSize
                if fitted.height > 200, fitted.height < 900 {
                    settings?.setContentSize(NSSize(width: 400, height: ceil(fitted.height)))
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc func openUpdate() {
        guard let update else { return }
        NSWorkspace.shared.open(update.url)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
}

enum Fixture {
    static let demo = TranscriptPair(
        raw: """
            Um, so I think we should use Redis because, because it'll be faster. Um, actually, \
            actually no, use Postgres because we already have row locking. Set the timeout to 60, \
            uh, sorry, 30 seconds. Um, Aman should review it. Actually Priya, and, um, don't \
            modify the existing migration.
            """,
        clean: """
            So I think we should use Redis because it'll be faster. Actually, use Postgres because \
            we already have row locking. Set the timeout to 30 seconds. Aman should review it. \
            Priya, and don't             modify the existing migration.
            """)

    static let booking = TranscriptPair(
        raw: "Book a table for six, sorry, four.",
        clean: "Book a table for six.")
}

private struct PillObserver: View {
    @Bindable var model: AppModel
    let onOpen: () -> Void
    let onFixBlockers: () -> Void
    let onRetry: () -> Void
    let onCopyWithheld: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        PillView(
            phase: model.phase, onOpen: onOpen, onFixBlockers: onFixBlockers, onRetry: onRetry,
            onCopyWithheld: model.withheldText == nil ? nil : onCopyWithheld,
            onDismiss: onDismiss
        )
        .padding(6)
    }
}

private struct InspectorObserver: View {
    @Bindable var model: AppModel

    var body: some View {
        InspectorView(
            graph: model.graph, compiled: model.compiled, destination: model.destination,
            onCopyAlternative: model.copyToPasteboard, developerMode: model.developerMode)
    }
}

if CommandLine.arguments.contains("--doctor") {
    let readiness = Diagnostics.readiness(hasAPIKey: Keychain.read()?.isEmpty == false)
    print("accessibility     \(readiness.accessibility)")
    print("input monitoring  \(readiness.inputMonitoring)")
    print("post events       \(readiness.postEvent)")
    print("microphone        \(readiness.microphone.rawValue) (3 = authorized)")
    print("assemblyai key    \(readiness.hasAPIKey)")
    print("signature         \(Diagnostics.signatureSummary())")
    let blockers = readiness.blockers
    print(blockers.isEmpty ? "ready" : "blocked on \(blockers.joined(separator: ", "))")
    exit(blockers.isEmpty ? 0 : 1)
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
