import LosslessEngine
import LosslessKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel
    let onDone: () -> Void

    @State private var readiness: Diagnostics.Readiness
    @State private var draftKey = ""

    init(model: AppModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _readiness = State(initialValue: model.readiness)
    }

    private var hasDictated: Bool { !model.recents.isEmpty }
    private var permissionsGranted: Bool {
        readiness.microphone == .authorized && readiness.inputMonitoring && readiness.accessibility
    }
    private var ready: Bool { model.isConfigured && permissionsGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lossless")
                    .font(.system(size: 22, weight: .semibold))
                Text("Hold the key, then speak.")
                    .font(Kind.body)
                    .foregroundStyle(Ink.secondary)
            }

            step(1, "AssemblyAI", done: model.isConfigured, note: nil) {
                if model.isConfigured {
                    Text("Connected").font(Kind.body).foregroundStyle(Ink.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField("Paste your key", text: $draftKey)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { model.connect(draftKey) }
                            Button("Connect") { model.connect(draftKey) }
                                .glassButton()
                                .controlSize(.small)
                                .disabled(draftKey.isEmpty)
                        }
                        if case .rejected = model.keyState {
                            Text("This key was rejected by AssemblyAI.")
                                .font(Kind.caption)
                                .foregroundStyle(Ink.attention)
                        }
                    }
                }
            }

            step(
                2, "Permissions", done: permissionsGranted,
                note:
                    "Input Monitoring is separate from Accessibility. The trigger will not fire without it."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    permission("Microphone", granted: readiness.microphone == .authorized) {
                        Task { _ = await Recorder.requestPermission() }
                    }
                    permission("Input Monitoring", granted: readiness.inputMonitoring) {
                        model.requestInputMonitoring()
                    }
                    permission("Accessibility", granted: readiness.accessibility) {
                        Focus.requestAccessibility()
                        Focus.openSettings(.accessibility)
                    }
                }
            }

            step(3, "Try it", done: hasDictated, note: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hold \(model.trigger.label) and say:")
                        .font(Kind.body)
                        .foregroundStyle(ready ? Ink.secondary : Ink.faint)
                    Text("Set the timeout to thirty seconds.")
                        .font(Kind.display)
                        .foregroundStyle(ready ? Ink.primary : Ink.faint)
                    if hasDictated { result }
                }
            }

            HStack {
                Spacer()
                Button(hasDictated ? "Done" : "Skip for now", action: onDone)
                    .glassButton()
            }
        }
        .padding(Metrics.gutter * 1.8)
        .frame(width: 460)
        .onReceive(Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()) { _ in
            readiness = model.readiness
        }
    }

    @ViewBuilder private var result: some View {
        if let graph = model.graph {
            VStack(alignment: .leading, spacing: 4) {
                let transcript = Transcript(
                    graph, compiled: model.compiled, cleanupDegraded: false)
                if let problem = transcript.problems.first {
                    Text(
                        problem.resolution == .inverted
                            ? "Reversed \(problem.transition)."
                            : "\(problem.transition) did not land."
                    )
                    .foregroundStyle(Ink.attention)
                } else if let applied = transcript.applied.first {
                    Text("\(applied.transition) \u{00B7} applied before the text landed.")
                        .foregroundStyle(Ink.primary)
                } else {
                    Text("Your text landed. Nothing needed fixing.")
                        .foregroundStyle(Ink.secondary)
                }
            }
            .font(Kind.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step<Content: View>(
        _ number: Int, _ title: String, done: Bool, note: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Text("\(number)")
                        .font(Kind.caption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(done ? Ink.secondary : Ink.faint)
            .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).sectionTitle()
                content()
                if let note {
                    Text(note)
                        .font(Kind.caption)
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func permission(
        _ title: String, granted: Bool, request: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? Ink.secondary : Ink.attention)
            Text(title).font(Kind.body).foregroundStyle(Ink.secondary)
            Spacer()
            if !granted {
                Button("Grant", action: request)
                    .glassButton()
                    .controlSize(.small)
            }
        }
    }
}
