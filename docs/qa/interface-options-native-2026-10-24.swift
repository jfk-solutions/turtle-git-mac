// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func interfaceHiddenOrder(_ place: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0; interfaceHiddenOrder(place, relativeTo: number)
    }
}
@main struct InterfaceOptionsVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func wait(_ label: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timeout: " + label)
    }
    @MainActor static func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
        guard let root else { return [] }
        return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, type) }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.interfaceHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal, hidden)
        defer { method_exchangeImplementations(normal, hidden) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), repoRoot = folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        let suite = "TurtleGit.InterfaceOptions." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        DialogGeometry.install(preferences: prefs)
        defer { DialogGeometry.install(preferences: .standard); prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "HintStagingMode")
        prefs.set(false, forKey: "ConfirmKillProcess")
        let repository = GitRepository(root: repoRoot, executable: URL(fileURLWithPath: "/usr/bin/git"), askpass: nil)
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Interface QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {
            _ = try await repository.run(["config", key, value])
        }
        let file = repoRoot.appendingPathComponent("sample.txt")
        let original = (0..<35).map { "line \($0)\n" }.joined()
        let edited = original.replacingOccurrences(of: "line 2\n", with: "first change\n").replacingOccurrences(of: "line 29\n", with: "second change\n")
        try Data(original.utf8).write(to: file); try await repository.stage(["sample.txt"]); _ = try await repository.commit(message: "Base")
        try Data(edited.utf8).write(to: file)
        let owner = CommitWindowController(repository: repository, access: nil, defaults: prefs), model = owner.model
        var comparisons: [FileComparisonWindowController] = [], merges: [TextConflictWindowController] = []
        func cleanup() async {
            owner.close(); comparisons.forEach { $0.close() }; merges.forEach { $0.close() }
            NSApp.windows.forEach { window in if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }; window.close() }
            for _ in 0..<2000 {
                if CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeFileOperations == 0 && PatchWindowModel.activeOperations == 0 && comparisons.allSatisfy({ !$0.model.mergeToolHasPendingWork }) && merges.allSatisfy({ !$0.model.mergeToolHasPendingWork }) { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        do {
            owner.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); owner.window?.orderFront(nil); model.reload()
            try await wait("classic commit preparation") { !model.inputsBlocked && !model.entries.isEmpty }
            try require(!model.gitGuiInterface && !model.stagingEnabled, "Classic must remain the default")
            model.message = "Preserved draft"
            model.setCommitInterface(true)
            try await wait("staging workspace") { model.gitGuiInterface && !model.inputsBlocked }
            try require(prefs.bool(forKey: "TurtleGit.Commit.GitGuiInterface"), "Commit choice not saved")
            model.selectGuiFiles(["sample.txt"], staged: false)
            try await wait("embedded patch") { model.guiPatch?.busy == false && model.guiPatch?.document.files.isEmpty == false }
            let patch = model.guiPatch!
            guard let hunk = patch.document.files.first?.hunks.first else { throw Failure(message: "No test hunk") }
            patch.selectedLines = Set(hunk.range.filter { patch.document.changedLine($0) })
            try require(patch.canApplyLines, "Line staging unavailable")
            patch.apply(entireHunks: false)
            try await wait("line staging settlement") { !model.inputsBlocked && !patch.busy }
            let staged = try await repository.run(["show", ":sample.txt"]).text
            try require(staged.contains("first change") && !staged.contains("second change"), "Line staging changed another chunk")
            try require(try String(contentsOf: file, encoding: .utf8) == edited, "Staging changed working file")
            try require(model.stagedEntries.contains { $0.path == "sample.txt" } && model.unstagedEntries.contains { $0.path == "sample.txt" }, "Partial file absent from one list")
            model.selectGuiFiles(["sample.txt"], staged: true)
            try await wait("unstaging preview") { !patch.busy && patch.staged }
            patch.selectedLines = [patch.document.files.first!.hunks.first!.header]
            try require(patch.canApplyHunks, "Chunk unstaging unavailable")
            model.busy = true
            try require(!patch.canApplyHunks, "Patch action escaped parent ownership gate")
            model.busy = false; patch.apply(entireHunks: true)
            try await wait("chunk unstaging") { !model.inputsBlocked && !patch.busy }
            try require(try await repository.run(["show", ":sample.txt"]).text == original, "Unstage did not restore index")
            model.setCommitInterface(false)
            try await wait("classic restoration") { !model.inputsBlocked }
            try require(!model.stagingEnabled && model.message == "Preserved draft", "Classic preference or draft not restored")
            try require(patch.retired, "Embedded patch survived interface retirement")
            model.setCommitInterface(true)
            try await wait("saved workspace") { !model.inputsBlocked }
            let reopened = CommitWindowModel(repository: repository, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
            try require(reopened.gitGuiInterface, "Saved commit interface not restored"); reopened.invalidateForClose()

            let base = folder.appendingPathComponent("base.txt"), theirs = folder.appendingPathComponent("theirs.txt"), mine = folder.appendingPathComponent("mine.txt")
            for (url,text) in [(base,"header\nbase value\nfooter\n"),(theirs,"header\ntheirs value\nfooter\n"),(mine,"header\nmine value\nfooter\n")] { try Data(text.utf8).write(to: url) }
            prefs.set(true, forKey: "TurtleGit.Comparison.CurvedInterface")
            let diff = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
            comparisons.append(diff)
            diff.window?.setFrameOrigin(NSPoint(x: -20000,y: -20000)); diff.window?.orderFront(nil)
            try await wait("curved diff editors") { diff.model.alignment != nil && views(diff.window?.contentView, CurvedDiffConnectionView.self).count == 1 && diff.model.connectionEditors().0 != nil }
            let merge = TextConflictWindowController(repository: repository, access: nil, path: "mine.txt", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
            merges.append(merge)
            merge.window?.setFrameOrigin(NSPoint(x: -20000,y: -20000)); merge.window?.orderFront(nil); merge.model.load()
            try await wait("three-way curved editors") { !merge.model.busy && merge.model.document != nil && views(merge.window?.contentView, CurvedDiffConnectionView.self).count == 2 && merge.model.connectionEditors(mine: true).0 != nil }
            try require(!merge.model.connectionBlocks.isEmpty, "Merge connections lack changed blocks")
            let retained = merge.model.result
            for window in [diff.window!,merge.window!] {
                window.contentView?.layoutSubtreeIfNeeded()
                for band in views(window.contentView, CurvedDiffConnectionView.self) {
                    try require(band.bounds.width > 0 && band.blocks.count > 0, "Connection not laid out")
                    try require(band.hitTest(.zero) == nil, "Connection intercepts text input")
                    guard let bitmap = band.bitmapImageRepForCachingDisplay(in: band.bounds) else { throw Failure(message: "No native connection bitmap") }
                    band.cacheDisplay(in: band.bounds, to: bitmap)
                    try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Connection render empty")
                }
            }
            prefs.set(false, forKey: "TurtleGit.Comparison.CurvedInterface")
            try await wait("classic comparison restoration") { views(diff.window?.contentView, CurvedDiffConnectionView.self).isEmpty && views(merge.window?.contentView, CurvedDiffConnectionView.self).isEmpty }
            try require(merge.model.result == retained, "Switching interface changed merge result")
            await cleanup()
            try require(NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil }, "Owned windows survived cleanup")
            try require(CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeFileOperations == 0 && PatchWindowModel.activeOperations == 0, "Owned workers survived cleanup")
            print("PASS interface options: saved choices, line stage/chunk unstage, partial lists, parent gates, draft/index preservation, two/three-way curves, classic restoration and cleanup")
        } catch { await cleanup(); throw error }
    }
}
