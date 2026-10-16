import AppKit
import TurtleGitCore

struct MergeTerminalRecordVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {
        for _ in 0..<2000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Terminal record timeout at line \(line)")
    }
    @MainActor static func verify()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitTerminal-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.Terminal."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        let a=root.appendingPathComponent("before.txt"),b=root.appendingPathComponent("after.txt"),export=root.appendingPathComponent("export.txt")
        let text="head 🐢\r\n",bytes=try ComparisonTextEncoding.utf16LEBOM.encode(text)
        try bytes.write(to:a);try bytes.write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model
        defer {owner.close()};owner.window!.alphaValue=0;owner.window!.setContentSize(.init(width:1150,height:700));owner.window!.orderFront(nil)
        model.commentProfileURL=root.appendingPathComponent("comments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        func editors()->[NSTextView] {TwoPaneEngineVerification.editors(owner.window?.contentView).filter {$0 is ComparisonContextMenuProviding}}
        try await wait {editors().count==2 && editors().allSatisfy {($0.enclosingScrollView?.verticalRulerView as? MergeLineRuler)?.sourceNumbers==[1,2]}}
        let right=editors().first {$0.isEditable} ?? editors().last!,nav=right as! MergeLineNavigationProviding
        try require(model.alignment?.rows.count==2 && model.alignment?.differences.isEmpty==true && nav.navigationCells?.last?.text=="","Actual engine/native pane lost final NoEnding record")
        try require(right.string=="head 🐢\n\n" && model.locatorMap.lineCount==2,"Final record did not reach display/locator")
        var limit=0;nav.chooseNavigationLine={_,maximum in limit=maximum;return maximum}
        right.perform(NSSelectorFromString("goToSourceLine:"),with:nil)
        try await wait {!nav.navigationPending && limit==2 && right.selectedRange()==NSRange(location:"head 🐢\n".utf16.count,length:0)}
        model.chooseExportLocation={_,_,_ in export};model.export(base:false);try await wait {!model.busy && FileManager.default.fileExists(atPath:export.path)}
        try require(try Data(contentsOf:export)==bytes && !model.dirty,"Export serialized a display-only EOF separator")
        model.activatePane(base:false);model.editingEnabled=true;try await wait {right.isEditable}
        right.insertText("tail 🐢",replacementRange:right.selectedRange());try await wait {model.draftText(base:false)==text+"tail 🐢"}
        try require(model.alignment?.rows.last?.destination.state == .edited,"EOF typing lost in-place edited row")
        model.undo();try await wait {!model.dirty && model.draftText(base:false)==text}
        model.redo();try await wait {model.draftText(base:false)==text+"tail 🐢"}
        model.save();try await wait {!model.busy && !model.dirty}
        let saved=try Data(contentsOf:b)
        try require(saved==ComparisonTextEncoding.utf16LEBOM.encode(text+"tail 🐢") && Data(contentsOf:a)==bytes,"Save lost BOM/endings/EOF bytes or changed Base")
        model.load();try await TwoPaneEngineVerification.settled(model)
        try await wait {model.alignment?.rows.count==2 && model.alignment?.rows.last?.base.text=="" && model.alignment?.rows.last?.destination.text=="tail 🐢"}
        try require(model.alignment?.rows.last?.base.lineNumber==2 && model.alignment?.rows.last?.base.state == .removed,"Base EOF did not occupy the trailing alignment gap")
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        try require(model.combined?.cells.map(\.text)==[text,"tail 🐢"] && model.combined?.sourceSaveText==text+"tail 🐢","Combined view retained the two-pane-only terminal record")
        model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
        if ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] != nil {try await MergeMarginVerification.capture(owner.window!,"merge-terminal-records")}
        owner.close()
        // An empty file has a real line 1 NoEnding record, distinct from a gap.
        let c=root.appendingPathComponent("empty-left.txt"),d=root.appendingPathComponent("empty-right.txt")
        try Data().write(to:c);try Data().write(to:d)
        let empty=FileComparisonWindowController(comparison:try WorkingFileComparison(base:c,destination:d),permissions:[],preferences:prefs),e=empty.model
        defer {empty.close()};empty.window!.alphaValue=0;empty.window!.orderFront(nil);e.load();try await TwoPaneEngineVerification.settled(e)
        try await wait {e.alignment?.rows.count==1 && TwoPaneEngineVerification.editors(empty.window?.contentView).filter {$0 is ComparisonContextMenuProviding}.count==2}
        let view=TwoPaneEngineVerification.editors(empty.window?.contentView).first {$0.isEditable}!
        try require(e.alignment?.rows[0].destination.lineNumber==1 && e.alignment?.rows[0].destination.state == .normal,"Empty document became an alignment gap")
        view.insertText("first 🐢",replacementRange:NSRange(location:0,length:0));try await wait {e.draftText(base:false)=="first 🐢"}
        e.undo();try await wait {!e.dirty && e.draftText(base:false).isEmpty}
        empty.close();try require(try Data(contentsOf:c).isEmpty && Data(contentsOf:d).isEmpty,"Empty-document editing wrote source files")
        print("PASS: actual two-pane terminal/empty records and gap placement, source line chooser/locator, exact export and UTF-16 BOM/CRLF Save, EOF typing Undo/Redo/reload, combined exclusion, empty-file input/history and owned cleanup")
    }
}
