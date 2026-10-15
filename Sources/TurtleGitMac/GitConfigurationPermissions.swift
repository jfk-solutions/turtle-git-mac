// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Git creates adjacent .lock files and renames them over config files. Persist
/// directory grants rather than file-only bookmarks for external config writes.
@MainActor enum GitConfigurationPermissions {
    private static let key = "TurtleGit.GitConfiguration.DirectoryBookmarks"
    private static var leases: [RepositoryAccessLease] = []
    static func restore() {
        guard leases.isEmpty else { return }
        var refreshed: [Data] = []
        for bookmark in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
            do {
                let provider = SystemRepositoryBookmarkProvider()
                let resolved = try provider.resolve(bookmark)
                let lease = RepositoryAccessLease(url: resolved.url)
                guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { refreshed.append(bookmark); continue }
                leases.append(lease)
                refreshed.append(resolved.stale ? try provider.create(for: resolved.url) : bookmark)
            } catch { refreshed.append(bookmark) }
        }
        UserDefaults.standard.set(refreshed, forKey: key)
    }
    static func retained(for file: URL) -> [RepositoryAccessLease] { leases.filter { $0.permits(file) } }
    static func authorized(_ file: URL) -> Bool {
        if !GitRuntime.isAppStoreBuild { return true }
        let home = RepositoryAccessLease(url: FileManager.default.homeDirectoryForCurrentUser)
        if home.contains(file) { return true }
        return leases.contains { $0.hasSecurityScope && $0.contains(file) }
    }
    static func remember(_ directory: URL, for file: URL) throws {
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
