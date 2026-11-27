import Foundation

public enum AppUpdate {
    public static let tagsURL = URL(string: "https://api.github.com/repos/iandorsey00/veradata/tags?per_page=100")!

    public static func newerVersionURL(installed: String, tags: [String]) -> URL? {
        guard let installedVersion = StableVersion(installed) else { return nil }
        let latest = tags.compactMap { tag -> StableVersion? in
            guard tag.hasPrefix("v") else { return nil }
            return StableVersion(String(tag.dropFirst()))
        }.max()
        guard let latest, latest > installedVersion else { return nil }
        let version = latest.components.map(String.init).joined(separator: ".")
        return URL(string: "https://github.com/iandorsey00/veradata/tree/v\(version)")
    }

    private struct StableVersion: Comparable {
        let components: [Int]

        init?(_ version: String) {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let numbers = parts.compactMap { part -> Int? in
                guard part.utf8.allSatisfy({ (48...57).contains($0) }),
                      part.count == 1 || part.first != "0" else { return nil }
                return Int(part)
            }
            guard numbers.count == 3 else { return nil }
            components = numbers
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }
}
