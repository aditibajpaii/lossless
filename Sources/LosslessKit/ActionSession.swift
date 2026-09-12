import Foundation
import LosslessEngine

public struct ActionPage: Hashable, Sendable, Codable {
    public var origin: String
    public var document: String

    public init(origin: String, document: String) {
        self.origin = origin
        self.document = document
    }
}

public struct ActionField: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ActionProposal: Hashable, Sendable, Codable {
    public var utteranceId: String
    public var page: ActionPage
    public var tool: String
    public var fields: [ActionField]
    public var readOnly: Bool

    public init(
        utteranceId: String, page: ActionPage, tool: String, fields: [ActionField],
        readOnly: Bool
    ) {
        self.utteranceId = utteranceId
        self.page = page
        self.tool = tool
        self.fields = fields
        self.readOnly = readOnly
    }

    public var summary: String {
        fields.map(\.value).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum ActionPhase: Hashable, Sendable {
    case idle
    case planning(id: String)
    case awaitingConfirm(ActionProposal)
    case executing(id: String)
    case blocked(String)
    case succeeded(String)
    case failed(String)
    case noTools
}

public enum ActionOffer: Equatable, Sendable {
    case stale
    case pageChanged
    case blocked
    case confirm(ActionProposal)
    case execute(ActionProposal)
}

public struct ActionSession: Sendable {
    public private(set) var phase: ActionPhase = .idle
    public private(set) var utteranceId: String?
    public private(set) var page: ActionPage?
    public private(set) var graph: RepairGraph?

    public init() {}

    public var isOpen: Bool {
        switch phase {
        case .idle, .blocked, .succeeded, .failed, .noTools: false
        default: true
        }
    }

    public mutating func attach(_ page: ActionPage) -> ActionOffer? {
        if case .executing = phase, let current = self.page, current != page {
            phase = .failed("Page changed · action cancelled")
            return .pageChanged
        }
        if case .awaitingConfirm = phase, let current = self.page, current != page,
            let id = utteranceId
        {
            self.page = page
            phase = .planning(id: id)
            return nil
        }
        self.page = page
        return nil
    }

    public mutating func heard(_ graph: RepairGraph, page: ActionPage?) -> String {
        let id = UUID().uuidString
        self.utteranceId = id
        self.graph = graph
        self.page = page
        phase = .planning(id: id)
        return id
    }

    public mutating func consider(_ proposal: ActionProposal, blocked: Bool, reason: String)
        -> ActionOffer
    {
        let expected: String?
        switch phase {
        case .planning(let id): expected = id
        case .awaitingConfirm(let current): expected = current.utteranceId
        case .blocked, .succeeded: expected = utteranceId
        default: expected = nil
        }
        guard let expected, proposal.utteranceId == expected else { return .stale }
        if let page, page != proposal.page {
            phase = .failed("Page changed · action cancelled")
            return .pageChanged
        }
        self.page = proposal.page
        if blocked {
            phase = .blocked(reason)
            return .blocked
        }
        if proposal.readOnly {
            phase = .executing(id: proposal.utteranceId)
            return .execute(proposal)
        }
        phase = .awaitingConfirm(proposal)
        return .confirm(proposal)
    }

    public mutating func confirm() -> ActionProposal? {
        guard case .awaitingConfirm(let proposal) = phase else { return nil }
        if let page, page != proposal.page {
            phase = .failed("Page changed · action cancelled")
            return nil
        }
        phase = .executing(id: proposal.utteranceId)
        return proposal
    }

    public mutating func markNoTools() {
        phase = .noTools
    }

    public mutating func succeed(_ text: String) {
        guard case .executing = phase else { return }
        phase = .succeeded(text)
    }

    public mutating func fail(_ text: String) {
        phase = .failed(text)
    }

    public mutating func cancel() {
        phase = .idle
        utteranceId = nil
        page = nil
        graph = nil
    }

    public var banner: ActionBanner {
        switch phase {
        case .idle:
            ActionBanner(symbol: "mic", label: "Hold to speak", persistent: false)
        case .planning:
            ActionBanner(symbol: "ellipsis", label: "Working", persistent: true)
        case .awaitingConfirm(let proposal):
            ActionBanner(
                symbol: "",
                label: proposal.summary.isEmpty ? "↵" : "\(proposal.summary)  ↵",
                persistent: true)
        case .executing:
            ActionBanner(symbol: "arrow.right", label: "Running", persistent: true)
        case .blocked(let reason):
            ActionBanner(symbol: "xmark", label: "Blocked · \(reason)", persistent: true)
        case .succeeded(let text):
            ActionBanner(symbol: "checkmark", label: text, persistent: false)
        case .failed(let text):
            ActionBanner(symbol: "exclamationmark", label: text, persistent: true)
        case .noTools:
            ActionBanner(symbol: "minus", label: "Nothing to do here", persistent: false)
        }
    }
}
