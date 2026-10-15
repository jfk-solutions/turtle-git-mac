import AppKit
import TurtleGitCore

@main struct FinderServiceHealthVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ text: String) throws { if !value { throw Failure(description: text) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !ready() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(ready(), "Finder health timeout at line \(line)")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Finder service health failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), root = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Service Health QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("baseline\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "baseline")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let permissions = try RepositoryAccessStore(storageURL: folder.appendingPathComponent("private/permissions.json"))
        let manager = FinderWatchManager(permissions: permissions, cache: FinderSnapshotStore(url: folder.appendingPathComponent("private/status.json")), requireScope: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, notify: {})
        await manager.add(root); try await wait { !manager.busy && manager.pendingOperations == 0 && manager.rows.count == 1 && manager.rows[0].status.hasPrefix("Updated") }
        let id = manager.rows[0].id, date = Date(timeIntervalSinceReferenceDate: 100)
        let service = FinderBackgroundService(); service.registrationStatus = { .enabled }; service.updateStatus()
        var statuses = 0, retries = 0, grants = 0
        var report = FinderCacheServiceReport(running: true, roots: [.init(id: id, failure: "Permission unavailable")], cleanupFailures: [UUID().uuidString: "Cleanup needs retry"])
        service.exchange = { request in
            switch request {
            case .status: statuses += 1; return try JSONEncoder().encode(report)
            case .refresh: retries += 1; report = FinderCacheServiceReport(running: true, roots: [.init(id: id, lastPublication: date)]); return nil
            case .grants: grants += 1; return nil
            }
        }
        manager.backgroundService = service
        service.checkStatus(manager); try await wait { !service.busy }
        try require(service.rootStatus(id, revision: manager.serviceRevision) == "Permission unavailable" && service.report?.cleanupFailures.count == 1 && service.failure == nil, "Background failures were hidden by synchronization status")
        service.checkStatus(manager, retry: true); service.checkStatus(manager, retry: true)
        try await wait { !service.busy }
        try require(retries == 1 && grants == 0 && statuses == 2 && service.rootStatus(id, revision: manager.serviceRevision).hasPrefix("Updated"), "Retry did not refresh once independently of permissions")
        let savedPermissionBytes = try Data(contentsOf: permissions.storageURL)
        service.exchange = { _ in throw Failure(description: "Controlled unavailable connection") }
        service.checkStatus(manager); try await wait { !service.busy }
        try require(service.failure != nil && service.report == nil && service.rootStatus(id, revision: manager.serviceRevision) == "Unavailable", "Connection failure retained healthy state")
        service.exchange = { _ in Data("{}".utf8) }
        service.checkStatus(manager); try await wait { !service.busy }
        try require(service.report?.legacy == true && service.rootStatus(id, revision: manager.serviceRevision).contains("older service"), "Legacy empty failure list claimed healthy detailed state")
        service.exchange = { _ in Data("{\"version\":99}".utf8) }
        service.checkStatus(manager); try await wait { !service.busy }
        try require(service.failure != nil && service.report == nil, "Unsupported report version was accepted")
        try require(try Data(contentsOf: permissions.storageURL) == savedPermissionBytes, "Status/retry rewrote permissions")
        var heldStatus: CheckedContinuation<Data?, Error>?, holdNext = true
        service.exchange = { request in
            switch request {
            case .status:
                if holdNext { holdNext = false; return try await withCheckedThrowingContinuation { heldStatus = $0 } }
                return try JSONEncoder().encode(FinderCacheServiceReport(running: true, roots: manager.rows.map { .init(id: $0.id, lastPublication: date) }))
            case .grants: grants += 1; return nil
            case .refresh: retries += 1; return nil
            }
        }
        service.checkStatus(manager); try await wait { heldStatus != nil }
        let second = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let secondRepo = GitRepository(root: second, executable: git)
        _ = try await secondRepo.run(["init", "-b", "main"])
        _ = try await secondRepo.run(["-c", "user.name=Health QA", "-c", "user.email=qa@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "second"])
        await manager.add(second)
        heldStatus?.resume(returning: try JSONEncoder().encode(report)); heldStatus = nil
        try await wait { !service.busy && manager.pendingOperations == 0 && service.report?.roots.count == 2 }
        try require(grants == 1 && Set(service.report!.roots.map(\.id)) == Set(manager.rows.map(\.id)), "Watch-list change lost queued sync or accepted stale report")
        let permissionsAfterWatchChange = try Data(contentsOf: permissions.storageURL)
        var pending: CheckedContinuation<Data?, Error>?
        service.exchange = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        service.checkStatus(manager); try await wait { pending != nil }
        service.registrationStatus = { .notRegistered }; service.updateStatus()
        pending?.resume(returning: try JSONEncoder().encode(report)); pending = nil
        try await wait { !service.busy }
        try require(!service.enabled && service.report == nil && service.lastChecked == nil, "Late reply revived disabled service")
        service.registrationStatus = { .enabled }; service.updateStatus()
        service.checkStatus(manager); try await wait { pending != nil }
        manager.retire()
        pending?.resume(returning: try JSONEncoder().encode(report)); pending = nil
        await manager.shutdown()
        try require(service.report == nil && !service.busy && !manager.active, "Late reply published after manager retirement")
        try require(try Data(contentsOf: permissions.storageURL) == permissionsAfterWatchChange, "Late status rewrote source permissions")
        try require(try await repo.run(["rev-parse", "HEAD"]).stdout == head && Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Health checks changed repository bytes")
        print("Finder service health passed: per-root and cleanup failures, publication times, retry without grants, duplicate request gate, connection/legacy/schema failures, disabled/retired late replies, scope and repository preservation. Injected authenticated transport; no login item registered.")
    }
}
