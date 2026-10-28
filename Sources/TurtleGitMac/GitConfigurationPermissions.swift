// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// An independent worker owns the security scopes before signalling a waiter.
/// Core's synchronous execution boundary may be called from any actor: its
/// readiness must never depend on a main-actor continuation being serviced.
struct GitConfigurationRestoration: @unchecked Sendable {
    var leases: [RepositoryAccessLease] = []
    var bookmarks: [Data] = []
}
final class GitConfigurationReadBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let bookmarks: [Data]
    private let requireScope: Bool
    private let resolveBookmarks: @Sendable ([Data], Bool) -> GitConfigurationRestoration
    private var started = false
    private var result: GitConfigurationRestoration?
    init(bookmarks: [Data], requireScope: Bool,
         resolve: @escaping @Sendable ([Data], Bool) -> GitConfigurationRestoration = GitConfigurationReadBarrier.resolveSystem) {
        self.bookmarks = bookmarks; self.requireScope = requireScope; self.resolveBookmarks = resolve
    }
    var pending: Bool { condition.lock(); defer { condition.unlock() }; return started && result == nil }
    func prepare(cancellation: OperationCancellation?) throws {
        try cancellation?.check()
        condition.lock()
        if !started {
            started = true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let value = resolveBookmarks(bookmarks, requireScope)
                condition.lock(); result = value; condition.broadcast(); condition.unlock()
            }
        }
        defer { condition.unlock() }
        while result == nil {
            try cancellation?.check()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        try cancellation?.check()
    }
    func restored() -> GitConfigurationRestoration? { condition.lock(); defer { condition.unlock() }; return result }
    static func resolveSystem(_ bookmarks: [Data], _ requireScope: Bool) -> GitConfigurationRestoration {
        var value = GitConfigurationRestoration()
        for bookmark in bookmarks {
            do {
                let provider = SystemRepositoryBookmarkProvider()
                let resolved = try provider.resolve(bookmark)
                let lease = RepositoryAccessLease(url: resolved.url, provider: provider)
                guard !requireScope || lease.hasSecurityScope else { value.bookmarks.append(bookmark); continue }
                value.leases.append(lease)
                value.bookmarks.append(resolved.stale ? try provider.create(for: resolved.url) : bookmark)
            } catch { value.bookmarks.append(bookmark) }
        }
        return value
    }
}

/// Git creates adjacent .lock files and renames them over config files. Persist
/// directory grants rather than file-only bookmarks for external config writes.
@MainActor enum GitConfigurationPermissions {
    private static let key = "TurtleGit.GitConfiguration.DirectoryBookmarks"
    private static var leases: [RepositoryAccessLease] = []
    private static var didRestore = false
    private static var readBarrier: GitConfigurationReadBarrier?
    private static func barrier() -> GitConfigurationReadBarrier {
        if let readBarrier { return readBarrier }
        let captured = GitConfigurationReadBarrier(bookmarks: UserDefaults.standard.array(forKey: key) as? [Data] ?? [], requireScope: GitRuntime.isAppStoreBuild)
        readBarrier = captured
        return captured
    }
    /// Cheap host installation before App.main captures bytes only; it neither
    /// resolves a bookmark nor waits for filesystem/security services.
    static func installGitReadPreparation() {
        let captured = barrier()
        GitRuntime.installReadPreparation { cancellation in try captured.prepare(cancellation: cancellation) }
    }
    static var restorationPending: Bool { readBarrier?.pending == true }
    private static func accept(_ result: GitConfigurationRestoration) {
        guard !didRestore else { return }
        didRestore = true
        leases = result.leases
        UserDefaults.standard.set(result.bookmarks, forKey: key)
    }
    static func restoreForGitReads() async {
        let captured = barrier()
        // The synchronous Core barrier and native async wait share one resolver;
        // its scopes are already retained before this main-actor adoption runs.
        _ = try? await Task.detached(priority: .userInitiated) { try captured.prepare(cancellation: nil) }.value
        if let result = captured.restored() { accept(result) }
    }
    static func restore() {
        guard !didRestore else { return }
        let captured = barrier()
        try? captured.prepare(cancellation: nil)
        if let result = captured.restored() { accept(result) }
    }
    static func retained(for file: URL) -> [RepositoryAccessLease] { restore(); return leases.filter { $0.permits(file) } }
    static func authorized(_ file: URL) -> Bool {
        restore()
        if !GitRuntime.isAppStoreBuild { return true }
        let home = RepositoryAccessLease(url: FileManager.default.homeDirectoryForCurrentUser)
        if home.contains(file) { return true }
        return leases.contains { $0.hasSecurityScope && $0.contains(file) }
    }
    static func remember(_ directory: URL, for file: URL) throws {
        restore()
        let lease = RepositoryAccessLease(url: directory)
        guard lease.contains(file), !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let provider = SystemRepositoryBookmarkProvider()
        let bookmark = try provider.create(for: directory)
        var saved = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        saved.append(bookmark); UserDefaults.standard.set(saved, forKey: key)
        leases.removeAll { $0.url == directory }; leases.append(lease)
    }
}

/// File grants belong to Commit template reads, independently of config-write
/// directory permissions. Keep each scope alive through its corresponding read.
@MainActor final class CommitTemplateFileAccess {
    static let key = "Commit.TemplateBookmarks"
    let preferences: UserDefaults
    var provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()
    var requiresSecurityScope = GitRuntime.isAppStoreBuild
    init(preferences: UserDefaults) { self.preferences = preferences }
    func needsPermission(_ file: URL, repositoryAccess: RepositoryAccessLease?) -> Bool {
        requiresSecurityScope && !(repositoryAccess?.permits(file) == true)
    }
    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        a.isFileURL && b.isFileURL && a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
    func acquire(_ file: URL) throws -> RepositoryAccessLease? {
        let values = preferences.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        guard let bookmark = values[file.standardizedFileURL.path] else { return nil }
        let resolved = try provider.resolve(bookmark)
        guard sameFile(resolved.url, file) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let lease = RepositoryAccessLease(url: resolved.url, provider: provider)
        guard !requiresSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        if resolved.stale {
            var refreshed = values; refreshed[file.standardizedFileURL.path] = try provider.create(for: resolved.url)
            preferences.set(refreshed, forKey: Self.key)
        }
        return lease
    }
    func remember(_ selected: URL, for expected: URL) throws -> RepositoryAccessLease {
        guard sameFile(selected, expected) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let lease = RepositoryAccessLease(url: selected, provider: provider)
        guard !requiresSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let bookmark = try provider.create(for: selected)
        var values = preferences.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        values[expected.standardizedFileURL.path] = bookmark
        preferences.set(values, forKey: Self.key)
        return lease
    }
}
