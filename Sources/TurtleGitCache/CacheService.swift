import AppKit
import TurtleGitCore

@MainActor final class CacheServiceHost:NSObject,NSXPCListenerDelegate {
    let runtime:FinderCacheServiceRuntime
    private let requirement:String
    private let listener:NSXPCListener
    private var signals:[DispatchSourceSignal]=[]
    init(configuration:Void) throws {
        // Both peers require an Apple-signed identity from the same team. Unsigned
        // development bundles fail closed rather than weakening production IPC.
        requirement=try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.appIdentifier,team:FinderCacheServiceIdentity.currentTeam())
        guard let shared=FinderIntegration.snapshotURL,
              let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let store=try FinderServicePermissionStore(url:support.appendingPathComponent("TurtleGitCache/grants.json"))
        // The helper is embedded four directory levels inside the containing app.
        let appURL=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let app=Bundle(url:appURL),app.bundleIdentifier==FinderCacheServiceIdentity.appIdentifier else { throw FinderServiceAuthorizationFailure.invalidRequest }
        let git=try GitRuntime.executable(bundle:app)
        runtime=FinderCacheServiceRuntime(permissions:store,cache:FinderSnapshotStore(url:shared),repository:{ GitRepository(root:$0,executable:git) },notify:{ DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(FinderIntegration.notification),object:nil) })
        listener=NSXPCListener(machServiceName:FinderCacheServiceIdentity.machService)
        super.init();listener.delegate=self
    }
    func start() throws {
        try runtime.start();listener.resume()
        for number in [SIGTERM,SIGINT] {
            signal(number,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:number,queue:.main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return };self.listener.invalidate()
                    await self.runtime.shutdown();exit(0)
                }
            };source.resume();signals.append(source)
        }
    }
    nonisolated func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection) -> Bool {
        // Configure before resuming. Authentication is enforced by NSXPCConnection
        // for every message, including requests received after a process exits.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface=NSXPCInterface(with:FinderCacheServiceProtocol.self)
        connection.exportedObject=CacheServiceEndpoint(runtime:runtime)
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
            do { reply(try JSONEncoder().encode(Dictionary(uniqueKeysWithValues:runtime.failures.map { ($0.key.uuidString,$0.value) })),nil) }
            catch { reply(nil,error.localizedDescription) }
        }
    }
}
@main struct CacheServiceMain {
    @MainActor static func main() {
        do {
            let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
            let service=try CacheServiceHost(configuration:());try service.start()
            withExtendedLifetime(service) { app.run() }
        } catch { fputs("TurtleGit cache service: \(error.localizedDescription)\n",stderr);exit(1) }
    }
}
