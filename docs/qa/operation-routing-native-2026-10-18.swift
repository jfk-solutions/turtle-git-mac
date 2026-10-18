// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum OperationRoutingVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Operation routing did not settle at \(line)")
    }
    static func owners<T>(_ type: T.Type) -> [T] { NSApp.windows.filter(\.isVisible).compactMap { $0.delegate as? T } }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Operation routing QA"), ("user.email", "routing@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["branch", "topic"])
        let suite = "TurtleGit.OperationRouting." + UUID().uuidString, sourceSuite = suite + ".source"
        let defaults = UserDefaults(suiteName: suite)!, source = UserDefaults(suiteName: sourceSuite)!
        for prefs in [defaults, source] { prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ConfirmKillProcess") }
        defer { defaults.removePersistentDomain(forName: suite); source.removePersistentDomain(forName: sourceSuite) }
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true }, comparisonMarks: WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = defaults; workspace.notifyFinder = {}
        workspace.commandLineRepositoryPermission = { _ in RepositoryAccessLease(url: root) }
        var log: LogWindowController?
        workspace.logWindowFactory = { repository, access in
            let controller = LogWindowController(repository: repository, access: access, labelDefaults: source, loadsImmediately: false)
            log = controller; return controller
        }
        func cleanup() async throws {
            workspace.stopMonitoringForTermination()
            for window in NSApp.windows { window.close() }
            try await wait { !workspace.busy && SwitchWindowModel.activeReads == 0 && ResetWindowModel.activeReads == 0 && BisectWindowModel.activeOperations == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeActionReads == 0 && FetchWindowModel.activePreparationReads == 0 && StashWindowModel.activePreparations == 0 && SwitchWindowController.activeChildReleases == 0 && ResetWindowController.activeChildReleases == 0 && BisectWindowController.activeChildReleases == 0 && !NSApp.windows.contains(where: \.isVisible) }
        }
        do {
            workspace.handleCommandLine(arguments: ["--command=log"], currentDirectory: root.path)
            try await wait { !workspace.busy && log != nil && log?.model.busy == false }
            guard let log else { throw Failure(message: "Missing configured Log") }
            try require(log.model.colorPreferences === source && source !== defaults, "Fixture did not create distinct originating preferences")
            log.model.onCheckout("topic")
            try await wait { owners(SwitchWindowController.self).first?.model.busy == false }
            let checkout = owners(SwitchWindowController.self)[0]
            try require(checkout.model.presentationPreferences === source, "Log to Switch lost originating preferences")
            checkout.model.onPostAction?(.pull, "main")
            try await wait { owners(FetchWindowController.self).first?.model.busy == false }
            let pull = owners(FetchWindowController.self)[0]
            try require(pull.model.presentationPreferences === source && pull.model.isPull, "Switch Pull follow-up used global defaults")
            pull.close()
            checkout.model.onPostAction?(.stash, "main")
            try await wait { owners(StashWindowController.self).first?.model.prepared == true && owners(StashWindowController.self).first?.model.preparing == false }
            let stash = owners(StashWindowController.self)[0]
            try require(stash.model.preferences === source && stash.model.followUp.showPull, "Switch Stash follow-up lost source preferences/request")
            stash.close(); checkout.close()
            log.model.onReset("HEAD")
            try await wait { owners(ResetWindowController.self).first?.model.busy == false && owners(ResetWindowController.self).first?.model.chooser.busy == false }
            let reset = owners(ResetWindowController.self)[0]
            try require(reset.model.presentationPreferences === source, "Log to Reset lost originating preferences")
            reset.model.onPostAction?(.clean)
            guard let clean = owners(CleanWindowController.self).first else { throw Failure(message: "Missing Reset Cleanup follow-up") }
            try require(clean.model.presentationPreferences === source, "Reset Cleanup used global defaults")
            clean.close(); reset.close()
            log.model.onBisect?(.init(good: nil, bad: nil, operation: nil, revisions: []))
            try await wait { owners(BisectWindowController.self).first?.model.busy == false }
            let bisect = owners(BisectWindowController.self)[0]
            try require(bisect.model.preferences === source, "Log to Bisect lost originating preferences")
            bisect.close()
            workspace.confirmingQuit = true
            log.model.onCheckout("topic"); log.model.onReset("HEAD"); log.model.onBisect?(.init(good: nil, bad: nil, operation: nil, revisions: []))
            try require(owners(SwitchWindowController.self).isEmpty && owners(ResetWindowController.self).isEmpty && owners(BisectWindowController.self).isEmpty, "Deferred Quit accepted root operation launch")
            workspace.confirmingQuit = false
            try await cleanup()
            print("PASS: originating Log preferences through Switch/Pull/Stash, Reset/Cleanup and Bisect, root Quit launch refusal, private owners and drained cleanup")
        } catch { let original = error; do { try await cleanup() } catch { throw Failure(message: "\(original); cleanup: \(error)") }; throw original }
    }
}
