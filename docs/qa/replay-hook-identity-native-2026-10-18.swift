// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum ReplayHookIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func verify() async throws {
        func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
        func phase(_ name: String) { fputs("Replay hook identity phase: \(name)\n", stderr); fflush(stderr) }
        func wait(_ condition: () -> Bool, diagnostic: () -> String = { "" }) async throws { for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "Replay identity ownership did not settle. " + diagnostic()) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ReplayIdentity.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "ConfirmKillProcess")
        defer { preferences.removePersistentDomain(forName: suite); ClientHookProcessPool.shared.cancelAll() }
        func fixture(_ name: String) async throws -> (GitRepository, RebaseWindowModel) {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let repository = GitRepository(root: path, executable: git)
            _ = try await repository.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Replay identity QA"), ("user.email", "qa@example.invalid"), ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false")] { _ = try await repository.run(["config", key, value]) }
            try Data("base\n".utf8).write(to: path.appendingPathComponent("file")); try await repository.stage(["file"]); _ = try await repository.commit(message: "base")
            _ = try await repository.run(["checkout", "-b", "topic"])
            try Data("topic\n".utf8).write(to: path.appendingPathComponent("topic")); try await repository.stage(["topic"]); _ = try await repository.commit(message: "topic")
            let model = RebaseWindowModel(repository: repository, access: nil, messageDefaults: preferences)
            model.options.branch = "topic"; model.options.upstream = "main"; model.options.force = true
            model.plan = try await repository.rebasePlan(model.options); model.editorExecutable = git
            model.readReplayIdentity = { try await repository.replayUserIdentity(environment: [:], cancellation: $0) }
            model.clientHooks.continueAfterFailure = { _ in false }
            return (repository, model)
        }
        let script = root.appendingPathComponent("pre-rebase.sh")
        try Data("printf '%s|%s' \"$1\" \"$2\" > \"$4/hook-args\"\nexit 9\n".utf8).write(to: script)
        func install(_ repository: GitRepository) throws {
            let hook = ClientHook(type: .preRebase, path: repository.root.path, command: "/bin/sh '" + script.path + "'", show: false)
            preferences.set(try ClientHookConfiguration.serialize([hook]), forKey: "hooks")
        }
        phase("autostash then missing-identity refusal")
        let (repository, model) = try await fixture("repair")
        defer { model.retire() }
        try install(repository)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        _ = try await repository.run(["config", "--local", "rebase.autostash", "true"])
        // Simulate configuration changing after successful stash creation. Git
        // stash itself needs identity; removing it earlier would fail at stash.
        var firstIdentityRead = true
        model.readReplayIdentity = { token in
            if firstIdentityRead { firstIdentityRead = false; _ = try await repository.run(["config", "--local", "user.name", ""], cancellation: token) }
            return try await repository.replayUserIdentity(environment: [:], cancellation: token)
        }
        try Data("dirty\n".utf8).write(to: repository.root.appendingPathComponent("file"))
        var offers = 0
        model.repairReplayIdentity = { offers += 1; return false }
        model.execute("start"); try await wait { !model.busy }
        try require(offers == 1 && !FileManager.default.fileExists(atPath: repository.root.appendingPathComponent("hook-args").path), "Missing identity ran pre-rebase script or skipped repair")
        try require(model.hasReplayStash, "Source identity preflight did not retain the earlier autostash")
        try require(try Data(contentsOf: repository.root.appendingPathComponent("file")) == Data("base\n".utf8), "Identity preflight ran before the source stash boundary")
        phase("repeated Settings repair then actual failed pre-rebase hook")
        var repaired = 0
        model.repairReplayIdentity = {
            repaired += 1
            if repaired == 2 { _ = try? await repository.run(["config", "--local", "user.name", "Repaired name"]) }
            return true
        }
        model.execute("start"); try await wait { !model.busy }
        try require(repaired == 2, "Settings return was trusted without rereading/reoffering incomplete identity")
        try require(model.error?.contains("Pre-rebase hook failed") == true, "Repaired identity did not reach the existing owned hook")
        try require(try String(contentsOf: repository.root.appendingPathComponent("hook-args"), encoding: .utf8) == "main|topic", "Preflight altered captured hook arguments")
        let afterRepair = try await repository.run(["rev-parse", "HEAD"]).stdout
        try require(afterRepair == head, "Failed hook changed replay history")

        phase("held identity read retirement and actual Quit accounting")
        let (heldRepository, heldModel) = try await fixture("held-read")
        defer { heldModel.retire() }
        try install(heldRepository)
        var held: CheckedContinuation<ReplayUserIdentity, Error>?, readToken: OperationCancellation?
        defer { held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil }
        heldModel.readReplayIdentity = { token in readToken = token; return try await withCheckedThrowingContinuation { held = $0 } }
        let beforeActive = RebaseWindowModel.activeReplayOperations
        heldModel.execute("start"); try await wait { held != nil }
        heldModel.retire()
        try require(readToken?.isCancelled == true && RebaseWindowModel.activeReplayOperations == beforeActive + 1, "Retired preflight lost its actual pending read/Quit ownership")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Application Quit ignored the actual pending replay identity read")
        let late = held; held = nil; late?.resume(returning: ReplayUserIdentity(authorName: "late", authorEmail: "late", committerName: "late", committerEmail: "late"))
        try await wait { RebaseWindowModel.activeReplayOperations == beforeActive }
        try require(!FileManager.default.fileExists(atPath: heldRepository.root.appendingPathComponent("hook-args").path), "Retired identity read started a hook")

        phase("owned native Git Settings initial presentation")
        let controller = RebaseWindowController(repository: heldRepository, access: nil, preferences: preferences)
        defer { controller.close() }
        controller.window?.alphaValue = 0
        controller.showWindow(nil)
        var settingsCompleted = false, forcedCompleted = false, okCompleted = false, cancelCompleted = false
        let settings = Task { @MainActor in let result = await controller.showReplayIdentitySettings(); settingsCompleted = true; return result }
        try await wait { controller.replayIdentitySettingsWindow?.sheetParent === controller.window }
        try require(controller.replayIdentityNavigation?.selected == .git && controller.model.hasReplayQuestion && controller.replayIdentitySettingsWindow?.alphaValue == 0, "Identity Settings did not own the Git page, private presentation and replay question")
        try await wait { controller.replayIdentityNavigation?.canDismiss == true }
        func settingsState() -> String {
            let child = controller.replayIdentitySettingsWindow
            return "child=\(String(describing: child)), visible=\(child?.isVisible == true), sheetParent=\(String(describing: child?.sheetParent)), style=\(child?.styleMask.rawValue ?? 0), closeEnabled=\(child?.standardWindowButton(.closeButton)?.isEnabled == true), delegate=\(String(describing: child?.delegate)), canDismiss=\(controller.replayIdentityNavigation?.canDismiss == true), question=\(controller.model.hasReplayQuestion), retired=\(controller.model.retired), initialTaskCompleted=\(settingsCompleted), forcedTaskCompleted=\(forcedCompleted), okTaskCompleted=\(okCompleted), cancelTaskCompleted=\(cancelCompleted)"
        }
        phase("native Settings performClose: " + settingsState())
        controller.replayIdentitySettingsWindow?.performClose(nil)
        try await wait({ controller.replayIdentitySettingsWindow == nil && controller.window?.attachedSheet == nil && settingsCompleted }, diagnostic: settingsState)
        phase("native Settings closure released its owner")
        let accepted = await settings.value
        try require(accepted && controller.replayIdentitySettingsWindow == nil && !controller.model.hasReplayQuestion, "Closing owned Settings did not release its one-shot handoff")
        func footerButton(_ title: String, navigation: SettingsNavigationController) throws -> NSButton {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == title, button.target === navigation { return button }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let button = find(navigation.view), button.action != nil else { throw Failure(description: "Actual Settings footer button missing: " + title) }
            return button
        }
        phase("native Settings OK footer and held transaction close refusal")
        let okSettings = Task { @MainActor in let result = await controller.showReplayIdentitySettings(); okCompleted = true; return result }
        try await wait { controller.replayIdentitySettingsWindow?.sheetParent === controller.window }
        guard let okNavigation = controller.replayIdentityNavigation else { throw Failure(description: "Git Settings navigation missing for OK") }
        try await wait { okNavigation.canDismiss }
        var applyReply: CheckedContinuation<Bool, Never>?
        defer { applyReply?.resume(returning: false); applyReply = nil }
        okNavigation.transaction.register("qa-held-save", participant: .init(page: .git, modified: { true }, validate: { nil }, apply: { await withCheckedContinuation { applyReply = $0 } }, cancel: {}))
        let okButton = try footerButton("OK", navigation: okNavigation)
        try require(NSApp.sendAction(okButton.action!, to: okButton.target, from: okButton), "Actual Settings OK action was not dispatched")
        try await wait { applyReply != nil && okNavigation.transaction.busy }
        let heldSheet = controller.replayIdentitySettingsWindow
        heldSheet?.performClose(nil)
        let busyCancel = try footerButton("Cancel", navigation: okNavigation)
        _ = NSApp.sendAction(busyCancel.action!, to: busyCancel.target, from: busyCancel)
        try require(controller.replayIdentitySettingsWindow === heldSheet && !okCompleted && !okNavigation.canDismiss, "Busy Settings accepted Close/Cancel before its actual save returned")
        let apply = applyReply; applyReply = nil; apply?.resume(returning: true)
        try await wait({ controller.replayIdentitySettingsWindow == nil && controller.window?.attachedSheet == nil && okCompleted }, diagnostic: settingsState)
        let okAccepted = await okSettings.value
        try require(okAccepted, "Actual Settings OK failed to release its owned handoff")

        phase("native Settings Cancel footer")
        let cancelSettings = Task { @MainActor in let result = await controller.showReplayIdentitySettings(); cancelCompleted = true; return result }
        try await wait { controller.replayIdentitySettingsWindow?.sheetParent === controller.window }
        guard let cancelNavigation = controller.replayIdentityNavigation else { throw Failure(description: "Git Settings navigation missing for Cancel") }
        try await wait { cancelNavigation.canDismiss }
        let cancelButton = try footerButton("Cancel", navigation: cancelNavigation)
        try require(NSApp.sendAction(cancelButton.action!, to: cancelButton.target, from: cancelButton), "Actual Settings Cancel action was not dispatched")
        try await wait({ controller.replayIdentitySettingsWindow == nil && controller.window?.attachedSheet == nil && cancelCompleted }, diagnostic: settingsState)
        let cancelAccepted = await cancelSettings.value
        try require(cancelAccepted, "Actual Settings Cancel failed to release its owned handoff")

        phase("native Settings second presentation for forced owner retirement")
        let forced = Task { @MainActor in let result = await controller.showReplayIdentitySettings(); forcedCompleted = true; return result }
        try await wait { controller.replayIdentitySettingsWindow?.sheetParent === controller.window }
        phase("forced Rebase owner close: " + settingsState())
        controller.close()
        try await wait({ controller.replayIdentitySettingsWindow == nil && controller.window?.attachedSheet == nil && forcedCompleted }, diagnostic: settingsState)
        phase("forced owner closure released Settings")
        let retired = await forced.value
        try require(!retired && controller.replayIdentitySettingsWindow == nil, "Owner close accepted late identity settings")
        try await wait { ClientHookProcessPool.shared.activeScripts == 0 }
        phase("all owned reads, scripts and windows drained")
        print("PASS: source autostash/identity/hook order, incomplete Settings retry, original hook arguments, owned native Git Settings and retired preflight drain")
    }
}
