import Foundation
import LosslessEngine

public enum SessionEvent: Sendable {
    case pressed(blockers: [String], safety: TargetSafety)
    case released(heldFor: TimeInterval)
    case recordingReady
    case cancelled
    case transcribed(Transcript)
    case delivered(DeliveryRoute)
    case failed(reason: String, recoverable: Bool)
    case retried
    case dismissed
    case readinessChanged(blockers: [String])
}

public struct Transcript: Sendable {
    public let text: String
    public let applied: [RepairLabel]
    public let problems: [RepairLabel]
    public let cleanupDegraded: Bool
    public let verified: Bool

    public init(
        text: String, applied: [RepairLabel] = [], problems: [RepairLabel] = [],
        cleanupDegraded: Bool = false, verified: Bool = true
    ) {
        self.text = text
        self.applied = applied
        self.problems = problems
        self.cleanupDegraded = cleanupDegraded
        self.verified = verified
    }

    public var inspectorVerdict: String {
        guard verified else { return "Not verified \u{00B7} unsupported language" }
        if let problem = problems.first { return problem.problemText }
        if !applied.isEmpty { return "Your correction was applied" }
        return "Nothing needed fixing"
    }

    public init(_ graph: RepairGraph, compiled: CompiledTranscript?, cleanupDegraded: Bool) {
        let patched = Set((compiled?.patches ?? []).map(\.sourceEventID))
        let quiet = cleanupDegraded || !graph.scope.verifiesRepairs
        self.init(
            text: compiled?.text ?? graph.clean,
            applied: quiet
                ? []
                : graph.userFacingClaims.filter { patched.contains($0.id) }
                    .compactMap {
                        RepairLabel(
                            before: $0.before ?? "", after: $0.after ?? "", resolution: .resolved)
                    },
            problems: quiet ? [] : (compiled?.unpatched ?? []).compactMap(RepairLabel.init),
            cleanupDegraded: cleanupDegraded,
            verified: graph.scope.verifiesRepairs)
    }
}

public enum SessionEffect: Equatable, Sendable {
    case startRecording
    case stopAndTranscribe
    case discardRecording
    case deliver(String)
    case playCue(Cue)
    case hide(after: TimeInterval)
    case refuseSecureField

    public enum Cue: String, Equatable, Sendable {
        case start
        case stop
        case error
    }
}

public struct DictationSession: Sendable {
    public private(set) var phase: PipelinePhase = .idle
    public private(set) var destination: String?
    public private(set) var canRetry = false

    public static let tapThreshold: TimeInterval = 0.25

    public init() {}

    public mutating func handle(_ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .pressed(let blockers, let safety):
            return press(blockers: blockers, safety: safety)

        case .released(let held):
            if case .arming = phase {
                return transition(to: .idle) + [.discardRecording]
            }
            guard case .listening = phase else { return [] }
            guard held >= Self.tapThreshold else {
                return transition(to: .idle) + [.discardRecording]
            }
            return [.playCue(.stop)] + transition(to: .transcribing) + [.stopAndTranscribe]

        case .recordingReady:
            guard case .arming = phase else { return [] }
            return transition(to: .listening(level: 0)) + [.playCue(.start)]

        case .cancelled:
            guard isBusy else { return [] }
            return transition(to: .idle) + [.discardRecording]

        case .transcribed(let transcript):
            return [.deliver(transcript.text)]

        case .delivered:
            return []

        case .failed(let reason, let recoverable):
            canRetry = recoverable
            return [.playCue(.error)]
                + transition(to: .failed(FailureSummary(reason: reason, canRetry: recoverable)))

        case .retried:
            guard canRetry, !isBusy else { return [] }
            return transition(to: .transcribing)

        case .dismissed:
            guard !isBusy else { return [] }
            return transition(to: .idle)

        case .readinessChanged(let blockers):
            guard case .blocked(let shown) = phase else { return [] }
            if blockers.isEmpty { return transition(to: .idle) }
            return blockers == shown ? [] : transition(to: .blocked(blockers))
        }
    }

    public mutating func settle(_ transcript: Transcript, route: DeliveryRoute, into app: String?)
        -> [SessionEffect]
    {
        destination = app
        let summary = DeliverySummary(
            route: route, destination: app, cleanupDegraded: transcript.cleanupDegraded,
            verified: transcript.verified, applied: transcript.applied,
            problems: transcript.problems)
        let cue: [SessionEffect] = summary.problems.isEmpty ? [] : [.playCue(.error)]
        return cue + transition(to: .delivered(summary))
    }

    private mutating func press(blockers: [String], safety: TargetSafety) -> [SessionEffect] {
        guard !isBusy else { return [] }
        guard blockers.isEmpty else { return transition(to: .blocked(blockers)) }
        guard safety.allowsDictation else {
            return [.playCue(.error), .refuseSecureField]
                + transition(to: .refusedSecureField)
        }
        canRetry = false
        return transition(to: .arming) + [.startRecording]
    }

    private mutating func transition(to next: PipelinePhase) -> [SessionEffect] {
        guard next != phase else { return [] }
        phase = next
        guard case .transient(let seconds) = next.visibility else { return [] }
        return [.hide(after: seconds)]
    }

    public var isBusy: Bool {
        switch phase {
        case .arming, .listening, .transcribing: true
        default: false
        }
    }

    public var isCapturing: Bool {
        switch phase {
        case .arming, .listening: true
        default: false
        }
    }

    public mutating func meter(_ level: Double) {
        guard case .listening = phase else { return }
        phase = .listening(level: level)
    }
}
