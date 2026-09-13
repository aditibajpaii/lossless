import Foundation
import LosslessEngine

struct Report: Encodable {
    let raw: String
    let clean: String
    let compiled: String
}

func analyze(_ pair: TranscriptPair) -> Report {
    let graph = RepairEngine.analyze(pair)
    return Report(raw: graph.raw, clean: graph.clean, compiled: graph.compiled.text)
}

func emit(_ report: Report) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "analyze":
    guard arguments.count == 3 else {
        FileHandle.standardError.write(Data("usage: analyze <raw.txt> <clean.txt>\n".utf8))
        exit(2)
    }
    let raw = try String(contentsOfFile: arguments[1], encoding: .utf8)
    let clean = try String(contentsOfFile: arguments[2], encoding: .utf8)
    emit(analyze(TranscriptPair(raw: raw.trimmed, clean: clean.trimmed)))

case "dictate":
    guard arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: dictate <audio.pcm>\n".utf8))
        exit(2)
    }
    guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"], !key.isEmpty else {
        FileHandle.standardError.write(Data("ASSEMBLYAI_API_KEY not set\n".utf8))
        exit(2)
    }
    let pcm = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let client = AssemblyAIDictationClient(apiKey: key)
    let response = try await client.transcribe(pcm: pcm, config: DictationConfig())
    emit(analyze(response.pair))

default:
    FileHandle.standardError.write(Data("usage: lossless-cli <analyze|dictate>\n".utf8))
    exit(2)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
