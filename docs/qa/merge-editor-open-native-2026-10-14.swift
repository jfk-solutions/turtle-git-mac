import AppKit
import TurtleGitCore

struct MergeEditorOpenNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorOpen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.EditorOpen." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let texts = ["head\nbase\ntail\n", "head\nmine\ntail\n", "head\ntheirs\ntail\n"]
        for (url, text) in zip([base, mine, theirs], texts) { try Data(text.utf8).write(to: url) }
        let root = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        let window = root.window!
        var closed = 0; root.onClosed = { closed += 1 }
        defer { (root.replacementOwner?.current ?? root).close() }
        root.model.load(); try await TwoPaneEngineVerification.settled(root.model)
        let frame = window.frame
        root.openMergeDocument(nil)
        guard let workflow = root.editorOpenWorkflow, let opener = workflow.opener else { throw Failure(message: "Scoped Open did not own its dialog") }
        try require(!root.windowShouldClose(window), "Open owner allowed Close")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Open owner allowed Quit")
        root.openMergeDocument(nil); try require(root.editorOpenWorkflow === workflow, "Duplicate Open replaced owner")
        opener.base.stringValue = folder.appendingPathComponent("missing").path; opener.mine.stringValue = mine.path; opener.accept()
        try require(root.window === window && root.editorOpenWorkflow === workflow && !opener.status.stringValue.isEmpty, "Invalid paths retired original editor")
        opener.base.stringValue = base.path; opener.theirs.stringValue = theirs.path; opener.mine.stringValue = mine.path; opener.accept()
        guard let owner = root.replacementOwner, let triple = owner.current as? TextConflictWindowController else { throw Failure(message: "Three-pane replacement missing") }
        try require(root.window == nil && triple.window === window && window.delegate === triple && window.frame == frame, "Replacement identity rootDetached=\(root.window == nil), sameWindow=\(triple.window === window), sameDelegate=\(window.delegate === triple), oldFrame=\(frame), newFrame=\(window.frame)")
        try await ThreePaneEngineVerification.wait { !triple.model.busy && triple.model.document != nil }
        var answer: ((NSApplication.ModalResponse) -> Void)?
        triple.makeEditorOpenWorkflow = { owner, grants, defaults in
            let workflow = MergeEditorOpenWorkflow(window: owner, permissions: grants, preferences: defaults)
            workflow.presentQuestion = { _, _, completion in answer = completion }; return workflow
        }
        let result = triple.model.result
        triple.openMergeDocument(nil); guard let cancel = answer else { throw Failure(message: "Dirty merge omitted Save question") }
        cancel(.alertThirdButtonReturn); cancel(.alertSecondButtonReturn)
        try require(triple.editorOpenWorkflow == nil && triple.model.result == result && triple.window === window, "Cancel/late answer changed original merge")
        triple.openMergeDocument(nil); answer?(.alertSecondButtonReturn)
        guard let nextOpener = triple.editorOpenWorkflow?.opener else { throw Failure(message: "Discard did not open dialog") }
        nextOpener.base.stringValue = base.path; nextOpener.mine.stringValue = mine.path; nextOpener.accept()
        guard let pair = owner.current as? FileComparisonWindowController else { throw Failure(message: "Return to two panes failed") }
        try require(pair.window === window && triple.window == nil && window.delegate === pair, "Second replacement lost existing window ownership")
        try await TwoPaneEngineVerification.settled(pair.model)
        pair.openMergeDocument(nil)
        let late = pair.editorOpenWorkflow
        window.close()
        try require(closed == 1 && owner.current == nil && pair.editorOpenWorkflow == nil, "Forced close did not retire current session once")
        try require(late?.opener == nil, "Forced close retained Open dialog")

        let saveWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        saveWindow.isReleasedWhenClosed = false
        defer { saveWindow.close() }
        let held = MergeEditorOpenWorkflow(window: saveWindow, permissions: [], preferences: prefs)
        var choice: ((NSApplication.ModalResponse) -> Void)?, saved: ((Bool) -> Void)?
        held.presentQuestion = { _, _, completion in choice = completion }
        held.start(dirty: true, description: "held save", save: { saved = $0 })
        choice?(.alertFirstButtonReturn)
        try require(MergeEditorOpenWorkflow.activeSaves == 1, "Save lifetime missing")
        held.retire(); saved?(true); saved?(false)
        try require(MergeEditorOpenWorkflow.activeSaves == 0 && held.opener == nil, "Late/duplicate Save response reopened owner or leaked lifetime")
        for (url, text) in zip([base, mine, theirs], texts) { try require(try Data(contentsOf: url) == Data(text.utf8), "Open replacement modified input") }
        print("PASS: owned File/Open invalid input, duplicate/Close/Quit gates, same NSWindow/frame across two/three/two panes, dirty Cancel/discard/late replies, final retirement, held Save lifetime and original bytes")
    }
}
