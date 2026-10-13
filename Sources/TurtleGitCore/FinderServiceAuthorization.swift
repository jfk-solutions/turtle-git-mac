// Private permission handoff for a future independent Finder cache service.
// GPL-2.0-or-later. Follows Apple's interprocess URL bookmark contract.
import Foundation
import Darwin

public protocol RepositoryTransferBookmarkProvider {
    func createTransfer(for url:URL) throws -> Data
    func resolveTransfer(_ data:Data) throws -> ResolvedBookmark
    func startAccessing(_ url:URL) -> Bool
    func stopAccessing(_ url:URL)
}
public struct SystemRepositoryTransferBookmarks:RepositoryTransferBookmarkProvider {
    public init() {}
    public func createTransfer(for url:URL) throws -> Data {
        // Implicit scope bookmarks are for live IPC, not persisted app-scope grants.
        try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
    }
    public func resolveTransfer(_ data:Data) throws -> ResolvedBookmark {
        var stale=false
        let url=try URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutImplicitStartAccessing],relativeTo:nil,bookmarkDataIsStale:&stale)
        return ResolvedBookmark(url:url,stale:stale)
    }
    public func startAccessing(_ url:URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url:URL) { url.stopAccessingSecurityScopedResource() }
}
public enum FinderServiceAuthorizationFailure:LocalizedError,Equatable {
    case invalidRequest,unsupportedVersion
    public var errorDescription:String? { self == .invalidRequest ? "The cache-service permission request is invalid." : "The cache-service permission protocol version is unsupported." }
}
/// Sent through private IPC only. Never place this payload in Finder's App Group.
public struct FinderServiceWatchGrant:Codable,Sendable {
    public let id:UUID
    public let bookmark:Data
    public let repositoryComponents:[String]
    public init(id:UUID,bookmark:Data,repositoryComponents:[String]) {
        self.id=id;self.bookmark=bookmark;self.repositoryComponents=repositoryComponents
    }
}
public struct FinderServiceAuthorization:Codable,Sendable {
    public let version:Int
    public let grants:[FinderServiceWatchGrant]
    public init(grants:[FinderServiceWatchGrant]) { version=1;self.grants=grants }
    public static func capture(_ values:[(UUID,URL,RepositoryAccessLease)],provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks()) throws -> Self {
        var seen=Set<UUID>()
        let grants=try values.map { id,root,lease -> FinderServiceWatchGrant in
            guard seen.insert(id).inserted,lease.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let scope=lease.url.standardizedFileURL.resolvingSymlinksInPath().path,repository=root.standardizedFileURL.resolvingSymlinksInPath().path
            let relative=repository==scope ? "" : String(repository.dropFirst(scope=="/" ? 1 : scope.count+1))
            let components=relative.isEmpty ? [] : relative.components(separatedBy:"/")
            guard valid(components) else { throw FinderServiceAuthorizationFailure.invalidRequest }
            return FinderServiceWatchGrant(id:id,bookmark:try provider.createTransfer(for:lease.url),repositoryComponents:components)
        }
        return Self(grants:grants)
    }
    fileprivate static func valid(_ components:[String]) -> Bool {
        components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) }
    }
    public func acquire(provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks(),requireSecurityScope:Bool = true) throws -> [FinderServiceAccess] {
        guard version==1 else { throw FinderServiceAuthorizationFailure.unsupportedVersion }
        guard grants.count<=1024,Set(grants.map(\.id)).count==grants.count,grants.allSatisfy({ !$0.bookmark.isEmpty && $0.bookmark.count<=1_048_576 && Self.valid($0.repositoryComponents) }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        var accesses:[FinderServiceAccess]=[]
        for grant in grants {
            let resolved=try provider.resolveTransfer(grant.bookmark)
            let lease=FinderServiceScope(url:resolved.url,provider:provider)
            if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
            let root=grant.repositoryComponents.reduce(resolved.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
            guard lease.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
            accesses.append(FinderServiceAccess(id:grant.id,root:root,scope:lease,bookmarkWasStale:resolved.stale))
        }
        return accesses
    }
}
public final class FinderServiceScope {
    public let url:URL
    public let hasSecurityScope:Bool
    private let provider:any RepositoryTransferBookmarkProvider
    fileprivate init(url:URL,provider:any RepositoryTransferBookmarkProvider) { self.url=url;self.provider=provider;hasSecurityScope=provider.startAccessing(url) }
    deinit { if hasSecurityScope { provider.stopAccessing(url) } }
    public func contains(_ root:URL) -> Bool { RepositoryAccessLease.pathIsContained(root,by:url) }
}
public struct FinderServiceAccess {
    public let id:UUID
    public let root:URL
    public let scope:FinderServiceScope
    public let bookmarkWasStale:Bool
    /// Receiver creates its own persistent scope, rather than saving the IPC bookmark.
    public func persistentGrant(provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws -> FinderServicePersistentGrant {
        let scopePath=scope.url.standardizedFileURL.resolvingSymlinksInPath().path,rootPath=root.standardizedFileURL.resolvingSymlinksInPath().path
        guard scope.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let suffix=rootPath==scopePath ? "" : String(rootPath.dropFirst(scopePath=="/" ? 1 : scopePath.count+1))
        let components=suffix.isEmpty ? [] : suffix.components(separatedBy:"/")
        return FinderServicePersistentGrant(id:id,bookmark:try provider.create(for:scope.url),repositoryComponents:components)
    }
}

/// Stored only in the receiver's private container; scopes are minted by that receiver.
public struct FinderServicePersistentGrant:Codable,Sendable,Equatable {
    public let id:UUID
    public let bookmark:Data
    public let repositoryComponents:[String]
    public func acquire(provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),requireSecurityScope:Bool = true) throws -> (URL,RepositoryAccessLease) {
        guard !bookmark.isEmpty,bookmark.count<=1_048_576,FinderServiceAuthorization.valid(repositoryComponents) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let resolved=try provider.resolve(bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
        if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
        let root=repositoryComponents.reduce(resolved.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
        guard lease.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return (root,lease)
    }
}

/// Receiver-private durable grants. This file must not live in Finder's shared group.
@MainActor public final class FinderServicePermissionStore {
    private struct Archive:Codable { let version:Int;let grants:[FinderServicePersistentGrant] }
    public let url:URL
    public private(set) var grants:[FinderServicePersistentGrant]
    private let provider:any RepositoryBookmarkProvider
    public init(url:URL,provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws {
        guard url.isFileURL else { throw FinderServiceAuthorizationFailure.invalidRequest }
        self.url=url;self.provider=provider
        if FileManager.default.fileExists(atPath:url.path) {
            let bytes=try Data(contentsOf:url)
            guard bytes.count<=16_777_216 else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let archive=try JSONDecoder().decode(Archive.self,from:bytes)
            guard archive.version==1 else { throw FinderServiceAuthorizationFailure.unsupportedVersion }
            guard Self.valid(archive.grants) else { throw FinderServiceAuthorizationFailure.invalidRequest };grants=archive.grants
        } else { grants=[] }
    }
    private static func valid(_ values:[FinderServicePersistentGrant]) -> Bool {
        values.count<=1024 && Set(values.map(\.id)).count==values.count && values.allSatisfy { !$0.bookmark.isEmpty && $0.bookmark.count<=1_048_576 && FinderServiceAuthorization.valid($0.repositoryComponents) }
    }
    private func save(_ values:[FinderServicePersistentGrant]) throws {
        guard Self.valid(values) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let bytes=try JSONEncoder().encode(Archive(version:1,grants:values))
        guard bytes.count<=16_777_216 else { throw FinderServiceAuthorizationFailure.invalidRequest }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".service-grants-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard FileManager.default.createFile(atPath:temporary.path,contents:bytes,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        guard Darwin.rename(temporary.path,url.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        grants=values
    }
    /// Mint all receiver scopes before replacing its previous registration set.
    public func install(_ request:FinderServiceAuthorization,transfer:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks(),requireSecurityScope:Bool = true) throws -> [FinderServicePersistentAccess] {
        let incoming=try request.acquire(provider:transfer,requireSecurityScope:requireSecurityScope)
        let persisted=try incoming.map { try $0.persistentGrant(provider:provider) }
        // Resolve every minted bookmark before committing it: persistence must be usable.
        let accesses=try persisted.map { value -> FinderServicePersistentAccess in
            let (root,lease)=try value.acquire(provider:provider,requireSecurityScope:requireSecurityScope)
            return FinderServicePersistentAccess(id:value.id,root:root,lease:lease)
        }
        try save(persisted);return accesses
    }
    public func restore(requireSecurityScope:Bool = true) throws -> FinderServiceRestoration {
        var accesses:[FinderServicePersistentAccess]=[],failures:[UUID:String]=[:],renewed=grants
        for (index,value) in grants.enumerated() {
            do {
                let resolved=try provider.resolve(value.bookmark),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
                if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
                let root=value.repositoryComponents.reduce(resolved.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
                guard lease.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
                if resolved.stale { renewed[index]=FinderServicePersistentGrant(id:value.id,bookmark:try provider.create(for:resolved.url),repositoryComponents:value.repositoryComponents) }
                accesses.append(FinderServicePersistentAccess(id:value.id,root:root,lease:lease))
            } catch { failures[value.id]=error.localizedDescription }
        }
        // Failed entries remain available for explicit renewed authorization.
        if renewed != grants { try save(renewed) }
        return FinderServiceRestoration(accesses:accesses,failures:failures)
    }
    public func remove(_ id:UUID) throws { try save(grants.filter { $0.id != id }) }
}
public struct FinderServicePersistentAccess {
    public let id:UUID
    public let root:URL
    public let lease:RepositoryAccessLease
}
public struct FinderServiceRestoration {
    public let accesses:[FinderServicePersistentAccess]
    public let failures:[UUID:String]
}
