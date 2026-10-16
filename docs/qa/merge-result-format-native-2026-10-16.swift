import AppKit
import TurtleGitCore

struct MergeResultFormatVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitResultFormat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite = "TurtleGit.ResultFormat." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        MergeComparisonOptions.exact.save(to:prefs); MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let b = "\thead 🐢  \r\n\told  \r\ntail", m = "\thead 🐢  \r\nmine\r\ntail", t = "\thead 🐢  \r\ntheirs\r\ntail"
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine"), theirs = root.appendingPathComponent("theirs"), output = root.appendingPathComponent("result")
        for (url,text) in [(base,b),(mine,m),(theirs,t)] { try Data(text.utf8).write(to:url) }
        let owner = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil); model.load()
        func views() -> [NSTextView] { ThreePaneEngineVerification.textViews(owner.window?.contentView).filter { !$0.isFieldEditor } }
        func wait(_ ready:()->Bool,line:Int = #line) async throws {
            for _ in 0..<2000 {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                if ready() && views().compactMap({ $0 as? MergeContextMenuProviding }).allSatisfy(\.mergeSourceRowsReady) { return }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            throw Failure(description:"Result-format wait at line \(line), error=\(String(describing:model.error))")
        }
        try await wait { !model.busy && !model.preparing && model.document != nil && views().contains { $0.isEditable } }
        let view = views().first { $0.isEditable }!, initial = model.resultPresentation, initialEncoding = model.encoding
        try await wait { view.string == model.resultDisplayText }
        try require(model.resultLineEnding == .crlf,"Output ending was inferred from marker serialization")
        let states = model.alignedResultStates, count = model.sourceComparison!.rows.count
        model.applyFormatChoice(.init(encoding:.windows1252,ending:.lf))
        try require(model.error != nil && model.resultPresentation == initial && model.encoding == initialEncoding && model.resultLineEnding == .crlf && !model.canUndo,"Unrepresentable combined choice partially changed text/format/history")
        model.error = nil
        try await wait { owner.window?.attachedSheet == nil && view.isEditable }
        let marker = (model.result as NSString).substring(with:model.blocks[0].range)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        func menu() -> NSMenu { (view as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:board) }
        func invoke(_ item:NSMenuItem) throws { try require(item.isEnabled && NSApplication.shared.sendAction(item.action!,to:item.target,from:item),"Disabled or undispatched format action " + item.title) }
        try invoke(menu().item(withTitle:MergeWhitespaceCommand.tabsToSpaces.rawValue)!)
        try await wait { view.string.hasPrefix("    head 🐢  ") && view.isEditable }
        try require(model.alignedResultProjection != nil && model.alignedResultStates == states && model.sourceComparison?.rows.count == count,"Whitespace conversion lost row/state alignment")
        try require(model.alignedResultProjection!.cells[1].displayText == "    old  ","Whole-view conversion skipped removed Base record")
        try require((model.result as NSString).substring(with:model.blocks[0].range) == marker,"Whitespace conversion rewrote hidden conflict payloads")
        try require(menu().item(withTitle:MergeWhitespaceCommand.tabsToSpaces.rawValue)?.isEnabled == false,"Converted rows used hidden raw-marker tabs for availability")
        model.undo(); try await wait { model.resultPresentation == initial && view.isEditable }
        model.redo(); try await wait { view.string.hasPrefix("    head") && view.isEditable }
        model.undo(); try await wait { model.resultPresentation == initial && view.isEditable }
        let endings = menu().item(withTitle:"Line endings")!.submenu!
        try invoke(endings.item(withTitle:"LF")!)
        try await wait { model.resultLineEnding == .lf && view.isEditable }
        let lf = model.resultPresentation
        try require(model.alignedResultProjection != nil && model.alignedResultStates == states && MergeLineEndings.styles(in:model.resultFormatText) == [.lf],"Ending conversion changed states or exposed marker endings in ribbon")
        try require((model.result as NSString).substring(with:model.blocks[0].range) == marker,"Ending conversion rewrote source conflict bytes")
        try invoke(menu().item(withTitle:"File Encoding")!.submenu!.item(withTitle:ComparisonTextEncoding.utf16BEBOM.rawValue)!)
        try await wait { model.encoding == .utf16BEBOM && view.isEditable }
        try require(model.resultPresentation == lf,"Encoding-only change rewrote record text")
        model.undo(); try await wait { model.encoding == initialEncoding && model.resultPresentation == lf && view.isEditable }
        model.undo(); try await wait { model.resultPresentation == initial && model.resultLineEnding == .crlf && view.isEditable }
        // The real owned Encoding/EOL sheet must settle Cancel without history changes.
        model.showFormatDialog(); try await wait { model.formatPending && owner.window?.attachedSheet != nil }
        try require(MergeRegexOperations.activeRequests == 1 && owner.windowShouldClose(owner.window!) == false,"Format sheet not owned by Close/Quit accounting")
        owner.window!.endSheet(owner.window!.attachedSheet!,returnCode:.alertSecondButtonReturn)
        try await wait { !model.formatPending && MergeRegexOperations.activeRequests == 0 && view.isEditable }
        try require(model.resultPresentation == initial && model.encoding == initialEncoding,"Cancel changed format/history")
        // Injected responses exercise the same ownership gates without a modal run loop.
        var answer:CheckedContinuation<MergeFormatSelection?,Never>?, calls = 0
        model.chooseFormat = { _,_,_ in calls += 1; return await withCheckedContinuation { answer = $0 } }
        model.showFormatDialog(); try await wait { answer != nil && model.formatPending }
        let before = model.resultPresentation, options = model.comparisonOptions
        model.showFormatDialog(); model.changeEncoding(.utf16LEBOM); model.changeLineEnding(.lf)
        model.changeWhitespace(.trimRight,tabWidth:4); model.setComparisonOptions(.init(ignoreCase:true)); model.load(); model.undo()
        view.insertText("blocked",replacementRange:NSRange(location:0,length:0))
        var saveRejected:Bool?; model.save(markResolved:false) { saveRejected = !$0 }
        try require(calls == 1 && saveRejected == true && model.resultPresentation == before && model.encoding == initialEncoding && model.comparisonOptions == options && !model.busy,"Pending format allowed concurrent mutation/reload/Save")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Pending format did not fence Quit")
        answer!.resume(returning:.init(encoding:.utf16BEBOM,ending:.cr)); answer = nil
        try await wait { !model.formatPending && model.encoding == .utf16BEBOM && model.resultLineEnding == .cr && view.isEditable }
        try require(model.alignedResultProjection != nil && model.alignedResultStates == states,"Combined format choice lost alignment")
        let formatted = model.resultPresentation
        model.undo(); try await wait { model.resultPresentation == initial && model.encoding == initialEncoding && model.resultLineEnding == .crlf && view.isEditable }
        model.redo(); try await wait { model.resultPresentation == formatted && model.encoding == .utf16BEBOM && view.isEditable }
        // Freeze Save in its output picker and reject keyboard/toolbar edits
        // immediately, before a deferred native isEditable refresh.
        var destination:CheckedContinuation<URL?,Never>?
        model.chooseStandaloneOutput = { _,_ in await withCheckedContinuation { destination = $0 } }
        model.confirmUnresolvedSave = { _ in true }
        let saving = model.resultPresentation
        model.save(markResolved:false)
        model.undo(); view.insertText("blocked",replacementRange:NSRange(location:0,length:0))
        let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
        try require(owner.window!.performKeyEquivalent(with:key),"Owned Undo key was not consumed")
        try require(model.resultPresentation == saving && model.encoding == .utf16BEBOM,"Save race consumed Undo or edited captured content")
        try await wait { destination != nil && model.busy }
        destination!.resume(returning:output); destination = nil
        try await wait { !model.busy && view.isEditable }
        try require(model.error == nil && Data(contentsOf:output) == ComparisonTextEncoding.utf16BEBOM.encode(saving.text) && !model.dirty,"Saved BOM/text/format baseline differ")
        model.undo(); try await wait { model.resultPresentation == initial && model.encoding == initialEncoding && model.dirty && view.isEditable }
        // A closed owner releases accounting immediately and refuses a late answer.
        model.showFormatDialog(); try await wait { answer != nil && model.formatPending }
        owner.close()
        try require(model.retired && !model.formatPending && MergeRegexOperations.activeRequests == 0,"Closed format owner leaked operation accounting")
        answer!.resume(returning:.init(encoding:.utf32LE,ending:.paragraphSeparator)); answer = nil
        await Task.yield()
        try require(model.resultPresentation == initial && model.encoding == initialEncoding,"Late format response changed closed document")
        try require(try Data(contentsOf:base) == Data(b.utf8) && Data(contentsOf:mine) == Data(m.utf8) && Data(contentsOf:theirs) == Data(t.utf8),"Format workflow rewrote read-only input files")
        // A legacy-encoded Mine can have Unicode in the other conflict side.
        // Formatting remains editable; Save still rejects a lossy encoding.
        let legacyBase = root.appendingPathComponent("legacy-base"), legacyMine = root.appendingPathComponent("legacy-mine"), legacyTheirs = root.appendingPathComponent("legacy-theirs"), rejectedOutput = root.appendingPathComponent("lossy-output")
        for (url,text) in [(legacyBase,"\tcommon  \nold\n"),(legacyMine,"\tcommon  \nmine\n"),(legacyTheirs,"\tcommon  \ntheirs 🐢\n")] { try Data(text.utf8).write(to:url) }
        let legacy = TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"legacy-mine",workingMerge:try WorkingTextMerge(base:legacyBase,theirs:legacyTheirs,mine:legacyMine),preferences:prefs), lm = legacy.model
        defer { legacy.close() }; legacy.window!.alphaValue = 0; legacy.window!.orderFront(nil); lm.load()
        func legacyWait(_ condition:()->Bool) async throws {
            for _ in 0..<2000 { legacy.window?.contentView?.layoutSubtreeIfNeeded(); if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(description:"Legacy formatting/Save wait")
        }
        try await legacyWait { !lm.busy && !lm.preparing && lm.document != nil && ThreePaneEngineVerification.textViews(legacy.window?.contentView).contains { $0.isEditable } }
        try require(lm.encoding == .windows1252 && lm.result.contains("🐢"),"Legacy/Unicode source scenario missing")
        lm.changeWhitespace(.tabsToSpaces,tabWidth:4)
        try await legacyWait { lm.result.hasPrefix("    common") }
        lm.changeLineEnding(.crlf)
        try await legacyWait { lm.resultLineEnding == .crlf }
        try require(lm.error == nil && lm.encoding == .windows1252 && lm.alignedResultProjection != nil,"Formatting required an unrelated encoding conversion")
        lm.chooseStandaloneOutput = { _,_ in rejectedOutput }; lm.confirmUnresolvedSave = { _ in true }; lm.save(markResolved:false)
        try await legacyWait { !lm.busy }
        try require(lm.error != nil && !FileManager.default.fileExists(atPath:rejectedOutput.path),"Lossy Save bypassed the encoding guard")
        lm.error = nil; legacy.close()
        try await legacyWait { MergeRegexOperations.activeRequests == 0 }
        print("PASS: aligned whitespace/ending commands retain row states and hidden conflict payloads, encoding/combined format Undo/Redo, owned real Cancel, injected duplicate/Save/reload/Quit gates, immediate Save-versus-Undo/typing/key races, exact UTF-16BE BOM Save, legacy/Unicode formatting with lossless Save rejection, closed-owner accounting and late-answer refusal; owned window closed")
    }
}
