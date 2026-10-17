import AppKit
import SwiftUI
import TurtleGitCore

private actor CacheClearGate {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func suspend() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct LogCacheNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timeout: " + message)
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Log cache native failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = base.appendingPathComponent("repository"), cache = HistoryFileCache(root: base.appendingPathComponent("cache"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git, askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Cache QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await repo.run(["add", "file.txt"]); _ = try await repo.run(["commit", "-m", "initial"])
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await repo.run(["add", "file.txt"]); _ = try await repo.run(["commit", "-m", "changed"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.LogCache.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "EnableGravatar"); preferences.set(false, forKey: "LogIncludeWorkingTreeChanges")
        preferences.set(false, forKey: "EnableLogCache")
        let disabled = LogWindowController(repository: repo, access: nil, labelDefaults: preferences, savesColumnLayout: false, savesGeometry: false, historyFileCache: cache)
        defer { disabled.close() }
        func select(_ owner: LogWindowController) async throws {
            owner.model.reload(); try await wait("Log revisions") { !owner.model.busy && owner.model.entries.count == 2 }
            owner.model.select([owner.model.entries[0].hash]); try await wait("Log changed files") { !owner.model.busy && owner.model.files.count == 1 }
        }
        try await select(disabled); try require(try cache.savedRecordCount() == 0, "Disabled Log wrote records")
        preferences.set(true, forKey: "EnableLogCache")
        let enabled = LogWindowController(repository: repo, access: nil, labelDefaults: preferences, savesColumnLayout: false, savesGeometry: false, historyFileCache: cache)
        defer { enabled.close() }
        try await select(enabled); try require(try cache.savedRecordCount() == 1, "New enabled Log ignored cache setting")
        let saved = SavedDataSettingsModel(store: ActionLogStore(storageURL: base.appendingPathComponent("action.log")), preferences: preferences, historyCache: cache, showFile: { _ in true })
        let owner = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentView = NSHostingView(rootView: SavedDataSettingsPage(model: saved, authentication: SavedDataAuthenticationOwner()))
        defer { owner.close(); saved.retire() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        owner.orderFront(nil)
        try await wait("Saved Data Clear control") { owner.contentView?.layoutSubtreeIfNeeded(); return views(owner.contentView!).compactMap { $0 as? NSButton }.contains { $0.accessibilityIdentifier() == "SavedData.ClearLogCache" } }
        let clear = views(owner.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "SavedData.ClearLogCache" }!
        try require(clear.isEnabled && saved.historyCacheRecords == 1, "Saved Data cache count/control unavailable")
        let gate = CacheClearGate()
        saved.clearHistoryRecords = { cache in await gate.suspend(); try cache.clearSavedRecords() }
        clear.performClick(nil)
        try await wait("Owned clear started") { saved.clearingHistoryCache && SavedDataSettingsModel.activeCacheClears == 1 }
        saved.clearHistoryCache(); try require(SavedDataSettingsModel.activeCacheClears == 1, "Duplicate clear started")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit lost cache clear ownership")
        for _ in 0..<2000 { if await gate.waiting { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try require(await gate.waiting, "Clear worker did not reach gate")
        saved.retire(); await gate.release()
        try await wait("Retired clear drained") { SavedDataSettingsModel.activeCacheClears == 0 }
        try require(saved.historyCacheRecords == 1 && saved.error == nil && !saved.clearingHistoryCache, "Retired clear applied late UI result")
        try require(try cache.savedRecordCount() == 0, "Retirement abandoned accepted deletion")
        saved.activate(); saved.refresh(); try require(saved.historyCacheRecords == 0, "Reactivated Saved Data missed deletion")
        // The already-open disabled window keeps its construction-time policy.
        disabled.model.select([]); disabled.model.select([disabled.model.entries[0].hash])
        try await wait("Disabled reload") { !disabled.model.busy && disabled.model.files.count == 1 }
        try require(try cache.savedRecordCount() == 0, "Existing disabled Log changed policy after preference edit")
        enabled.model.select([]); enabled.model.select([enabled.model.entries[0].hash])
        try await wait("Repopulated Log") { !enabled.model.busy && enabled.model.files.count == 1 }
        try require(try cache.savedRecordCount() == 1, "Log could not repopulate after Saved Data clear")
        saved.clearHistoryRecords = { _ in throw Failure(message: "Injected cache clear failure") }
        saved.clearHistoryCache(); try await wait("Clear failure") { !saved.clearingHistoryCache }
        try require(saved.error != nil && saved.historyCacheRecords == 1, "Clear failure erased count/error")
        try require(try await repo.run(["rev-parse", "HEAD"]).stdout == head, "Cache changed HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Cache changed index")
        disabled.close(); enabled.close(); owner.close(); saved.retire()
        try require(SavedDataSettingsModel.activeCacheClears == 0, "Cache owner leaked")
        print("PASS: Log cache native preference, native Clear, retirement, Quit, repopulation and failure")
    }
}
