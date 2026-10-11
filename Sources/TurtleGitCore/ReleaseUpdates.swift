// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let numbers: [UInt64]
    public let prerelease: [String]
    public init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = components.compactMap { UInt64($0) }; guard numbers.count == components.count else { return nil }
        let suffix = pieces.count == 2 ? pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard suffix.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
        self.numbers = numbers + Array(repeating: 0, count: 4 - numbers.count); prerelease = suffix
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let first = UInt64(a), let second = UInt64(b) { return first < second }
            if UInt64(a) != nil { return true }; if UInt64(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
public struct PublishedRelease: Decodable, Sendable {
    public let tag: String, name: String?, notes: String?
    public let url: URL
    public let draft: Bool, prerelease: Bool
    enum CodingKeys: String, CodingKey { case tag = "tag_name", name, notes = "body", url = "html_url", draft, prerelease }
}
public enum ReleaseUpdateFailure: LocalizedError {
    case feed, response(Int), invalidVersion, oversized
    public var errorDescription: String? {
        switch self {
        case .feed: return "The public release feed is unavailable or contains an unexpected release link."
        case .response(let code): return "Could not check for updates (HTTP \(code)). Try again later."
        case .invalidVersion: return "The installed version or release tag cannot be compared. Open the release page to check manually."
        case .oversized: return "The release response exceeded the supported size."
        }
    }
}
public enum ReleaseUpdateFeed {
    public static func repository(bundle: Bundle = .main) -> String {
        let value = bundle.object(forInfoDictionaryKey: "TurtleGitUpdateRepository") as? String ?? "jfk-solutions/turtle-git-mac"
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) } }) ? value : "jfk-solutions/turtle-git-mac"
    }
    public static func releases(_ data: Data, repository: String, includePreview: Bool) throws -> [PublishedRelease] {
        guard data.count <= 4 * 1024 * 1024 else { throw ReleaseUpdateFailure.oversized }
        let releases = try JSONDecoder().decode([PublishedRelease].self, from: data).filter { !$0.draft && (includePreview || !$0.prerelease) }
        for release in releases {
            guard release.url.scheme == "https", release.url.host?.lowercased() == "github.com", release.url.user == nil,
                  release.url.path.lowercased().hasPrefix("/" + repository.lowercased() + "/releases/tag/") else { throw ReleaseUpdateFailure.feed }
        }
        return releases.sorted {
            guard let a = ReleaseVersion($0.tag), let b = ReleaseVersion($1.tag) else { return ReleaseVersion($0.tag) != nil }
            return a > b
        }
    }
    public static func fetch(repository: String, includePreview: Bool, session: URLSession = .shared) async throws -> [PublishedRelease] {
        let url = URL(string: "https://api.github.com/repos/" + repository + "/releases?per_page=100")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TurtleGit-for-Mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ReleaseUpdateFailure.feed }
        guard http.statusCode == 200 else { throw http.statusCode == 404 ? ReleaseUpdateFailure.feed : ReleaseUpdateFailure.response(http.statusCode) }
        return try releases(data, repository: repository, includePreview: includePreview)
    }
}
