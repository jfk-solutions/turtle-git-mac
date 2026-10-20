import AppKit
import Darwin
import TurtleGitCore

struct ImportPatchLifecycleVerification {
    @MainActor static func wait(_ predicate: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Import lifecycle fixture did not settle at line \(line)")
    }
    @MainActor static func run(root: URL, git: URL) async throws {
        let suite = "TurtleGit.ImportLifecycle." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        for accepted in [true, false] {
            print("START: Import accepted close \(accepted)"); fflush(stdout)
            let directory = root.appendingPathComponent(accepted ? "accepted-close" : "cancelled-close")
            let (repo, files) = try await ImportPatchVerification.fixture(directory, git)
            let owner = ImportPatchWindowController(repository: repo, access: nil, preferences: preferences)
            owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
            var closed = 0; owner.onClosed = { closed += 1 }
            owner.model.add(files); owner.model.apply()
            try await wait { !owner.model.busy }
            print("APPLIED: finished=\(owner.model.finished) error=\(String(describing: owner.model.error))"); fflush(stdout)
            precondition(owner.model.finished && owner.model.error == nil)
            if accepted { owner.model.apply() } else { owner.model.requestClose() }
            print("CLOSE: busy=\(owner.model.busy) closing=\(owner.model.closing) editable=\(owner.model.editable) sheet=\(String(describing: owner.window!.attachedSheet))"); fflush(stdout)
            try await wait { owner.model.closed && owner.presentationClosed }
            precondition(owner.model.accepted == accepted && !owner.model.closing && !owner.model.busy && closed == 1)
            owner.model.apply(); owner.model.requestClose(); precondition(closed == 1)
        }
        print("PASS: Import Patch real completed batches distinguish final OK from Cancel, close once and reject closed-owner actions")
        for phase in ["identity", "apply", "recovery", "close-read"] {
            print("START: Import forced \(phase)"); fflush(stdout)
            let directory = root.appendingPathComponent("blocked-" + phase)
            let (original, files) = try await ImportPatchVerification.fixture(directory, git, conflict: phase == "recovery")
            if phase == "recovery" {
                do { _ = try await original.importMailPatch(files[0]); preconditionFailure("Expected conflict") } catch is GitFailure {}
            }
            let head = try await original.run(["rev-parse", "HEAD"]).stdout, refs = try await original.run(["show-ref"]).stdout
            let index = try Data(contentsOf: directory.appendingPathComponent(".git/index")), config = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
            let shim = directory.appendingPathComponent("lifecycle-git"), marker = directory.appendingPathComponent("lifecycle-pid")
            let command = phase == "identity" ? "config" : phase == "close-read" ? "rev-parse" : "am"
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            let environment = GitRuntime.environment(executable: git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
            let script = "#!/bin/sh\n" + environment + "\nfor argument; do\nif [ \"$argument\" = " + quote(command) + " ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nexec " + quote(git.path) + " \"$@\"\n"
            try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            let repo = GitRepository(root: directory, executable: shim)
            let owner = ImportPatchWindowController(repository: repo, access: nil, preferences: preferences)
            owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
            let model = owner.model; var changes = 0, closeReplies = 0, unavailable = 0
            model.onChanged = { _ in changes += 1 }; model.close = { closeReplies += 1 }
            model.chooseUnavailableClose = { _ in unavailable += 1; return true }
            model.chooseRecovery = { .abort }; model.add([files[0]])
            if phase == "close-read" { model.requestClose() } else { model.apply() }
            try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            let output = model.output; owner.close()
            try await wait { kill(pid, 0) == -1 }
            try await wait { kill(-pid, 0) == -1 && errno == ESRCH }
            let groupState = kill(-pid, 0), groupError = errno
            precondition(groupState == -1 && groupError == ESRCH)
            let state = kill(pid, 0), processError = errno
            precondition(state == -1 && processError == ESRCH && model.closed && !model.busy && !model.closing && model.activeCancellation == nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            precondition(changes == 0 && closeReplies == 0 && unavailable == 0 && model.output == output && model.error == nil && !model.accepted)
            let finalHead = try await original.run(["rev-parse", "HEAD"]).stdout, finalRefs = try await original.run(["show-ref"]).stdout
            let finalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
            precondition(finalHead == head && finalRefs == refs && finalIndex == index && finalConfig == config)
            if phase == "recovery" { let session = try await original.mailPatchSession(); precondition(session == .applying) }
            print("PASS: Import Patch forced " + phase + " closure reaps Git and its process group, preserves repository/session state and suppresses late replies")
        }
        let (repo, files) = try await ImportPatchVerification.fixture(root.appendingPathComponent("late-viewers"), git)
        for review in [false, true] {
            let model = ImportPatchWindowModel(repository: repo, access: nil, preferences: preferences)
            var opened = 0; model.showPatch = { _, _, _ in opened += 1 }; model.showReview = { _, _, _ in opened += 1 }
            model.add(files); let ids = Set([model.items[0].id])
            if review { model.reviewPatch(ids) } else { model.viewPatch(ids, alternate: false) }
            model.invalidate(); try await Task.sleep(nanoseconds: 100_000_000)
            precondition(model.closed && !model.openingViewer && opened == 0 && model.error == nil)
        }
        print("PASS: Import Patch forced closure suppresses delayed patch/review viewer handoffs")
    }
}
