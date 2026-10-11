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
