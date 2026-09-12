import LosslessEngine
import LosslessKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    init(model: AppModel) {
        self.model = model
        _readiness = State(initialValue: model.readiness)
    }

    @State private var readiness: Diagnostics.Readiness
    @State private var draftKey = ""
    @State private var isReplacingKey = false
    @State private var showingPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            field("AssemblyAI key") { keyControl }

            field("Key terms") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Names, services, jargon", text: $model.keyTerms)
                        .textFieldStyle(.roundedBorder)
                    Text("Comma separated.")
                        .font(Kind.caption)
                        .foregroundStyle(Ink.faint)
                }
            }

            field("Context") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $model.contextLevel) {
                        ForEach(ContextLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(model.contextLevel.detail)
                        .font(Kind.caption)
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            field("Trigger") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $model.trigger) {
                        ForEach(Trigger.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker("", selection: $model.soundCues) {
                        Text("Sound on").tag(true)
                        Text("Silent").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        "Hold to speak. Escape cancels, and using it inside a shortcut does not start a dictation."
                    )
                    .font(Kind.caption)
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            field("Permissions") {
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

            if !readiness.blockers.isEmpty {
                HStack(spacing: 8) {
                    Text("macOS applies these on next launch.")
                        .font(Kind.caption)
                        .foregroundStyle(Ink.faint)
                    Spacer()
                    Button("Relaunch", action: model.relaunch)
                        .glassButton()
                        .controlSize(.small)
                }
            }

            PrivacyPill(facts: model.privacyFacts, isOpen: $showingPrivacy)
        }
        .padding(Metrics.gutter * 1.6)
        .frame(width: 400)
        .onReceive(
            Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
        ) { _ in readiness = model.readiness }
    }

    @ViewBuilder private var keyControl: some View {
        if case .connected = model.keyState, !isReplacingKey {
            HStack(spacing: 8) {
                Text(model.keyFingerprint ?? "Connected")
                    .font(Kind.body.monospaced())
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Button("Replace") {
                    draftKey = ""
                    isReplacingKey = true
                }
                .glassButton()
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField("Paste your key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }
                    Button("Connect", action: submit)
                        .glassButton()
                        .controlSize(.small)
                        .disabled(draftKey.isEmpty || model.keyState == .checking)
                }
                keyStatus
            }
        }
    }

    @ViewBuilder private var keyStatus: some View {
        switch model.keyState {
        case .checking:
            Text("Checking with AssemblyAI\u{2026}").font(Kind.caption).foregroundStyle(Ink.faint)
        case .rejected:
            Text("This key was rejected by AssemblyAI.")
                .font(Kind.caption).foregroundStyle(Ink.attention)
        case .unverified(let reason):
            Text("\(reason). The key was not saved.")
                .font(Kind.caption).foregroundStyle(Ink.attention)
        case .connected, .missing:
            Text("Stored in macOS Keychain once it works.")
                .font(Kind.caption).foregroundStyle(Ink.faint)
        }
    }

    private func submit() {
        guard !draftKey.isEmpty else { return }
        isReplacingKey = false
        model.connect(draftKey)
        draftKey = ""
    }

    private func field<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).sectionTitle()
            content()
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

private struct PrivacyPill: View {
    let facts: [String]
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 12)
                Text("What leaves this Mac")
                    .font(Kind.caption)
            }
            .foregroundStyle(isOpen ? Ink.secondary : Ink.faint)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 28)
            .background(Ink.primary.opacity(isOpen ? 0.10 : 0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Ink.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("What Lossless sends, and what stays here")
        .accessibilityLabel("What leaves this Mac")
        .accessibilityHint("Shows what Lossless sends and stores")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(facts, id: \.self) { fact in
                    Text(fact)
                        .font(Kind.caption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }
}
