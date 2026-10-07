import AppKit
import Foundation
import TurtleGitCore

@main struct CleanNativeVerification {
    @MainActor static func wait(_ model: CleanProgressWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy, "Clean timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Clean QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("tracked\n".utf8).write(to: root.appendingPathComponent("tracked"))
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("anchor\n".utf8).write(to: folder.appendingPathComponent("anchor"))
        _ = try await repo.run(["add", "."]); _ = try await repo.run(["commit", "-m", "Initial"])
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked")); _ = try await repo.run(["add", "tracked"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("tracked"))
        let metadata = [".git/index", ".git/config", ".git/HEAD", "tracked", "folder/anchor"]
        let before = try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Clean.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CleanWindowController(repository: repo, defaults: defaults)
        defer { controller.close() }
        let model = controller.model
        precondition(model.options == CleanOptions() && !model.dryRun && !model.submodules && !model.permanently)
        model.options.unmanagedRepositories = true; model.options.directories = false
        precondition(!model.options.unmanagedRepositories)
        model.options.type = .ignored; model.dryRun = true; model.submodules = true
        var request: CleanDialogRequest?
        model.onAccepted = { request = $0 }; model.close = {}
        model.setScope(["../outside"]); model.accept()
        precondition(request == nil && defaults.persistentDomain(forName: suite) == nil)
        model.error = nil
        try Data("untracked\n".utf8).write(to: folder.appendingPathComponent("new"))
        model.setScope(["folder/new", "folder/"])
        let scopes = try model.directoryScopes(); precondition(scopes == ["folder"])
        model.setScope(["tracked"]); let whole = try model.directoryScopes(); precondition(whole.isEmpty)
        model.setScope(["folder"]); model.accept()
        precondition(request?.paths == ["folder"] && request?.dryRun == true && request?.submodules == true)
        let reopened = CleanWindowModel(repository: repo, defaults: defaults)
        precondition(reopened.options.type == .ignored && !reopened.options.directories && !reopened.dryRun && !reopened.submodules && !reopened.permanently)
        defaults.set(false, forKey: "RevertWithRecycleBin")
        precondition(CleanWindowModel(repository: repo, defaults: defaults).permanently)
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent("ignored"))
        let previewRequest = CleanDialogRequest(options: CleanOptions(type: .nonIgnored), paths: ["folder"], dryRun: true, submodules: false, permanently: false)
        let progress = CleanProgressWindowController(repository: repo, access: nil, request: previewRequest)
        defer { progress.close() }
        progress.model.start(); try await wait(progress.model)
        precondition(progress.model.previewSucceeded && !progress.model.failed && FileManager.default.fileExists(atPath: folder.appendingPathComponent("new").path))
        precondition(progress.model.output.contains("folder/new"))
        progress.model.remove(permanently: true); try await wait(progress.model)
        precondition(!progress.model.failed && !progress.model.previewSucceeded && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("new").path))
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("ignored").path))
        // Foreign index locks fail without removal; Retry obtains a fresh plan.
        try Data("retry\n".utf8).write(to: folder.appendingPathComponent("retry"))
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data("owned by another operation".utf8).write(to: lock)
        let execute = CleanDialogRequest(options: CleanOptions(type: .nonIgnored), paths: ["folder"], dryRun: false, submodules: false, permanently: true)
        let retry = CleanProgressWindowModel(repository: repo, access: nil, request: execute)
        retry.start(); try await wait(retry)
        precondition(retry.failed && FileManager.default.fileExists(atPath: folder.appendingPathComponent("retry").path))
        let lockBytes = try Data(contentsOf: lock); precondition(lockBytes == Data("owned by another operation".utf8))
        try FileManager.default.removeItem(at: lock); retry.retry(); try await wait(retry)
        precondition(!retry.failed && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("retry").path))
        // Default action genuinely moves bytes to Trash. Remove only owned QA copies.
        try Data("trash bytes\n".utf8).write(to: folder.appendingPathComponent("trash"))
        let trash = CleanProgressWindowModel(repository: repo, access: nil, request: CleanDialogRequest(options: CleanOptions(type: .nonIgnored), paths: ["folder"], dryRun: false, submodules: false, permanently: false))
        trash.start(); try await wait(trash)
        precondition(!trash.failed && trash.trashedFiles.count == 1)
        for url in trash.trashedFiles { let bytes = try Data(contentsOf: url); precondition(bytes == Data("trash bytes\n".utf8)); try FileManager.default.removeItem(at: url) }
        try Data("cancel\n".utf8).write(to: folder.appendingPathComponent("cancel"))
        let cancel = CleanProgressWindowModel(repository: repo, access: nil, request: execute)
        cancel.start(); cancel.cancel(); try await wait(cancel)
        precondition(cancel.failed && cancel.current == "Cancelled" && FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancel").path))
        let after = try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        precondition(MenuIcon.clean.image() != nil)
        print("Native Clean: defaults, persistence, scopes, dry run, permanent action, real Trash, lock/Retry, cancellation and tracked state passed")
    }
}
