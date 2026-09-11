import Foundation

public struct LatencyTrace: Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        case press
        case recordingReady
        case release
        case audioFinalised
        case requestOpened
        case uploadCompleted
        case responseReceived
        case decoded
        case analysed
        case pastePosted
        case settled
    }

    private var marks: [Stage: Double] = [:]
    private let origin = DispatchTime.now().uptimeNanoseconds

    public init() {}

    public mutating func mark(_ stage: Stage) {
        mark(stage, atUptime: DispatchTime.now().uptimeNanoseconds)
    }

    public mutating func mark(_ stage: Stage, atUptime nanos: UInt64) {
        guard nanos >= origin else { return }
        marks[stage] = Double(nanos - origin) / 1_000_000
    }

    public func at(_ stage: Stage) -> Double? { marks[stage] }

    public func span(_ from: Stage, _ to: Stage) -> Double? {
        guard let start = marks[from], let end = marks[to] else { return nil }
        return end - start
    }

    public var keyUpToText: Double? { span(.release, .pastePosted) }

    public var summary: String {
        Stage.allCases.compactMap { stage in
            marks[stage].map { "\(stage.rawValue)=\(String(format: "%.0f", $0))" }
        }
        .joined(separator: " ")
    }
}

public final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [(LatencyTrace.Stage, UInt64)] = []

    public init() {}

    public func mark(_ stage: LatencyTrace.Stage) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        stages.append((stage, now))
        lock.unlock()
    }

    public func drain() -> [(LatencyTrace.Stage, UInt64)] {
        lock.lock()
        defer {
            stages = []
            lock.unlock()
        }
        return stages
    }
}

public struct LatencySample: Sendable {
    public let stage: String
    public let p50: Double
    public let p95: Double
    public let count: Int

    public init(stage: String, p50: Double, p95: Double, count: Int) {
        self.stage = stage
        self.p50 = p50
        self.p95 = p95
        self.count = count
    }
}

public enum LatencyStats {
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = fraction * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        guard upper < sorted.count else { return sorted[sorted.count - 1] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }

    public static func spans(_ traces: [LatencyTrace]) -> [LatencySample] {
        var rows: [LatencySample] = []
        let stages = LatencyTrace.Stage.allCases
        for index in 1..<stages.count {
            let values = traces.compactMap { $0.span(stages[index - 1], stages[index]) }
            guard !values.isEmpty else { continue }
            rows.append(
                LatencySample(
                    stage: "\(stages[index - 1].rawValue)->\(stages[index].rawValue)",
                    p50: percentile(values, 0.50), p95: percentile(values, 0.95),
                    count: values.count))
        }
        let total = traces.compactMap(\.keyUpToText)
        if !total.isEmpty {
            rows.append(
                LatencySample(
                    stage: "release->pastePosted", p50: percentile(total, 0.50),
                    p95: percentile(total, 0.95), count: total.count))
        }
        return rows
    }
}
