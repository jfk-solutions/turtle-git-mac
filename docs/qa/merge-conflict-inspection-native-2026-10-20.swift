import AppKit
import TurtleGitCore

/// Real two-file/three-way hosts, private settings and input files. The runner
/// keeps all normal receiver windows invisible and owns process retirement.
enum MergeConflictInspectionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static var diagnostics: () -> String = { "" }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(25)
        while !condition() {
            if Date() > end { throw Failure(description:"Merge inspection settlement timed out at fixture line \(line): \(diagnostics())") }
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }
    @MainActor static func descendants<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
        guard let root else { return [] }
        return (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0,type) }
    }
    @MainActor static func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }
    @MainActor static func invoke(_ item: NSMenuItem) { _ = (item.target as? NSObject)?.perform(item.action,with:item) }
    @MainActor static func capture(_ window:NSWindow,directory:URL) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let origin = window.frame.origin,appearance = window.appearance
        defer {window.alphaValue = 0;window.appearance = appearance;window.contentView?.appearance = appearance;window.setFrameOrigin(origin)}
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.alphaValue = 0;window.appearance = NSAppearance(named:theme);window.contentView?.appearance = window.appearance
            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            try await Task.sleep(nanoseconds:200_000_000)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1400,height:1000)
            window.setFrameOrigin(.init(x:screen.midX - window.frame.width / 2,y:screen.midY - window.frame.height / 2))
            window.alphaValue = 1;window.displayIfNeeded()
            let hide = Task { @MainActor in try? await Task.sleep(nanoseconds:1_800_000_000);window.alphaValue = 0 }
            defer {hide.cancel();window.alphaValue = 0}
            try await Task.sleep(nanoseconds:120_000_000)
            let destination = directory.appendingPathComponent("merge-conflict-inspection-" + suffix + ".png")
            let child = Process();child.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            child.arguments = ["-x","-o","-l",String(window.windowNumber),destination.path]
            child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
            try child.run()
            defer {if child.isRunning {child.terminate();child.waitUntilExit()}}
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
            if child.isRunning {window.alphaValue = 0;child.terminate();child.waitUntilExit();throw Failure(description:"Owned Merge inspection capture timed out")}
            window.alphaValue = 0;hide.cancel()
            try require(child.terminationStatus == 0 && NSBitmapImageRep(data:try Data(contentsOf:destination)) != nil,"Merge inspection WindowServer capture failed")
            print("CAPTURE: " + destination.path)
        }
    }
    @MainActor static func closeAndDrain(_ owner:TextConflictWindowController,comparisons:[FileComparisonWindowController]) async throws {
        owner.close();comparisons.forEach { $0.close() }
        try await wait { !owner.model.mergeToolHasPendingWork && comparisons.allSatisfy { !$0.model.mergeToolHasPendingWork } }
    }
    @MainActor static func verify(root: URL, git: URL) async throws {
        let folder = root.appendingPathComponent("merge-inspection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let suite = "TurtleGit.MergeInspection." + UUID().uuidString, preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:folder) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:preferences)
        MergeComparisonOptions.exact.save(to:preferences)
        preferences.set(false,forKey:"TurtleGitMerge.DisplayBinDiff")
        let base = folder.appendingPathComponent("base.cpp"), theirs = folder.appendingPathComponent("theirs.cpp"), mine = folder.appendingPathComponent("mine.cpp")
        let originals = ["head\r\nlet shared_value = 100;\r\nlet spacing = 1;\r\nseparate\r\nbase second\r\ntail\r\n",
                         "head\r\nlet shared_value = 101;\r\nlet spacing = 1; \r\nseparate\r\ntheirs second\r\ntail\r\n",
                         "head\r\nlet shared_value = 102;\r\nlet spacing  = 1;\r\nseparate\r\nmine second\r\ntail\r\n"]
        for (url,value) in zip([base,theirs,mine],originals) { try Data(value.utf8).write(to:url) }
        let owner = TextConflictWindowController(repository:GitRepository(root:folder,executable:git),access:nil,path:"mine.cpp",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:preferences)
        defer { owner.close() }
        var comparisons:[FileComparisonWindowController] = []
        do {
        let model = owner.model, window = owner.window!
        diagnostics = { [weak model,weak window] in
            guard let model,let window else { return "owner/model released" }
            let editors = descendants(window.contentView,NSTextView.self).filter { !$0.isFieldEditor }
            let bars = descendants(window.contentView,MergeLineDiffPreview.self)
            return "busy=\(model.busy) preparing=\(model.preparing) sourceTools=\(model.sourceToolsAllowed) nativeReady=\(model.nativeEditorReady) document=\(model.document != nil) error=\(model.error ?? "nil") saved=\(model.showLineDiffBar) visible=\(model.lineDiffBarVisible) preview=\(String(describing:model.previewRow)) cells=\(String(describing:model.lineDiffCells?.map(\.displayText))) bars=\(bars.map(\.displayedStrings)) editors=\(editors.map { "editable=\($0.isEditable) frame=\($0.frame) source=\($0.string.prefix(100))" })"
        }
        defer { diagnostics = { "" } }
        window.alphaValue = 0; window.orderFront(nil); model.load()
        try await wait { window.contentView?.layoutSubtreeIfNeeded(); return !model.busy && model.sourceToolsAllowed }
        try require(!model.lineDiffBarVisible && descendants(window.contentView,MergeLineDiffPreview.self).isEmpty && model.showLineDiffBar,"Three-way load did not hide pane while retaining saved checkmark")
        model.setLineDiffBar(false);model.setLineDiffBar(true)
        try await wait { descendants(window.contentView,MergeLineDiffPreview.self).count == 1 }
        let views = descendants(window.contentView,NSTextView.self).filter { !$0.isFieldEditor }
        guard let left = views.first(where: { !$0.isEditable && $0.string.contains("101") }),
              let right = views.first(where: { !$0.isEditable && $0.string.contains("102") }),
              let result = views.first(where: { $0.isEditable }),
              let hover = left as? MergeLineDiffHoverProviding,
              let otherHover = right as? MergeLineDiffHoverProviding else { throw Failure(description:"Three-way inspection panes missing") }
        let selection = left.selectedRange(), resultText = model.result, dirty = model.dirty
        let line = (left.string as NSString).range(of:"let shared_value = 101;").location
        guard line != NSNotFound else { throw Failure(description:"Inspection source line absent") }
        window.makeFirstResponder(left)
        let removedLine = (left.string as NSString).range(of:"let shared_value = 100;").location
        try require(removedLine != NSNotFound,"Captured removed source row missing")
        hover.previewLine(atDisplayOffset:removedLine + 5)
        try await wait { descendants(window.contentView,MergeLineDiffPreview.self).first?.displayedStrings == ["let shared_value = 100;","let shared_value = 100;"] }
        hover.previewLine(atDisplayOffset:line + 5)
        try await wait { descendants(window.contentView,MergeLineDiffPreview.self).first?.displayedStrings == ["let shared_value = 101;","let shared_value = 102;"] }
        let bar = descendants(window.contentView,MergeLineDiffPreview.self)[0]
        try require(window.firstResponder === left && left.selectedRange() == selection && model.result == resultText && model.dirty == dirty,"Hover changed focus/selection/result")
        try require(!model.showInlineDiff && bar.displayedAttributes.contains { value in
            var found = false; value.enumerateAttribute(.backgroundColor,in:.init(location:0,length:value.length)) { color,_,_ in
                if let color = color as? NSColor, color == MergePalette.inlineRemoved || color == MergePalette.inlineAdded { found = true }
            }; return found
        },"Three-way inspection did not force inline colors independently")
        try require(bar.displayedMarkers.allSatisfy { !$0.isEmpty },"Three-way inspection did not force whitespace/EOL markers")
        try require(bar.acceptsFirstResponder == false && bar.accessibilityLabel()?.contains("Theirs above Mine") == true,"Inspection focus/AX label")
        otherHover.previewLine(atDisplayOffset:nil)
        try require(model.previewRow != nil,"Unrelated pane exit cleared current inspection")
        hover.previewLine(atDisplayOffset:nil)
        try await wait { bar.displayedStrings.isEmpty }
        window.makeFirstResponder(left);left.setSelectedRange(.init(location:line + 5,length:0))
        try await wait { model.lineDiffCells?.first?.displayText == "let shared_value = 101;" }
        if let output = ProcessInfo.processInfo.environment["TURTLEGIT_HISTORY_EDITOR_CAPTURE"] {
            try await capture(window,directory:URL(fileURLWithPath:output))
        }
        let held = model.previewRow
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let context = (left as! MergeContextMenuProviding).mergeContextMenu(defaults:preferences,pasteboard:board)
        let toggle = items(context).first { $0.title == "Line diff bar" }!
        try require(toggle.isEnabled && toggle.image != nil && toggle.state == .on,"Context inspection visibility state")
        invoke(toggle)
        try await wait { !model.showLineDiffBar && descendants(window.contentView,MergeLineDiffPreview.self).isEmpty }
        try require(preferences.object(forKey:"TurtleGitMerge.LineDiff") as? Bool == false,"Inspection visibility did not persist privately")
        invoke(toggle)
        try await wait { model.showLineDiffBar && !descendants(window.contentView,MergeLineDiffPreview.self).isEmpty }
        let main = NSMenu(), menu = owner.editorCommandMenu!
        menu.applicationMenu = { main }; menu.keyWindow = { window }; menu.install(in:main)
        guard let lineToggle = items(main).first(where: { $0.title == "Line diff bar" }),let numbers = items(main).first(where: { $0.title == "Line numbers" }) else { throw Failure(description:"Native View inspection commands missing") }
        try require(!items(main).contains { $0.title == "Next inline difference" || $0.title == "Previous inline difference" },"Three-way enabled source-forbidden inline traversal")
        let originalNumbers = model.showLineNumbers
        invoke(numbers)
        try await wait { descendants(window.contentView,MergeLineRuler.self).allSatisfy { $0.showNumbers == !originalNumbers } }
        invoke(numbers)
        try await wait { model.showLineNumbers == originalNumbers }
        do {
            model.busy = true;menu.refresh()
            defer {model.busy = false;menu.refresh()}
            try require(!lineToggle.isEnabled,"Busy View inspection action remained enabled")
            invoke(lineToggle);hover.previewLine(atDisplayOffset:0)
            try require(model.showLineDiffBar && model.previewRow == held && model.lineDiffCells == nil,"Busy inspection accepted a mutation/read")
        }
        let focused = window.firstResponder
        model.setWrapLines(true);model.setCollapsed(true)
        try await wait { model.sourceToolsAllowed }
        hover.previewLine(atDisplayOffset:line + 5)
        try require(model.lineDiffCells?.last?.displayText == "let shared_value = 102;" && window.firstResponder === focused,"Wrapping/folding lost logical source pairing or focus")
        // The result uses source metadata, never assumes serialized row == source
        // row after marker insertion. Inspect a source-mapped ordinary result.
        window.makeFirstResponder(result)
        (result as? MergeLineDiffHoverProviding)?.previewLine(atDisplayOffset:0)
        try require(model.lineDiffCells?.map(\.displayText) == ["head","head"],"Result inspection did not map to captured source rows")
        model.setLineDiffBar(false)
        var locator = model.locatorPreferences;locator.visible.toggle();model.setLocatorPreferences(locator)
        try require(!model.lineDiffBarVisible,"Locator restored disabled inspection")
        model.setLineDiffBar(true)
        let retainedSelection = left.selectedRange()
        model.load(discardingDraft:true)
        try await wait { !model.busy && model.sourceToolsAllowed }
        try require(!model.lineDiffBarVisible && model.previewRow == nil && model.showLineDiffBar,"Reload did not hide/retire inspection while retaining saved checkbox")
        locator = model.locatorPreferences;locator.visible.toggle();model.setLocatorPreferences(locator)
        try require(model.lineDiffBarVisible && left.selectedRange() == retainedSelection,"Locator did not restore saved inspection without changing source selection")
        model.retire();hover.previewLine(atDisplayOffset:line);invoke(toggle);invoke(lineToggle)
        try require(model.previewRow == nil && model.lineDiffCells == nil && model.showLineDiffBar,"Retired hover/menu revived inspection")
        owner.close()
        for (url,value) in zip([base,theirs,mine],originals) { try require(try Data(contentsOf:url) == Data(value.utf8),"Inspection changed source file") }

        // Exercise the existing two-file host through the extracted renderer.
        let pair = FileComparisonWindowController(comparison:try WorkingFileComparison(base:theirs,destination:mine),permissions:[],preferences:preferences)
        comparisons.append(pair)
        diagnostics = { [weak pair] in
            guard let pair else { return "two-file owner released" }
            let model = pair.model
            let bars = descendants(pair.window?.contentView,MergeLineDiffPreview.self)
            let editors = descendants(pair.window?.contentView,NSTextView.self).filter { !$0.isFieldEditor }
            return "two-file busy=\(model.busy) filtering=\(model.filtering) commands=\(model.contextCommandsAllowed) onePane=\(model.onePaneActive) singleFile=\(model.singleFileMode) showBar=\(model.showLineDiffBar) initialNavigation=\(model.initialNavigationPending) alignmentSelections=\(model.alignmentSelections.count) selectionRequest=\(String(describing:model.selectionRequest)) pendingWork=\(model.mergeToolHasPendingWork) editorConfigLoading=\(model.editorConfigLoading) preview=\(String(describing:model.previewRow)) pairedRow=\(String(describing:model.lineDiffRow.map{[$0.base.displayText,$0.destination.displayText]})) options=\(model.comparisonOptions) error=\(model.error ?? "nil") bars=\(bars.map(\.displayedStrings)) rows=\(String(describing:model.alignment?.rows.map{[$0.base.displayText,$0.destination.displayText]})) editors=\(editors.map { "editable=\($0.isEditable) frame=\($0.frame) source=\($0.string.prefix(100))" })"
        }
        defer { pair.close() }
        pair.window!.alphaValue = 0;pair.window!.orderFront(nil);pair.model.load()
        try await wait {
            pair.window?.contentView?.layoutSubtreeIfNeeded()
            let attached = descendants(pair.window?.contentView,NSTextView.self).filter { $0 is MergeLineDiffHoverProviding && $0.window === pair.window && $0.bounds.width > 0 }
            return pair.model.document != nil && !pair.model.busy && !pair.model.filtering && !pair.model.initialNavigationPending && pair.model.alignmentSelections.isEmpty && pair.model.selectionRequest == nil && !pair.model.mergeToolHasPendingWork && pair.model.editorConfigLoading.isEmpty && pair.model.alignment != nil && attached.count == 2 && attached.contains { $0.string.contains("101") } && attached.contains { $0.string.contains("102") }
        }
        pair.model.setInlineDiff(false)
        guard let row = pair.model.alignment?.rows.firstIndex(where: { $0.base.displayText.contains("101") }) else { throw Failure(description:"Two-file source row missing") }
        pair.model.previewLine(atRow:row)
        try require(pair.model.previewRow == row,"Settled two-file preview was rejected immediately: " + diagnostics())
        try await wait { descendants(pair.window?.contentView,MergeLineDiffPreview.self).first?.displayedStrings == ["let shared_value = 101;","let shared_value = 102;"] }
        let twoBar = descendants(pair.window?.contentView,MergeLineDiffPreview.self)[0]
        try require(twoBar.displayedMarkers.allSatisfy { !$0.isEmpty } && !pair.model.showInlineDiff,"Shared renderer changed two-file forced whitespace")
        try require(twoBar.accessibilityLabel()?.contains("Base above Mine") == true,"Two-file extracted renderer labels changed")
        var ignored = MergeComparisonOptions.exact;ignored.whitespace = .ignoreAll
        pair.model.setComparisonOptions(ignored)
        // A finished alignment still owns deferred native caret restoration.
        // Its zero-width selection notification can clear an earlier preview;
        // start the one-shot inspection only after those actual receipts drain.
        try await wait { !pair.model.busy && !pair.model.filtering && !pair.model.initialNavigationPending && pair.model.alignmentSelections.isEmpty && pair.model.selectionRequest == nil && !pair.model.mergeToolHasPendingWork && pair.model.editorConfigLoading.isEmpty && pair.model.alignment != nil }
        guard let whitespaceRow = pair.model.alignment?.rows.firstIndex(where: { $0.base.displayText.contains("let spacing") }) else { throw Failure(description:"Filtered inspection row missing") }
        pair.model.previewLine(atRow:whitespaceRow)
        try require(pair.model.previewRow == whitespaceRow,"Settled filtered preview was rejected immediately: " + diagnostics())
        try await wait { twoBar.displayedStrings.first?.contains("let spacing") == true }
        try require(twoBar.displayedStrings[0] != twoBar.displayedStrings[1] && !pair.model.showInlineDiff,"Filtered inspection lost original whitespace or changed main setting")
        try require(twoBar.displayedAttributes.contains { value in
            var found = false;value.enumerateAttribute(.backgroundColor,in:.init(location:0,length:value.length)) { color,_,_ in
                if let color = color as? NSColor,color == MergePalette.inlineRemoved || color == MergePalette.inlineAdded { found = true }
            };return found
        },"Shared line strip failed to expose comparison-filtered whitespace changes")
        pair.model.previewLine(atRow:nil)
        try await wait { twoBar.displayedStrings.isEmpty }
        pair.model.previewLine(atRow:Int.max)
        try require(pair.model.lineDiffRow == nil,"Invalid two-file row retained preview")
        pair.close()
        print("PASS: three-way Theirs/Mine hover/caret/result mapping, forced inline/whitespace, private visibility, menu/context busy/retired guards, line numbers, wrap/fold pairing, focus/source preservation and two-file renderer regression")
        } catch {
            let failure = error
            do {try await closeAndDrain(owner,comparisons:comparisons)}
            catch {throw Failure(description:"\(failure); owned Merge cleanup failed: \(error)")}
            throw failure
        }
        try await closeAndDrain(owner,comparisons:comparisons)
    }
}
