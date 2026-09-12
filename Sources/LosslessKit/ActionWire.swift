import Foundation
import LosslessEngine

public enum ActionInbound: Equatable, Sendable {
    case hello(origin: String, document: String)
    case propose(ActionProposal)
    case noTools(utteranceId: String)
    case executed(utteranceId: String, result: String)
    case error(message: String)
}

public enum ActionOutbound: Equatable, Sendable {
    case utterance(
        utteranceId: String, raw: String, clean: String, compiled: String,
        claims: [LastUtterance.Claim])
    case execute(utteranceId: String, tool: String, arguments: [String: String])
    case decision(utteranceId: String, verdict: String, reason: String)
    case cancel(reason: String)
}

public enum ActionWire {
    public static func decode(_ data: Data) -> ActionInbound? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        switch type {
        case "hello":
            guard let origin = object["origin"] as? String,
                let document = object["document"] as? String
            else { return nil }
            return .hello(origin: origin, document: document)
        case "propose":
            guard let utteranceId = object["utteranceId"] as? String,
                let origin = object["origin"] as? String,
                let document = object["document"] as? String,
                let tool = object["tool"] as? String,
                let rawFields = object["fields"] as? [[String: Any]]
            else { return nil }
            let fields = rawFields.compactMap { field -> ActionField? in
                guard let name = field["name"] as? String,
                    let value = field["value"] as? String
                else { return nil }
                return ActionField(name: name, value: value)
            }
            let readOnly = object["readOnly"] as? Bool ?? false
            return .propose(
                ActionProposal(
                    utteranceId: utteranceId,
                    page: ActionPage(origin: origin, document: document),
                    tool: tool, fields: fields, readOnly: readOnly))
        case "noTools":
            guard let utteranceId = object["utteranceId"] as? String else { return nil }
            return .noTools(utteranceId: utteranceId)
        case "executed":
            guard let utteranceId = object["utteranceId"] as? String,
                let result = object["result"] as? String
            else { return nil }
            return .executed(utteranceId: utteranceId, result: result)
        case "error":
            guard let message = object["message"] as? String else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    public static func encode(_ message: ActionOutbound) -> Data {
        let object: [String: Any]
        switch message {
        case .utterance(let utteranceId, let raw, let clean, let compiled, let claims):
            object = [
                "type": "utterance",
                "utteranceId": utteranceId,
                "raw": raw,
                "clean": clean,
                "compiled": compiled,
                "claims": claims.map {
                    [
                        "before": $0.before,
                        "after": $0.after,
                        "kind": $0.kind,
                        "resolution": $0.resolution,
                    ] as [String: String]
                },
            ]
        case .execute(let utteranceId, let tool, let arguments):
            object = [
                "type": "execute",
                "utteranceId": utteranceId,
                "tool": tool,
                "arguments": arguments,
            ]
        case .decision(let utteranceId, let verdict, let reason):
            object = [
                "type": "decision",
                "utteranceId": utteranceId,
                "verdict": verdict,
                "reason": reason,
            ]
        case .cancel(let reason):
            object = [
                "type": "cancel",
                "reason": reason,
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
