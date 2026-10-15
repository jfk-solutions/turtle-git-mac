// Native watched-root management for Finder's explicit directory registration.
// GPL-2.0-or-later; adapts TGitCache watcher/crawler ownership to macOS.
import AppKit
import ServiceManagement
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
    @Published private(set) var busy=false { didSet { if !busy { sessions.values.forEach { $0.scheduler?.kick() };backgroundService?.requestSync(self) } } }
    @Published private(set) var pendingOperations=0 { didSet { if pendingOperations==0 { backgroundService?.requestSync(self) } } }
    @Published var error:String?
    private(set) var serviceRevision=0
    var backgroundService:FinderBackgroundService?
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
        var additionalLeases:[RepositoryAccessLease]=[]
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
        let manager=try FinderWatchManager(permissions:RepositoryAccessStore(storageURL:url),cache:FinderIntegration.snapshotURL.map { FinderSnapshotStore(url:$0) })
        manager.backgroundService=FinderBackgroundService();return manager
    }
    private func render() {
        rows=permissions.repositories.map { FinderWatchRow(id:$0.id,name:$0.name,path:$0.lastKnownPath,status:statuses[$0.id] ?? "Waiting") }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func restore() { guard active,!busy else { return };for value in permissions.repositories where sessions[value.id]==nil { attach(value.id) } }
    private func attach(_ id:UUID) {
        guard active else { return };sessions.removeValue(forKey:id)?.retire()
        do {
            let lease=try permissions.acquire(id,requireSecurityScope:requireScope,updatingRecord:false),session=Session(id:id,lease:lease,repository:try repositoryFactory(lease.url))
            session.additionalLeases=try permissions.acquireAdditionalPermissions(id,requireSecurityScope:requireScope)
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
        let allowed=directories.filter { directory in !requireScope || ([session.lease]+session.additionalLeases).contains { $0.contains(directory) } }
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
                _ = try permissions.replace(session.id,with:session.lease.url);session.permissionReady=true;serviceRevision += 1;render()
            }
            var ticket:FinderPublicationTicket?
            if let cache { ticket=try await Task.detached { try cache.begin(root:root,cancellation:token) }.value }
            let result=try await session.repository.collectFinderRepository(authorizedRoot:session.lease.url,additionalAuthorizedRoots:session.additionalLeases.map(\.url),cancellation:token,watchReady:{ [weak self,weak session] paths in if let self,let session { await self.install(session,paths) } })
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
            serviceRevision += 1;sessions.removeValue(forKey:saved.id)?.retire()
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
        guard active,!busy,pendingOperations==0,rows.count==sessions.count else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let values=try sessions.values.map { session -> (UUID,URL,RepositoryAccessLease,[RepositoryAccessLease]) in
            guard session.active,session.permissionReady else { throw RepositoryAccessFailure.securityScopeUnavailable }
            return (session.id,session.repository.root,session.lease,session.additionalLeases)
        }.sorted { $0.0.uuidString<$1.0.uuidString }
        return try FinderServiceAuthorization.capture(values,provider:provider)
    }
    func retire() { guard active else { return };active=false;backgroundService?.retire();mutation?.cancel();sessions.values.forEach { $0.retire() };sessions=[:] }
    func shutdown() async { retire();while pendingOperations>0 { try? await Task.sleep(nanoseconds:10_000_000) };await backgroundService?.settle() }
}

struct FinderWatchedRepositoriesPage:View {
    @ObservedObject var manager:FinderWatchManager
    @State private var selection=Set<UUID>()
    @State private var confirmingRemove=false
    @State private var permissionSelection:UUID?
    @State private var confirmingPermissionRemove=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Keep these repositories refreshed for Finder.")
            if let service=manager.backgroundService { FinderBackgroundServiceControls(service:service,manager:manager) }
            Table(manager.rows,selection:$selection) {
                TableColumn("Repository") { row in HStack { Image(nsImage:MenuIcon.repositoryBrowser.image() ?? NSImage()).frame(width:16,height:16);Text(row.name) } }
                TableColumn("Path",value:\.path)
                TableColumn("Status") { row in Text(row.status).foregroundStyle(row.status.contains("unavailable") ? Color.orange : row.status.hasPrefix("Updated") ? Color.green : Color.primary) }
                TableColumn("Background") { row in
                    if let service = manager.backgroundService { FinderBackgroundRootStatus(service: service, id: row.id, revision: manager.serviceRevision) }
                    else { Text("Disabled").foregroundStyle(.secondary) }
                }
            }.accessibilityLabel("Watched repositories").frame(minHeight:180)
            HStack {
                Button { choose(nil) } label: { CommandLabel(title:"Add…",icon:.add) }
                Button { confirmingRemove=true } label: { CommandLabel(title:"Remove",icon:.remove) }.disabled(selection.count != 1)
                Button { if let id=selection.first { manager.refresh(id) } } label: { CommandLabel(title:"Refresh",icon:.refresh) }.disabled(selection.count != 1)
                Button { choose(selection.first) } label: { CommandLabel(title:"Renew Access…",icon:.open) }.disabled(selection.count != 1)
            }.disabled(manager.busy || !manager.active)
            if let id=selection.first,selection.count==1 {
                GroupBox("Additional folder access") {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Linked worktrees may need access to the main repository’s Git folder. Add only the folders reported in the repository status.").font(.caption).foregroundStyle(.secondary)
                        List(manager.additionalPermissions(id),selection:$permissionSelection) { grant in
                            Label(grant.path,systemImage:"folder").tag(grant.id).help(grant.path)
                        }.frame(height:90).accessibilityLabel("Additional authorized folders")
                        HStack {
                            Button { chooseAdditional(id) } label: { CommandLabel(title:"Add Folder Access…",icon:.add) }
                            Button { chooseAdditional(id,replacing:permissionSelection) } label: { CommandLabel(title:"Renew Folder Access…",icon:.open) }.disabled(permissionSelection==nil)
                            Button { confirmingPermissionRemove=true } label: { CommandLabel(title:"Remove Access",icon:.remove) }.disabled(permissionSelection==nil)
                        }.disabled(manager.busy || !manager.active)
                    }.padding(4)
                }
            }
            if manager.pendingOperations>0 { ProgressView("Refreshing watched repositories…").controlSize(.small) }
            if let error=manager.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Changes take effect immediately. An open workspace refreshes its repository separately.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).onAppear { manager.restore() }
        .onChange(of:selection) { _ in permissionSelection=nil }
        .alert("Remove additional folder access?",isPresented:$confirmingPermissionRemove) {
            Button("Cancel",role:.cancel) {}
            Button("Remove Access") { if let id=selection.first,let permission=permissionSelection { Task { await manager.changePermission(id,removing:permission);permissionSelection=nil } } }
        } message: { Text("Refresh may stop until access is granted again. Files remain unchanged.") }
        .alert("Remove watched repository?",isPresented:$confirmingRemove) {
            Button("Cancel",role:.cancel) {}
            Button("Remove") { if let id=selection.first { Task { await manager.remove(id);selection=[] } } }
        } message: { Text("Stop its background watch and remove its cached subtree. Repository files remain unchanged.") }
    }
    private func chooseAdditional(_ id:UUID,replacing permission:UUID? = nil) {
        guard let window=NSApp.keyWindow,window.attachedSheet==nil,!manager.busy,manager.active else { return }
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.showsHiddenFiles=true
        panel.prompt="Grant Folder Access";panel.message="Choose the Git administration folder reported in the repository status, or a parent folder containing it."
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url=panel.url,manager.active else { return }
            Task { await manager.changePermission(id,url:url,replacing:permission) }
        }
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
            Text(service.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
