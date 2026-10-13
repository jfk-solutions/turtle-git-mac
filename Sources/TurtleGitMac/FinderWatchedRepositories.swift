// Native watched-root management for Finder's explicit directory registration.
// GPL-2.0-or-later; adapts TGitCache watcher/crawler ownership to macOS.
import AppKit
import SwiftUI
import TurtleGitCore

private enum FinderWatchFailure:LocalizedError {
    case duplicate
    var errorDescription:String? { "This repository is already watched." }
}

struct FinderWatchRow:Identifiable {
    let id:UUID
    let name:String
    let path:String
    let status:String
}
@MainActor final class FinderWatchManager:ObservableObject {
    @Published private(set) var rows:[FinderWatchRow]=[]
    @Published private(set) var busy=false { didSet { if !busy { sessions.values.forEach { $0.scheduler?.kick() } } } }
    @Published private(set) var pendingOperations=0
    @Published var error:String?
    private(set) var active=true
    private let permissions:RepositoryAccessStore
    private let cache:FinderSnapshotStore?
    private let requireScope:Bool
    private let scopeProvider:any RepositoryBookmarkProvider
    private let repositoryFactory:(URL) throws -> GitRepository
    private let notify:()->Void
    private var sessions:[UUID:Session]=[:]
    private var statuses:[UUID:String]=[:]
    private var mutation:OperationCancellation?
    @MainActor private final class Session {
        let id:UUID
        let lease:RepositoryAccessLease
        var repository:GitRepository
        var active=true
        var permissionReady=false
        var request:OperationCancellation?
        var monitor:RepositoryFileEventMonitor?
        var scheduler:RepositoryEventRefresh?
        var watched:[URL]=[]
        init(id:UUID,lease:RepositoryAccessLease,repository:GitRepository) { self.id=id;self.lease=lease;self.repository=repository }
        func retire() { active=false;request?.cancel();monitor?.stop();monitor=nil;scheduler?.retire();scheduler=nil }
    }
    init(permissions:RepositoryAccessStore,cache:FinderSnapshotStore?,requireScope:Bool = GitRuntime.isAppStoreBuild,scopeProvider:any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),
         repositoryFactory:@escaping (URL) throws -> GitRepository = { GitRepository(root:$0,executable:try GitRuntime.executable()) },
         notify:@escaping ()->Void = { DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) }) {
        self.permissions=permissions;self.cache=cache;self.requireScope=requireScope;self.scopeProvider=scopeProvider;self.repositoryFactory=repositoryFactory;self.notify=notify;render()
    }
    static func production() throws -> FinderWatchManager {
        let url=RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("watched-repositories.json")
        return try FinderWatchManager(permissions:RepositoryAccessStore(storageURL:url),cache:FinderIntegration.snapshotURL.map { FinderSnapshotStore(url:$0) })
    }
    private func render() {
        rows=permissions.repositories.map { FinderWatchRow(id:$0.id,name:$0.name,path:$0.lastKnownPath,status:statuses[$0.id] ?? "Waiting") }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func restore() { guard active,!busy else { return };for value in permissions.repositories where sessions[value.id]==nil { attach(value.id) } }
    private func attach(_ id:UUID) {
        guard active else { return };sessions.removeValue(forKey:id)?.retire()
        do {
            let lease=try permissions.acquire(id,requireSecurityScope:requireScope,updatingRecord:false),session=Session(id:id,lease:lease,repository:try repositoryFactory(lease.url))
            sessions[id]=session
            session.scheduler=RepositoryEventRefresh(available:{ [weak self,weak session] in
                guard let self,let session else { return false };return self.active && !self.busy && session.active && session.request==nil
            },refresh:{ [weak self,weak session] in if let self,let session { await self.collect(session) } })
            statuses[id]="Waiting";render();session.scheduler?.invalidate()
        } catch { statuses[id]="Permission or repository unavailable: "+error.localizedDescription;render() }
    }
    private func install(_ session:Session,_ directories:[URL]) {
        guard active,session.active,sessions[session.id] === session,session.watched != directories else { return }
        session.monitor?.stop();session.monitor=nil
        let allowed=directories.filter { !requireScope || session.lease.contains($0) }
        do {
            session.monitor=try RepositoryFileEventMonitor(roots:allowed) { [weak self,weak session] events in
                guard !events.isEmpty else { return }
                Task { @MainActor in guard let self,let session,self.active,session.active,self.sessions[session.id] === session else { return };session.scheduler?.invalidate() }
            };session.watched=directories
        } catch { statuses[session.id]="Monitoring unavailable: "+error.localizedDescription;render() }
    }
    private func collect(_ session:Session) async {
        guard active,session.active,sessions[session.id] === session,session.request==nil else { return }
        let token=OperationCancellation();session.request=token;pendingOperations += 1;statuses[session.id]="Refreshing…";render()
        defer { session.request=nil;pendingOperations -= 1;withExtendedLifetime(session.lease) {} }
        do {
            let root=try await session.repository.discoverRoot(cancellation:token)
            guard session.lease.contains(root) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(root.path) }
            session.repository=try repositoryFactory(root)
            let cache=self.cache
            if !session.permissionReady {
                if let old=permissions.repositories.first(where:{ $0.id==session.id }),old.lastKnownPath != root.path,let cache {
                    let previous=URL(fileURLWithPath:old.lastKnownPath,isDirectory:true)
                    _ = try await Task.detached { try cache.remove(root:previous,cancellation:token) }.value
                    guard active,session.active,!token.isCancelled else { return };notify()
                }
                guard active,session.active,!token.isCancelled else { return }
                _ = try permissions.replace(session.id,with:session.lease.url);session.permissionReady=true;render()
            }
            var ticket:FinderPublicationTicket?
            if let cache { ticket=try await Task.detached { try cache.begin(root:root,cancellation:token) }.value }
            let result=try await session.repository.collectFinderRepository(authorizedRoot:session.lease.url,cancellation:token,watchReady:{ [weak self,weak session] paths in if let self,let session { await self.install(session,paths) } })
            guard active,session.active,!token.isCancelled,sessions[session.id] === session else { return }
            if let cache,let ticket {
                let published=try await Task.detached { try cache.publish(ticket,snapshots:result.snapshots,cancellation:token) }.value
                guard active,session.active,!token.isCancelled else { return }
                if !published.published { statuses[session.id]="Refresh superseded";session.scheduler?.invalidate() }
                else { statuses[session.id]=result.failures.isEmpty ? "Updated" : "Updated; \(result.failures.count) child repositories unavailable";notify() }
            } else { statuses[session.id]="Updated; Finder integration unavailable" }
            render()
        } catch { if active,session.active,!token.isCancelled { statuses[session.id]=error.localizedDescription;render() } }
    }
    func refresh(_ id:UUID) {
        guard active,!busy else { return };if let session=sessions[id] { session.scheduler?.invalidate() } else { attach(id) }
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
                    _ = try await Task.detached { try cache.remove(root:path,cancellation:token) }.value
                    guard active,!token.isCancelled else { return };notify()
                }
            }
            let saved=try id.map { try permissions.replace($0,with:root) } ?? permissions.remember(root)
            sessions.removeValue(forKey:saved.id)?.retire()
            guard active,!token.isCancelled else { return };attach(saved.id);render()
            withExtendedLifetime(lease) {}
        } catch {
            if active,!token.isCancelled { self.error=error.localizedDescription;if let id,sessions[id]==nil { attach(id) };render() }
        }
    }
    func remove(_ id:UUID) async {
        guard active,!busy,let saved=permissions.repositories.first(where:{ $0.id==id }) else { return }
        busy=true;pendingOperations += 1;error=nil;let token=OperationCancellation();mutation=token
        sessions.removeValue(forKey:id)?.retire()
        defer { mutation=nil;pendingOperations -= 1;busy=false }
        do {
            if let cache {
                let root=URL(fileURLWithPath:saved.lastKnownPath,isDirectory:true)
                _ = try await Task.detached { try cache.remove(root:root,cancellation:token) }.value
                guard active,!token.isCancelled else { return };notify()
            }
            try permissions.forget(id);statuses[id]=nil;render()
        } catch { if active,!token.isCancelled { self.error=error.localizedDescription;attach(id) } }
    }
    func serviceAuthorization(provider:any RepositoryTransferBookmarkProvider = SystemRepositoryTransferBookmarks()) throws -> FinderServiceAuthorization {
        guard active,!busy,pendingOperations==0,rows.count==sessions.count else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let values=try sessions.values.map { session -> (UUID,URL,RepositoryAccessLease) in
            guard session.active,session.permissionReady else { throw RepositoryAccessFailure.securityScopeUnavailable }
            return (session.id,session.repository.root,session.lease)
        }.sorted { $0.0.uuidString<$1.0.uuidString }
        return try FinderServiceAuthorization.capture(values,provider:provider)
    }
    func retire() { guard active else { return };active=false;mutation?.cancel();sessions.values.forEach { $0.retire() };sessions=[:] }
    func shutdown() async { retire();while pendingOperations>0 { try? await Task.sleep(nanoseconds:10_000_000) } }
}

struct FinderWatchedRepositoriesPage:View {
    @ObservedObject var manager:FinderWatchManager
    @State private var selection=Set<UUID>()
    @State private var confirmingRemove=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Keep these repositories refreshed while TurtleGit is running.")
            Table(manager.rows,selection:$selection) {
                TableColumn("Repository") { row in HStack { Image(nsImage:MenuIcon.repositoryBrowser.image() ?? NSImage()).frame(width:16,height:16);Text(row.name) } }
                TableColumn("Path",value:\.path)
                TableColumn("Status") { row in Text(row.status).foregroundStyle(row.status.contains("unavailable") ? Color.orange : row.status.hasPrefix("Updated") ? Color.green : Color.primary) }
            }.accessibilityLabel("Watched repositories").frame(minHeight:180)
            HStack {
                Button { choose(nil) } label: { CommandLabel(title:"Add…",icon:.add) }
                Button { confirmingRemove=true } label: { CommandLabel(title:"Remove",icon:.remove) }.disabled(selection.count != 1)
                Button { if let id=selection.first { manager.refresh(id) } } label: { CommandLabel(title:"Refresh",icon:.refresh) }.disabled(selection.count != 1)
                Button { choose(selection.first) } label: { CommandLabel(title:"Renew Access…",icon:.open) }.disabled(selection.count != 1)
            }.disabled(manager.busy || !manager.active)
            if manager.pendingOperations>0 { ProgressView("Refreshing watched repositories…").controlSize(.small) }
            if let error=manager.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Changes take effect immediately. An open workspace refreshes its repository separately.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).onAppear { manager.restore() }
        .alert("Remove watched repository?",isPresented:$confirmingRemove) {
            Button("Cancel",role:.cancel) {}
            Button("Remove") { if let id=selection.first { Task { await manager.remove(id);selection=[] } } }
        } message: { Text("Stop its background watch and remove its cached subtree. Repository files remain unchanged.") }
    }
    private func choose(_ id:UUID?) {
        guard let window=NSApp.keyWindow,window.attachedSheet==nil,!manager.busy,manager.active else { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt=id==nil ? "Watch Repository" : "Renew Access"
        panel.message="Choose the repository root folder."
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url=panel.url,manager.active else { return };Task { await manager.add(url,replacing:id) }
        }
    }
}
