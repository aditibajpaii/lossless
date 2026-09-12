import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import LosslessEngine
import os

enum Diagnostics {
    static let log = Logger(subsystem: "com.lossless.app", category: "pipeline")

    struct Readiness: Sendable {
        let accessibility: Bool
        let inputMonitoring: Bool
        let postEvent: Bool
        let microphone: AVAuthorizationStatus
        let hasAPIKey: Bool

        var blockers: [String] {
            var blockers: [String] = []
            if !hasAPIKey { blockers.append("AssemblyAI key") }
            if microphone != .authorized { blockers.append("Microphone") }
            if !inputMonitoring { blockers.append("Input Monitoring") }
            if !accessibility { blockers.append("Accessibility") }
            return blockers
        }
    }

    static func readiness(hasAPIKey: Bool) -> Readiness {
        Readiness(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(),
            postEvent: CGPreflightPostEventAccess(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            hasAPIKey: hasAPIKey)
    }

    static func report(_ readiness: Readiness, tapInstalled: Bool) {
        log.notice(
            """
            readiness accessibility=\(readiness.accessibility, privacy: .public) \
            inputMonitoring=\(readiness.inputMonitoring, privacy: .public) \
            postEvent=\(readiness.postEvent, privacy: .public) \
            microphone=\(readiness.microphone.rawValue, privacy: .public) \
            apiKey=\(readiness.hasAPIKey, privacy: .public) \
            tap=\(tapInstalled, privacy: .public)
            """)
    }

    static func phase(_ phase: PipelinePhase) {
        let name: String
        switch phase {
        case .idle: name = "idle"
        case .arming: name = "arming"
        case .listening: name = "listening"
        case .transcribing: name = "transcribing"
        case .delivered: name = "delivered"
        case .blocked: name = "blocked"
        case .failed: name = "failed"
        case .refusedSecureField: name = "refusedSecureField"
        case .acting: name = "acting"
        }
        log.notice("phase \(name, privacy: .public)")
    }

    static func trigger(_ edge: String) {
        log.notice("trigger \(edge, privacy: .public)")
    }

    static func signatureSummary() -> String {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
            let code
        else { return "unreadable" }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let details = information as? [String: Any]
        else { return "unreadable" }
        let flags = details[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let adhoc = flags & 0x2 != 0
        let authority = (details[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty == false
        return adhoc
            ? "ad-hoc (grants reset on every rebuild)" : (authority ? "certificate" : "unsigned")
    }

    static func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }
}
