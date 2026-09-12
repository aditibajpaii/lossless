import AppKit
import Foundation
import LosslessEngine
import LosslessIntent
import LosslessKit
import Observation

enum KeyState: Equatable, Sendable {
    case missing
    case connected
    case checking
    case rejected
    case unverified(String)
}

@MainActor
@Observable
final class AppModel {
    private var session = DictationSession()
    private var publishedPhase: PipelinePhase = .idle
    var action = ActionSession()
    var actionArmed = false

    var phase: PipelinePhase {
        if actionArmed {
            switch session.phase {
            case .arming, .listening:
                return .acting(
                    ActionBanner(
                        symbol: "waveform", label: "Listening \u{00B7} Action", persistent: true,
                        showsMeter: true, level: listeningLevel))
            default:
                break
            }
        }
        switch action.phase {
        case .idle:
            return session.phase
        default:
            return .acting(action.banner)
        }
    }

    var isAwaitingConfirm: Bool {
        if case .awaitingConfirm = action.phase { true } else { false }
    }

    private var listeningLevel: Double {
        if case .listening(let level) = session.phase { return level }
        return 0
    }

    var destination: String? { session.destination }
    var canRetry: Bool { session.canRetry && retryAudio != nil }

    private(set) var graph: RepairGraph?
    private(set) var compiled: CompiledTranscript?
    private(set) var criticalPathMS: Double?
    private(set) var traces: [LatencyTrace] = []
    private(set) var recents: [Utterance] = []
    private(set) var keyState: KeyState = .missing
    private(set) var withheldText: String?

    var keyTerms: String {
        didSet { UserDefaults.standard.set(keyTerms, forKey: "keyTerms") }
    }

    var contextLevel: ContextLevel {
        didSet { UserDefaults.standard.set(contextLevel.rawValue, forKey: "contextLevel") }
    }

    var soundCues: Bool {
        didSet { Cues.enabled = soundCues }
    }

    var trigger: Trigger = .current {
        didSet {
            guard trigger != oldValue else { return }
            Trigger.select(trigger)
            onTriggerChange?(trigger)
        }
    }

    var developerMode = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet { UserDefaults.standard.set(developerMode, forKey: "developerMode") }
    }

    var targetWindowFrame: CGRect? { context.windowFrame }

    var onPhaseChange: ((PipelinePhase) -> Void)?
    var onGraphReady: (() -> Void)?
    var onTriggerChange: ((Trigger) -> Void)?

    private let recorder = Recorder()
    private var meterTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var context = FocusContext.unknown
    private var recordingID: UUID?
    private var recordingStarted: Date?
    private var retryAudio: URL?
    private var trace = LatencyTrace()
    private var client: AssemblyAIDictationClient?
    private let readinessOverride: Diagnostics.Readiness?
    private var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            client = nil
        }
    }

    private var generation = 0

    private static let recordingCap = Duration.seconds(120)

    init(storedKey: String? = nil, readinessOverride: Diagnostics.Readiness? = nil) {
        self.readinessOverride = readinessOverride
        apiKey =
            storedKey ?? Keychain.read()
            ?? ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"] ?? ""
        keyTerms = UserDefaults.standard.string(forKey: "keyTerms") ?? ""
        contextLevel =
            UserDefaults.standard.string(forKey: "contextLevel")
            .flatMap(ContextLevel.init(rawValue:)) ?? .appOnly
        soundCues = UserDefaults.standard.object(forKey: "soundCues") as? Bool ?? true
        keyState = apiKey.isEmpty ? .missing : .connected
        Self.removeStaleRecordings()
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    var keyFingerprint: String? {
        guard apiKey.count >= 4 else { return nil }
        return String(repeating: "\u{2022}", count: 12) + apiKey.suffix(4)
    }

    var readiness: Diagnostics.Readiness {
        readinessOverride ?? Diagnostics.readiness(hasAPIKey: isConfigured)
    }

    var privacyFacts: [String] {
        ContextPolicy.disclosureLines(
            level: contextLevel, hasKeyTerms: !boostedTerms().isEmpty)
            + [
                "Lossless deletes the local recording after each utterance.",
                "A failed one is kept only until you retry or dictate again.",
                "Up to 20 recent transcripts are held in memory until Lossless quits and are never written to disk.",
                "Dictation does not start at all when a password field has focus.",
                "Your AssemblyAI key is stored in macOS Keychain.",
            ]
    }

    func connect(_ draft: String) {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            keyState = .missing
            return
        }
        keyState = .checking
        Task { [weak self] in
            let verdict = await AssemblyAIDictationClient(apiKey: candidate).verifyKey()
            guard let self else { return }
            switch verdict {
            case .accepted:
                if Keychain.write(candidate) {
                    apiKey = candidate
                    keyState = .connected
                } else {
                    keyState = .unverified("Could not save the key in macOS Keychain")
                }
            case .rejected:
                keyState = .rejected
            case .unreachable(let reason):
                keyState = .unverified(reason)
            }
            refreshReadiness()
        }
    }

    func forgetKey() {
        apiKey = ""
        Keychain.remove()
        keyState = .missing
        refreshReadiness()
    }

    func copyWithheld() {
        guard let withheldText else { return }
        guard Clipboard.write(withheldText) != nil else { return }
        self.withheldText = nil
        perform(session.handle(.dismissed))
    }

    func copyLastTranscript() {
        guard let text = recents.first?.text else { return }
        copyToPasteboard(text)
    }

    func prepare() {
        guard readiness.microphone == .notDetermined else { return refreshReadiness() }
        Diagnostics.note("requesting microphone access")
        Task { [weak self] in
            let granted = await Recorder.requestPermission()
            Diagnostics.note("microphone request returned \(granted)")
            self?.refreshReadiness()
        }
        refreshReadiness()
    }

    func requestInputMonitoring() {
        Task.detached {
            let granted = Focus.requestInputMonitoring()
            Diagnostics.note("input monitoring request returned \(granted)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !granted { Focus.openSettings(.inputMonitoring) }
                refreshReadiness()
            }
        }
    }

    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func refreshReadiness() {
        perform(session.handle(.readinessChanged(blockers: readiness.blockers)))
    }

    func dismiss() {
        finishAction(reason: "dismissed")
        perform(session.handle(.dismissed))
    }

    func beginUtterance() {
        if case .awaitingConfirm = action.phase { return }
        finishAction(reason: "new utterance")
        guard !session.isBusy else { return }
        let blockers = readiness.blockers
        if !blockers.isEmpty, readiness.microphone == .notDetermined {
            Task { [weak self] in
                _ = await Recorder.requestPermission()
                self?.refreshReadiness()
            }
        }
        let target = blockers.isEmpty ? Focus.capture() : FocusContext.unknown
        let effects = session.handle(
            .pressed(blockers: blockers, safety: blockers.isEmpty ? target.safety : .editable))

        if effects.contains(.startRecording) {
            discardRetryAudio()
            withheldText = nil
            generation += 1
            trace = LatencyTrace()
            trace.mark(.press)
            context = target
            recordingStarted = nil
            recordingID = UUID()
        }
        perform(effects)
    }

    func beginAction() {
        if case .awaitingConfirm = action.phase { return }
        beginUtterance()
        actionArmed = session.isBusy
        publish()
    }

    func endUtterance() {
        guard session.isCapturing else { return }
        stopTimers()
        generation += 1
        let held = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        if recordingStarted != nil { trace.mark(.release) }
        perform(session.handle(.released(heldFor: held)))
        if !session.isBusy { actionArmed = false }
    }

    func cancelUtterance() {
        actionArmed = false
        finishAction(reason: "cancelled")
        guard session.isBusy else { return }
        generation += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        stopTimers()
        perform(session.handle(.cancelled))
    }

    func shutdown() {
        generation += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        stopTimers()
        finishAction(reason: "shutdown")
        discardRetryAudio()
        guard let recordingID else { return }
        self.recordingID = nil
        Task { [recorder] in
            guard let url = await recorder.stop(id: recordingID) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func retry() {
        guard let url = retryAudio, session.canRetry, !session.isBusy else { return }
        generation += 1
        let mine = generation
        trace = LatencyTrace()
        trace.mark(.press)
        perform(session.handle(.retried))
        context = .unknown
        transcriptionTask = Task { [weak self] in
            await self?.transcribe(
                url, generation: mine, deleteOnSuccess: true, target: .unknown, copyOnly: true)
        }
    }

    private func perform(_ effects: [SessionEffect]) {
        for effect in effects {
            switch effect {
            case .startRecording:
                let warming = transport()
                let mine = generation
                guard let recordingID else { break }
                Task.detached { await warming.warm() }
                Task { [weak self] in await self?.openMicrophone(mine, id: recordingID) }
            case .stopAndTranscribe:
                let mine = generation
                guard let recordingID else { break }
                let target = context
                self.recordingID = nil
                transcriptionTask = Task { [weak self] in
                    await self?.complete(mine, recordingID: recordingID, target: target)
                }
            case .discardRecording:
                recordingStarted = nil
                guard let recordingID else { break }
                self.recordingID = nil
                Task { [weak self] in
                    guard let url = await self?.recorder.stop(id: recordingID) else { return }
                    try? FileManager.default.removeItem(at: url)
                }
            case .refuseSecureField:
                Diagnostics.note("refused to record into a secure field")
            case .playCue(let cue):
                Cues.play(cue)
            case .hide(let seconds):
                scheduleHide(after: seconds)
            case .deliver:
                break
            }
        }
        publish()
    }

    private func publish() {
        let current = phase
        guard current != publishedPhase else { return }
        publishedPhase = current
        Diagnostics.phase(current)
        onPhaseChange?(current)
        switch current.visibility {
        case .transient(let seconds):
            scheduleHide(after: seconds)
        case .persistent:
            idleTask?.cancel()
            idleTask = nil
        case .hidden:
            break
        }
    }

    private func openMicrophone(_ mine: Int, id: UUID) async {
        do {
            _ = try await recorder.start(id: id)
        } catch {
            return apply(mine) { $0.fail("Microphone unavailable", canRetry: false) }
        }
        guard mine == generation, recordingID == id else {
            _ = await recorder.stop(id: id)
            return
        }
        recordingStarted = .now
        trace.mark(.recordingReady)
        perform(session.handle(.recordingReady))
        startMeter(mine)
        startCap(mine)
    }

    private func startMeter(_ mine: Int) {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, mine == generation else { return }
                let level = await recorder.level()
                guard mine == generation else { return }
                session.meter(level)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func startCap(_ mine: Int) {
        capTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recordingCap)
            guard !Task.isCancelled, let self, mine == generation else { return }
            Diagnostics.note("recording cap reached, releasing")
            endUtterance()
        }
    }

    private func stopTimers() {
        meterTask?.cancel()
        meterTask = nil
        capTask?.cancel()
        capTask = nil
    }

    private func complete(_ mine: Int, recordingID: UUID, target: FocusContext) async {
        guard let url = await recorder.stop(id: recordingID) else {
            return apply(mine) { $0.fail("Nothing recorded", canRetry: false) }
        }
        await transcribe(
            url, generation: mine, deleteOnSuccess: true, target: target, copyOnly: false)
    }

    private func transcribe(
        _ url: URL, generation mine: Int, deleteOnSuccess: Bool, target: FocusContext,
        copyOnly: Bool
    ) async {
        var retainForRetry = false
        defer {
            if deleteOnSuccess, !retainForRetry {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        guard let wav = try? Data(contentsOf: url) else {
            return apply(mine) { $0.fail("Nothing recorded", canRetry: false) }
        }
        trace.mark(.audioFinalised)
        Diagnostics.note("captured \(wav.count) bytes of wav")

        let config = DictationConfig(
            conversationContext: conversationContext(for: target), wordBoost: boostedTerms())
        let response: DictationResponse
        let stages = StageRecorder()
        do {
            response = try await transport().transcribe(
                pcm: wav.droppingWaveHeader(), config: config, trace: { stages.mark($0) })
        } catch is CancellationError {
            Diagnostics.note("dictation cancelled")
            return
        } catch {
            Diagnostics.note("dictation failed: \(message(for: error))")
            guard mine == generation else { return }
            let recoverable = isRecoverable(error)
            retainForRetry = recoverable
            return apply(mine) { model in
                model.retryAudio = recoverable ? url : nil
                model.transcriptionTask = nil
                model.fail(model.message(for: error), canRetry: recoverable)
            }
        }
        guard mine == generation else { return }
        guard !Task.isCancelled else { return }

        let pair = response.pair
        guard !pair.clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return apply(mine) { $0.fail("Nothing heard", canRetry: false) }
        }

        for (stage, at) in stages.drain() { trace.mark(stage, atUptime: at) }

        let analysed = RepairEngine.analyze(pair)
        trace.mark(.analysed)
        let patchable = response.cleanupDegraded ? nil : analysed.compiled
        let transcript = Transcript(
            analysed, compiled: patchable, cleanupDegraded: response.cleanupDegraded)
        _ = session.handle(.transcribed(transcript))

        guard !Task.isCancelled else { return }
        let acting = actionArmed
        actionArmed = false
        if acting {
            recordTranscript(
                analysed, compiled: patchable, transcript: transcript,
                cleanupDegraded: response.cleanupDegraded, started: started, target: target)
            let id = action.heard(analysed, page: action.page)
            sendActionUtterance(
                id: id, graph: analysed, compiled: patchable,
                cleanupDegraded: response.cleanupDegraded)
            perform(session.handle(.cancelled))
            onGraphReady?()
            return
        }
        let outcome =
            copyOnly
            ? Injector.copy(transcript.text, reason: "Transcribed")
            : await Injector.deliver(transcript.text, into: target)
        guard mine == generation else { return }
        trace.mark(.pastePosted)
        recordTranscript(
            analysed, compiled: patchable, transcript: transcript,
            cleanupDegraded: response.cleanupDegraded, started: started, target: target)
        if case .withheld = outcome { withheldText = transcript.text }

        perform(
            session.settle(transcript, route: outcome.route, into: target.applicationName))
        onGraphReady?()
    }

    private func recordTranscript(
        _ analysed: RepairGraph, compiled patchable: CompiledTranscript?,
        transcript: Transcript, cleanupDegraded: Bool, started: UInt64, target: FocusContext
    ) {
        retryAudio = nil
        transcriptionTask = nil
        criticalPathMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        graph = analysed
        compiled = patchable
        DemoServer.shared.publish(
            LastUtterance(
                graph: analysed, compiled: patchable, cleanupDegraded: cleanupDegraded))
        recents.insert(
            Utterance(
                text: transcript.text, problems: transcript.problems.count,
                destination: target.applicationName, at: Date()),
            at: 0)
        if recents.count > 20 { recents.removeLast() }
        trace.mark(.settled)
        Diagnostics.note("latency \(trace.summary)")
        traces.append(trace)
        if traces.count > 20 { traces.removeFirst() }
    }

    private func conversationContext(for target: FocusContext) -> String? {
        ContextPolicy.prompt(
            level: contextLevel, application: target.applicationName,
            windowTitle: target.windowTitle, bundleIdentifier: target.bundleIdentifier)
    }

    private func transport() -> AssemblyAIDictationClient {
        if let client { return client }
        let made = AssemblyAIDictationClient(apiKey: apiKey)
        client = made
        return made
    }

    private func apply(_ mine: Int, _ body: (AppModel) -> Void) {
        guard mine == generation else { return }
        body(self)
    }

    private func fail(_ reason: String, canRetry: Bool) {
        actionArmed = false
        stopTimers()
        recordingStarted = nil
        perform(
            session.handle(
                .failed(reason: reason, recoverable: canRetry && retryAudio != nil)))
    }

    private func discardRetryAudio() {
        guard let url = retryAudio else { return }
        retryAudio = nil
        try? FileManager.default.removeItem(at: url)
    }

    private static func removeStaleRecordings(now: Date = .now) {
        let directory = FileManager.default.temporaryDirectory
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for url in urls
        where url.lastPathComponent.hasPrefix("lossless-") && url.pathExtension == "wav" {
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate,
                now.timeIntervalSince(modified) > 60 * 60
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isRecoverable(_ error: Error) -> Bool {
        switch error {
        case DictationError.transport: true
        case DictationError.status(let code, _): code >= 500 || code == 429
        default: false
        }
    }

    private func boostedTerms() -> [String] {
        keyTerms
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func message(for error: Error) -> String {
        switch error {
        case DictationError.missingAPIKey: "Add your AssemblyAI key in Settings"
        case DictationError.transport: "Couldn't transcribe"
        case DictationError.status(401, _), DictationError.status(403, _): "API key rejected"
        case DictationError.status: "Couldn't transcribe"
        default: "Couldn't transcribe"
        }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        idleTask?.cancel()
        let shown = phase
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, phase == shown else { return }
            if action.isOpen { return }
            finishAction(reason: "dismissed")
            perform(session.handle(.dismissed))
        }
    }

    func handleAction(_ message: ActionInbound) {
        switch message {
        case .hello(let origin, let document):
            guard WebSocket.loopbackOrigin(origin) else {
                action.fail("Page changed · action cancelled")
                DemoServer.shared.send(.cancel(reason: "unknown origin"))
                publish()
                return
            }
            if action.attach(ActionPage(origin: origin, document: document)) == .pageChanged {
                DemoServer.shared.send(.cancel(reason: "Page changed · action cancelled"))
                publish()
                return
            }
            replayOpenUtterance()
        case .propose(let proposal):
            verifyProposal(proposal)
        case .noTools:
            action.markNoTools()
            publish()
        case .executed(_, let result):
            action.succeed(result)
            publish()
        case .error(let message):
            action.fail(message)
            publish()
        }
    }

    func verifyProposal(_ proposal: ActionProposal) {
        guard let graph = action.graph else {
            action.fail("No utterance to check")
            publish()
            return
        }
        let mapped = ProposedAction(
            tool: proposal.tool,
            fields: proposal.fields.map { ProposedField(name: $0.name, value: $0.value) },
            readOnly: proposal.readOnly)
        let decision = IntentGate.check(mapped, against: graph)
        let offer = action.consider(
            proposal, blocked: decision.verdict == .block, reason: decision.actionReason)
        switch offer {
        case .blocked:
            DemoServer.shared.send(
                .decision(
                    utteranceId: proposal.utteranceId, verdict: "block",
                    reason: decision.actionReason))
            publish()
        case .stale:
            publish()
        case .pageChanged:
            DemoServer.shared.send(.cancel(reason: "Page changed · action cancelled"))
            publish()
        case .confirm:
            DemoServer.shared.send(
                .decision(
                    utteranceId: proposal.utteranceId, verdict: "allow",
                    reason: decision.actionReason))
            publish()
        case .execute(let accepted):
            DemoServer.shared.send(
                .decision(
                    utteranceId: proposal.utteranceId, verdict: "allow",
                    reason: decision.actionReason))
            sendExecute(accepted)
            publish()
        }
    }

    func confirmAction() {
        guard let proposal = action.confirm() else {
            if case .failed = action.phase {
                DemoServer.shared.send(.cancel(reason: "Page changed · action cancelled"))
                publish()
            }
            return
        }
        sendExecute(proposal)
        publish()
    }

    func cancelAction() {
        finishAction(reason: "cancelled")
        publish()
    }

    func seedActionUtterance() {
        guard let graph else { return }
        let id = action.heard(graph, page: action.page)
        sendActionUtterance(
            id: id, graph: graph, compiled: compiled, cleanupDegraded: false)
        publish()
    }

    private func replayOpenUtterance() {
        guard let id = action.utteranceId, let graph = action.graph else { return }
        switch action.phase {
        case .planning, .awaitingConfirm, .blocked, .succeeded:
            sendActionUtterance(
                id: id, graph: graph, compiled: compiled, cleanupDegraded: false)
        default:
            break
        }
    }

    private func sendActionUtterance(
        id: String, graph: RepairGraph, compiled: CompiledTranscript?, cleanupDegraded: Bool
    ) {
        let last = LastUtterance(
            graph: graph, compiled: compiled, cleanupDegraded: cleanupDegraded)
        DemoServer.shared.send(
            .utterance(
                utteranceId: id, raw: last.raw, clean: last.clean, compiled: last.compiled,
                claims: last.claims))
    }

    private func sendExecute(_ proposal: ActionProposal) {
        DemoServer.shared.send(
            .execute(
                utteranceId: proposal.utteranceId, tool: proposal.tool,
                arguments: Dictionary(
                    proposal.fields.map { ($0.name, $0.value) },
                    uniquingKeysWith: { _, last in last })))
    }

    private func finishAction(reason: String) {
        actionArmed = false
        switch action.phase {
        case .idle:
            return
        case .succeeded, .blocked:
            if reason == "dismissed" { return }
        default:
            break
        }
        action.cancel()
        DemoServer.shared.send(.cancel(reason: reason))
    }

    func loadFixture(_ pair: TranscriptPair, destination: String) {
        let analysed = RepairEngine.analyze(pair)
        let patchable = analysed.compiled
        graph = analysed
        compiled = patchable
        DemoServer.shared.publish(
            LastUtterance(graph: analysed, compiled: patchable, cleanupDegraded: false))
        perform(
            session.settle(
                Transcript(analysed, compiled: patchable, cleanupDegraded: false),
                route: .pasted, into: destination))
    }

    func copyToPasteboard(_ text: String) {
        Clipboard.write(text)
    }

}

extension Data {
    func droppingWaveHeader() -> Data {
        guard count > 44, prefix(4) == Data("RIFF".utf8) else { return self }
        var cursor = 12
        while cursor + 8 <= count {
            let identifier = subdata(in: cursor..<(cursor + 4))
            let size = subdata(in: (cursor + 4)..<(cursor + 8)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            if identifier == Data("data".utf8) {
                let start = cursor + 8
                return subdata(in: start..<Swift.min(count, start + size))
            }
            cursor += 8 + size + (size % 2)
        }
        return self
    }
}

struct Utterance: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let problems: Int
    let destination: String?
    let at: Date
}
