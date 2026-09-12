import Foundation

enum Updates {
    struct Release: Sendable, Equatable {
        let version: String
        let url: URL
    }

    private static let latest = URL(
        string: "https://api.github.com/repos/achalbajpai/lossless/releases/latest")

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func check() async -> Release? {
        guard let latest else { return nil }
        var request = URLRequest(url: latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = payload["tag_name"] as? String,
            let page = payload["html_url"] as? String, let url = URL(string: page)
        else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: current) else { return nil }
        return Release(version: version, url: url)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let left = components(candidate)
        let right = components(installed)
        guard !left.isEmpty, !right.isEmpty else { return false }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
    }
}
