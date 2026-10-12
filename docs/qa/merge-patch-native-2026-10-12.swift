import AppKit
import SwiftUI
import TurtleGitCore

struct MergePatchNativeVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: "MergePatch", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergePatchNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.MergePatch." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsTransaction()
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MergeEditorSettings(defaults: prefs, commentProfileURL: root.appendingPathComponent("ignorecomments.txt")).environment(\.settingsTransaction, settings))
        settingsWindow.contentView = host; host.frame = settingsWindow.contentLayoutRect; host.layoutSubtreeIfNeeded()
        defer { settings.invalidate(); settingsWindow.contentView = nil; settingsWindow.close() }
        func findField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "MergePatchContext" { return field }
            return view.subviews.compactMap(findField).first
        }
        try await TwoPaneEngineVerification.wait { findField(host) != nil }
        let field = findField(host)!
        try check(field.stringValue == "-1", "Source default context is missing")
        func edit(_ value: String) { field.stringValue = value; field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field)) }
        edit("1001"); try await TwoPaneEngineVerification.wait { settings.modified }
        settings.apply(closeAfter: false); try await TwoPaneEngineVerification.wait { !settings.busy && settings.error != nil }
        try check(prefs.object(forKey: "TurtleGitMerge.ContextLines") == nil, "Invalid context was saved")
        edit("0"); try await Task.sleep(nanoseconds: 30_000_000)
        settings.apply(closeAfter: false); try await TwoPaneEngineVerification.wait { !settings.busy && prefs.object(forKey: "TurtleGitMerge.ContextLines") != nil }
        try check(MergeUnifiedPatch.contextLines(from: prefs) == 0 && !settings.modified, "Apply did not persist context")
        edit("12"); try await TwoPaneEngineVerification.wait { settings.modified }; settings.cancel()
        try await TwoPaneEngineVerification.wait { field.stringValue == "0" && !settings.modified }
        func controls(_ view: NSView) -> [NSControl] { (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(controls) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            host.appearance = NSAppearance(named: appearance); host.layoutSubtreeIfNeeded()
            let frames = controls(host).map { $0.convert($0.bounds, to: host) }
            try check(frames.allSatisfy { $0.minX >= -1 && $0.maxX <= host.bounds.maxX + 1 }, "Actual General controls overflow: \(frames); host=\(host.bounds), ideal=\(host.fittingSize)")
        }
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        let before = "one\ntwo\nold\nfour\n", after = "one\ntwo\nnew\nfour\n"
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { owner.window?.close() }
        let model = owner.model; model.comparisonDefaults = prefs; model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt")
        model.patchExecutable = URL(fileURLWithPath: "/usr/bin/git"); model.load(); try await TwoPaneEngineVerification.settled(model)
        let output = root.appendingPathComponent("saved.diff")
        model.choosePatchLocation = { _,_,_ in nil }; model.createUnifiedPatch()
        try await TwoPaneEngineVerification.wait { !model.busy }
        try check(!FileManager.default.fileExists(atPath: output.path), "Cancelled export wrote a patch")
        model.activatePane(base: false); model.editingEnabled = true
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(owner.window?.contentView).contains { $0.isEditable } }
        let editor = TwoPaneEngineVerification.editors(owner.window?.contentView).first { $0.isEditable }!
        editor.insertText("unsaved edit", replacementRange: (editor.string as NSString).range(of: "new"))
        try await TwoPaneEngineVerification.settled(model)
        let draft = model.draftText(base: false)
        try check(model.dirty && model.canUndo && draft.contains("unsaved edit"), "Unsaved draft fixture missing")
        // External saved content is read at export time; unsaved editor text is not used.
        let external = "one\ntwo\nexternally saved\nfour\n"; try Data(external.utf8).write(to: mine)
        var proposedName = ""
        model.choosePatchLocation = { _,name,_ in proposedName = name; return output }
        model.createUnifiedPatch(); try check(model.busy && model.exporting && !owner.windowShouldClose(owner.window!), "Patch export did not own busy/close gate")
        try await TwoPaneEngineVerification.wait { !model.busy }
        let patch = try String(contentsOf: output, encoding: .utf8)
        try check(patch.contains("@@ -3 +3 @@") && patch.contains("+externally saved") && !patch.contains("TurtleGitMergePatch-"), "Context or saved-input export incorrect")
        try check(model.dirty && model.canUndo && model.draftText(base: false) == draft && model.error == nil && proposedName == "mine.txt.diff", "Patch export mutated editing state or default name")
        let previousMenu = NSApplication.shared.mainMenu, menu = NSMenu(), fileMenu = NSMenu(title: "File"), fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu; menu.addItem(fileItem); NSApplication.shared.mainMenu = menu
        defer { NSApplication.shared.mainMenu = previousMenu }
        owner.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: owner.window))
        guard let item = fileMenu.items.first(where: { $0.title == "Create patch file" }) else { throw NSError(domain: "Missing File command", code: 1) }
        try check(item.image != nil && owner.validateMenuItem(item), "File command icon/gate missing")
        model.singleFileMode = true; try check(!owner.validateMenuItem(item), "Single-file patch command enabled"); model.singleFileMode = false
        owner.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: owner.window)); try check(fileMenu.items.isEmpty, "Window command leaked into another window")
        var reply: CheckedContinuation<URL?, Never>?
        model.choosePatchLocation = { _,_,_ in await withCheckedContinuation { reply = $0 } }
        let stale = root.appendingPathComponent("stale.diff"); model.createUnifiedPatch(); try await TwoPaneEngineVerification.wait { reply != nil }
        model.retireImageLoader(); reply?.resume(returning: stale); try await TwoPaneEngineVerification.wait { !model.busy }
        try check(!FileManager.default.fileExists(atPath: stale.path), "Late save reply wrote after close")
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        try check(finalBase == Data(before.utf8) && finalMine == Data(external.utf8), "Patch export changed inputs")
        print("Merge patch: native General context default/range/Apply/Cancel/light-dark layout, native File command/icon/ownership, saved-input/context export, Cancel/busy/close/single-file/late-reply gates and unchanged inputs/history passed. Owned windows closed; private preferences/files only.")
    }
}
