// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// File-only, read-only bookmarks for native SSH identities.
public struct SystemSSHIdentityBookmarkProvider: RepositoryBookmarkProvider {
    public init() {}
    public func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, stale: stale)
    }
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}
public enum SSHIdentityAccessFailure: LocalizedError {
    case file, missingGrant, permission, putty, changed
    public var errorDescription: String? {
        switch self {
        case .changed: return "SSH key permissions changed. Refresh the list and review the selection again."
        case .file: return "Choose a regular private key file using Browse."
        case .missingGrant: return "Select this SSH key again using Browse to grant access."
        case .permission: return "The saved SSH key permission could not be renewed. Select it again using Browse."
        case .putty: return "This is a PuTTY key. Use SSH Key Generator → Load existing key to save an OpenSSH copy, then select that copy."
        }
    }
}
public struct SSHIdentityAccess {
    public let file: URL
    /// Retain through ssh-add. Releasing this result balances the security scope.
    public let permission: RepositoryAccessLease
}
/// A displayed permission, not the private key. The opaque bookmark is retained
/// only for conditional removal; clients cannot read it or construct snapshots.
public struct SSHIdentityGrant: Identifiable, Equatable, Sendable {
    public let configuredPath: String
    fileprivate let bookmark: Data
    public var id: GitReferenceName { GitReferenceName(configuredPath) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.bookmark == rhs.bookmark }
}
/// Use on the application's main actor. Records contain only bookmarks and paths,
/// never key bytes or passphrases. They are not exported to Finder or Git config.
public final class SSHIdentityAccessStore {
    private struct Grant: Codable { var configuredPath: String; var bookmark: Data }
    public let storageURL: URL
    private let provider: any RepositoryBookmarkProvider
    public init(storageURL: URL = SSHIdentityAccessStore.defaultStorageURL, provider: any RepositoryBookmarkProvider = SystemSSHIdentityBookmarkProvider()) {
        self.storageURL = storageURL; self.provider = provider
    }
    public static var defaultStorageURL: URL {
        RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("ssh-identities/grants.json")
    }
    private func read() throws -> [Grant] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        return try JSONDecoder().decode([Grant].self, from: Data(contentsOf: storageURL))
    }
    private func persist(_ grants: [Grant]) throws {
        let folder = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent("grant-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { let code = errno; close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try writer.write(contentsOf: JSONEncoder().encode(grants)); try writer.close() }
        catch { try? writer.close(); throw error }
        guard rename(temporary.path, storageURL.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw SSHIdentityAccessFailure.file }
        // Only inspect a bounded format marker. Never persist or log key contents.
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        if let prefix = try reader.read(upToCount: 32), prefix.starts(with: Data("PuTTY-User-Key-File-".utf8)) { throw SSHIdentityAccessFailure.putty }
    }
    /// Invoke only after explicit file selection. Canceling the containing settings
    /// page leaves this grant available but does not save a remote key setting.
    public func remember(_ url: URL, requireSecurityScope: Bool = false) throws {
        let permission = RepositoryAccessLease(url: url, provider: provider)
        guard !requireSecurityScope || permission.hasSecurityScope else { throw SSHIdentityAccessFailure.permission }
        try validate(url)
        let path = url.path
        let grant = Grant(configuredPath: path, bookmark: try provider.create(for: url))
        var grants = try read(); grants.removeAll { Data($0.configuredPath.utf8) == Data(path.utf8) }; grants.append(grant)
        try persist(grants)
        withExtendedLifetime(permission) {}
    }
    public func acquire(path: String, requireSecurityScope: Bool = false) throws -> SSHIdentityAccess {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw SSHIdentityAccessFailure.file }
        var grants = try read()
        guard let index = grants.firstIndex(where: { Data($0.configuredPath.utf8) == Data(path.utf8) }) else { throw SSHIdentityAccessFailure.missingGrant }
        let resolved: ResolvedBookmark
        do { resolved = try provider.resolve(grants[index].bookmark) } catch { throw SSHIdentityAccessFailure.permission }
        let permission = RepositoryAccessLease(url: resolved.url, provider: provider)
        guard !requireSecurityScope || permission.hasSecurityScope else { throw SSHIdentityAccessFailure.permission }
        try validate(resolved.url)
        if resolved.stale { grants[index].bookmark = try provider.create(for: resolved.url); try persist(grants) }
        // A moved bookmark resolves the file without silently rewriting Git config.
        return SSHIdentityAccess(file: resolved.url, permission: permission)
    }
    /// Listing does not resolve bookmarks, start scopes, inspect key bytes or
    /// rewrite stale grants. Missing/moved files can still be forgotten.
    public func grants() throws -> [SSHIdentityGrant] {
        var seen = Set<GitReferenceName>()
        return try read().map { grant in
            guard grant.configuredPath.hasPrefix("/"), !grant.configuredPath.utf8.contains(0),
                  seen.insert(GitReferenceName(grant.configuredPath)).inserted else { throw SSHIdentityAccessFailure.permission }
            return SSHIdentityGrant(configuredPath: grant.configuredPath, bookmark: grant.bookmark)
        }
    }
    /// Remove only the reviewed snapshots in one atomic update. A grant renewed
    /// or reauthorized while confirmation is open must be reviewed again.
    public func forget(_ selection: [SSHIdentityGrant]) throws {
        guard !selection.isEmpty else { return }
        let current = try read(), ids = Set(selection.map(\.id))
        guard ids.count == selection.count, Set(current.map { GitReferenceName($0.configuredPath) }).count == current.count, selection.allSatisfy({ wanted in
            current.contains { Data($0.configuredPath.utf8) == Data(wanted.configuredPath.utf8) && $0.bookmark == wanted.bookmark }
        }) else { throw SSHIdentityAccessFailure.changed }
        try persist(current.filter { !ids.contains(GitReferenceName($0.configuredPath)) })
    }
    public func forget(path: String) throws {
        try persist(read().filter { Data($0.configuredPath.utf8) != Data(path.utf8) })
    }
}
