import AppKit
import ServiceManagement
import TurtleGitCore

@MainActor final class FinderBackgroundService: ObservableObject {
    enum Request { case grants(Data), refresh, status }
    @Published private(set) var busy = false
    @Published private(set) var message = "Background service is not enabled."
    @Published private(set) var enabled = false
    @Published private(set) var report: FinderCacheServiceReport?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var failure: String?
    private let service = SMAppService.agent(plistName: FinderCacheServiceIdentity.agentPlist)
    var registrationStatus: (() -> SMAppService.Status)?
    var exchange: ((Request) async throws -> Data?)?
    var embeddedServiceAvailable: () -> Bool = {
        let root = Bundle.main.bundleURL
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Contents/Library/LaunchAgents/" + FinderCacheServiceIdentity.agentPlist).path)
            && FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("Contents/Library/LaunchServices/TurtleGitCache.app/Contents/MacOS/TurtleGitCache").path)
    }
    private var queued = false
    private var policyRefreshQueued=false
    private var sentRevision: Int?
    private var reportRevision: Int?
    private var epoch = UUID()
    private var retired = false
    init() { updateStatus() }
    func updateStatus() {
        guard !retired else { return }
        let status = registrationStatus?() ?? service.status
        let next = status == .enabled
        if next != enabled { epoch = UUID(); report = nil; lastChecked = nil; reportRevision = nil; failure = nil; sentRevision = nil }
        enabled = next
        switch status {
        case .enabled: if report == nil { message = "Background service enabled. Check its repository status below." }
        case .requiresApproval: message = "Allow TurtleGit in System Settings → Login Items."
        case .notRegistered: message = "Background service is not enabled."
        case .notFound: message = embeddedServiceAvailable() ? "Background service is not enabled." : "The background service is missing from this build."
        @unknown default: message = "Background service status is unavailable."
        }
    }
    func retire() { retired = true; queued = false;policyRefreshQueued=false;epoch = UUID() }
    func statusPolicyChanged(_ manager:FinderWatchManager) {
        guard !retired else{return}
        epoch=UUID();report=nil;reportRevision=nil;lastChecked=nil
        policyRefreshQueued=true;requestSync(manager)
    }
    func enable(_ manager: FinderWatchManager) async {
        guard !busy, !retired else { return }; busy = true; defer { finishOperation(manager) }
        do {
            _ = try FinderCacheServiceIdentity.currentTeam()
            if service.status != .enabled { try service.register() }; updateStatus()
            if enabled { sentRevision = nil; try await synchronize(manager); try await readReport(manager) }
        } catch { if !retired { updateStatus(); failure = error.localizedDescription; message = "Background service request failed." } }
    }
    func disable() async {
        guard !busy, !retired else { return }; busy = true; defer { busy = false }
        do { try await service.unregister(); updateStatus() }
        catch { if !retired { failure = error.localizedDescription } }
    }
    func requestSync(_ manager: FinderWatchManager, force: Bool = false) {
        if force { sentRevision = nil }
        guard enabled, !retired else { return }; queued = true
        guard !busy, manager.pendingOperations == 0, !manager.busy, manager.active else { return }
        busy = true
        Task { [self, weak manager] in
            defer { finishOperation(manager) }
            guard let manager else { return }
            while queued, enabled, !retired, manager.active {
                queued = false
                do {
                    if policyRefreshQueued {policyRefreshQueued=false;_ = try await perform(.refresh)}
                    try await synchronize(manager);try await readReport(manager)
                }
                catch { if !retired, manager.active { failure = error.localizedDescription; message = "Background service request failed." }; break }
            }
        }
    }
    func checkStatus(_ manager: FinderWatchManager, retry: Bool = false) {
        guard !retired, enabled, !busy, manager.active, !manager.busy, manager.pendingOperations == 0 else { return }
        busy = true
        Task { [self, weak manager] in
            defer { finishOperation(manager) }
            guard let manager else { return }
            let requestEpoch = epoch, revision = manager.serviceRevision
            do {
                if retry { _ = try await perform(.refresh) }
                guard !retired, enabled, manager.active, requestEpoch == epoch, revision == manager.serviceRevision else { return }
                try await readReport(manager)
            } catch {
                if !retired, enabled, manager.active, requestEpoch == epoch, revision == manager.serviceRevision {
                    report = nil; lastChecked = nil; reportRevision = nil; failure = error.localizedDescription; message = "Background service is unavailable. Check status or retry."
                }
            }
        }
    }
    private func finishOperation(_ manager: FinderWatchManager?) {
        busy = false
        if let manager, queued, !retired, enabled, manager.active { requestSync(manager) }
    }
    func rootStatus(_ id: UUID, revision: Int) -> String {
        guard enabled else { return "Disabled" }
        guard failure == nil, let report, reportRevision == revision else { return failure == nil ? "Not checked" : "Unavailable" }
        guard report.running else { return "Service stopped" }
        guard let root = report.roots.first(where: { $0.id == id }) else { return report.legacy ? "Status unavailable in older service" : "Not synchronized" }
        if let failure = root.failure { return failure }
        if root.refreshing { return "Refreshing…" }
        if let date = root.lastPublication { return "Updated " + date.formatted(date: .omitted, time: .standard) }
        return report.legacy ? "Status unavailable in older service" : "Waiting for first refresh"
    }
    private func synchronize(_ manager: FinderWatchManager) async throws {
        guard !retired, manager.active, sentRevision != manager.serviceRevision else { return }
        let revision = manager.serviceRevision, requestEpoch = epoch, leases = manager.serviceLeases()
        defer { withExtendedLifetime(leases) {} }
        let request = try manager.serviceAuthorization()
        _ = try await perform(.grants(try JSONEncoder().encode(request)))
        if !retired, manager.active, requestEpoch == epoch { sentRevision = revision }
    }
    private func readReport(_ manager: FinderWatchManager) async throws {
        let revision = manager.serviceRevision, requestEpoch = epoch
        guard let data = try await perform(.status) else { throw Self.error("Background service returned no status.") }
        let next = try FinderCacheServiceReport.decode(data)
        guard !retired, enabled, manager.active, requestEpoch == epoch, revision == manager.serviceRevision else { return }
        report = next; reportRevision = revision; lastChecked = Date(); failure = nil
        let failed = next.roots.filter { $0.failure != nil }.count + next.cleanupFailures.count
        if next.legacy { message = "Older background service: detailed status is unavailable. Reopen the current TurtleGit build." }
        else if let cacheFailure = next.cacheFailure { message = "Background cache needs attention: " + cacheFailure + " Retry to apply the saved setting and refresh status." }
        else if !next.running { message = "Background service is stopped." }
        else if failed > 0 { message = "Background service reports \(failed) repository or cleanup problem(s)." }
        else { message = "Background service ready for \(next.roots.count) watched repository(s)." }
    }
    private static func error(_ text: String) -> NSError { NSError(domain: "TurtleGit.CacheService", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    @MainActor private final class Reply {
        var continuation: CheckedContinuation<Data?, Error>?
        var timeout: Task<Void, Never>?
        let connection: NSXPCConnection
        init(_ connection: NSXPCConnection) { self.connection = connection }
        func finish(_ data: Data? = nil, error: Error? = nil) {
            guard let continuation else { return }; self.continuation = nil
            timeout?.cancel(); timeout = nil; connection.invalidationHandler = nil; connection.interruptionHandler = nil; connection.invalidate()
            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
        }
    }
    func settle() async { while busy { try? await Task.sleep(nanoseconds: 10_000_000) } }
    private func perform(_ request: Request) async throws -> Data? {
        if let exchange { return try await exchange(request) }
        let requirement = try FinderCacheServiceIdentity.requirement(identifier: FinderCacheServiceIdentity.bundleIdentifier, team: FinderCacheServiceIdentity.currentTeam())
        let connection = NSXPCConnection(machServiceName: FinderCacheServiceIdentity.machService)
        connection.setCodeSigningRequirement(requirement); connection.remoteObjectInterface = NSXPCInterface(with: FinderCacheServiceProtocol.self)
        let state = Reply(connection)
        return try await withCheckedThrowingContinuation { continuation in
            state.continuation = continuation
            connection.invalidationHandler = { Task { @MainActor in state.finish(error: Self.error("Background service connection closed.")) } }
            connection.interruptionHandler = { Task { @MainActor in state.finish(error: Self.error("Background service connection interrupted.")) } }
            state.timeout = Task { try? await Task.sleep(nanoseconds: 10_000_000_000); if !Task.isCancelled { state.finish(error: Self.error("Background service did not respond.")) } }
            connection.resume()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in Task { @MainActor in state.finish(error: error) } }) as? FinderCacheServiceProtocol else { state.finish(error: Self.error("Background service interface is unavailable.")); return }
            switch request {
            case .grants(let data): remote.replaceGrants(data) { message in Task { @MainActor in state.finish(error: message.map(Self.error)) } }
            case .refresh: remote.refresh { message in Task { @MainActor in state.finish(error: message.map(Self.error)) } }
            case .status: remote.status { data, message in Task { @MainActor in state.finish(data, error: message.map(Self.error)) } }
            }
        }
    }
}
