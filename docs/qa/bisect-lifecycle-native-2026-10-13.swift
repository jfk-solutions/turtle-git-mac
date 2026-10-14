import AppKit
import Darwin
import TurtleGitCore

@main struct BisectLifecycleVerification {
    @MainActor static var owned: [BisectWindowModel] = []
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            for model in owned { model.retire() }
            for _ in 0..<1000 {
                if BisectWindowModel.activeOperations == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            print("FAIL Bisect lifecycle: \(error)"); exit(1)
        }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let real = GitRepository(root: root, executable: engine, askpass: nil)
        _ = try await real.run(["init", "-b", "main"])
        _ = try await real.run(["config", "user.name", "Bisect fixture"])
        _ = try await real.run(["config", "user.email", "bisect@example.invalid"])
        var hashes: [String] = []
        for number in 0..<6 {
            try Data("\(number)\n".utf8).write(to: root.appendingPathComponent("change"))
            try await real.stage(["change"]); _ = try await real.commit(message: "step \(number)")
            hashes.append(try await real.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        func wrapper(_ gate: String, _ marker: String) throws -> GitRepository {
            let file = root.appendingPathComponent(marker + "-git")
            let executable = "'" + engine.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = "#!/bin/sh\ncase \" $* \" in *' \(gate) '*) echo $$ > \"$3/\(marker)\"; /bin/sleep 30;; esac\nexec \(executable) \"$@\"\n"
            try Data(script.utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return GitRepository(root: root, executable: file, askpass: nil)
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw NSError(domain: "Bisect fixture timeout", code: 1)
        }
        func gone(_ marker: String) throws {
            let pid = Int32(try String(contentsOf: root.appendingPathComponent(marker)).trimmingCharacters(in: .whitespacesAndNewlines))!
            precondition(kill(pid, 0) == -1 && errno == ESRCH)
        }
        let loading = BisectWindowModel(repository: try wrapper("--is-bare-repository", "load-pid"), access: nil)
        owned.append(loading)
        loading.load(); try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("load-pid").path) }
        precondition(loading.busy && BisectWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        loading.retire(); try await wait { !loading.busy }
        precondition(loading.retired && loading.choices.isEmpty && loading.state == nil && loading.error == nil && BisectWindowModel.activeOperations == 0); try gone("load-pid")

        let repository = try wrapper("bisect good", "good-pid")
        let model = BisectWindowModel(repository: repository, access: nil)
        owned.append(model)
        model.load(good: hashes[0], bad: "HEAD"); try await wait { !model.busy }
        precondition(model.canStart); model.hasPicker = true; precondition(!model.canStart); model.hasPicker = false
        model.start(); try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("good-pid").path) }
        precondition(BisectWindowModel.activeOperations == 1); model.cancel(); precondition(model.cancelling && model.busy)
        try await wait { !model.busy }; try gone("good-pid")
        precondition(model.state?.active == true && model.lastExitCode == 1 && model.canPerform(.reset) && !model.canPerform(.good))
        model.perform(.reset); try await wait { !model.busy }
        precondition(model.state?.active == false && model.lastExitCode == 0 && model.state?.head == hashes.last)

        try FileManager.default.removeItem(at: root.appendingPathComponent("good-pid"))
        let retired = BisectWindowModel(repository: repository, access: nil)
        owned.append(retired)
        retired.load(good: hashes[0], bad: "HEAD"); try await wait { !retired.busy }
        var callbacks = 0; retired.onChanged = { _ in callbacks += 1 }; retired.onProgress = { callbacks += 1 }
        retired.start(); try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("good-pid").path) }
        let callbacksBeforeRetirement=callbacks
        retired.retire(); try await wait { !retired.busy }; try gone("good-pid")
        precondition(callbacks == callbacksBeforeRetirement && retired.state?.active == false && !retired.canStart && !retired.canPerform(.reset))
        _ = try await real.bisect(.reset)

        try Data("dirty tracked\n".utf8).write(to: root.appendingPathComponent("change"))
        let stash = BisectWindowModel(repository: real, access: nil)
        owned.append(stash)
        stash.load(good: hashes[0], bad: "HEAD"); try await wait { !stash.busy }
        var reply: ((Bool) -> Void)?
        stash.confirmStash = { await withCheckedContinuation { continuation in reply = { continuation.resume(returning: $0) } } }
        stash.cancelPrompt = { let answer = reply; reply = nil; answer?(false) }
        stash.start(); try await wait { reply != nil }; stash.retire(); try await wait { !stash.busy }
        let dirty = try Data(contentsOf: root.appendingPathComponent("change"))
        precondition(dirty == Data("dirty tracked\n".utf8))
        let stashes = try await real.run(["stash", "list"]).text
        precondition(stashes.isEmpty && BisectWindowModel.activeOperations == 0)
        precondition(!NSApp.windows.contains { $0.isVisible })
        print("PASS Bisect family: cancellable live reads/Start and Reset recovery, owned PID reaping, Quit accounting, picker gate, forced-retirement late-result fences and cancelled stash decision preserving tracked bytes")
    }
}
