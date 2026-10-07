import AppKit
import TurtleGitCore

@main struct PushPreferencesVerification {
    @MainActor static func wait(_ model: PushWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Push timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.PushPreferences.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = root.appendingPathComponent("client"), bare = root.appendingPathComponent("remote.git"), second = root.appendingPathComponent("second.git")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        let repo = GitRepository(root: client, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await repo.run(["config", "user.name", "Preferences QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["clone", "--bare", client.path, bare.path]); _ = try await repo.run(["clone", "--bare", client.path, second.path])
        _ = try await repo.run(["remote", "add", "a-first", bare.path]); _ = try await repo.run(["remote", "add", "z-second", second.path])
        _ = try await repo.run(["config", "push.recurseSubmodules", "check"])
        let model = PushWindowModel(repository: repo, access: nil, preferences: preferences)
        model.load(); try await wait(model); precondition(model.options.submodules == .check && !model.options.allRemotes)
        model.options.remote = "a-first"; model.options.destination = "saved"; model.options.setUpstream = false; model.options.allRemotes = true; model.options.submodules = .onDemand
        model.push(); try await wait(model)
        model.load(); try await wait(model); precondition(model.options.allRemotes && model.options.submodules == .onDemand)
        let source = model.options.source
        preferences.set(true, forKey: "Push." + client.path + ".allBranches")
        model.load(source: source); try await wait(model); precondition(!model.options.allBranches && model.options.allRemotes)
        // A saved recursion choice outranks changed Git config; absent/invalid native values fall back.
        _ = try await repo.run(["config", "push.recurseSubmodules", "no"])
        model.load(); try await wait(model); precondition(model.options.submodules == .onDemand)
        preferences.set(99, forKey: model.submodulePreferenceKey); model.load(); try await wait(model); precondition(model.options.submodules == .none)
        preferences.removeObject(forKey: model.submodulePreferenceKey)
        preferences.set(false, forKey: "Push." + client.path + ".allBranches")
        model.load(); try await wait(model)
        // Validation failure does not persist changed option choices.
        let savedAll = preferences.object(forKey: "Push." + client.path + ".allRemotes") as? Bool
        model.options.allRemotes = false; model.options.remote = "a-first"; model.options.destination = "../invalid"; model.options.submodules = .check
        model.push(); try await wait(model, allowError: true)
        precondition(preferences.object(forKey: model.submodulePreferenceKey) == nil && preferences.object(forKey: "Push." + client.path + ".allRemotes") as? Bool == savedAll)
        // All-branches No remembers Yes for future submissions when suppression is checked, exactly as source.
        model.options.allBranches = true; model.options.allRemotes = true; model.options.destination = ""; model.options.submodules = .none
        var questions = 0
        model.confirmPush = { message, allBranches, deletion, choose in
            questions += 1; precondition(message == "Do you really want to push all local branches?" && allBranches && !deletion); choose(false, true)
        }
        _ = try await repo.run(["branch", "all-confirmed"])
        let refsBefore = try await GitRepository(root: bare, executable: git).checkoutReferences()
        model.push(); precondition(questions == 1 && !model.busy && preferences.bool(forKey: "PushAllBranches"))
        let refsAfter = try await GitRepository(root: bare, executable: git).checkoutReferences(); precondition(refsBefore.map(\.name) == refsAfter.map(\.name))
        model.confirmPush = { _, _, _, _ in preconditionFailure("Suppressed warning must not reopen") }
        model.push(); try await wait(model)
        let published = try await GitRepository(root: bare, executable: git).checkoutReferences()
        precondition(published.contains { $0.name == "refs/heads/all-confirmed" })
        // Suppression is global within app preferences, whereas option choices are repository-scoped.
        let other = PushWindowModel(repository: GitRepository(root: bare, executable: git), access: nil, preferences: preferences); other.load(); try await wait(other)
        precondition(!other.options.allRemotes && other.options.submodules == .none)
        _ = try await repo.run(["remote", "remove", "z-second"])
        model.load(); try await wait(model); precondition(!model.options.allRemotes)
        // Empty-source questions use the exact source text and deletion flag; No does no work.
        model.options.allBranches = false; model.options.source = ""; model.options.destination = "saved"
        model.confirmPush = { message, allBranches, deletion, choose in
            questions += 1; precondition(message == "The local branch/tag name is empty. This results in a remote removal.\nContinue?" && !allBranches && deletion); choose(false, false)
        }
        model.push(); precondition(!model.busy && model.confirmation == nil)
        model.options.destination = ""
        model.confirmPush = { message, allBranches, deletion, choose in
            questions += 1; precondition(message == "The local branch name and the remote branch name are empty.\nContinue?" && !allBranches && !deletion); choose(false, false)
        }
        model.push(); precondition(questions == 3 && !model.busy)
        // Construct real native alerts to check source button defaults/suppression without displaying sheets.
        let all = PushWindowController.submissionAlert(message: "all", allBranches: true, deletion: false)
        precondition(all.buttons.map(\.title) == ["Yes", "No"] && all.buttons[1].keyEquivalent == "\r" && all.showsSuppressionButton && all.suppressionButton?.title == "Don't show this message again")
        let removal = PushWindowController.submissionAlert(message: "delete", allBranches: false, deletion: true)
        precondition(removal.buttons[0].keyEquivalent == "\r" && !removal.showsSuppressionButton && removal.alertStyle == .warning)
        let empty = PushWindowController.submissionAlert(message: "empty", allBranches: false, deletion: false)
        precondition(empty.buttons[0].keyEquivalent == "\r" && !empty.showsSuppressionButton)
        for alert in [all, removal, empty] { alert.window.isReleasedWhenClosed = false; alert.window.close() }
        print("Push preferences: config/remembered recursion precedence, repository isolation, multi-remote restoration and single-remote fallback, explicit-source all-branch override, invalid-submission non-persistence; exact Yes/No questions and native default/suppression construction; No+remember cancels now and permits subsequent all-branch push passed")
    }
}
