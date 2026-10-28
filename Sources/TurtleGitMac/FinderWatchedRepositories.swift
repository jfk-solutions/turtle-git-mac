// Native watched-root management for Finder's explicit directory registration.
// GPL-2.0-or-later; adapts TGitCache watcher/crawler ownership to macOS.
import AppKit
import ServiceManagement
import SwiftUI
import TurtleGitCore

private enum FinderWatchFailure:LocalizedError {
    case duplicate, unavailable, initialPublication(String)
    var errorDescription:String? {
        switch self {
        case .initialPublication(let detail):return "The repository was saved, but Finder status could not be published.\n"+detail
        case .duplicate:return "This repository is already watched."
        case .unavailable:return "Finder repository watches are unavailable. Open Icon Overlays settings and retry."
        }
    }
}

struct FinderWatchRow:Identifiable {
    let id:UUID
    let name:String
    let path:String
    let status:String
}
@MainActor final class FinderWatchManager:ObservableObject {
    enum Startup:Equatable { case deferred, allSavedRepositories }
    @Published private(set) var rows:[FinderWatchRow]=[]
    @Published private(set) var busy=false { didSet { if !busy { restoreRequestedRepositories();drainTargetRefreshes();sessions.values.forEach { $0.scheduler?.kick() };backgroundService?.requestSync(self) } } }
    @Published private(set) var pendingOperations=0 { didSet { if pendingOperations==0 { backgroundService?.requestSync(self) } } }
    @Published var error:String?
    private(set) var serviceRevision=0
    var backgroundService:FinderBackgroundService?
    private(set) var active=true
    private let permissions:RepositoryAccessStore
    private let cache:FinderSnapshotStore?
    private var cacheSession:FinderPublicationSession?
    private var cacheSessionStartup:Task<FinderPublicationSession,Error>?
    private var cacheSessionStartupID: UUID?
    private var publicationRetirement:Task<Void,Never>?
    private var restoration: Task<Void, Never>?
    private var restorationCancellation: OperationCancellation?
    var hasPendingFinderPublication:Bool { cacheSession != nil || pendingOperations>0 }
    private func publicationSession(_ cache:FinderSnapshotStore,cancellation:OperationCancellation) async throws -> FinderPublicationSession {
        guard active else { throw OperationCancellationFailure.cancelled }
        if let cacheSession { return cacheSession }
        let task: Task<FinderPublicationSession, Error>
        let identity: UUID
        if let pending = cacheSessionStartup, let pendingID = cacheSessionStartupID { task = pending; identity = pendingID }
        else {
            identity = UUID()
            task = Task.detached(priority: .utility) { try cache.startSession(cancellation: cancellation) }
            cacheSessionStartup = task; cacheSessionStartupID = identity
        }
        do {
            let session = try await task.value
            // Retain a newly acquired session even if retirement happened during
            // the wait: shutdown owns ending it after all readers drain.
            cacheSession = session; if cacheSessionStartupID == identity { cacheSessionStartup = nil; cacheSessionStartupID = nil }
            try cancellation.check()
            guard active else { throw OperationCancellationFailure.cancelled }
            return session
        } catch { if cacheSessionStartupID == identity { cacheSessionStartup = nil; cacheSessionStartupID = nil }; throw error }
    }
    private func removePublication(_ root:URL,cache:FinderSnapshotStore,cancellation:OperationCancellation) async throws {
        let session=try await publicationSession(cache,cancellation:cancellation)
        let updated=try await Task.detached { try cache.remove(root:root,session:session,cancellation:cancellation) }.value
        if let failure=updated.persistenceFailure { error="Finder live status updated, but saved cache could not be updated: "+failure }
    }
    private let requireScope:Bool
    private let scopeProvider:any RepositoryBookmarkProvider
    private let repositoryFactory:(URL) throws -> GitRepository
    private let notify:()->Void
    private let statusPolicyProvider:(() throws -> FinderStatusPolicy)?
    private var statusPolicyObservers:[NSObjectProtocol]=[]
    private var sessions:[UUID:Session]=[:]
    private var statuses:[UUID:String]=[:]
    private var mutation:OperationCancellation?
    private var pendingTargetRefreshes:GitPathMap<URL> = [:]
    private(set) var startup:Startup = .deferred
    @MainActor private final class Session {
        let id:UUID
        let lease:RepositoryAccessLease
        var additionalLeases:[RepositoryAccessLease]=[]
        var repository:GitRepository
        var active=true
        var permissionReady=false
        var collectionStarted=false
        var request:OperationCancellation?
        var monitor:RepositoryFileEventMonitor?
        var scheduler:RepositoryEventRefresh?
        var watched:[URL]=[]
        init(id:UUID,lease:RepositoryAccessLease,repository:GitRepository) { self.id=id;self.lease=lease;self.repository=repository }
        func retire() { active=false;request?.cancel();monitor?.stop();monitor=nil;scheduler?.retire();scheduler=nil }
    }
    init(permissions:RepositoryAccessStore,cache:FinderSnapshotStore?,requireScope:Bool = GitRuntime.isAppStoreBuild,scopeProvider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),
         repositoryFactory:@escaping (URL) throws -> GitRepository = { GitRepository(root:$0,executable:try GitRuntime.executable()) },
         statusPolicyProvider:(() throws -> FinderStatusPolicy)? = nil,
         notify:@escaping ()->Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) }) {
        self.permissions=permissions;self.cache=cache;self.requireScope=requireScope;self.scopeProvider=scopeProvider;self.repositoryFactory=repositoryFactory;self.notify=notify;self.statusPolicyProvider=statusPolicyProvider;render()
        if statusPolicyProvider != nil {
            for (name,operation) in [(FinderStatusPolicyPreferences.notification,false),(FinderStatusOperationLease.notification,true)] {
                statusPolicyObservers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) { [weak self] _ in
                    Task { @MainActor in self?.reloadStatusPolicy(operation:operation) }
                })
            }
        }
    }
    deinit {for observer in statusPolicyObservers {DistributedNotificationCenter.default().removeObserver(observer)}}
    static func production(startup:Startup = .deferred) throws -> FinderWatchManager {
        let url=RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("watched-repositories.json")
        let manager=try FinderWatchManager(permissions:RepositoryAccessStore(storageURL:url),cache:FinderIntegration.snapshotURL.map { FinderSnapshotStore(url:$0) },statusPolicyProvider:{try FinderStatusPolicy.read()})
        manager.backgroundService=FinderBackgroundService()
        if startup == .allSavedRepositories {manager.restore()}
        return manager
    }
    private func render() {
        rows=permissions.repositories.map { FinderWatchRow(id:$0.id,name:$0.name,path:$0.lastKnownPath,status:statuses[$0.id] ?? "Waiting") }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    /// Workspace/Settings startup owns the complete local watcher set. Action
    /// routers instead retain the saved authority without crawling every root.
    func restore() {guard active else{return};startup = .allSavedRepositories;restoreRequestedRepositories()}
    private func restoreRequestedRepositories() {
        guard active, !busy, startup == .allSavedRepositories, restoration == nil else { return }
        let requests = permissions.repositories.compactMap { value -> RepositoryAuthorityRequest? in
            if let session = sessions[value.id] {
                if !session.collectionStarted { session.scheduler?.invalidate() }
                return nil
            }
            return try? permissions.captureAuthority(value.id)
        }
        guard !requests.isEmpty else { return }
        let cancellation = OperationCancellation(), requireScope = self.requireScope
        restorationCancellation = cancellation
        pendingOperations += 1
        restoration = Task { [self] in
            defer {
                restoration = nil; restorationCancellation = nil
                pendingOperations -= 1
            }
            // Resolve sequentially on a worker: a disconnected volume can be
            // slow, but cannot delay the window or another foreground action.
            for request in requests {
                guard active, !cancellation.isCancelled else { return }
                do {
                    let authority = try await Task.detached(priority: .utility) {
                        try request.resolve(requireSecurityScope: requireScope, cancellation: cancellation)
                    }.value
                    guard active, !cancellation.isCancelled else { return }
                    // Add/Renew/Remove may have replaced this immutable request
                    // while the worker was resolving it. Never revive that grant.
                    guard permissions.repositories.first(where: { $0.id == request.record.id }) == request.record,
                          sessions[request.record.id] == nil else { continue }
                    guard try permissions.adoptAuthority(authority, from: request) else { continue }
                    installAuthority(request.record.id, lease: authority.primary, additional: authority.additional)
                } catch {
                    guard active, !cancellation.isCancelled else { return }
                    if permissions.repositories.first(where: { $0.id == request.record.id }) == request.record,
                       sessions[request.record.id] == nil {
                        statuses[request.record.id] = "Permission or repository unavailable: " + error.localizedDescription
                        render()
                    }
                }
            }
        }
    }
    /// A completed action wakes only its already-authorized watched repository.
    /// An arbitrary Finder path never creates a new grant through this route.
    func refresh(repository root:URL) {
        guard active else{return}
        let path=root.standardizedFileURL.path
        guard !busy else {pendingTargetRefreshes[path]=root;return}
        if let session=sessions.values.first(where:{$0.active && GitReferenceName.equal($0.repository.root.standardizedFileURL.path,path)}) {
            session.scheduler?.invalidate();return
        }
        let saved=permissions.repositories
        var checked=Set<UUID>()
        func attachIfMatching(_ id:UUID)->Bool {
            _=checked.insert(id)
            // Resolve retained authority without updating recency/bookmarks or
            // normalizing unrelated stored path strings through the filesystem.
            // A moved bookmark must match before its Git reader is attached.
            guard let lease=try? permissions.acquire(id,requireSecurityScope:requireScope,updatingRecord:false,recordingOpen:false),
                  GitReferenceName.equal(lease.url.standardizedFileURL.path,path) else {return false}
            attach(id,acceptedLease:lease);return true
        }
        for value in saved where GitReferenceName.equal(value.lastKnownPath,path) {if attachIfMatching(value.id) {return}}
        for value in saved where !checked.contains(value.id) {if attachIfMatching(value.id) {return}}
    }
    private func drainTargetRefreshes() {
        guard active,!busy else{return}
        let pending=pendingTargetRefreshes.values;pendingTargetRefreshes.removeAll()
        for root in pending {refresh(repository:root)}
    }
    private func attach(_ id:UUID,scheduleInitial:Bool = true,acceptedLease:RepositoryAccessLease? = nil) {
        guard active else { return };sessions.removeValue(forKey:id)?.retire()
        do {
            let lease = try acceptedLease ?? permissions.acquire(id, requireSecurityScope: requireScope, updatingRecord: false)
            let additional = try permissions.acquireAdditionalPermissions(id, requireSecurityScope: requireScope)
            installAuthority(id, lease: lease, additional: additional, scheduleInitial: scheduleInitial)
        } catch { statuses[id]="Permission or repository unavailable: "+error.localizedDescription;render() }
    }
    private func installAuthority(_ id: UUID, lease: RepositoryAccessLease, additional: [RepositoryAccessLease], scheduleInitial: Bool = true) {
        guard active else { return }
        do {
            let session = Session(id: id, lease: lease, repository: try repositoryFactory(lease.url))
            session.additionalLeases = additional
            sessions[id] = session
            session.scheduler = RepositoryEventRefresh(available: { [weak self, weak session] in
                guard let self, let session else { return false }
                return self.active && !self.busy && session.active && session.request == nil
            }, refresh: { [weak self, weak session] in if let self, let session { try? await self.collect(session) } })
            statuses[id] = "Waiting"; render()
            if scheduleInitial { session.scheduler?.invalidate() }
        } catch { statuses[id] = "Permission or repository unavailable: " + error.localizedDescription; render() }
    }
    private func install(_ session:Session,_ directories:[URL]) {
        guard active,session.active,sessions[session.id] === session,session.watched != directories else { return }
        session.monitor?.stop();session.monitor=nil
        let allowed=directories.filter { directory in !requireScope || ([session.lease]+session.additionalLeases).contains { $0.contains(directory) } }
        do {
            session.monitor=try RepositoryFileEventMonitor(roots:allowed) { [weak self,weak session] events in
                guard !events.isEmpty else { return }
                Task { @MainActor in guard let self,let session,self.active,session.active,self.sessions[session.id] === session else { return };session.scheduler?.invalidate() }
            };session.watched=directories
        } catch { statuses[session.id]="Monitoring unavailable: "+error.localizedDescription;render() }
    }
    private func prepareRepositoryAuthority(_ session:Session,cancellation token:OperationCancellation) async throws -> URL {
        let root=try await session.repository.discoverRoot(cancellation:token)
        guard active,session.active,sessions[session.id] === session,!token.isCancelled else {throw OperationCancellationFailure.cancelled}
        guard session.lease.contains(root) else {throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path)}
        session.repository=try repositoryFactory(root)
        if !session.permissionReady {
            if let old=permissions.repositories.first(where:{$0.id==session.id}),old.lastKnownPath != root.path,let cache {
                try await removePublication(URL(fileURLWithPath:old.lastKnownPath,isDirectory:true),cache:cache,cancellation:token)
                guard active,session.active,sessions[session.id] === session,!token.isCancelled else {throw OperationCancellationFailure.cancelled}
                notify()
            }
            guard active,session.active,sessions[session.id] === session,!token.isCancelled else {throw OperationCancellationFailure.cancelled}
            _=try permissions.replace(session.id,with:session.lease.url)
            session.permissionReady=true;serviceRevision += 1;render()
        }
        return root
    }
    /// A helper grant message replaces its entire authority set. Add/Clone must
    /// therefore validate every saved grant before sending it, without running
    /// unrelated status/submodule collections in an action-only application.
    private func prepareBackgroundAuthorization(requiredRepository:UUID,cancellation:OperationCancellation) async throws {
        guard backgroundService?.enabled == true else{return}
        var failures=[Error]()
        for value in permissions.repositories {
            try cancellation.check();guard active else {throw FinderWatchFailure.unavailable}
            do {
                if sessions[value.id]==nil {attach(value.id,scheduleInitial:false)}
                guard let session=sessions[value.id] else {throw FinderWatchFailure.initialPublication(statuses[value.id] ?? "Repository access is unavailable.")}
                while session.request != nil {
                    try cancellation.check();guard active,session.active,sessions[session.id] === session else {throw OperationCancellationFailure.cancelled}
                    try await Task.sleep(nanoseconds:10_000_000)
                }
                if !session.permissionReady {try await prepareServiceAuthority(session,cancellation:cancellation)}
            } catch {
                try cancellation.check()
                guard active else {throw OperationCancellationFailure.cancelled}
                if value.id==requiredRepository || error is OperationCancellationFailure || error is GitCommandCancellationFailure || error is CancellationError {throw error}
                // A disconnected unrelated watch prevents complete helper
                // transfer, not a valid target's local Add/Clone publication.
                // Keep the old helper grants and a visible, queued retry.
                failures.append(error)
            }
        }
        if !failures.isEmpty {backgroundService?.deferAuthorization(failures)}
    }
    private func prepareServiceAuthority(_ session:Session,cancellation:OperationCancellation) async throws {
        session.request=cancellation;pendingOperations += 1
        defer {session.request=nil;pendingOperations -= 1;withExtendedLifetime(session.lease) {}}
        _=try await prepareRepositoryAuthority(session,cancellation:cancellation)
    }
    var canSynchronizeBackground:Bool {
        active && !busy && pendingOperations==0 && rows.count==sessions.count && sessions.values.allSatisfy {$0.active && $0.permissionReady}
    }
    private func collect(_ session:Session,cancellation:OperationCancellation? = nil,requirePublication:Bool = false) async throws {
        guard active,session.active,sessions[session.id] === session,session.request==nil else { throw OperationCancellationFailure.cancelled }
        let token=cancellation ?? OperationCancellation();session.request=token;session.collectionStarted=true;pendingOperations += 1;statuses[session.id]="Refreshing…";render()
        defer { session.request=nil;pendingOperations -= 1;withExtendedLifetime(session.lease) {} }
        do {
            let policy=try statusPolicyProvider?()
            if let policy,policy.blockStatus,(policy.cacheMode == .shell || policy.cacheMode == .shellExtended),FinderStatusOperationLease.isBlocked() {
                statuses[session.id]="Waiting for Git command completion";render();if requirePublication {throw FinderWatchFailure.initialPublication("Waiting for Git command completion. Retry Add to TurtleGit when the command finishes.")};return
            }
            let root=try await prepareRepositoryAuthority(session,cancellation:token)
            let cache=self.cache
            var ticket:FinderPublicationTicket?
            if let cache {
                let session=try await publicationSession(cache,cancellation:token)
                ticket=try await Task.detached { try cache.begin(root:root,session:session,cancellation:token,policy:policy) }.value
            }
            let watchReady:@Sendable ([URL]) async -> Void = { [weak self,weak session] paths in if let self,let session { await self.install(session,paths) } }
            let result:FinderRepositoryCollection
            if let policy,policy.cacheMode != .standard {
                result=try await session.repository.collectFinderOverlayRepository(authorizedRoot:session.lease.url,additionalAuthorizedRoots:session.additionalLeases.map(\.url),policy:policy,cancellation:token,watchReady:watchReady)
            } else {
                result=try await session.repository.collectFinderRepository(authorizedRoot:session.lease.url,additionalAuthorizedRoots:session.additionalLeases.map(\.url),cancellation:token,watchReady:watchReady,policy:policy)
            }
            guard active,session.active,!token.isCancelled,sessions[session.id] === session else { throw OperationCancellationFailure.cancelled }
            if let cache,let ticket {
                let published=try await Task.detached { try cache.publish(ticket,snapshots:result.snapshots,cancellation:token) }.value
                guard active,session.active,!token.isCancelled else { throw OperationCancellationFailure.cancelled }
                if !published.published { statuses[session.id]="Refresh superseded";session.scheduler?.invalidate();if requirePublication {throw FinderWatchFailure.initialPublication("Refresh superseded. Retry Add to TurtleGit.")} }
                else {
                    statuses[session.id]=result.failures.isEmpty ? "Updated" : "Updated; \(result.failures.count) child repositories unavailable"
                    if let failure=published.persistenceFailure {
                        statuses[session.id,default:"Updated"] += published.warmCacheRebuilt ? "; "+failure : "; saved cache unavailable: "+failure
                    }
                    notify()
                    if requirePublication,!published.warmCacheRebuilt,let failure=published.persistenceFailure {throw FinderWatchFailure.initialPublication(failure)}
                    if requirePublication,!result.failures.isEmpty {
                        throw FinderWatchFailure.initialPublication(result.failures.values.sorted().joined(separator:"\n"))
                    }
                }
            } else { statuses[session.id]="Updated; Finder integration unavailable";if requirePublication {throw FinderWatchFailure.initialPublication("Finder integration is unavailable in this application.")} }
            render()
        } catch { if active,session.active,!token.isCancelled { statuses[session.id]=error.localizedDescription;render() };throw error }
    }
    func refresh(_ id:UUID) {
        guard active,!busy else { return };if let session=sessions[id] { session.scheduler?.invalidate() } else { attach(id) }
    }
    func reloadStatusPolicy(operation:Bool=false) {
        guard active else{return}
        if operation {
            guard let policy=try? statusPolicyProvider?(),policy.blockStatus,
                  policy.cacheMode == .shell || policy.cacheMode == .shellExtended else{return}
        }
        for session in sessions.values {session.request?.cancel();session.scheduler?.invalidate()}
        if !operation {backgroundService?.statusPolicyChanged(self)}
    }
    func add(_ url:URL,replacing id:UUID? = nil) async {
        guard active,!busy else { return };busy=true;pendingOperations += 1;error=nil
        let token=OperationCancellation();mutation=token
        defer { mutation=nil;pendingOperations -= 1;busy=false }
        do {
            let lease=RepositoryAccessLease(url:url,provider:scopeProvider)
            if requireScope && !lease.hasSecurityScope { throw RepositoryAccessFailure.securityScopeUnavailable }
            let root=try await repositoryFactory(url).discoverRoot(cancellation:token)
            guard lease.contains(root) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path) }
            guard active,!token.isCancelled else { return }
            let old=id.flatMap { target in permissions.repositories.first { $0.id==target } }
            if let id,permissions.repositories.contains(where:{ $0.id != id && $0.lastKnownPath==root.standardizedFileURL.resolvingSymlinksInPath().path }) { throw FinderWatchFailure.duplicate }
            if let old,old.lastKnownPath != root.path {
                sessions.removeValue(forKey:old.id)?.retire()
                if let cache {
                    let path=URL(fileURLWithPath:old.lastKnownPath,isDirectory:true)
                    try await removePublication(path,cache:cache,cancellation:token)
                    guard active,!token.isCancelled else { return };notify()
                }
            }
            let saved=try id.map { try permissions.replace($0,with:root) } ?? permissions.remember(root)
            serviceRevision += 1;sessions.removeValue(forKey:saved.id)?.retire()
            guard active,!token.isCancelled else { return };attach(saved.id);render()
            withExtendedLifetime(lease) {}
        } catch {
            if active,!token.isCancelled { self.error=error.localizedDescription;if let id,sessions[id]==nil { attach(id) };render() }
        }
    }
    /// Register a root using an already accepted live folder grant. Unlike the
    /// Settings Add action this must not silently discard a completed Clone
    /// while another watch mutation is draining.
    @discardableResult func register(root:URL,access:RepositoryAccessLease,additionalFolders:[URL] = [],cancellation:OperationCancellation,awaitInitialPublication:Bool = false) async throws -> UUID {
        while busy {
            try cancellation.check();guard active else {throw FinderWatchFailure.unavailable}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try cancellation.check();guard active else {throw FinderWatchFailure.unavailable}
        guard access.contains(root),!requireScope || access.hasSecurityScope else {throw RepositoryAccessFailure.securityScopeUnavailable}
        busy=true;pendingOperations += 1;error=nil;mutation=cancellation
        defer {if mutation === cancellation {mutation=nil};pendingOperations -= 1;busy=false;withExtendedLifetime(access) {}}
        let discovered=try await repositoryFactory(root).discoverRoot(cancellation:cancellation)
        try cancellation.check();guard active else {throw FinderWatchFailure.unavailable}
        guard GitReferenceName.equal(discovered.standardizedFileURL.resolvingSymlinksInPath().path,root.standardizedFileURL.resolvingSymlinksInPath().path) else {throw RepositoryAccessFailure.repositoryRootOutsidePermission(discovered.path)}
        // Persist the child bookmark while its accepted parent lease is alive;
        // this does not require another folder picker or enable the service.
        for folder in additionalFolders {
            guard access.permittedFolders(requireSecurityScope:requireScope).contains(where:{RepositoryAccessLease.pathIsContained(folder,by:$0)}) else {throw RepositoryAccessFailure.securityScopeUnavailable}
        }
        let saved=try permissions.remember(root)
        do {
            for folder in additionalFolders where !RepositoryAccessLease.pathIsContained(folder,by:root) {try permissions.addPermission(saved.id,url:folder)}
        } catch {
            serviceRevision += 1;sessions.removeValue(forKey:saved.id)?.retire();attach(saved.id);render()
            self.error=error.localizedDescription;throw error
        }
        serviceRevision += 1;sessions.removeValue(forKey:saved.id)?.retire();attach(saved.id,scheduleInitial:!awaitInitialPublication);render()
        // Finish any cancellable transfer preparation before the acknowledged
        // initial publication. Once that publication succeeds, registration's
        // paired recent-repository record must still complete on its caller.
        try await prepareBackgroundAuthorization(requiredRepository:saved.id,cancellation:cancellation)
        if awaitInitialPublication {
            guard let session=sessions[saved.id] else {throw FinderWatchFailure.initialPublication(statuses[saved.id] ?? "Repository access is unavailable.")}
            try await collect(session,cancellation:cancellation,requirePublication:true)
        }
        return saved.id
    }
    func remove(_ id:UUID) async {
        guard active,!busy,let saved=permissions.repositories.first(where:{ $0.id==id }) else { return }
        busy=true;pendingOperations += 1;error=nil;let token=OperationCancellation();mutation=token
        sessions.removeValue(forKey:id)?.retire()
        defer { mutation=nil;pendingOperations -= 1;busy=false }
        do {
            if let cache {
                let root=URL(fileURLWithPath:saved.lastKnownPath,isDirectory:true)
                try await removePublication(root,cache:cache,cancellation:token)
                guard active,!token.isCancelled else { return };notify()
            }
            try permissions.forget(id);serviceRevision += 1;statuses[id]=nil;render()
        } catch { if active,!token.isCancelled { self.error=error.localizedDescription;attach(id) } }
    }
    func additionalPermissions(_ id:UUID) -> [SavedFolderPermission] { permissions.repositories.first { $0.id==id }?.additionalPermissions ?? [] }
    func changePermission(_ id:UUID,url:URL? = nil,replacing replacement:UUID? = nil,removing permission:UUID? = nil) async {
        guard active,!busy,permissions.repositories.contains(where:{ $0.id==id }) else { return }
        busy=true;pendingOperations += 1;error=nil
        let old=sessions.removeValue(forKey:id);old?.retire()
        defer { pendingOperations -= 1;busy=false }
        // Retain every old lease until its cancelled Git reader has settled.
        while old?.request != nil { try? await Task.sleep(nanoseconds:10_000_000) }
        guard active else { return }
        do {
            if let url {
                let lease=RepositoryAccessLease(url:url,provider:scopeProvider)
                guard !requireScope || lease.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                try permissions.addPermission(id,url:url,replacing:replacement);withExtendedLifetime(lease) {}
            } else if let permission { try permissions.removePermission(id,permission:permission) }
            serviceRevision += 1;attach(id);render()
        } catch { self.error=error.localizedDescription;attach(id);render() }
    }
    func serviceLeases() -> [RepositoryAccessLease] { sessions.values.flatMap { [$0.lease]+$0.additionalLeases } }
    func serviceAuthorization(provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks()) throws -> FinderServiceAuthorization {
        guard canSynchronizeBackground else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let values=try sessions.values.map { session -> (UUID,URL,RepositoryAccessLease,[RepositoryAccessLease]) in
            guard session.active,session.permissionReady else { throw RepositoryAccessFailure.securityScopeUnavailable }
            return (session.id,session.repository.root,session.lease,session.additionalLeases)
        }.sorted { $0.0.uuidString<$1.0.uuidString }
        return try FinderServiceAuthorization.capture(values,provider:provider)
    }
    func retire() {
        guard active else { return }
        pendingTargetRefreshes.removeAll()
        active=false
        restorationCancellation?.cancel()
        for observer in statusPolicyObservers {DistributedNotificationCenter.default().removeObserver(observer)};statusPolicyObservers=[]
        backgroundService?.retire();mutation?.cancel();sessions.values.forEach { $0.retire() };sessions=[:]
        publicationRetirement=Task { [self] in
            while pendingOperations>0 { try? await Task.sleep(nanoseconds:10_000_000) }
            if let cache,let session=cacheSession {
                cacheSession=nil
                do {
                    let updated=try await Task.detached { try cache.endSession(session) }.value
                    if let failure=updated.persistenceFailure { error="Finder live status retired, but saved cache could not be updated: "+failure }
                    notify()
                } catch { self.error="Finder cache shutdown unavailable: "+error.localizedDescription }
            }
        }
    }
    func shutdown() async { retire();await publicationRetirement?.value;await backgroundService?.settle() }
}

/// The page owns its chooser/question; the application owns accepted watches.
@MainActor final class FinderWatchPageModel: ObservableObject {
    let manager: FinderWatchManager
    @Published private(set) var selected = Set<UUID>()
    @Published private(set) var selectedPermission: UUID?
    @Published private(set) var hasSheet = false
    @Published private var revision = UUID()
    private var active = false
    private var retired = false
    private weak var window: NSWindow?
    private var ownerObserver: NSObjectProtocol?
    private var sheet: NSWindow?
    private var sheetID: UUID?
    var chooseFolder: ((String, URL?, @escaping (URL?) -> Void) -> Void)?
    var ask: ((String, String, @escaping (Bool) -> Void) -> Void)?
    struct Context: Equatable {
        let owner: ObjectIdentifier
        let revision: UUID
        let roots: Set<UUID>
        let permission: UUID?
        let serviceRevision: Int
    }
    init(manager: FinderWatchManager) { self.manager = manager }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
    var context: Context { .init(owner: ObjectIdentifier(self), revision: revision, roots: selected, permission: selectedPermission, serviceRevision: manager.serviceRevision) }
    var canInteract: Bool { active && manager.active && !manager.busy && !hasSheet && window != nil }
    func attach(to owner: NSWindow?) {
        guard !retired, let owner, window !== owner || ownerObserver == nil else { return }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) }
        if window != nil { suspend() }
        window = owner; revision = UUID()
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retired = true; self?.suspend() }
        }
    }
    func activate() { guard !retired else { return }; active = true; revision = UUID(); reconcile() }
    func suspend() {
        active = false; revision = UUID(); sheetID = nil; hasSheet = false
        if let sheet { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }; sheet = nil
    }
    func reconcile() {
        let roots = Set(manager.rows.map(\.id)), next = selected.intersection(roots)
        if next != selected { selected = next; selectedPermission = nil; revision = UUID() }
        if let id = selected.first, let permission = selectedPermission, !manager.additionalPermissions(id).contains(where: { $0.id == permission }) { selectedPermission = nil; revision = UUID() }
    }
    private func accepts(_ context: Context) -> Bool { canInteract && context == self.context }
    func selection(context: Context) -> Binding<Set<UUID>> {
        Binding(get: { self.selected }, set: { value in
            guard self.accepts(context) else { return }
            let next = value.intersection(Set(self.manager.rows.map(\.id)))
            if next != self.selected { self.selected = next; self.selectedPermission = nil; self.revision = UUID() }
        })
    }
    func permission(context: Context) -> Binding<UUID?> {
        Binding(get: { self.selectedPermission }, set: { value in
            guard self.accepts(context), self.selected.count == 1, let id = self.selected.first else { return }
            guard value == nil || self.manager.additionalPermissions(id).contains(where: { $0.id == value }) else { return }
            self.selectedPermission = value; self.revision = UUID()
        })
    }
    func refresh(context: Context) {
        guard accepts(context) else { return }; for id in context.roots { manager.refresh(id) }
    }
    private func begin(context: Context) -> (UUID, Context)? {
        guard accepts(context), window?.attachedSheet == nil else { return nil }
        let id = UUID(); sheetID = id; hasSheet = true; revision = UUID(); return (id, self.context)
    }
    private func finish(_ id: UUID, context: Context) -> Bool {
        guard sheetID == id else { return false }
        let accepted = active && manager.active && !manager.busy && context == self.context
        sheetID = nil; sheet = nil; hasSheet = false; revision = UUID(); return accepted
    }
    private func choose(title: String, initial: URL?, context: Context, accepted: @escaping (URL) -> Void) {
        guard let (id, modal) = begin(context: context), let window else { return }
        let reply: (URL?) -> Void = { [weak self] url in
            guard let self, self.finish(id, context: modal), let url else { return }; accepted(url)
        }
        if let chooseFolder { chooseFolder(title, initial, reply); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.title = title; panel.prompt = title; panel.directoryURL = initial; sheet = panel
        panel.message = title == "Watch Repository" || title == "Renew Access" ? "Choose the repository root folder." : "Choose the reported Git administration folder, or a parent folder containing it."
        panel.beginSheetModal(for: window) { response in reply(response == .OK ? panel.url : nil) }
    }
    private func confirm(title: String, message: String, context: Context, accepted: @escaping () -> Void) {
        guard let (id, modal) = begin(context: context), let window else { return }
        let reply: (Bool) -> Void = { [weak self] value in guard let self, self.finish(id, context: modal), value else { return }; accepted() }
        if let ask { ask(title, message, reply); return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Remove"); sheet = alert.window
        alert.beginSheetModal(for: window) { response in reply(response == .alertSecondButtonReturn) }
    }
    func chooseRoot(renew: Bool, context: Context) {
        guard accepts(context), !renew || context.roots.count == 1 else { return }
        let id = renew ? context.roots.first : nil
        let initial = id.flatMap { target in manager.rows.first { $0.id == target }.map { URL(fileURLWithPath: $0.path, isDirectory: true) } }
        choose(title: renew ? "Renew Access" : "Watch Repository", initial: initial, context: context) { [manager] url in Task { await manager.add(url, replacing: id) } }
    }
    func choosePermission(renew: Bool, context: Context) {
        guard accepts(context), context.roots.count == 1, let id = context.roots.first, !renew || context.permission != nil else { return }
        let permission = renew ? context.permission : nil
        let initial = permission.flatMap { target in manager.additionalPermissions(id).first { $0.id == target }.map { URL(fileURLWithPath: $0.path, isDirectory: true) } }
        choose(title: renew ? "Renew Folder Access" : "Grant Folder Access", initial: initial, context: context) { [manager] url in Task { await manager.changePermission(id, url: url, replacing: permission) } }
    }
    func remove(context: Context) {
        guard accepts(context), !context.roots.isEmpty else { return }
        let rows = manager.rows.filter { context.roots.contains($0.id) }, ids = rows.map(\.id)
        guard ids.count == context.roots.count else { return }
        confirm(title: ids.count == 1 ? "Remove watched repository?" : "Remove watched repositories?", message: rows.map(\.path).joined(separator: "\n") + "\n\nStop these watches and remove their cached subtrees. Repository files remain unchanged.", context: context) { [manager] in
            Task { for id in ids { await manager.remove(id); if manager.error != nil { break } } }
        }
    }
    func removePermission(context: Context) {
        guard accepts(context), context.roots.count == 1, let id = context.roots.first, let permission = context.permission,
              let grant = manager.additionalPermissions(id).first(where: { $0.id == permission }) else { return }
        confirm(title: "Remove additional folder access?", message: grant.path + "\n\nRefresh may stop until access is granted again. Files remain unchanged.", context: context) { [manager] in Task { await manager.changePermission(id, removing: permission) } }
    }
}

struct FinderWatchedRepositoriesPage: View {
    @ObservedObject var manager: FinderWatchManager
    @StateObject private var controls: FinderWatchPageModel
    init(manager: FinderWatchManager, controls: FinderWatchPageModel? = nil) {
        self.manager = manager; _controls = StateObject(wrappedValue: controls ?? FinderWatchPageModel(manager: manager))
    }
    var body:some View {
        let context = controls.context
        VStack(alignment:.leading,spacing:12) {
            Text("Keep these repositories refreshed for Finder.")
            if let service=manager.backgroundService { FinderBackgroundServiceControls(service:service,manager:manager) }
            Table(manager.rows,selection:controls.selection(context: context)) {
                TableColumn("Repository") { row in HStack { Image(nsImage:MenuIcon.repositoryBrowser.image() ?? NSImage()).frame(width:16,height:16);Text(row.name) } }
                TableColumn("Path",value:\.path)
                TableColumn("Status") { row in Text(row.status).foregroundStyle(row.status.contains("unavailable") ? Color.orange : row.status.hasPrefix("Updated") ? Color.green : Color.primary) }
                TableColumn("Background") { row in
                    if let service = manager.backgroundService { FinderBackgroundRootStatus(service: service, id: row.id, revision: manager.serviceRevision) }
                    else { Text("Disabled").foregroundStyle(.secondary) }
                }
            }.accessibilityLabel("Watched repositories").frame(minHeight:180)
            HStack {
                Button { controls.chooseRoot(renew: false, context: context) } label: { CommandLabel(title:"Add…",icon:.add) }
                Button { controls.remove(context: context) } label: { CommandLabel(title:"Remove",icon:.remove) }.disabled(controls.selected.isEmpty)
                Button { controls.refresh(context: context) } label: { CommandLabel(title:"Refresh",icon:.refresh) }.disabled(controls.selected.isEmpty)
                Button { controls.chooseRoot(renew: true, context: context) } label: { CommandLabel(title:"Renew Access…",icon:.open) }.disabled(controls.selected.count != 1)
            }.disabled(!controls.canInteract)
            if let id=controls.selected.first,controls.selected.count==1 {
                GroupBox("Additional folder access") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Linked worktrees may need access to the main repository’s Git folder. Add only the folders reported in the repository status.").font(.caption).foregroundStyle(.secondary)
                        List(manager.additionalPermissions(id),selection:controls.permission(context: context)) { grant in
                            Label(grant.path,systemImage:"folder").tag(grant.id).help(grant.path)
                        }.frame(height:90).accessibilityLabel("Additional authorized folders")
                        HStack {
                            Button { controls.choosePermission(renew: false, context: context) } label: { CommandLabel(title:"Add Folder Access…",icon:.add) }
                            Button { controls.choosePermission(renew: true, context: context) } label: { CommandLabel(title:"Renew Folder Access…",icon:.open) }.disabled(controls.selectedPermission==nil)
                            Button { controls.removePermission(context: context) } label: { CommandLabel(title:"Remove Access",icon:.remove) }.disabled(controls.selectedPermission==nil)
                        }.disabled(!controls.canInteract)
                    }.padding(4)
                }
            }
            if manager.pendingOperations>0 { ProgressView("Refreshing watched repositories…").controlSize(.small) }
            if let error=manager.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Changes take effect immediately. An open workspace refreshes its repository separately.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(16)
        .background(FinderWatchOwnerProbe(controls: controls).frame(width: 0, height: 0))
        .onAppear { controls.activate(); manager.restore() }
        .onDisappear { controls.suspend() }
        .onChange(of: manager.rows.map(\.id)) { _ in controls.reconcile() }
        .onChange(of: manager.serviceRevision) { _ in controls.reconcile() }
    }
}

private struct FinderWatchOwnerProbe: NSViewRepresentable {
    let controls: FinderWatchPageModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.controls = controls; return view }
    func updateNSView(_ view: Probe, context: Context) { controls.attach(to: view.window) }
    final class Probe: NSView {
        weak var controls: FinderWatchPageModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controls?.attach(to: window) }
    }
}

private struct FinderBackgroundRootStatus: View {
    @ObservedObject var service: FinderBackgroundService
    let id: UUID
    let revision: Int
    var body: some View {
        let text = service.rootStatus(id, revision: revision)
        let root = service.report?.roots.first { $0.id == id }
        Text(text).lineLimit(2).help(text)
            .foregroundStyle(service.failure != nil || root?.failure != nil ? Color.orange : root?.lastPublication != nil ? Color.green : Color.secondary)
    }
}

private struct FinderBackgroundServiceControls: View {
    @ObservedObject var service: FinderBackgroundService
    @ObservedObject var manager: FinderWatchManager
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Refresh after TurtleGit quits", isOn: Binding(get: { service.enabled }, set: { value in Task { if value { await service.enable(manager) } else { await service.disable() } } }))
                    .disabled(service.busy || manager.busy || manager.pendingOperations > 0)
                Spacer()
                Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            HStack {
                Button { service.checkStatus(manager) } label: { CommandLabel(title: "Check Status", icon: .refresh) }
                Button { service.checkStatus(manager, retry: true) } label: { CommandLabel(title: "Retry Background Refresh", icon: .refresh) }
                Button("Synchronize") { service.requestSync(manager, force: true) }
                if service.busy { ProgressView().controlSize(.small) }
            }.disabled(!service.enabled || service.busy || manager.busy || manager.pendingOperations > 0)
            Text(service.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).id(service.message)
            if let checked = service.lastChecked { Text("Status checked " + checked.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
            if let failure = service.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let report = service.report {
                ForEach(report.cleanupFailures.keys.sorted(), id: \.self) { id in
                    let name = manager.rows.first { $0.id.uuidString == id }?.name ?? "Removed repository"
                    Text(name + " — cache cleanup: " + (report.cleanupFailures[id] ?? "")).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
        }.task {
            service.updateStatus(); service.requestSync(manager)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                service.checkStatus(manager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in service.updateStatus(); service.requestSync(manager) }
    }
}
