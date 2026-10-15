import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct MergeToolbarVerification {
    @MainActor static func wait(_ condition: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NSError(domain: "MergeToolbar", code: line, userInfo: [NSLocalizedDescriptionKey: "Toolbar transition at line \(line)"])
    }
    @MainActor static func require(_ value: @autoclosure () -> Bool, line: Int = #line) throws {
        if !value() { throw NSError(domain: "MergeToolbar", code: line, userInfo: [NSLocalizedDescriptionKey: "Toolbar assertion at line \(line)"]) }
    }
    @MainActor static func item(_ command: MergeToolbarCommand, in toolbar: MergeEditorToolbar) -> NSToolbarItem {
        toolbar.toolbar.items.first { $0.itemIdentifier == command.identifier }!
    }
    @MainActor static func send(_ item: NSToolbarItem) throws { try require(NSApp.sendAction(item.action!, to: item.target, from: item)) }
    @MainActor static func capture(_ controller: NSWindowController, name: String, directory: URL?) async throws {
        guard let directory, let window = controller.window else { return }
        guard #available(macOS 14.4, *) else { throw NSError(domain: "Owned-window capture needs macOS 14.4", code: 1) }
        NSApp.setActivationPolicy(.regular); controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Owned toolbar window unavailable", code: 1) }
            let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"))
        }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let captures = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_TOOLBAR_CAPTURE"].map { URL(fileURLWithPath: $0) }
        if let captures { try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true) }
        let suite = "TurtleGit.MergeToolbar.Native." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt")
        try Data("same\nold\nmiddle\nold2\n".utf8).write(to: base); try Data("same\nnew\nmiddle\nnew2\n".utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        defer { owner.window?.close() }
        let model = owner.model; model.load()
        try await wait { !model.busy && !model.filtering && model.alignment != nil }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let toolbar = owner.editorToolbar!
        try await wait { toolbar.toolbar.items.count >= 10 }
        try require(owner.window?.toolbar === toolbar.toolbar && model.nativeToolbarInstalled && !toolbar.toolbar.autosavesConfiguration)
        try require(Array(toolbar.toolbar.items.prefix(7).map(\.itemIdentifier)) == [MergeToolbarCommand.open, .save, .saveAs, .reload, .undo, .redo, .previousDifference].map(\.identifier))
        for item in toolbar.toolbar.items { try require(item.image != nil && item.menuFormRepresentation?.image != nil && !item.autovalidates) }
        var helpCalls = 0; owner.showEditorHelp = { helpCalls += 1 }
        toolbar.perform(.help); try require(helpCalls == 1)
        // Navigation is caret-relative; start inside the first changed block.
        try await wait { model.activeFindText?.string.contains("new\n") == true }
        let comparisonText = model.activeFindText!
        owner.window?.makeFirstResponder(comparisonText)
        comparisonText.setSelectedRange((comparisonText.string as NSString).range(of:"new"))
        let next = item(.nextDifference, in: toolbar), oldDifference = model.difference
        model.busy = true; toolbar.refresh(); toolbar.toolbar.validateVisibleItems(); try require(!next.isEnabled)
        try send(next); try require(model.difference == oldDifference)
        model.busy = false; toolbar.refresh(); try send(next); try require(model.difference != oldDifference && (comparisonText.string as NSString).substring(with:comparisonText.selectedRange()) == "new2")
        let wrapping = item(.wrap, in: toolbar).view as! NSButton, oldWrap = model.wrapLines
        wrapping.performClick(nil); try require(model.wrapLines != oldWrap && wrapping.state == (model.wrapLines ? .on : .off))
        toolbar.toolbar.insertItem(withItemIdentifier: MergeToolbarCommand.whitespace.identifier, at: toolbar.toolbar.items.count)
        toolbar.toolbar.displayMode = .iconOnly
        try await wait { (prefs.dictionary(forKey: toolbar.profileKey)?["displayMode"] as? Int) == Int(NSToolbar.DisplayMode.iconOnly.rawValue) }
        try require((prefs.dictionary(forKey: toolbar.profileKey)?["items"] as? [String])?.last == MergeToolbarCommand.whitespace.identifier.rawValue)
        toolbar.toolbar.displayMode = .iconAndLabel
        let saveAs = item(.saveAs, in: toolbar) as! NSMenuToolbarItem
        try require(saveAs.menu.items.map(\.title) == [MergeToolbarCommand.saveLeft.title, MergeToolbarCommand.saveRight.title])
        let overflow = item(.find, in: toolbar).menuFormRepresentation!
        try require(NSApp.sendAction(overflow.action!, to: overflow.target, from: overflow))
        let editors = MergeMarkedWordInterface.panes(in: owner.window?.contentView)
        try require(editors.contains { ($0 as! MergeFindProviding).mergeFindController?.window?.isVisible == true })
        editors.forEach { ($0 as! MergeFindProviding).mergeFindController?.close() }
        model.activatePane(base: false); model.editingEnabled = true
        try await wait { model.activeFindText?.isEditable == true }
        let text = model.activeFindText!, history = text.undoManager!
        history.groupsByEvent = false; history.beginUndoGrouping(); text.insertText("changed by toolbar\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length)); history.endUndoGrouping()
        try await wait { !model.filtering && model.activeDirty }
        toolbar.refresh(); try require(item(.save, in: toolbar).isEnabled)
        try send(item(.save, in: toolbar)); try await wait { !model.busy && !model.filtering && !model.activeDirty && !model.hasPendingEditorChoice }
        let saved = try Data(contentsOf: mine); try require(saved == Data("changed by toolbar\n".utf8))
        print("Toolbar: comparison dispatch/Save reached"); fflush(stdout)
        // Replacement keeps the actual host but binds a new toolbar/model.
        let host = owner.window!, oldOpen = item(.open, in: toolbar)
        try owner.replaceEditor(.compare(base: base, mine: mine, single: false), permissions: [])
        let replacement = host.delegate as! FileComparisonWindowController
        try require(replacement !== owner)
        do { try await wait { !replacement.model.busy && !replacement.model.filtering && replacement.model.alignment != nil } }
        catch { fputs("Replacement state: busy=\(replacement.model.busy) filtering=\(replacement.model.filtering) document=\(replacement.model.document != nil) alignment=\(replacement.model.alignment != nil) error=\(replacement.model.error ?? "none")\n", stderr); throw error }
        try require(replacement.window === host && host.toolbar === replacement.editorToolbar?.toolbar && replacement.model.nativeToolbarInstalled)
        fputs("Old toolbar item: enabled=\(oldOpen.isEnabled) targetOld=\((oldOpen.target as AnyObject?) === toolbar) oldContains=\(toolbar.toolbar.items.contains { $0 === oldOpen }) newContains=\(replacement.editorToolbar!.toolbar.items.contains { $0 === oldOpen })\n", stderr)
        try require(!oldOpen.isEnabled && !replacement.editorToolbar!.toolbar.items.contains { $0 === oldOpen })
        try require(replacement.editorToolbar!.toolbar.items.last?.itemIdentifier == MergeToolbarCommand.whitespace.identifier)
        toolbar.perform(.help); try require(helpCalls == 1)
        // Real image-to-text transition removes then recreates the text toolbar.
        let png = root.appendingPathComponent("image.png")
        let pixels = NSBitmapImageRep(data: MenuIcon.modified.image()!.tiffRepresentation!)!
        try pixels.representation(using: .png, properties: [:])!.write(to: png)
        let image = FileComparisonWindowController(images: try ImageFileComparison(base: png, destination: png), permissions: [], preferences: prefs)
        defer { image.window?.close() }; image.model.load()
        try await wait { !image.model.busy && image.model.imageComparison != nil && image.window?.toolbar == nil && !image.model.nativeToolbarInstalled }
        let imageHost = image.window!
        try image.replaceEditor(.compare(base: base, mine: mine, single: true), permissions: [])
        let textOwner = imageHost.delegate as! FileComparisonWindowController
        try require(textOwner !== image)
        try await wait { !textOwner.model.busy && !textOwner.model.filtering && textOwner.model.alignment != nil }
        try require(imageHost.toolbar === textOwner.editorToolbar?.toolbar && textOwner.model.nativeToolbarInstalled)
        imageHost.close()
        print("Toolbar: text/image replacement reached"); fflush(stdout)
        // Three-pane conflict actions use the selected block and native Undo.
        let theirs = root.appendingPathComponent("theirs.txt"), mergedMine = root.appendingPathComponent("merge-mine.txt")
        try Data("same\ntheirs\n".utf8).write(to: theirs); try Data("same\nmine\n".utf8).write(to: mergedMine)
        let merge = TextConflictWindowController(repository: GitRepository(root: root, executable: git), access: nil, path: "merge-mine.txt", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mergedMine), preferences: prefs)
        defer { merge.window?.close() }; merge.model.load()
        try await wait { !merge.model.busy && merge.model.document != nil && !merge.model.blocks.isEmpty }
        merge.window?.contentView?.layoutSubtreeIfNeeded()
        let conflictBar = merge.editorToolbar!, original = merge.model.result
        try await wait { conflictBar.toolbar.items.count >= 10 }
        conflictBar.refresh(); try require(!item(.resolved, in: conflictBar).isEnabled)
        merge.model.continueResolving()
        try await wait { merge.model.canChooseConflict }
        conflictBar.refresh()
        let useMine = item(.useMine, in: conflictBar); try send(useMine)
        try require(merge.model.result != original && !MergeText.hasMarkers(merge.model.result))
        try await wait { merge.model.canUndo }
        conflictBar.perform(.undo); try require(merge.model.result == original)
        let choices = item(.saveAs, in: conflictBar) as! NSMenuToolbarItem
        try require(choices.menu.items.count == 4)
        try await capture(replacement, name: "compare-native-toolbar", directory: captures)
        try await capture(merge, name: "merge-native-toolbar", directory: captures)
        let heldFind = item(.find, in: conflictBar), retiredToolbar = conflictBar
        merge.window?.close(); host.close(); retiredToolbar.perform(.useMine); try require(!heldFind.isEnabled && merge.model.result == original)
        try Data("complete\n".utf8).write(to: root.appendingPathComponent("completed"))
        print("PASS: native Compare/Merge toolbar source order/artwork, live states/toggles, validated busy refusal, menu/overflow dispatch, real Save and conflict Undo, replacement rebinding, image suppression and retired item refusal; windows closed")
    }
}
