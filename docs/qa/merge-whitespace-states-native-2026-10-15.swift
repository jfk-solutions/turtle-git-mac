// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

struct MergeWhitespaceStatesVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Whitespace states wait at line \(line)")
    }
    @MainActor static func rgb(_ color:NSColor,_ appearance:NSAppearance)->UInt32? {
        var value:UInt32?;appearance.performAsCurrentDrawingAppearance {if let c=color.usingColorSpace(.sRGB) {value=UInt32((c.redComponent*255).rounded())<<16 | UInt32((c.greenComponent*255).rounded())<<8 | UInt32((c.blueComponent*255).rounded())}};return value
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),output=root.appendingPathComponent("export.txt")
        let old="head\r\nversion 1\r\nmiddle\r\nold content\r\nlast",new="head\r\nversion 2\r\nmiddle\r\nnew content\r\nlast"
        let baseBytes=try ComparisonTextEncoding.utf16LEBOM.encode(old),mineBytes=try ComparisonTextEncoding.utf8BOM.encode(new)
        try baseBytes.write(to:base);try mineBytes.write(to:mine)
        let suite="TurtleGit.WhitespaceStates."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);MergePalette.reload()}
        prefs.set(true,forKey:"TurtleGitMerge.OnePane");MergeComparisonOptions.exact.save(to:prefs)
        let filter=MergeRegexFilter(name:"Versions",expression:"[0-9]+",replacement:"");try MergeRegexFilters.save([filter],defaults:prefs)
        var palette=MergeColorPreferences();palette.light[.normal] = .init(0x112233,0x345678);palette.dark[.normal] = .init(0xabcdef,0x234567);try palette.save(to:prefs);MergePalette.reload(defaults:prefs)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");model.regexDefaults=prefs;model.refreshRegexFilters();model.load();try await TwoPaneEngineVerification.settled(model)
        model.selectRegexFilter(filter.name);try await TwoPaneEngineVerification.settled(model)
        try await wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1}
        var view=TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        try await wait{view.string.contains("version 1") && view.string.contains("version 2")}
        let combined=model.combined!
        try require(combined.cells[1].state == .removedWhitespace && combined.cells[2].state == .addedWhitespace && combined.cells[1].lineNumber == 2 && combined.cells[2].lineNumber == 2,"Combined aliases or source line numbers differ")
        let counts=MergeLineStatistics(states:combined.cells.map(\.state));try require(counts.removed == 1 && counts.added == 1,"Neutral aliases counted as real additions/removals")
        let finder=view as! MergeFindProviding
        try require(MergeFind.matches("version",in:finder.mergeFindLines,options:.init(modifiedOnly:true)).count == 2,"Modified-only Find lost neutral aliases")
        for (name,dark) in [(NSAppearance.Name.aqua,false),(.darkAqua,true)] {
            let appearance=NSAppearance(named:name)!;owner.window!.appearance=appearance;model.objectWillChange.send()
            try await wait{guard let color=view.textStorage?.attribute(.backgroundColor,at:(view.string as NSString).range(of:"version 1").location,effectiveRange:nil) as? NSColor else{return false};return rgb(color,appearance) == MergeColorPreferences.standard(.normal,dark:dark).background}
        }
        model.setCollapsed(true);try require(model.folding.folding.visibility[1] == .shown && model.folding.folding.visibility[2] == .shown,"Compare-mode filtered pairs folded away")
        model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
        try require(model.alignment!.rows[1].base.state == .filtered && !model.alignment!.rows[1].base.hiddenByComparison,"Two-pane filter rows lost visible green state")
        model.setComparisonOptions(.init(whitespace:.ignoreAll));try await TwoPaneEngineVerification.settled(model)
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        try require(model.combined!.cells.filter{$0.displayText.hasPrefix("version")}.map(\.text) == ["version 2\r\n"],"Ignore All did not collapse the source common pair")
        model.setCollapsed(false)
        let beforeOptions=TwoPaneEngineVerification.editors(owner.window?.contentView)[0]
        try await wait{beforeOptions.string.contains("new content")}
        beforeOptions.setSelectedRange((beforeOptions.string as NSString).range(of:"new content"));await Task.yield()
        model.setComparisonOptions(.init(whitespace:.ignoreChanges));try await TwoPaneEngineVerification.settled(model)
        try require(model.combined!.cells[1].hiddenByComparison && model.combined!.cells[2].hiddenByComparison,"Ignore Changes did not retain hidden neutral aliases")
        model.setCollapsed(true)
        try await wait{model.folding.folding.visibility.count == model.combined!.cells.count && model.folding.folding.visibility[1] != .shown && model.folding.folding.visibility[2] != .shown}
        try require(model.combined!.cells[1].state == .removedWhitespace && model.combined!.cells[2].state == .addedWhitespace,"Ignore Changes lost source alias identities")
        model.setComparisonOptions(.exact);try await TwoPaneEngineVerification.settled(model);model.setCollapsed(false)
        try await wait{TwoPaneEngineVerification.editors(owner.window?.contentView).count == 1}
        view=TwoPaneEngineVerification.editors(owner.window?.contentView)[0];try await wait{view.string.contains("version 1") && view.string.contains("new content")}
        model.chooseExportLocation={_,_,_ in output};model.export(base:false);try await wait{!model.exporting && FileComparisonWindowModel.activePaneExports == 0}
        let exported="head\r\nversion 1\r\nversion 2\r\nmiddle\r\nnew content\r\nlast"
        try require(try Data(contentsOf:output) == ComparisonTextEncoding.utf8BOM.encode(exported),"Explicit source Save As did not serialize neutral rows/encoding/endings")
        try require(try Data(contentsOf:base) == baseBytes && Data(contentsOf:mine) == mineBytes,"Viewing/export changed input files")
        model.activatePane(base:false);model.editingEnabled=true;try await wait{view.isEditable}
        view.insertText("edited content",replacementRange:(view.string as NSString).range(of:"new content"));try await TwoPaneEngineVerification.settled(model)
        let edited="head\r\nversion 1\r\nversion 2\r\nmiddle\r\nedited content\r\nlast"
        try require(model.draftText(base:false) == edited && model.canUndo,"Editing lost neutral payloads or included a real removal: draft=\(String(reflecting:model.draftText(base:false))) undo=\(model.canUndo)")
        model.undo();try await TwoPaneEngineVerification.settled(model);try require(model.draftText(base:false) == new && !model.dirty,"Neutral edit Undo lost original Mine")
        model.redo();try await TwoPaneEngineVerification.settled(model);model.save();try await wait{!model.busy && !model.filtering && !model.dirty}
        try require(try Data(contentsOf:mine) == ComparisonTextEncoding.utf8BOM.encode(edited) && Data(contentsOf:base) == baseBytes,"Neutral edit Save changed Base/encoding/endings")
        print("PASS: source neutral whitespace rows, independent palette/line numbers/counts, mode/filter/fold/Find behavior, exact explicit export and native editing/Undo/Redo/Save; owned window closed")
    }
}
