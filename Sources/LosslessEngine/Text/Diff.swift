public enum DiffOperation: Hashable, Sendable {
    case match(raw: Int, clean: Int)
    case delete(raw: Int)
    case insert(clean: Int)
}

public enum MyersDiff {
    public static func trace(raw: [String], clean: [String]) -> [DiffOperation] {
        let n = raw.count
        let m = clean.count
        let max = n + m
        guard max > 0 else { return [] }

        var v = [Int](repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []

        for d in 0...max {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) {
                    x = v[k + 1 + max]
                } else {
                    x = v[k - 1 + max] + 1
                }
                var y = x - k
                while x < n, y < m, raw[x] == clean[y] {
                    x += 1
                    y += 1
                }
                v[k + max] = x
                if x >= n, y >= m {
                    return backtrack(trace: trace, raw: raw, clean: clean, d: d, max: max)
                }
            }
        }
        return []
    }

    private static func backtrack(
        trace: [[Int]], raw: [String], clean: [String], d finalD: Int, max: Int
    ) -> [DiffOperation] {
        var operations: [DiffOperation] = []
        var x = raw.count
        var y = clean.count

        for d in stride(from: finalD, through: 1, by: -1) {
            let v = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[k - 1 + max] < v[k + 1 + max]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[previousK + max]
            let previousY = previousX - previousK

            while x > previousX, y > previousY {
                x -= 1
                y -= 1
                operations.append(.match(raw: x, clean: y))
            }
            if x > previousX {
                x -= 1
                operations.append(.delete(raw: x))
            } else if y > previousY {
                y -= 1
                operations.append(.insert(clean: y))
            }
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            operations.append(.match(raw: x, clean: y))
        }
        return operations.reversed()
    }
}

public struct EditWindow: Hashable, Sendable {
    public let rawTokens: Range<Int>
    public let cleanTokens: Range<Int>

    public var isDeletion: Bool { !rawTokens.isEmpty && cleanTokens.isEmpty }
    public var isInsertion: Bool { rawTokens.isEmpty && !cleanTokens.isEmpty }
    public var isReplacement: Bool { !rawTokens.isEmpty && !cleanTokens.isEmpty }
}

public enum Survival: Hashable, Sendable {
    case survived(Range<Int>)
    case removed
    case indeterminate
}

public struct TokenAlignment: Hashable, Sendable {
    public let rawToClean: [Int: Int]
    public let cleanToRaw: [Int: Int]
    public let windows: [EditWindow]

    public func survival(ofRaw range: Range<Int>) -> Survival {
        survival(ofRawTokens: Array(range))
    }

    public func survival(ofRawTokens indices: [Int]) -> Survival {
        guard !indices.isEmpty else { return .indeterminate }
        let mapped = indices.compactMap { rawToClean[$0] }
        guard let lower = mapped.min(), let upper = mapped.max() else { return .removed }
        guard mapped.count == indices.count else { return .indeterminate }
        return .survived(lower..<(upper + 1))
    }

    public func survives(rawToken index: Int) -> Bool { rawToClean[index] != nil }
}

public enum TokenAligner {
    public static func align(raw: [Token], clean: [Token]) -> TokenAlignment {
        let operations = MyersDiff.trace(raw: raw.map(\.key), clean: clean.map(\.key))
        var rawToClean: [Int: Int] = [:]
        var cleanToRaw: [Int: Int] = [:]
        for operation in operations {
            guard case .match(let rawIndex, let cleanIndex) = operation else { continue }
            rawToClean[rawIndex] = cleanIndex
            cleanToRaw[cleanIndex] = rawIndex
        }
        return TokenAlignment(
            rawToClean: rawToClean, cleanToRaw: cleanToRaw, windows: windows(operations))
    }

    private static func windows(_ operations: [DiffOperation]) -> [EditWindow] {
        var windows: [EditWindow] = []
        var rawStart: Int?
        var rawEnd = 0
        var cleanStart: Int?
        var cleanEnd = 0
        var rawCursor = 0
        var cleanCursor = 0

        func flush() {
            guard rawStart != nil || cleanStart != nil else { return }
            let rawRange = (rawStart ?? rawCursor)..<max(rawEnd, rawStart ?? rawCursor)
            let cleanRange = (cleanStart ?? cleanCursor)..<max(cleanEnd, cleanStart ?? cleanCursor)
            windows.append(EditWindow(rawTokens: rawRange, cleanTokens: cleanRange))
            rawStart = nil
            cleanStart = nil
        }

        for operation in operations {
            switch operation {
            case .match(let rawIndex, let cleanIndex):
                flush()
                rawCursor = rawIndex + 1
                cleanCursor = cleanIndex + 1
            case .delete(let rawIndex):
                if rawStart == nil { rawStart = rawIndex }
                rawEnd = rawIndex + 1
                rawCursor = rawIndex + 1
            case .insert(let cleanIndex):
                if cleanStart == nil { cleanStart = cleanIndex }
                cleanEnd = cleanIndex + 1
                cleanCursor = cleanIndex + 1
            }
        }
        flush()
        return windows
    }
}
