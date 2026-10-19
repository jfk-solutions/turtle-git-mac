// Private permission handoff for a future independent Finder cache service.
// GPL-2.0-or-later. Follows Apple's interprocess URL bookmark contract.
import Foundation
import Darwin
import Security

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
    public var additionalBookmarks:[Data]? = nil
    public init(id:UUID,bookmark:Data,repositoryComponents:[String],additionalBookmarks:[Data]? = nil) {
        self.id=id;self.bookmark=bookmark;self.repositoryComponents=repositoryComponents;self.additionalBookmarks=additionalBookmarks
    }
}
public struct FinderServiceAuthorization:Codable,Sendable {
    public let version:Int
    public let grants:[FinderServiceWatchGrant]
    public init(grants:[FinderServiceWatchGrant]) { version=grants.contains { !($0.additionalBookmarks ?? []).isEmpty } ? 2 : 1;self.grants=grants }
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
    fileprivate static func validBookmarks(_ values:[Data]?) -> Bool {
        (values?.count ?? 0)<=64 && (values ?? []).allSatisfy { !$0.isEmpty && $0.count<=1_048_576 }
    }
    public static func capture(_ values:[(UUID,URL,RepositoryAccessLease,[RepositoryAccessLease])],provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks()) throws -> Self {
        let primary=try capture(values.map { ($0.0,$0.1,$0.2) },provider:provider)
        return Self(grants:try zip(primary.grants,values).map { grant,value in
            guard value.3.count<=64 else { throw FinderServiceAuthorizationFailure.invalidRequest }
            return FinderServiceWatchGrant(id:grant.id,bookmark:grant.bookmark,repositoryComponents:grant.repositoryComponents,
                additionalBookmarks:try value.3.map { try provider.createTransfer(for:$0.url) })
        })
    }
    fileprivate static func valid(_ components:[String]) -> Bool {
        components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) }
    }
    public func acquire(provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks(),requireSecurityScope:Bool = true) throws -> [FinderServiceAccess] {
        guard version==1 || version==2 else { throw FinderServiceAuthorizationFailure.unsupportedVersion }
        guard grants.count<=1024,Set(grants.map(\.id)).count==grants.count,grants.allSatisfy({ !$0.bookmark.isEmpty && $0.bookmark.count<=1_048_576 && Self.valid($0.repositoryComponents) && Self.validBookmarks($0.additionalBookmarks) }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        var accesses:[FinderServiceAccess]=[]
        for grant in grants {
            let resolved=try provider.resolveTransfer(grant.bookmark)
            let lease=FinderServiceScope(url:resolved.url,provider:provider)
            if requireSecurityScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
            let root=grant.repositoryComponents.reduce(resolved.url) { $0.appendingPathComponent($1,isDirectory:true) }.standardizedFileURL
            guard lease.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
            let additional=try (grant.additionalBookmarks ?? []).map { data -> FinderServiceScope in
                let resolved=try provider.resolveTransfer(data),scope=FinderServiceScope(url:resolved.url,provider:provider)
                guard !requireSecurityScope || scope.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable };return scope
            }
            accesses.append(FinderServiceAccess(id:grant.id,root:root,scope:lease,bookmarkWasStale:resolved.stale,additionalScopes:additional))
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
    public var additionalScopes:[FinderServiceScope] = []
    /// Receiver creates its own persistent scope, rather than saving the IPC bookmark.
    public func persistentGrant(provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider()) throws -> FinderServicePersistentGrant {
        let scopePath=scope.url.standardizedFileURL.resolvingSymlinksInPath().path,rootPath=root.standardizedFileURL.resolvingSymlinksInPath().path
        guard scope.contains(root) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let suffix=rootPath==scopePath ? "" : String(rootPath.dropFirst(scopePath=="/" ? 1 : scopePath.count+1))
        let components=suffix.isEmpty ? [] : suffix.components(separatedBy:"/")
        let additional = try additionalScopes.map { try provider.create(for:$0.url) }
        return FinderServicePersistentGrant(id:id,bookmark:try provider.create(for:scope.url),repositoryComponents:components,additionalBookmarks:additional.isEmpty ? nil : additional)
    }
}

/// Stored only in the receiver's private container; scopes are minted by that receiver.
public struct FinderServicePersistentGrant:Codable,Sendable,Equatable {
    public let id:UUID
    public let bookmark:Data
    public let repositoryComponents:[String]
    public var additionalBookmarks:[Data]? = nil
    public func acquireAdditional(provider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),requireSecurityScope:Bool = true) throws -> [RepositoryAccessLease] {
        guard FinderServiceAuthorization.validBookmarks(additionalBookmarks) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return try (additionalBookmarks ?? []).map { data in
            let resolved=try provider.resolve(data),lease=RepositoryAccessLease(url:resolved.url,provider:provider)
            guard !requireSecurityScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable };return lease
        }
    }
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
            guard archive.version==1 || archive.version==2 else { throw FinderServiceAuthorizationFailure.unsupportedVersion }
            guard Self.valid(archive.grants) else { throw FinderServiceAuthorizationFailure.invalidRequest };grants=archive.grants
        } else { grants=[] }
    }
    private static func valid(_ values:[FinderServicePersistentGrant]) -> Bool {
        values.count<=1024 && Set(values.map(\.id)).count==values.count && values.allSatisfy { !$0.bookmark.isEmpty && $0.bookmark.count<=1_048_576 && FinderServiceAuthorization.valid($0.repositoryComponents) && FinderServiceAuthorization.validBookmarks($0.additionalBookmarks) }
    }
    private func save(_ values:[FinderServicePersistentGrant]) throws {
        guard Self.valid(values) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let bytes=try JSONEncoder().encode(Archive(version:values.contains { !($0.additionalBookmarks ?? []).isEmpty } ? 2 : 1,grants:values))
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
            return FinderServicePersistentAccess(id:value.id,root:root,lease:lease,additionalLeases:try value.acquireAdditional(provider:provider,requireSecurityScope:requireSecurityScope))
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
                let additional=try value.acquireAdditional(provider:provider,requireSecurityScope:requireSecurityScope)
                // Refresh receiver-private bookmarks while all scopes are live.
                let bookmarks=try additional.map { try provider.create(for:$0.url) }
                renewed[index]=FinderServicePersistentGrant(id:value.id,bookmark:resolved.stale ? try provider.create(for:resolved.url) : value.bookmark,repositoryComponents:value.repositoryComponents,additionalBookmarks:bookmarks.isEmpty ? value.additionalBookmarks : bookmarks)
                accesses.append(FinderServicePersistentAccess(id:value.id,root:root,lease:lease,additionalLeases:additional))
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
    public var additionalLeases:[RepositoryAccessLease] = []
    public var authorizedRoots:[URL] { [lease.url]+additionalLeases.map(\.url) }
    public func contains(_ url:URL) -> Bool { authorizedRoots.contains { RepositoryAccessLease.pathIsContained(url,by:$0) } }
}
public struct FinderServiceRestoration {
    public let accesses:[FinderServicePersistentAccess]
    public let failures:[UUID:String]
}

public enum FinderCacheServiceFailure:LocalizedError {
    case transitioning, outsidePermission
    public var errorDescription:String? {
        switch self {
        case .transitioning:return "The cache service is changing registrations."
        case .outsidePermission:return "Repository administration requires an additional folder permission."
        }
    }
}

/// Independent-process coordinator. Its caller supplies private grants and a shared
/// status store; it does not register a login item or authenticate IPC itself.
/// Private diagnostics contain no bookmarks or transferable authority.
public struct FinderCacheServiceReport: Codable, Sendable {
    public struct Root: Codable, Sendable {
        public let id: UUID
        public let refreshing: Bool
        public let lastPublication: Date?
        public let failure: String?
        public init(id: UUID, refreshing: Bool = false, lastPublication: Date? = nil, failure: String? = nil) {
            self.id = id; self.refreshing = refreshing; self.lastPublication = lastPublication; self.failure = failure
        }
    }
    public let version: Int
    public let running: Bool
    public let roots: [Root]
    public let cleanupFailures: [String: String]
    public let legacy: Bool
    /// Optional additions retain compatibility with version-one diagnostic replies.
    public let cacheSave: Bool?
    public let cacheFailure: String?
    public init(running: Bool, roots: [Root], cleanupFailures: [String: String] = [:], legacy: Bool = false,
                cacheSave: Bool? = nil, cacheFailure: String? = nil) {
        version = 1; self.running = running; self.roots = roots; self.cleanupFailures = cleanupFailures; self.legacy = legacy
        self.cacheSave = cacheSave; self.cacheFailure = cacheFailure
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_777_216 else { throw FinderServiceAuthorizationFailure.invalidRequest }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] == nil {
            let failures = try JSONDecoder().decode([String: String].self, from: data)
            guard failures.count <= 10_000, failures.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
            return Self(running: true, roots: failures.map { Root(id: UUID(uuidString: $0.key)!, failure: $0.value) }, legacy: true)
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1 else { throw FinderServiceAuthorizationFailure.unsupportedVersion }
        guard result.roots.count <= 10_000, Set(result.roots.map(\.id)).count == result.roots.count,
              result.cleanupFailures.count <= 10_000, result.cleanupFailures.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return result
    }
}

@MainActor public final class FinderCacheServiceRuntime {
    @MainActor private final class Session {
        let access:FinderServicePersistentAccess
        let repository:GitRepository
        var monitor:RepositoryFileEventMonitor?
        var directories:[URL]=[]
        var refresh:RepositoryEventRefresh?
        var token:OperationCancellation?
        var task:Task<Void,Never>?
        private var drainWaiters:[CheckedContinuation<Void,Never>]=[]
        var active=true
        var watchFailure:String?
        var lastPublication:Date?
        var cachedDirectories:GitPathSet=[]
        init(_ access:FinderServicePersistentAccess,repository:GitRepository) { self.access=access;self.repository=repository }
        func retire() { active=false;monitor?.stop();monitor=nil;refresh?.retire();refresh=nil;token?.cancel();task?.cancel() }
        /// The scheduler wrapper owns the access as well as its collector task.
        /// Join that wrapper's completion before releasing the process lease.
        func drain() async {
            guard token != nil else { return }
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        func finishedReading() {
            task=nil;token=nil
            let waiters=drainWaiters;drainWaiters=[]
            for waiter in waiters { waiter.resume() }
        }
        deinit { monitor?.stop();token?.cancel();task?.cancel() }
    }
    private var activity=FinderCacheActivityLog()
    public var activitySnapshot: FinderCacheActivitySnapshot {
        FinderCacheActivitySnapshot(running:running,
            cachedDirectories:GitPathSet(sessions.values.flatMap { $0.cachedDirectories }).count,
            watchedPaths:GitPathSet(sessions.values.flatMap { $0.directories.map(\.path) }).count,
            lines:activity.lines)
    }
    private func recordActivity(_ message:String) {activity.append(message);changed()}
    public var report: FinderCacheServiceReport {
        FinderCacheServiceReport(running: running, roots: permissions.grants.map { grant in
            let session = sessions[grant.id]
            return .init(id: grant.id, refreshing: session?.token != nil, lastPublication: session?.lastPublication, failure: rootFailures[grant.id])
        }.sorted { $0.id.uuidString < $1.id.uuidString }, cleanupFailures: Dictionary(uniqueKeysWithValues: cleanupFailures.map { ($0.key.uuidString, $0.value) }),
            cacheSave: appliedCacheSave, cacheFailure: cacheFailure)
    }
    private var publicationSession: FinderPublicationSession?
    private var retiredPublicationSessions: [FinderPublicationSession] = []
    private var appliedCacheSave: Bool?
    private var policyFailure: String?
    private var warmFailure: String?
    private var lifecycleFailure: String?
    private var restorationFailure: String?
    private var cacheFailure: String? {
        let values = [policyFailure, warmFailure, lifecycleFailure, restorationFailure].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }
    public private(set) var running=false
    private var rootFailures:[UUID:String]=[:]
    private var cleanupFailures:[UUID:String]=[:]
    public var failures:[UUID:String] { rootFailures.merging(cleanupFailures) { $0+"\n"+$1 } }
    private let permissions:FinderServicePermissionStore
    private let cache:FinderSnapshotStore
    private let factory:(URL)->GitRepository
    private let notify:()->Void
    private let changed:()->Void
    private var sessions:[UUID:Session]=[:]
    private var transitioning=false
    private var retiring:[Session]=[]
    private var pendingRemovals:GitPathMap<UUID>=[:]
    private var generation=0
    private var shutdownTask:Task<Void,Never>?
    private var requireSecurityScope=true
    // A collector dependency permits deterministic ownership/cancellation checks
    // while production retains its authorized Git collection and watcher setup.
    var collectionOverride:((GitRepository,FinderServicePersistentAccess,OperationCancellation) async throws -> FinderRepositoryCollection)?
    public init(permissions:FinderServicePermissionStore,cache:FinderSnapshotStore,
                repository:@escaping (URL)->GitRepository = { GitRepository(root:$0) },
                notify:@escaping ()->Void = {},changed:@escaping ()->Void = {}) {
        self.permissions=permissions;self.cache=cache;factory=repository;self.notify=notify;self.changed=changed
    }
    public func start(requireSecurityScope:Bool = true) throws {
        guard !running,!transitioning,shutdownTask==nil else { throw FinderCacheServiceFailure.transitioning }
        let restored=try permissions.restore(requireSecurityScope:requireSecurityScope)
        reloadCachePolicy();retryRetiredPublications()
        do {
            let session = try cache.startSession()
            publicationSession = session; warmFailure = session.persistenceFailure
        }
        catch { lifecycleFailure = error.localizedDescription; changed(); throw error }
        running=true;generation += 1;rootFailures=restored.failures;restorationFailure=nil
        self.requireSecurityScope = requireSecurityScope
        recordActivity("Status cache started")
        attach(restored.accesses);changed()
    }
    /// Durable installation is atomic. Cache cleanup is a separate operation:
    /// failures are reported and retained for retry, never hidden as success.
    public func replace(_ request:FinderServiceAuthorization,
                        transfer:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks(),
                        requireSecurityScope:Bool = true) async throws {
        guard running,!transitioning,shutdownTask==nil else { throw FinderCacheServiceFailure.transitioning }
        let accesses=try permissions.install(request,transfer:transfer,requireSecurityScope:requireSecurityScope)
        self.requireSecurityScope = requireSecurityScope
        transitioning=true;generation += 1;let identity=generation
        let old=Array(sessions.values);sessions.removeAll();retiring=old
        for session in old { session.retire() }
        for session in old { await session.drain() }
        // Shutdown may have happened while Git readers were settling.
        guard running,generation==identity else { return }
        rootFailures=[:]
        let retained=GitPathSet(accesses.map { FileTransferPaths.lexicalPath($0.root.path) })
        for session in old where !retained.contains(FileTransferPaths.lexicalPath(session.access.root.path)) {
            pendingRemovals[FileTransferPaths.lexicalPath(session.access.root.path)]=session.access.id
        }
        retiring=[];transitioning=false;attach(accesses);cleanup();changed()
    }
    /// Reconcile the published preference without retiring readers or their tickets.
    /// A failed warm-cache write/delete is retained for an explicit or later retry.
    public func reloadCachePolicy() {
        do {
            let preference = try cache.persistence()
            appliedCacheSave = preference.cacheSave
            try cache.setPersistence(preference)
            policyFailure = nil; warmFailure = nil
        } catch { policyFailure = error.localizedDescription }
        changed()
    }
    public func refresh(_ id:UUID? = nil) {
        guard running,!transitioning else { return }
        reloadCachePolicy();retryRetiredPublications();cleanup()
        // Permission failures on launch are retriable without replacing the
        // receiver's durable grant registry or interrupting healthy roots.
        do {
            let restored=try permissions.restore(requireSecurityScope:requireSecurityScope)
            restorationFailure=nil
            let missing=restored.accesses.filter { sessions[$0.id]==nil && (id==nil || id==$0.id) }
            for (key,failure) in restored.failures where sessions[key]==nil { rootFailures[key]=failure }
            for access in missing { rootFailures.removeValue(forKey:access.id) }
            attach(missing)
        } catch { restorationFailure=error.localizedDescription;changed() }
        for (key,session) in sessions where id==nil || id==key { session.refresh?.invalidate() }
    }
    private func retryRetiredPublications() {
        var failures:[String]=[],retained:[FinderPublicationSession]=[]
        for session in retiredPublicationSessions {
            do {
                let snapshot = try cache.endSession(session)
                warmFailure = snapshot.persistenceFailure; notify()
            }
            catch { retained.append(session);failures.append(error.localizedDescription) }
        }
        retiredPublicationSessions=retained
        lifecycleFailure=failures.isEmpty ? nil : failures.joined(separator:"\n")
    }
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value;return }
        recordActivity("Stopping status cache…")
        running=false;generation += 1;transitioning=true
        let identity=generation,old=Array(sessions.values)+retiring
        sessions.removeAll();retiring=old
        // Capture and detach the ending lease before suspension. A second caller
        // joins this exact barrier; it cannot retire a later process generation.
        let endingPublication=publicationSession;publicationSession=nil
        for session in old { session.retire() }
        let operation=Task { [self] in
            for session in old { await session.drain() }
            if let endingPublication { retiredPublicationSessions.append(endingPublication) }
            retryRetiredPublications()
            guard generation==identity else { return }
            retiring=[];transitioning=false;changed()
        }
        shutdownTask=operation
        await operation.value
        if generation==identity { shutdownTask=nil }
    }
    private func attach(_ accesses:[FinderServicePersistentAccess]) {
        for access in accesses {
            let session=Session(access,repository:factory(access.root));sessions[access.id]=session
            session.refresh=RepositoryEventRefresh(available:{ [weak self,weak session] in
                self?.running==true && session?.active==true
            },refresh:{ [weak self,weak session] in
                guard let self,let session,session.active else { return }
                let token=OperationCancellation();session.token=token; self.changed()
                session.task=Task { [weak self] in
                    guard let self else { return };await self.collect(session,token:token)
                }
                await session.task?.value;session.finishedReading();self.changed()
            })
            session.refresh?.invalidate()
        }
    }
    private func collect(_ session:Session,token:OperationCancellation) async {
        recordActivity("Crawling folder: " + session.access.root.path)
        do {
            reloadCachePolicy()
            guard let publicationSession else { throw FinderCacheServiceFailure.transitioning }
            let ticket=try cache.begin(root:session.access.root,session:publicationSession,cancellation:token)
            if let warning=ticket.persistenceFailure { warmFailure=warning;changed() }
            let collection:FinderRepositoryCollection
            if let collectionOverride {
                collection=try await collectionOverride(session.repository,session.access,token)
            } else {
                collection=try await session.repository.collectFinderRepository(authorizedRoot:session.access.lease.url,additionalAuthorizedRoots:session.access.additionalLeases.map(\.url),cancellation:token,watchReady:{ [weak self,weak session] paths in
                    await self?.watch(session,paths:paths)
                })
            }
            try token.check()
            guard running,session.active,sessions[session.access.id]===session else { return }
            // An unauthorized shared Git directory must not be silently monitored.
            guard collection.watchDirectories.allSatisfy({ session.access.contains($0) }) else { throw FinderCacheServiceFailure.outsidePermission }
            if let failure=session.watchFailure { throw NSError(domain:"TurtleGit.FinderWatcher",code:1,userInfo:[NSLocalizedDescriptionKey:failure]) }
            let publication=try cache.publish(ticket,snapshots:collection.snapshots,cancellation:token)
            if publication.published {
                warmFailure = publication.persistenceFailure
                session.lastPublication = Date()
                var directories=GitPathSet(collection.snapshots.flatMap(\.roots))
                for snapshot in collection.snapshots {
                    for path in snapshot.states.keys {
                        var parent=FileTransferPaths.fileURL(FinderSnapshot.parentPath(path))
                        while snapshot.roots.contains(where: { FinderSnapshot.contains(parent.path,root:$0) }) {
                            directories.insert(parent.path);let next=FileTransferPaths.fileURL(FinderSnapshot.parentPath(parent.path));if GitReferenceName.equal(next.path,parent.path) {break};parent=next
                        }
                    }
                }
                session.cachedDirectories=directories
                recordActivity("Updated path: " + session.access.root.path)
                rootFailures.removeValue(forKey:session.access.id)
                if !collection.failures.isEmpty { rootFailures[session.access.id]=collection.failures.values.sorted().joined(separator:"\n") }
                notify();changed()
            } else { session.refresh?.invalidate() }
        } catch {
            guard running,session.active,!token.isCancelled else { return }
            rootFailures[session.access.id]=error.localizedDescription;recordActivity("Error: " + session.access.root.path + " — " + error.localizedDescription)
        }
    }
    private func watch(_ session:Session?,paths:[URL]) {
        guard let session,running,session.active else { return }
        guard paths.allSatisfy({ session.access.contains($0) }),paths != session.directories else { return }
        do {
            let monitor=try RepositoryFileEventMonitor(roots:paths,onEvents:{ [weak self,weak session] _ in
                Task { @MainActor in
                    guard let self,let session,self.running,session.active,self.sessions[session.access.id]===session else { return }
                    session.refresh?.invalidate()
                }
            })
            session.monitor?.stop();session.monitor=monitor;session.directories=paths;session.watchFailure=nil
        } catch { session.watchFailure=error.localizedDescription;rootFailures[session.access.id]=error.localizedDescription;changed() }
    }
    private func cleanup() {
        let active=GitPathSet(sessions.values.map { FileTransferPaths.lexicalPath($0.access.root.path) })
        cleanupFailures=[:]
        for (root,id) in pendingRemovals {
            if active.contains(root) { pendingRemovals.removeValue(forKey:root);continue }
            do {
                guard let publicationSession else { throw FinderCacheServiceFailure.transitioning }
                let snapshot = try cache.remove(root:FileTransferPaths.fileURL(root),session:publicationSession)
                warmFailure = snapshot.persistenceFailure
                pendingRemovals.removeValue(forKey:root);notify()
            }
            catch { cleanupFailures[id]=error.localizedDescription }
        }
    }
}

// Private, authenticated service messages. Standard XPC NSData/NSString payloads
// avoid sharing Codable implementation objects across the process boundary.
@objc public protocol FinderCacheServiceProtocol {
    func replaceGrants(_ request:Data,withReply reply:@escaping (String?)->Void)
    func refresh(withReply reply:@escaping (String?)->Void)
    func status(withReply reply:@escaping (Data?,String?)->Void)
}
public enum FinderCacheServiceIdentity {
    public static let bundleIdentifier="org.turtlegit.macos.cache"
    public static let appIdentifier="org.turtlegit.macos"
    public static let machService=FinderIntegration.group+".cache"
    public static let agentPlist="org.turtlegit.macos.cache.plist"
    public static func currentTeam() throws -> String {
        var code:SecCode?,staticCode:SecStaticCode?,information:CFDictionary?
        guard SecCodeCopySelf([], &code)==errSecSuccess,let code,
              SecCodeCopyStaticCode(code,[],&staticCode)==errSecSuccess,let staticCode,
              SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue:kSecCSSigningInformation),&information)==errSecSuccess,
              let values=information as? [String:Any],let team=values[kSecCodeInfoTeamIdentifier as String] as? String else { throw RepositoryAccessFailure.securityScopeUnavailable }
        _ = try requirement(identifier:bundleIdentifier,team:team);return team
    }
    public static func requirement(identifier:String,team:String) throws -> String {
        guard [bundleIdentifier,appIdentifier].contains(identifier),team.count==10,team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw FinderServiceAuthorizationFailure.invalidRequest }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}
