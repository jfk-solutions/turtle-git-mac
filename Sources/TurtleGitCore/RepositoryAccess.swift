import Foundation

public struct SavedRepository: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var lastKnownPath: String
    public var bookmark: Data
    public var lastOpened: Date
}

public struct ResolvedBookmark {
    public let url: URL
    public let stale: Bool
    public init(url: URL, stale: Bool) { self.url = url; self.stale = stale }
}

/// Injectable so persistence, renewal and scope lifetime can be tested without signing privileges.
public protocol RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemRepositoryBookmarkProvider: RepositoryBookmarkProvider {
    public init() {}
    public func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.nameKey], relativeTo: nil)
    }
    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, stale: stale)
    }
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Keep alive for the entire repository session, including all child Git operations.
public final class RepositoryAccessLease {
    public let url: URL
    public let hasSecurityScope: Bool
    private let provider: any RepositoryBookmarkProvider
    public init(url: URL, provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) {
        self.url = url; self.provider = provider
        hasSecurityScope = provider.startAccessing(url)
    }
    deinit { if hasSecurityScope { provider.stopAccessing(url) } }
    public func contains(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, url.isFileURL else { return false }
        guard let root = Self.canonicalPath(url), let path = Self.canonicalPath(candidate) else { return false }
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    // Foundation's resolvingSymlinksInPath can leave an entire path unchanged when
    // its final component does not exist. Resolve each link even for a future file.
    private static func canonicalPath(_ url: URL) -> String? {
        var pending = url.path.components(separatedBy: "/")[...]
        var resolved: [String] = []
        var links = 0
        while let component = pending.popFirst() {
            if component.isEmpty || component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let path = "/" + (resolved + [component]).joined(separator: "/")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                links += 1
                guard links <= 40 else { return nil }
                if destination.hasPrefix("/") { resolved = [] }
                pending = (destination.components(separatedBy: "/") + Array(pending))[...]
            } else { resolved.append(component) }
        }
        return "/" + resolved.joined(separator: "/")
    }
}

public enum RepositoryAccessFailure: LocalizedError {
    case unknownRepository, securityScopeUnavailable
    case repositoryRootOutsidePermission(String)
    public var errorDescription: String? {
        switch self {
        case .unknownRepository: return "This saved repository is no longer available. Select its folder again."
        case .securityScopeUnavailable: return "The saved folder permission could not be renewed. Select the repository folder again."
        case .repositoryRootOutsidePermission(let path): return "Select the repository root folder to authorize it: " + path
        }
    }
}

/// Call from the application's main actor. Bookmarks stay in its private container, never the Finder cache.
public final class RepositoryAccessStore {
    public private(set) var repositories: [SavedRepository]
    public let storageURL: URL
    private let provider: any RepositoryBookmarkProvider
    public init(storageURL: URL, provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws {
        self.storageURL = storageURL; self.provider = provider
        if FileManager.default.fileExists(atPath: storageURL.path) {
            repositories = try JSONDecoder().decode([SavedRepository].self, from: Data(contentsOf: storageURL))
        } else { repositories = [] }
    }
    public static var defaultStorageURL: URL {
        #if DEBUG
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("org.turtlegit.macos.documentation-preview") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDocumentationPreview/" + identifier + "/repositories.json")
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurtleGit", isDirectory: true).appendingPathComponent("repositories.json")
    }
    private func persist(_ updated: [SavedRepository]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        repositories = updated
    }
    @discardableResult public func remember(_ url: URL) throws -> SavedRepository {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let bookmark = try provider.create(for: url)
        let old = repositories.first { $0.lastKnownPath == path }
        let saved = SavedRepository(id: old?.id ?? UUID(), name: url.lastPathComponent, lastKnownPath: path,
                                    bookmark: bookmark, lastOpened: Date())
        let updated = [saved] + repositories.filter { $0.id != saved.id }
        try persist(updated)
        return saved
    }
    public func acquire(_ id: UUID, requireSecurityScope: Bool = false) throws -> RepositoryAccessLease {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { throw RepositoryAccessFailure.unknownRepository }
        let resolved = try provider.resolve(repositories[index].bookmark)
        let lease = RepositoryAccessLease(url: resolved.url, provider: provider)
        if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
        var updated = repositories
        if resolved.stale { updated[index].bookmark = try provider.create(for: resolved.url) }
        updated[index].lastKnownPath = resolved.url.standardizedFileURL.resolvingSymlinksInPath().path
        updated[index].name = resolved.url.lastPathComponent
        updated[index].lastOpened = Date()
        let entry = updated.remove(at: index); updated.insert(entry, at: 0)
        try persist(updated)
        return lease
    }
    public func forget(_ id: UUID) throws { try persist(repositories.filter { $0.id != id }) }
}
