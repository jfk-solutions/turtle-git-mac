import AppKit
import FinderSync
import TurtleGitCore

@main struct ClipboardPatchEntryVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timeout: " + message)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Clipboard patch entries failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), fm = FileManager.default
        let folder = base.appendingPathComponent("plain target"), selected = folder.appendingPathComponent("file.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true); try Data("before\n".utf8).write(to: selected)
        let patch = Data("--- file.txt\n+++ file.txt\n@@ -1 +1 @@\n-before\n+after\n".utf8)
        let clipboard = NSPasteboard(name: .init("TurtleGit.ClipboardPatch.QA." + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        let suite = "TurtleGit.ClipboardPatch.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let handoff = FinderPatchHandoff(root: base.appendingPathComponent("handoff"))
        PatchClipboard.write(UnifiedDiffDocument(bytes: patch), to: clipboard)
        let original = FinderRequest(action: .reviewPatch, paths: [selected])
        let captured = await FinderPatchReviewCapture.request(original, pasteboard: clipboard, store: handoff)
        try require(captured.clipboardPatch != nil && captured.clipboardPatch != FinderPatchHandoff.unavailable, "Finder did not capture private patch")
        let command = FinderMenuCommand(request: captured), url = command.url(alternate: true)!
        try require(FinderRequest(url: url)?.clipboardPatch == captured.clipboardPatch, "Finder command lost receipt")
        let selectedPatch = FinderRequest(action: .reviewPatch, paths: [base.appendingPathComponent("chosen.patch")])
        try require(await FinderPatchReviewCapture.request(selectedPatch, pasteboard: clipboard, store: handoff).clipboardPatch == nil, "Clipboard overrode selected patch file")
        let ordinary = FinderRequest(action: .log, paths: [selected])
        try require(await FinderPatchReviewCapture.request(ordinary, pasteboard: clipboard, store: handoff).clipboardPatch == nil, "Clipboard changed non-review action")
        let unavailable = await FinderPatchReviewCapture.request(original, pasteboard: clipboard, store: nil)
        try require(unavailable.clipboardPatch == FinderPatchHandoff.unavailable, "Missing shared permission silently fell back")
        clipboard.clearContents(); clipboard.setString(String(decoding: patch, as: UTF8.self), forType: .string)
        try require(await FinderPatchReviewCapture.request(original, pasteboard: clipboard, store: handoff).clipboardPatch == nil, "Finder polled plain text as registered patch")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.reviewPatchPreferences = preferences; workspace.finderPatchHandoff = handoff
        var workflows: [ReviewPatchWorkflow] = [], reviews: [WorkingTreePatchWindowController] = []
        defer { workflows.forEach { $0.cancel() }; reviews.forEach { $0.close() } }
        workspace.reviewPatchPreparation = { workflow in
            workflows.append(workflow); workflow.chooseFile = { preconditionFailure("Finder receipt asked for a patch file") }
            workflow.chooseTarget = { folder }; workflow.preparedPresentation = { reviews.append($0) }
        }
        clipboard.clearContents(); clipboard.setString("replaced before app received URL", forType: .string)
        workspace.handle(url); workspace.handle(url)
        try await wait("Finder review") { reviews.count == 1 || workflows.first?.error != nil }
        try require(reviews.count == 1 && workflows.count == 1 && workspace.root == nil && reviews[0].model.previewDocument.exportDocument.bytes == patch, "Finder snapshot, duplicate receipt or workspace isolation failed")
        try require(!fm.fileExists(atPath: handoff.root.appendingPathComponent(captured.clipboardPatch! + ".patch").path), "Consumed receipt survived")
        let applied = reviews[0]; applied.model.apply(); try await wait("Explicit patch apply") { !applied.model.busy && (try? Data(contentsOf: selected)) == Data("after\n".utf8) }; applied.close()
        try Data("before\n".utf8).write(to: selected)
        // The source chooser's real AppKit accessory performs its own explicit
        // clipboard read, then retires the panel before target selection.
        let opener = ReviewPatchWorkflow(file: nil, target: nil, preferred: folder, executable: git, preferences: preferences, pasteboard: clipboard)
        workflows.append(opener)
        var panels: [NSOpenPanel] = [], replies: [(NSApplication.ModalResponse) -> Void] = [], targetReply: CheckedContinuation<URL?, Never>?
        opener.presentPicker = { panel, _, reply in panels.append(panel); replies.append(reply) }
        opener.chooseTarget = { await withCheckedContinuation { targetReply = $0 } }
        opener.preparedPresentation = { reviews.append($0) }; opener.start()
        try await wait("Source chooser") { panels.count == 1 }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let button = views(panels[0].accessoryView!).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "PatchReview.UseClipboard" }!
        button.performClick(nil); try require(panels[0].message.contains("does not contain"), "Invalid clipboard did not remain in chooser")
        PatchClipboard.write(UnifiedDiffDocument(bytes: patch), to: clipboard); button.performClick(nil); replies[0](.OK); replies[0](.cancel)
        try await wait("Target chooser") { targetReply != nil }
        clipboard.clearContents(); clipboard.setString("changed during target selection", forType: .string)
        targetReply!.resume(returning: folder); targetReply = nil
        try await wait("Accessory review") { reviews.count == 2 || opener.error != nil }
        try require(reviews.count == 2 && reviews[1].model.previewDocument.exportDocument.bytes == patch && (try Data(contentsOf: selected)) == Data("before\n".utf8), "Accessory lost snapshot or applied without explicit action")
        reviews[1].close(); button.performClick(nil)
        let retired = ReviewPatchWorkflow(file: nil, target: folder, executable: git, preferences: preferences, pasteboard: clipboard)
        workflows.append(retired); var oldReply: ((NSApplication.ModalResponse) -> Void)?, oldPanel: NSOpenPanel?, late = 0
        retired.presentPicker = { panel, _, reply in oldPanel = panel; oldReply = reply }; retired.preparedPresentation = { _ in late += 1 }; retired.start()
        try await wait("Retired chooser") { oldPanel != nil }
        let oldButton = views(oldPanel!.accessoryView!).compactMap { $0 as? NSButton }.first!
        retired.cancel(); oldReply?(.OK); oldButton.performClick(nil)
        try await wait("Retired chooser drained") { oldButton.target == nil && oldButton.action == nil }
        await Task.yield()
        try await wait("Loads settled") { ReviewPatchWorkflow.activeLoads == 0 }
        try require(late == 0 && (try Data(contentsOf: selected)) == Data("before\n".utf8), "Late source chooser escaped owner")
        workspace.handle(unavailable.url!); try require(workspace.error?.contains("Finder could not pass") == true, "Missing handoff permission was not reported")
        print("PASS: clipboard patch entry family: Finder capture/receipt/file precedence, app dispatch and duplicate refusal, native clipboard accessory, target snapshot, explicit apply and retired choosers")
    }
}
