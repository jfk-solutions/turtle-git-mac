import AppKit
import ServiceManagement
import TurtleGitCore

@MainActor final class FinderBackgroundService:ObservableObject {
    @Published private(set) var busy=false
    @Published private(set) var message="Background service is not enabled."
    @Published private(set) var enabled=false
    private let service=SMAppService.agent(plistName:FinderCacheServiceIdentity.agentPlist)
    private var queued=false
    private var sentRevision:Int?
    init() { updateStatus() }
    func updateStatus() {
        enabled=service.status == .enabled
        switch service.status {
        case .enabled:message="Background service enabled."
        case .requiresApproval:message="Allow TurtleGit in System Settings → Login Items."
        case .notRegistered:message="Background service is not enabled."
        case .notFound:message="The background service is missing from this build."
        @unknown default:message="Background service status is unavailable."
        }
    }
    func enable(_ manager:FinderWatchManager) async {
        guard !busy else { return };busy=true;defer { busy=false }
        do {
            // Check signing before modifying the user's background registration.
            _ = try FinderCacheServiceIdentity.currentTeam()
            if service.status != .enabled { try service.register() };updateStatus()
            if enabled { sentRevision=nil;try await synchronize(manager) }
        } catch { updateStatus();message=error.localizedDescription }
    }
    func disable() async {
        guard !busy else { return };busy=true;defer { busy=false }
        do { try await service.unregister();updateStatus() }
        catch { message=error.localizedDescription }
    }
    func requestSync(_ manager:FinderWatchManager,force:Bool = false) {
        if force { sentRevision=nil }
        guard enabled else { return }
        queued=true
        guard !busy,manager.pendingOperations==0,!manager.busy,manager.active else { return }
        busy=true
        Task { [weak self,weak manager] in
            guard let self,let manager else { return }
            defer { self.busy=false }
            while self.queued,self.enabled,manager.active {
                self.queued=false
                do { try await self.synchronize(manager) }
                catch { self.message=error.localizedDescription;break }
            }
        }
    }
    private func synchronize(_ manager:FinderWatchManager) async throws {
        guard sentRevision != manager.serviceRevision else { return }
        let revision=manager.serviceRevision
        let leases=manager.serviceLeases()
        defer { withExtendedLifetime(leases) {} }
        let request=try manager.serviceAuthorization()
        try await send(try JSONEncoder().encode(request))
        sentRevision=revision
        message="Watched repositories synchronized. They can refresh after TurtleGit quits."
    }
    @MainActor private final class Reply {
        var continuation:CheckedContinuation<Void,Error>?
        var timeout:Task<Void,Never>?
        let connection:NSXPCConnection
        init(_ connection:NSXPCConnection) { self.connection=connection }
        func finish(_ error:Error?) {
            guard let continuation else { return };self.continuation=nil
            timeout?.cancel();timeout=nil;connection.invalidationHandler=nil;connection.interruptionHandler=nil;connection.invalidate()
            if let error { continuation.resume(throwing:error) } else { continuation.resume() }
        }
    }
    func settle() async { while busy { try? await Task.sleep(nanoseconds:10_000_000) } }
    private func send(_ data:Data) async throws {
        let requirement=try FinderCacheServiceIdentity.requirement(identifier:FinderCacheServiceIdentity.bundleIdentifier,team:FinderCacheServiceIdentity.currentTeam())
        let connection=NSXPCConnection(machServiceName:FinderCacheServiceIdentity.machService)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface=NSXPCInterface(with:FinderCacheServiceProtocol.self)
        let state=Reply(connection)
        func failure(_ text:String) -> NSError { NSError(domain:"TurtleGit.CacheService",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            state.continuation=continuation
            connection.invalidationHandler={ Task { @MainActor in state.finish(failure("Background service connection closed.")) } }
            connection.interruptionHandler={ Task { @MainActor in state.finish(failure("Background service connection interrupted.")) } }
            state.timeout=Task { try? await Task.sleep(nanoseconds:10_000_000_000);if !Task.isCancelled { state.finish(failure("Background service did not respond.")) } }
            connection.resume()
            guard let remote=connection.remoteObjectProxyWithErrorHandler({ error in Task { @MainActor in state.finish(error) } }) as? FinderCacheServiceProtocol else { state.finish(failure("Background service interface is unavailable."));return }
            remote.replaceGrants(data) { message in Task { @MainActor in state.finish(message.map { failure($0) }) } }
        }
    }
}
