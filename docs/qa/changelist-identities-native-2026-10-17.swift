import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct ChangelistIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Changelist wait at \(line)")
    }
    @MainActor static func ready(_ model: CommitWindowModel) async throws {
        try await wait { !model.busy && CommitWindowModel.activeFileOperations == 0 && CommitWindowModel.activeReloads == 0 }
    }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_CHANGELIST_CAPTURE"] else { return }
        if #available(macOS 14.4, *) {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"), (.darkAqua,"dark")] {
                window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let own = all.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Owned changelist window absent") }
                let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
                config.showsCursor = false; config.includeChildWindows = false
                let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                try NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + "-changelists-" + suffix + ".png"))
            }; window.alphaValue = 0
        } else { throw Failure(description: "Changelist capture requires macOS 14.4") }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.windows.forEach { $0.close() } }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for path in ["one","two","three"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["one","two","three"]); _ = try await repo.commit(message: "base")
        for path in ["one","two","three"] { try Data("working\n".utf8).write(to: root.appendingPathComponent(path)) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse","HEAD"]).stdout
        let first = "réview", second = "re\u{301}view"
        _ = try await repo.assignChangelist(paths: ["one"], name: first)
        _ = try await repo.assignChangelist(paths: ["two"], name: second)
        let name = "TurtleGit.Changelists." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "Commit.SkipCancelConfirmation"); defaults.set(false, forKey: "Commit.KeepChangelists")
        defer { defaults.removePersistentDomain(forName: name) }
        let commit = CommitWindowController(repository: repo, access: nil, defaults: defaults), model = commit.model
        commit.window?.alphaValue = 0; commit.window?.orderFront(nil); model.reload(); try await ready(model)
        try require(model.error == nil && model.changelists.nameIdentities.count == 2, "Commit lost canonical names")
        let groups = StatusListGroups.rows(entries: model.visibleEntries, changelists: model.changelists)
        try require(Set(groups.map(\.id)).count == groups.count, "Commit group row IDs collide")
        try require(StatusListGroups.files(in: .changelist(first), rows: groups).map(\.path) == ["one"], "First group membership")
        try require(StatusListGroups.files(in: .changelist(second), rows: groups).map(\.path) == ["two"], "Second group membership")
        try require(changelistNameHelp(GitReferenceName(first), names: model.changelists.nameIdentities).contains("C3 A9"), "Ambiguous name help omitted bytes")
        let generation = model.fileMenu(["one"]).generation
        var changed = model.changelists
        changed.exactAssignments["one"] = GitReferenceName(second)
        model.changelists = changed
        try require(model.fileMenu(["one"]).generation != generation, "Canonical-only membership change retained old Commit menus")
        model.reload(); try await ready(model)
        let third = model.entries.first { $0.path == "three" }!
        model.newChangelist([third]); model.changelistName = second; model.createChangelist(); try await ready(model)
        let saved = try await repo.changelists()
        try require(saved.nameIdentities.count == 2 && GitReferenceName.equal(saved.name(for: "three")!, second), "Commit assigned wrong exact name")
        let metadata = root.appendingPathComponent(".git/turtlegit-changelists.json"), beforeCancel = try Data(contentsOf: metadata)
        model.newChangelist([third]); model.changelistName = "Cancelled"; model.cancelChangelist()
        try require(try Data(contentsOf: metadata) == beforeCancel, "Cancelled draft wrote metadata")
        try await capture(commit.window!, name: "commit")

        let status = StatusWindowController(repository: repo, access: nil, defaults: defaults), tree = status.model
        status.window?.alphaValue = 0; status.window?.orderFront(nil); tree.reload()
        try await wait { !tree.busy && StatusWindowModel.activeOperations == 0 }
        try require(tree.error == nil && tree.changelists.nameIdentities.count == 2, "Working Tree lost exact names")
        tree.selectGroup(.changelist(first)); try require(tree.selection == ["one"], "First exact group selected another name")
        tree.selectGroup(.changelist(second)); try require(tree.selection == ["two","three"], "Second exact group selected another name")
        try require(Set(tree.tableRows.map(\.id)).count == tree.tableRows.count, "Working Tree group IDs collide")
        try await capture(status.window!, name: "working-tree")
        tree.assignChangelist(tree.fileMenu(["two"]), name: first)
        try await wait { !tree.busy && StatusWindowModel.activeOperations == 0 }
        try require(GitReferenceName.equal(tree.changelists.name(for: "two")!, first) && GitReferenceName.equal(tree.changelists.name(for: "three")!, second), "Working Tree move merged canonical names")
        let unchangedHead = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && unchangedHead == head, "Membership changed Git state")
        status.close()
        model.reload(); try await ready(model)
        model.onCommitProgress = nil
        model.checked = ["one"]; model.message = "Selected changelist commit"; model.commit()
        try await wait { !model.busy && CommitWindowModel.activeFileOperations == 0 && CommitWindowModel.activeReloads == 0 }
        try require(model.error == nil, "Commit/pruning failed: \(model.error ?? "")")
        let after = try await repo.changelists()
        try require(after.name(for: "one") == nil && GitReferenceName.equal(after.name(for: "two")!, first) && GitReferenceName.equal(after.name(for: "three")!, second), "Commit cleanup lost exact unchecked names")
        let committed = try await repo.run(["show", "--format=", "--name-only", "HEAD"]).stdout
        try require(String(decoding: committed, as: UTF8.self).trimmingCharacters(in: .newlines) == "one", "Commit included unchecked files")
        commit.close()
        print("PASS: byte-distinct changelist names, native group slots/menus/help, canonical-only menu invalidation, Commit create/cancel, Working Tree group selection/move, real selected commit cleanup, preserved unchecked names, owned light/dark windows and private preferences")
    }
}
