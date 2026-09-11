import Foundation

public struct LastUtterance: Codable, Hashable, Sendable {
    public struct Claim: Codable, Hashable, Sendable {
        public var before: String
        public var after: String
        public var kind: String
        public var resolution: String

        public init(before: String, after: String, kind: String, resolution: String) {
            self.before = before
            self.after = after
            self.kind = kind
            self.resolution = resolution
        }
    }

    public var raw: String
    public var clean: String
    public var compiled: String
    public var claims: [Claim]
    public var verified: Bool
    public var cleanupDegraded: Bool

    public init(
        raw: String, clean: String, compiled: String, claims: [Claim], verified: Bool,
        cleanupDegraded: Bool
    ) {
        self.raw = raw
        self.clean = clean
        self.compiled = compiled
        self.claims = claims
        self.verified = verified
        self.cleanupDegraded = cleanupDegraded
    }

    public init(graph: RepairGraph, compiled: CompiledTranscript?, cleanupDegraded: Bool) {
        self.raw = graph.raw
        self.clean = graph.clean
        self.compiled = compiled?.text ?? graph.clean
        self.claims = graph.userFacingClaims.compactMap { event in
            guard let before = event.before, let after = event.after,
                !before.isEmpty, !after.isEmpty, before != after
            else { return nil }
            return Claim(
                before: before, after: after, kind: event.kind.rawValue,
                resolution: event.resolution.rawValue)
        }
        self.verified = graph.scope.verifiesRepairs && !cleanupDegraded
        self.cleanupDegraded = cleanupDegraded
    }
}
