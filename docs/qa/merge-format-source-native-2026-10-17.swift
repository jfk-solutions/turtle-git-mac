// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct MergeFormatSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Encoding source timeout at \(line)")
    }
    @MainActor static func capture(_ window: NSWindow, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { throw Failure(description: "PNG missing") }
            try data.write(to: folder.appendingPathComponent("merge-encoding-source-" + suffix + ".png"))
        }; window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TurtleGitEncodingSource-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.EncodingSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let text = "first\r\nsecond\nlast", bytes = Data(text.utf8)
        try bytes.write(to: base); try bytes.write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        defer { owner.close() }; owner.window?.alphaValue = 0; owner.window?.orderFront(nil); let model = owner.model
        model.load(); try await TwoPaneEngineVerification.settled(model); model.activatePane(base: false); model.editingEnabled = true
        try await wait { model.canTransfer(toBase: false) }
        model.showFormatDialog(base: false)
        try await wait { owner.window?.attachedSheet?.delegate is MergeFormatPrompt }
        let prompt = owner.window!.attachedSheet!.delegate as! MergeFormatPrompt
        try require(prompt.window?.title == "Mine Encoding" && prompt.paneLabel.stringValue == "Mine" && prompt.encoding.itemTitles == MergeFormatSelection.encodings.map(\.rawValue) && prompt.ending.numberOfItems == 10, "Source caption/order/choices differ")
        try require(prompt.selection.ending == nil && MergeFormatPrompt.activeDialogs == 1 && FileComparisonWindowModel.activePaneExports == 1 && !owner.windowShouldClose(owner.window!), "Mixed Auto or choice ownership missing")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Encoding sheet allowed Quit")
        model.showFormatDialog(base: false); try require(MergeFormatPrompt.activeDialogs == 1, "Duplicate format sheet opened")
        prompt.encoding.selectItem(at: -1); prompt.accept()
        try require(!prompt.status.stringValue.isEmpty && owner.window?.attachedSheet === prompt.window && MergeFormatPrompt.activeDialogs == 1, "Invalid selection accepted")
        prompt.encoding.selectItem(at: 8); prompt.ending.selectItem(at: 0); prompt.accept(); prompt.accept()
        try await wait { !model.hasPendingEditorChoice && FileComparisonWindowModel.activePaneExports == 0 && MergeFormatPrompt.activeDialogs == 0 }
        try require(model.encoding(base: false) == .utf8BOM && model.draftText(base: false) == text && model.dirty, "Auto changed mixed endings or lost output encoding")
        model.showFormatDialog(base: false); try await wait { owner.window?.attachedSheet?.delegate is MergeFormatPrompt }
        let cancelled = owner.window!.attachedSheet!.delegate as! MergeFormatPrompt; cancelled.encoding.selectItem(at: 4); cancelled.ending.selectItem(at: 3); cancelled.cancel(); cancelled.accept()
        try await wait { !model.hasPendingEditorChoice && FileComparisonWindowModel.activePaneExports == 0 }
        try require(model.encoding(base: false) == .utf8BOM && model.draftText(base: false) == text && !cancelled.encoding.isEnabled, "Cancel or old prompt altered the draft")
        // A native chooser is cancelled by model retirement even if its window
        // is temporarily retained for an editor replacement.
        model.showFormatDialog(base: false); try await wait { owner.window?.attachedSheet != nil }
        model.retireImageLoader(); try await wait { owner.window?.attachedSheet == nil && FileComparisonWindowModel.activePaneExports == 0 && MergeFormatPrompt.activeDialogs == 0 }
        let accepted = model.draftText(base: false); prompt.accept(); cancelled.accept(); try require(model.draftText(base: false) == accepted, "Retired native target revived")
        owner.close()
        // Independent injected three-pane choice lifetime survives forced close
        // and refuses the old accepted metadata after its response drains.
        let three = TextConflictWindowController(repository: GitRepository(root: root), access: nil, path: "mine.txt", workingMerge: try WorkingTextMerge(base: base, theirs: base, mine: mine), preferences: prefs)
        defer { three.close() }; three.window?.alphaValue = 0; three.window?.orderFront(nil); three.model.load()
        try await wait { !three.model.busy && three.model.document != nil && three.model.sourceToolsAllowed }
        let original = three.model.resultPresentation, encoding = three.model.encoding
        var reply: CheckedContinuation<MergeFormatSelection?, Never>?
        three.model.chooseFormat = { _, _, _ in await withCheckedContinuation { reply = $0 } }
        three.model.showFormatDialog(); try await wait { reply != nil }
        three.close()
        try require(MergeRegexOperations.activeRequests == 1 && !three.model.formatPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Closed format owner released undrained lifetime")
        reply?.resume(returning: .init(encoding: .utf32BE, ending: .lf)); reply = nil
        try await wait { MergeRegexOperations.activeRequests == 0 }
        try require(three.model.resultPresentation == original && three.model.encoding == encoding, "Late format reply changed a retired result")
        let standalone = MergeFormatPrompt(pane: "Mine", selection: .init(encoding: .utf8BOM)); defer { standalone.close() }
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_ENCODING_SOURCE_CAPTURE"], let window = standalone.window { try await capture(window, into: URL(fileURLWithPath: path)) }
        try require(try Data(contentsOf: base) == bytes && Data(contentsOf: mine) == bytes, "Encoding dialog changed input files")
        print("PASS native Encoding source: pane/Encoding/EOL/OK-Cancel, exact nine/ten choices, invalid/default/Auto/Cancel/single acceptance, native model retirement and injected three-pane Quit drain; original bytes unchanged")
    }
}
