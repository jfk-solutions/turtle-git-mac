import AppKit
import TurtleGitCore

@MainActor final class CacheServiceHost:NSObject,NSXPCListenerDelegate,NSApplicationDelegate {
    let runtime:FinderCacheServiceRuntime
    private let requirement:String
    private let queryRequirement:String
    private let queryListener:NSXPCListener
    private let queryListenerIdentity:ObjectIdentifier
    private let listener:NSXPCListener
    private var signals:[DispatchSourceSignal]=[]
    private var tray:FinderCacheTrayController?
    private var stopTask:Task<Void,Never>?
    private var policyObserver:NSObjectProtocol?
    private var statusObservers:[NSObjectProtocol]=[]
    init(configuration:Void) throws {
        // Both peers require an Apple-signed identity from the same team. Unsigned
        // development bundles fail closed rather than weakening production IPC.
        let team=try FinderCacheServiceIdentity.currentTeam()
        requirement=try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.appIdentifier,team:team)
        queryRequirement=try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.finderIdentifier,team:team)
        guard let shared=FinderIntegration.snapshotURL,
              let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let store=try FinderServicePermissionStore(url:support.appendingPathComponent("TurtleGitCache/grants.json"))
        // The helper is embedded four directory levels inside the containing app.
        let appURL=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let app=Bundle(url:appURL),app.bundleIdentifier==FinderCacheServiceIdentity.appIdentifier else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let git=try GitRuntime.executable(bundle:app)
        let nativeIndexRuntime=GitLibGit2Configuration(helperURL:appURL.appendingPathComponent("Contents/Helpers/LibGit2/bin/turtlegit-libgit2"))
        var changed:()->Void = {}
        runtime=FinderCacheServiceRuntime(permissions:store,cache:FinderSnapshotStore(url:shared),repository:{ GitRepository(root:$0,executable:git,libgit2Configuration:nativeIndexRuntime) },notify:{ DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) },changed:{changed()})
        listener=NSXPCListener(machServiceName:FinderCacheServiceIdentity.machService)
        queryListener=NSXPCListener(machServiceName:FinderCacheServiceIdentity.queryMachService)
        queryListenerIdentity=ObjectIdentifier(queryListener)
        super.init();listener.delegate=self;queryListener.delegate=self
        changed = { [weak self] in self?.tray?.refresh() }
    }
    func start() throws {
        try runtime.start();listener.resume();queryListener.resume();NSApp.delegate=self
        policyObserver=DistributedNotificationCenter.default().addObserver(
            forName:NSNotification.Name(FinderCachePersistencePreferences.notification),object:nil,queue:.main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.stopTask==nil else { return }
                self.runtime.reloadCachePolicy()
            }
        }
        for name in [FinderStatusPolicyPreferences.notification,FinderStatusOperationLease.notification] {
            statusObservers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main) {[weak self] _ in Task {@MainActor in guard let self,self.stopTask==nil else{return};self.runtime.operationStateChanged()}})
        }
        tray=FinderCacheTrayController(snapshot:{ [weak self] in self?.runtime.activitySnapshot ?? .init(running:false) },exitService:{ [weak self] in await self?.stopAndExit() })
        for number in [SIGTERM,SIGINT] {
            signal(number,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:number,queue:.main)
            source.setEventHandler { [weak self] in self?.requestStop()
            };source.resume();signals.append(source)
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {requestStop();return .terminateLater}
    private func requestStop() { Task { [self] in await stopAndExit() } }
    private func stopAndExit() async {
        if let stopTask { await stopTask.value; return }
        let operation=Task { [self] in
            tray?.beginStopping()
            if let policyObserver { DistributedNotificationCenter.default().removeObserver(policyObserver);self.policyObserver=nil }
            for observer in statusObservers {DistributedNotificationCenter.default().removeObserver(observer)};statusObservers=[]
            listener.invalidate();queryListener.invalidate();await runtime.shutdown()
            if let failure=runtime.report.cacheFailure { fputs("TurtleGit cache shutdown: \(failure)\n",stderr) }
            tray?.retire();exit(0)
        }
        stopTask=operation;await operation.value
    }
    nonisolated func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection) -> Bool {
        // Configure before resuming. Authentication is enforced by NSXPCConnection
        // for every message, including requests received after a process exits.
        if ObjectIdentifier(listener)==queryListenerIdentity {
            connection.setCodeSigningRequirement(queryRequirement)
            connection.exportedInterface=NSXPCInterface(with:FinderCacheQueryProtocol.self)
            connection.exportedObject=CacheServiceQueryEndpoint(runtime:runtime)
        } else {
            connection.setCodeSigningRequirement(requirement)
            connection.exportedInterface=NSXPCInterface(with:FinderCacheServiceProtocol.self)
            connection.exportedObject=CacheServiceEndpoint(runtime:runtime)
        }
        connection.resume();return true
    }
}
final class CacheServiceEndpoint:NSObject,FinderCacheServiceProtocol {
    let runtime:FinderCacheServiceRuntime
    init(runtime:FinderCacheServiceRuntime) { self.runtime=runtime }
    func replaceGrants(_ request:Data,withReply reply:@escaping (String?)->Void) {
        guard request.count<=16_777_216 else { reply("Permission request is too large.");return }
        Task { @MainActor in
            do { let value=try JSONDecoder().decode(FinderServiceAuthorization.self,from:request);try await runtime.replace(value);reply(nil) }
            catch { reply(error.localizedDescription) }
        }
    }
    func refresh(withReply reply:@escaping (String?)->Void) {
        Task { @MainActor in runtime.refresh();reply(nil) }
    }
    func status(withReply reply:@escaping (Data?,String?)->Void) {
        Task { @MainActor in
            do { reply(try JSONEncoder().encode(runtime.report),nil) }
            catch { reply(nil,error.localizedDescription) }
        }
    }
}
final class CacheServiceQueryEndpoint:NSObject,FinderCacheQueryProtocol {
    let runtime:FinderCacheServiceRuntime
    init(runtime:FinderCacheServiceRuntime){self.runtime=runtime}
    func refreshObserved(_ request:Data,withReply reply:@escaping (String?)->Void) {
        guard request.count<=2*1024*1024 else{reply("Finder status query is too large.");return}
        Task {@MainActor in do {let paths=try JSONDecoder().decode([String].self,from:request);try runtime.refreshObserved(paths);reply(nil)}catch{reply(error.localizedDescription)}}
    }
}
@main struct CacheServiceMain {
    @MainActor static func main() {
        do {
            let app=NSApplication.shared;app.setActivationPolicy(.accessory)
            let service=try CacheServiceHost(configuration:());try service.start()
            withExtendedLifetime(service) { app.run() }
        } catch { fputs("TurtleGit cache service: \(error.localizedDescription)\n",stderr);exit(1) }
    }
}
