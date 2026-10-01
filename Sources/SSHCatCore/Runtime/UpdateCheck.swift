import Foundation

/// Checks GitHub only when the user asks.
public enum UpdateCheck {
    public static let releasesPage = URL(string: "https://github.com/zhdsmy/SSHCat/releases/latest")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/zhdsmy/SSHCat/releases/latest")!

    public static func newerRelease(than current: String) async throws -> String? {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try newer(than: current, releaseJSON: data)
    }

    static func newer(than current: String, releaseJSON: Data) throws -> String? {
        struct Release: Decodable { var tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: releaseJSON).tag_name
        guard let latest = Version.parse(tag), let running = Version.parse(current, appVersion: true) else {
            throw URLError(.cannotParseResponse)
        }
        return latest > running ? tag : nil
    }

    private struct Version: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }

        static func parse(_ raw: String, appVersion: Bool = false) -> Self? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if appVersion, let suffix = value.range(of: #" \([0-9]+\)$"#, options: .regularExpression) {
                value.removeSubrange(suffix)
            }
            if value.first == "v" { value.removeFirst() }
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let numbers = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                      part == "0" || !part.hasPrefix("0") else { return nil }
                return Int(part)
            }
            guard numbers.count == 3 else { return nil }
            return Self(major: numbers[0], minor: numbers[1], patch: numbers[2])
        }
    }
}
