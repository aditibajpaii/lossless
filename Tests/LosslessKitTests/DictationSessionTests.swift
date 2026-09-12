import Foundation
import LosslessEngine
import Testing

@testable import LosslessKit

@Suite("Dictation flows")
struct DictationSessionTests {
    @Test("the happy path records, delivers and disappears")
    func happyPath() {
        var session = DictationSession()

        #expect(
            session.handle(.pressed(blockers: [], safety: .editable))
                == [.startRecording])
        #expect(session.phase == .arming)
        #expect(session.handle(.recordingReady) == [.playCue(.start)])
        #expect(session.phase == .listening(level: 0))

        session.meter(0.6)
        #expect(session.phase == .listening(level: 0.6))

        #expect(
            session.handle(.released(heldFor: 1.4)) == [.playCue(.stop), .stopAndTranscribe])
        #expect(session.phase == .transcribing)

        let transcript = Transcript(text: "Ship the build tonight.")
        #expect(session.handle(.transcribed(transcript)) == [.deliver("Ship the build tonight.")])

        let effects = session.settle(transcript, route: .pasted, into: "Notes")
        #expect(effects == [.hide(after: 0.7)])
        #expect(session.phase.presentation.label == "Pasted")
        #expect(!session.phase.presentation.emphasised)

        #expect(session.handle(.dismissed) == [])
        #expect(session.phase == .idle)
    }

    @Test("a repair is applied before delivery and named once")
    func repairAppliedBeforePaste() {
        var session = DictationSession()
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Set the timeout to 60, sorry, 30 seconds.",
                clean: "Set the timeout to 60, 30 seconds."))
        let transcript = Transcript(graph, compiled: graph.compiled, cleanupDegraded: false)

        #expect(transcript.text == "Set the timeout to 30 seconds.")
        #expect(transcript.problems.isEmpty)

        _ = session.handle(.pressed(blockers: [], safety: .editable))
        _ = session.handle(.recordingReady)
        _ = session.handle(.released(heldFor: 1.2))
        #expect(session.handle(.transcribed(transcript)) == [.deliver(transcript.text)])
        _ = session.settle(transcript, route: .pasted, into: "Notes")

        #expect(session.phase.presentation.label == "60 \u{2192} 30")
        #expect(session.phase.visibility == .transient(1.4))
    }

    @Test("a warning stays until the next utterance")
    func unresolvedRepairPersists() {
        var session = DictationSession()
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Aman should review it. Actually Priya.",
                clean: "Aman should review it. Priya."))
        let transcript = Transcript(graph, compiled: graph.compiled, cleanupDegraded: false)

        #expect(transcript.text == "Aman should review it. Priya.")
        #expect(transcript.problems.count == 1)
        #expect(transcript.problems.first?.transition == "Aman \u{2192} Priya")
        #expect(transcript.problems.first?.resolution == .unresolved)

        let effects = session.settle(transcript, route: .pasted, into: "Slack")
        #expect(effects == [.playCue(.error)])
        #expect(!effects.contains { if case .hide = $0 { true } else { false } })
        #expect(session.phase.visibility == .persistent)
        #expect(session.phase.presentation.label == "Aman \u{2192} Priya wasn't applied")
        #expect(session.phase.presentation.offersReview)

        #expect(session.handle(.dismissed) == [])
        #expect(session.phase == .idle)
    }

    @Test("retry is offered exactly when there is audio to retry")
    func retryFlow() {
        var session = DictationSession()
        _ = session.handle(.pressed(blockers: [], safety: .editable))
        _ = session.handle(.recordingReady)
        _ = session.handle(.released(heldFor: 1.0))

        #expect(
            session.handle(.failed(reason: "Couldn't transcribe", recoverable: true)).first
                == .playCue(.error))
        #expect(session.canRetry)
        #expect(session.phase.presentation.label == "Couldn't transcribe \u{00B7} Retry")
        #expect(session.phase.visibility == .persistent)

        #expect(session.handle(.retried) == [])
        #expect(session.phase == .transcribing)

        _ = session.handle(.failed(reason: "Nothing heard", recoverable: false))
        #expect(!session.canRetry)
        #expect(session.phase.presentation.label == "Nothing heard")
        #expect(session.handle(.retried) == [])
        #expect(session.phase.presentation.label == "Nothing heard")
    }

    @Test("a blocked press clears once permissions are granted")
    func onboardingFlow() {
        var session = DictationSession()
        let missing = ["Microphone", "Accessibility"]

        #expect(
            session.handle(.pressed(blockers: missing, safety: .unknown))
                == [.hide(after: 5)])
        #expect(session.phase == .blocked(missing))

        #expect(
            session.handle(.readinessChanged(blockers: ["Accessibility"]))
                == [.hide(after: 5)])
        #expect(session.phase == .blocked(["Accessibility"]))

        #expect(session.handle(.readinessChanged(blockers: [])) == [])
        #expect(session.phase == .idle)

        #expect(
            session.handle(.pressed(blockers: [], safety: .editable))
                == [.startRecording])
        #expect(session.phase == .arming)
    }

    @Test("a password field stops the microphone rather than the paste")
    func secureFieldNeverRecords() {
        var session = DictationSession()
        let effects = session.handle(.pressed(blockers: [], safety: .secure))

        #expect(effects.contains(.refuseSecureField))
        #expect(!effects.contains(.startRecording))
        #expect(session.phase == .refusedSecureField)
        #expect(session.phase.presentation.label == "Dictation paused \u{00B7} secure field")
    }

    @Test("a tap is not a dictation")
    func tapIsDiscarded() {
        var session = DictationSession()
        _ = session.handle(.pressed(blockers: [], safety: .editable))
        _ = session.handle(.recordingReady)
        let effects = session.handle(.released(heldFor: 0.1))
        #expect(effects.contains(.discardRecording))
        #expect(!effects.contains(.stopAndTranscribe))
        #expect(session.phase == .idle)
    }

    @Test("a target the user walked away from says so instead of claiming a paste")
    func targetChanged() {
        var session = DictationSession()
        let transcript = Transcript(text: "Send it this afternoon.")
        _ = session.settle(transcript, route: .copied(reason: "Target changed"), into: "Slack")
        #expect(session.phase.presentation.label == "Target changed \u{00B7} Copied")
        #expect(session.phase.visibility == .persistent)
    }

    @Test("a degraded cleanup is quiet")
    func degradedCleanupIsSilent() {
        var session = DictationSession()
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Set the timeout to 60, sorry, 30 seconds.",
                clean: "Set the timeout to 60, sorry, 30 seconds."))
        let transcript = Transcript(graph, compiled: nil, cleanupDegraded: true)

        #expect(transcript.problems.isEmpty)
        #expect(transcript.applied.isEmpty)
        _ = session.settle(transcript, route: .pasted, into: "Notes")
        #expect(
            session.phase.presentation.label == "Cleanup unavailable \u{00B7} pasted verbatim")
    }

    @Test("an unsupported language produces no repair talk")
    func unsupportedLanguageIsQuiet() {
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw:
                    "\u{092F}\u{0939} \u{092C}\u{0939}\u{0941}\u{0924} \u{0905}\u{091A}\u{094D}\u{091B}\u{093E} \u{0939}\u{0948} \u{0914}\u{0930} \u{0915}\u{093E}\u{092E}",
                clean:
                    "\u{092F}\u{0939} \u{092C}\u{0939}\u{0941}\u{0924} \u{0905}\u{091A}\u{094D}\u{091B}\u{093E} \u{0939}\u{0948}"
            ))
        let transcript = Transcript(graph, compiled: graph.compiled, cleanupDegraded: false)
        #expect(!transcript.verified)
        #expect(transcript.problems.isEmpty)

        var session = DictationSession()
        _ = session.settle(transcript, route: .pasted, into: "Notes")
        #expect(session.phase.presentation.label == "Pasted")
    }

    @Test("a press while busy is ignored")
    func pressWhileBusy() {
        var session = DictationSession()
        _ = session.handle(.pressed(blockers: [], safety: .editable))
        #expect(session.handle(.pressed(blockers: [], safety: .editable)) == [])
        #expect(session.phase == .arming)
    }

    @Test("the start cue waits until audio capture is ready")
    func microphoneArming() {
        var session = DictationSession()

        #expect(session.handle(.pressed(blockers: [], safety: .editable)) == [.startRecording])
        #expect(session.phase.presentation.label == "Starting")
        #expect(session.handle(.recordingReady) == [.playCue(.start)])
        #expect(session.phase == .listening(level: 0))
    }

    @Test("releasing while the microphone is arming discards that session")
    func releaseWhileArming() {
        var session = DictationSession()
        _ = session.handle(.pressed(blockers: [], safety: .editable))

        #expect(session.handle(.released(heldFor: 0)) == [.discardRecording])
        #expect(session.phase == .idle)
        #expect(session.handle(.recordingReady) == [])
    }

    @Test("a release during transcribing does not start a new close")
    func releaseWhileTranscribingIsIgnored() {
        var session = DictationSession()
        _ = session.handle(.pressed(blockers: [], safety: .editable))
        _ = session.handle(.recordingReady)
        _ = session.handle(.released(heldFor: 1.2))
        #expect(session.phase == .transcribing)
        #expect(session.isCapturing == false)
        #expect(session.isBusy)
        #expect(session.handle(.released(heldFor: 0.4)) == [])
        #expect(session.phase == .transcribing)

        let transcript = Transcript(text: "Utterance A still lands.")
        #expect(session.handle(.transcribed(transcript)) == [.deliver("Utterance A still lands.")])
        _ = session.settle(transcript, route: .pasted, into: "Notes")
        #expect(session.phase.presentation.label == "Pasted")
    }

    @Test("the inspector verdict matches the delivered text")
    func inspectorFollowsCompiler() {
        let graph = RepairEngine.analyze(
            TranscriptPair(
                raw: "Set the timeout to 60, sorry, 30 seconds.",
                clean: "Set the timeout to 60, 30 seconds."))
        #expect(graph.problemLabels.contains { $0.before == "60" && $0.after == "30" })
        let transcript = Transcript(graph, compiled: graph.compiled, cleanupDegraded: false)
        #expect(transcript.text == "Set the timeout to 30 seconds.")
        #expect(transcript.problems.isEmpty)
        #expect(transcript.inspectorVerdict == "Your correction was applied")
    }

    @Test("a withheld delivery offers Copy")
    func withheldOffersCopy() {
        var session = DictationSession()
        let transcript = Transcript(text: "must not land in a password box")
        _ = session.settle(
            transcript, route: .withheld(reason: "Secure field"), into: "Safari")
        #expect(session.phase.presentation.label == "Secure field \u{00B7} Copy available")
        if case .delivered(let summary) = session.phase {
            #expect(summary.offersCopy)
        } else {
            Issue.record("expected a delivered withheld phase")
        }
    }
}
