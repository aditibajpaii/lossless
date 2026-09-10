import Foundation

public enum APIEndpoints {
    public static let dictation =
        URL(string: "https://dictation.assemblyai.com/transcribe")
        ?? URL(fileURLWithPath: "/dev/null")

    public static let account =
        URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")
        ?? URL(fileURLWithPath: "/dev/null")
}

public enum KeyVerdict: Equatable, Sendable {
    case accepted
    case rejected
    case unreachable(String)
}

public struct DictationConfig: Encodable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let conversationContext: String?
    public let wordBoost: [String]
    public let llm: [String: String]

    public init(
        sampleRate: Int = 16_000, channels: Int = 1, conversationContext: String? = nil,
        wordBoost: [String] = []
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.conversationContext = conversationContext?.isEmpty == true ? nil : conversationContext
        self.wordBoost = wordBoost
        self.llm = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channels
        case conversationContext = "conversation_context"
        case wordBoost = "word_boost"
        case llm
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channels, forKey: .channels)
        try container.encodeIfPresent(conversationContext, forKey: .conversationContext)
        if !wordBoost.isEmpty { try container.encode(wordBoost, forKey: .wordBoost) }
        try container.encode(llm, forKey: .llm)
    }
}

public struct DictationResponse: Decodable, Sendable {
    public struct Word: Decodable, Sendable {
        public let text: String
        public let confidence: Double
    }

    public let text: String
    public let words: [Word]?
    public let confidence: Double?
    public let audioDurationMS: Int?
    public let requestTimeMS: Double?
    public let llmResponse: String?
    public let llmError: String?

    private enum CodingKeys: String, CodingKey {
        case text, words, confidence
        case audioDurationMS = "audio_duration_ms"
        case requestTimeMS = "request_time_ms"
        case llmResponse = "llm_response"
        case llmError = "llm_error"
    }

    public var pair: TranscriptPair {
        TranscriptPair(raw: text, clean: usableCleanup ?? text)
    }

    public var cleanupDegraded: Bool { llmError != nil || usableCleanup == nil }

    private var usableCleanup: String? {
        guard let llmResponse,
            !llmResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return llmResponse
    }
}

public enum DictationError: Error, Sendable {
    case missingAPIKey
    case transport(String)
    case status(Int, String)
}

public protocol DictationClient: Sendable {
    func transcribe(
        pcm: Data, config: DictationConfig, trace: @escaping @Sendable (LatencyTrace.Stage) -> Void
    ) async throws -> DictationResponse

    func warm() async

    func verifyKey() async -> KeyVerdict
}

extension DictationClient {
    public func transcribe(pcm: Data, config: DictationConfig) async throws -> DictationResponse {
        try await transcribe(pcm: pcm, config: config, trace: { _ in })
    }
}

public struct AssemblyAIDictationClient: DictationClient {
    private let apiKey: String
    private let session: URLSession

    public static let requestTimeout: TimeInterval = 30
    public static let resourceTimeout: TimeInterval = 60

    public init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func verifyKey() async -> KeyVerdict {
        guard !apiKey.isEmpty else { return .rejected }
        var request = URLRequest(url: APIEndpoints.account)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (_, response) = try? await session.data(for: request),
            let status = (response as? HTTPURLResponse)?.statusCode
        else { return .unreachable("Could not reach AssemblyAI") }
        switch status {
        case 200..<300: return .accepted
        case 401, 403: return .rejected
        default: return .unreachable("AssemblyAI answered \(status)")
        }
    }

    public func warm() async {
        guard
            var components = URLComponents(
                url: APIEndpoints.dictation, resolvingAgainstBaseURL: false)
        else { return }
        components.path = "/"
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    public func transcribe(
        pcm: Data, config: DictationConfig, trace: @escaping @Sendable (LatencyTrace.Stage) -> Void
    ) async throws -> DictationResponse {
        guard !apiKey.isEmpty else { throw DictationError.missingAPIKey }
        let boundary = "lossless.\(UUID().uuidString)"
        var request = URLRequest(url: APIEndpoints.dictation)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MultipartBody.encode(pcm: pcm, config: config, boundary: boundary)

        let progress = UploadProgress(onComplete: { trace(.uploadCompleted) })
        trace(.requestOpened)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: progress)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw DictationError.transport(error.localizedDescription)
        }
        trace(.responseReceived)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DictationError.status(status, String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(DictationResponse.self, from: data)
        trace(.decoded)
        return decoded
    }
}

enum MultipartBody {
    static func encode(pcm: Data, config: DictationConfig, boundary: String) throws -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"utterance.pcm\"\r\n")
        append("Content-Type: audio/pcm\r\n\r\n")
        body.append(pcm)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"config\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(try JSONEncoder().encode(config))
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onComplete: @Sendable () -> Void
    private var reported = false

    init(onComplete: @escaping @Sendable () -> Void) {
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard !reported, totalBytesExpectedToSend > 0,
            totalBytesSent >= totalBytesExpectedToSend
        else { return }
        reported = true
        onComplete()
    }
}
