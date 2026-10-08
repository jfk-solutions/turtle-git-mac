import AppKit
import SwiftUI
import TurtleGitCore

@main struct ActionLogVerification {
    @MainActor static func wait(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Action log receiver timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ActionLog.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress")
        let store = ActionLogStore(storageURL: root.appendingPathComponent("private/logfile.txt"))
        ProgressActionLog.install(store: store, preferences: prefs)
        let folder = root.appendingPathComponent("repository"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repo = GitRepository(root: folder, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Action log QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base".utf8).write(to: folder.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let plan = try await repo.prepareReset(to: head, mode: .mixed)
        let model = ResetProgressWindowModel(repository: repo, plan: plan, preferences: prefs)
        let controller = ResetProgressWindowController(model: model); controller.window?.contentViewController = nil
        defer { controller.close() }
        await model.run(); precondition(model.success && !model.busy && !store.exists)
        let displayed = model.output; controller.close()
        let saved = try store.read(); precondition(saved.contains(repo.root.path) && ActionLogStore.lines(saved).suffix(ActionLogStore.lines(displayed).count) == ActionLogStore.lines(displayed))
        model.saveActionLog(); let savedAgain = try store.read(); precondition(savedAgain == saved, "Double close must not duplicate the attempt")
        // A stale snapshot fails, Retry preserves the failure before clearing it.
        let stale = try await repo.prepareReset(to: head, mode: .soft)
        try Data("next".utf8).write(to: folder.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "next")
        let failed = ResetProgressWindowModel(repository: repo, plan: stale, preferences: prefs)
        let failedController = ResetProgressWindowController(model: failed); failedController.window?.contentViewController = nil
        defer { failedController.close() }
        await failed.run(); precondition(!failed.success && failed.postActions.contains(.retry)); let failureText = failed.output
        failed.perform(.retry); let afterRetry = try store.read(); precondition(afterRetry.contains(failureText))
        try await wait { !failed.busy }; failedController.close()
        let afterFailedClose = try store.read(); precondition(ActionLogStore.lines(afterFailedClose).filter { $0 == failureText }.count == 2)
        // Quiet successful operations still leave the date/repository header.
        let quiet = ResetProgressWindowModel(repository: repo, plan: try await repo.prepareReset(to: "HEAD", mode: .soft), preferences: prefs)
        let quietController = ResetProgressWindowController(model: quiet); quietController.window?.contentViewController = nil
        await quiet.run(); precondition(quiet.success && quiet.output.isEmpty); let beforeQuiet = try store.read(); quietController.close()
        let afterQuiet = try store.read(); precondition(afterQuiet != beforeQuiet)
        var shown: [URL] = []
        let settings = SavedDataSettingsModel(store: store, preferences: prefs, showFile: { shown.append($0); return true })
        precondition(settings.available && settings.maximumLines == "4000")
        for invalid in ["-1", "+1", "1.5", "4294967296", "", " 4"] { settings.maximumLines = invalid; precondition(!settings.valid); settings.apply(); precondition(prefs.object(forKey: "MaxLinesInLogfile") == nil) }
        settings.show(); precondition(shown == [store.storageURL])
        settings.maximumLines = "0"; settings.apply(); precondition(ActionLogStore.maximumLines(preferences: prefs) == 0)
        let old = try store.read(); ProgressActionLog.install(store: store, preferences: prefs); quiet.saveActionLog(); let afterDisabled = try store.read(); precondition(afterDisabled == old)
        settings.clear(); precondition(!settings.available && !store.exists && settings.error == nil)
        let host = NSHostingView(rootView: SavedDataSettingsPage()); host.frame = NSRect(x: 0, y: 0, width: 760, height: 700); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        // Logging failure leaves a completed Git result intact.
        let bad = root.appendingPathComponent("not-a-directory"); try Data().write(to: bad)
        ProgressActionLog.install(store: ActionLogStore(storageURL: bad.appendingPathComponent("logfile.txt")), preferences: prefs)
        prefs.set(4000, forKey: "MaxLinesInLogfile"); quiet.saveActionLog(); precondition(quiet.success)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); precondition(finalHead != head)
        print("PASS: native close/quiet output/Retry retention, Saved Data validation and Show/Clear, zero disable and write-failure isolation")
    }
}
