import AppKit
import TurtleGitCore
struct MergeFormatNativeVerification {
    @MainActor static func verify() async throws {
        let prompt = MergeFormatPrompt(pane:"Mine",selection:.init(encoding:.utf8BOM)); defer { prompt.close() }
        precondition(prompt.encoding.numberOfItems == 9 && prompt.ending.numberOfItems == 10 && prompt.selection == .init(encoding:.utf8BOM))
        prompt.encoding.selectItem(at:1); prompt.ending.selectItem(at:1)
        precondition(prompt.selection == .init(encoding:.utf16LE,ending:.crlf))
        precondition(MergeLineNumberPrompt.validated("1",limit:1) == nil && MergeLineNumberPrompt.validated("2",limit:1) == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeFormat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        let bytes = Data("first\r\nsecond\nlast".utf8); try bytes.write(to:base); try bytes.write(to:mine)
        let owner = FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[])
        defer { owner.window?.close() }
        let model = owner.model; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.load()
        try await TwoPaneEngineVerification.settled(model)
        model.activatePane(base:false); model.editingEnabled = true
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait { model.canTransfer(toBase:false) && TwoPaneEngineVerification.editors(owner.window?.contentView).contains { $0.isEditable } }
        prompt.present(owner:owner.window!) { _ in }
        owner.window?.orderOut(nil); prompt.window?.orderOut(nil)
        precondition(!owner.windowShouldClose(owner.window!))
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        prompt.cancel()
        model.chooseFormat = { _,_,_ in nil }; model.showFormatDialog(base:false)
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(model.encoding(base:false) == .windows1252 && model.draftText(base:false) == String(decoding:bytes,as:UTF8.self))
        model.chooseFormat = { _,_,_ in .init(encoding:.utf16BEBOM,ending:.crlf) }; model.showFormatDialog(base:false)
        try await TwoPaneEngineVerification.wait { !model.filtering && model.encoding(base:false) == .utf16BEBOM }
        precondition(model.draftText(base:false) == "first\r\nsecond\r\nlast")
        let disk = try Data(contentsOf:mine); precondition(disk == bytes)
        var continuation: CheckedContinuation<MergeFormatSelection?,Never>?
        model.chooseFormat = { _,_,_ in await withCheckedContinuation { continuation = $0 } }
        model.showFormatDialog(base:false); try await TwoPaneEngineVerification.wait { continuation != nil }
        model.retireImageLoader(); continuation?.resume(returning:.init(encoding:.utf8,ending:.lf))
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(model.encoding(base:false) == .utf16BEBOM)
        print("Merge Encoding: original nine/ten choices, Auto/Cancel, native two-pane format transaction, exact EOL conversion/unchanged disk, stale close fencing and source single-line Go To exclusion passed. Owned window closed.")
    }
}
