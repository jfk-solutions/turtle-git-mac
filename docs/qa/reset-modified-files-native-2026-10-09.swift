import AppKit
import TurtleGitCore

@main struct ResetModifiedFilesVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reset Compare QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let unusual = "changed\t雪\n.txt"
        func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: root.appendingPathComponent(name)) }
        for name in ["mixed", "staged", "unstaged", "deleted", unusual] { try write(name, "base\n") }
        try await repo.stage(["."]); _ = try await repo.commit(message: "base")
        let earlier = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try write("committed-only", "already committed\n"); try await repo.stage(["committed-only"]); _ = try await repo.commit(message: "HEAD")
        try write("mixed", "index\n"); try write("staged", "index\n"); try write("added", "new tracked\n")
        try await repo.stage(["mixed", "staged", "added"]); _ = try await repo.run(["rm", "deleted"])
        try write("mixed", "working\n"); try write("unstaged", "working\n"); try write(unusual, "working\n"); try write("untracked", "not tracked\n")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let tree = try await repo.run(["write-tree"]).text
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let tracked = ["mixed", "staged", "unstaged", "added", unusual, "committed-only", "untracked"]
        let bytes = try tracked.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let owner = ResetWindowController(repository: repo, access: nil, revision: earlier)
        defer { owner.close() }
        owner.model.load(); try await wait { !owner.model.busy && !owner.model.chooser.busy }
        try require(owner.model.chooser.revision == earlier, "Reset revision preset changed")
        let delegate = TurtleGitApplicationDelegate()
        var presentations = 0, configured = 0, logs = 0, fileLogs: [String] = []
        owner.presentModifiedComparison = { [weak owner] parent, child in
            presentations += 1
            parent.makeFirstResponder(nil)
            return parent === owner?.window && child !== parent && !parent.isVisible && !child.isVisible
        }
        owner.configureModifiedComparison = { model in
            configured += 1
            model.onLog = { hash in if hash == nil { logs += 1 } }
            model.onFileLog = { path, hash in if hash == nil { fileLogs.append(path) } }
        }
        owner.model.showModifiedFiles()
        guard let first = owner.modifiedComparison else { throw Failure(description: "Owned comparison missing") }
        try await wait { !first.model.busy && first.model.snapshot != nil }
        try require(first.model.error == nil && first.model.from == "HEAD" && first.model.to == "Working tree", "Wrong comparison endpoints")
        try require(first.model.snapshot?.from == .revision(head) && first.model.snapshot?.to == .workingTree, "Preview did not resolve HEAD")
        let expected = Set(["mixed", "staged", "unstaged", "added", "deleted", unusual])
        try require(Set(first.model.visibleFiles.map(\.path)) == expected, "Staged/unstaged path list differs")
        try require(owner.model.showingModifiedFiles && !owner.windowShouldClose(owner.window!), "Parent not locked")
        try require(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Quit bypassed preview lock")
        owner.model.showModifiedFiles(); owner.model.reset()
        let plan = try await repo.prepareReset(to: earlier, mode: .mixed); owner.model.apply(plan)
        try require(presentations == 1 && configured == 1 && owner.model.progress == nil && !owner.model.busy, "Duplicate preview or Reset escaped modal gate")
        try require(owner.model.chooser.revision == earlier, "Preview replaced selected Reset revision")
        first.model.log(); first.model.logFiles([unusual]); try require(logs == 1 && fileLogs == [unusual], "Comparison interactions not configured")
        let staleClose = first.onClosed
        first.close()
        try require(owner.modifiedComparison == nil && !owner.model.showingModifiedFiles, "Child close did not release parent")
        try require(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "Idle Reset blocked Quit after child release")
        owner.model.showModifiedFiles()
        guard let second = owner.modifiedComparison else { throw Failure(description: "Reopen missing") }
        try await wait { !second.model.busy && second.model.snapshot != nil }
        staleClose()
        try require(owner.modifiedComparison === second && owner.model.showingModifiedFiles, "Stale child close released newer preview")
        second.close()
        var rejected: RevisionComparisonWindowModel?
        owner.configureModifiedComparison = { rejected = $0 }
        owner.presentModifiedComparison = { _, _ in false }; owner.model.showModifiedFiles()
        if let rejected { try await wait { !rejected.busy } }
        try require(owner.modifiedComparison == nil && !owner.model.showingModifiedFiles, "Rejected presentation retained modal lock")
        owner.configureModifiedComparison = { _ in }
        owner.model.bare = true; owner.model.showModifiedFiles(); try require(owner.modifiedComparison == nil, "Bare preview allowed")
        owner.model.bare = false; owner.model.busy = true; owner.model.showModifiedFiles(); try require(owner.modifiedComparison == nil, "Busy preview allowed"); owner.model.busy = false
        owner.presentModifiedComparison = { parent, _ in parent.makeFirstResponder(nil); return true }; owner.model.showModifiedFiles()
        guard let final = owner.modifiedComparison else { throw Failure(description: "Final preview missing") }
        try await wait { !final.model.busy }
        owner.close(); try require(owner.modifiedComparison == nil && !owner.model.showingModifiedFiles, "Forced parent close leaked child")
        owner.model.showModifiedFiles(); try require(owner.modifiedComparison == nil, "Closed parent reopened child")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let afterTree = try await repo.run(["write-tree"]).text
        try require(afterHead == head && afterTree == tree && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Preview changed HEAD, staged tree or config")
        for (index, name) in tracked.enumerated() { try require(bytes[index] == Data(contentsOf: root.appendingPathComponent(name)), "Preview changed working bytes") }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted").path), "Preview restored deleted file")
        print("PASS: Reset-owned HEAD/working-tree preview; staged/unstaged/add/delete/Unicode paths, untracked and earlier-only exclusions; parent reset/apply/close/Quit and duplicate gates; Log/file callbacks; close/reopen/stale/failure/bare/busy/forced-close cleanup; unchanged HEAD/staged tree/config/working bytes. Presenter injected; no windows displayed or main app launched.")
    }
}
