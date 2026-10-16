import AppKit
import TurtleGitCore

struct MergeTypingVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.Typing."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let a=folder.appendingPathComponent("base.txt"),b=folder.appendingPathComponent("mine.txt"),t=folder.appendingPathComponent("theirs.txt")
        let base=Data("A🦎e\u{301}Z\r\nold\r\nlast".utf8),mine=Data("A🦎e\u{301}Z\r\nnew\r\nlast".utf8),theirs=Data("A🦎e\u{301}Z\r\ntheirs\r\nlast".utf8)
        try base.write(to:a);try mine.write(to:b);try theirs.write(to:t)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        let menu=owner.editorCommandMenu!,root=NSMenu(title:"typing")
        menu.keyWindow={window};menu.applicationMenu={root};menu.install(in:root)
        let view=MergeMarkedWordInterface.panes(in:window.contentView).first{$0.string.contains("new")}!
        window.makeFirstResponder(view);view.setSelectedRange(NSRange(location:1,length:0))
        try require(MergeMenuLifecycleVerification.key(NSInsertFunctionKey,114,[],window) && (view as! MergeTypingProviding).mergeOverwrite,"Insert did not toggle overwrite")
        let typingView=view as! MergeTypingProviding
        let original=model.draftText(base:false),selection=NSRange(location:1,length:0)
        view.insertText("雪",replacementRange:NSRange(location:NSNotFound,length:0))
        try require(model.draftText(base:false)=="A雪e\u{301}Z\r\nnew\r\nlast","Overwrite split emoji or touched ending")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==original && (view as! MergeTypingProviding).mergeOverwrite,"Undo changed mode or lost bytes")
        view.setSelectedRange(NSRange(location:3,length:0));view.insertText(NSAttributedString(string:"🐢"),replacementRange:NSRange(location:NSNotFound,length:0))
        try require(model.draftText(base:false)=="A🦎🐢Z\r\nnew\r\nlast","Overwrite split decomposed character")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        // Explicit paste remains insertion even when it contains just one character.
        view.setSelectedRange(selection);view.insertText("P",replacementRange:selection)
        try require(model.draftText(base:false)=="AP🦎e\u{301}Z\r\nnew\r\nlast","Paste was overwritten")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        print("Typing phase: Unicode, selection and paste passed");fflush(stdout)
        let lineEnd=(view.string as NSString).range(of:"\n").location
        view.setSelectedRange(NSRange(location:lineEnd,length:0));view.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0))
        try require(model.draftText(base:false)=="A🦎e\u{301}Z!\r\nnew\r\nlast","Overwrite consumed line ending")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        view.setSelectedRange(NSRange(location:1,length:4));view.insertText("S",replacementRange:NSRange(location:NSNotFound,length:0))
        try require(model.draftText(base:false)=="ASZ\r\nnew\r\nlast","Explicit selection was extended")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        view.setSelectedRange(NSRange(location:1,length:0))
        try require(MergeMenuLifecycleVerification.key(13,36,.control,window),"Ctrl-Enter route missing")
        try require(model.draftText(base:false)=="A🦎e\u{301}Z\rnew\r\nlast" && view.selectedRange().location==1,"Current-row cycle changed neighbours/caret")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==original,"Ending cycle Undo lost baseline")
        print("Typing phase: row cycle and Undo passed");fflush(stdout)
        let last=(view.string as NSString).range(of:"last").location
        view.setSelectedRange(NSRange(location:last,length:0));try require(!typingView.canCycleCurrentEnding,"Unended EOF may not gain ending")
        model.busy=true;let mode=(view as! MergeTypingProviding).mergeOverwrite;typingView.toggleMergeOverwrite();typingView.cycleCurrentEnding()
        try require((view as! MergeTypingProviding).mergeOverwrite==mode && model.draftText(base:false)==original,"Busy typing command dispatched");model.busy=false
        let changed=(view.string as NSString).range(of:"new");view.setSelectedRange(changed);model.updateSelection(changed,cells:model.displayCells(base:false))
        try require(MergeMenuLifecycleVerification.key(109,46,.control,window) && !model.annotations(base:false).marked.isEmpty,"Ctrl-M did not mark")
        try require(MergeMenuLifecycleVerification.key(109,46,.control,window) && model.annotations(base:false).marked.isEmpty,"Ctrl-M did not unmark")
        print("Typing phase: marks and busy fences passed");fflush(stdout)
        model.resetHistory();model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        let combined=MergeMarkedWordInterface.panes(in:window.contentView).first{$0.string.contains("new")}!
        window.makeFirstResponder(combined);let removed=(combined.string as NSString).range(of:"old")
        combined.setSelectedRange(NSRange(location:removed.location,length:0));(combined as! MergeTypingProviding).cycleCurrentEnding()
        try require(model.draftText(base:false)=="A🦎e\u{301}Z\r\nold\rnew\r\nlast","Combined removed-row cycle lost saved rows")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==original,"Combined cycle Undo failed")
        print("Typing phase: combined removed-row cycle and Undo passed");fflush(stdout)
        let saveRow=(combined.string as NSString).range(of:"new")
        combined.setSelectedRange(NSRange(location:saveRow.location,length:0));(combined as! MergeTypingProviding).cycleCurrentEnding()
        let saved=model.draftText(base:false),output=folder.appendingPathComponent("cycled-output.txt")
        model.chooseExportLocation={_,_,_ in output};model.saveAs(base:false)
        try await TwoPaneEngineVerification.wait{!model.exporting && FileManager.default.fileExists(atPath:output.path)}
        try require(try Data(contentsOf:output)==Data(saved.utf8),"Save As changed exact mixed line endings")
        print("Typing phase: exact Save As passed");fflush(stdout)
        menu.retire();owner.close()
        let merge=TextConflictWindowController(repository:GitRepository(root:folder,executable:URL(fileURLWithPath:CommandLine.arguments[2])),access:nil,path:b.path,workingMerge:try WorkingTextMerge(base:a,theirs:t,mine:b),preferences:prefs)
        defer {merge.close()};merge.window!.alphaValue=0;merge.window!.orderFront(nil);merge.model.load()
        try await ThreePaneEngineVerification.wait{!merge.model.busy && merge.model.document != nil && (merge.window as? TextConflictNSWindow)?.mergedText != nil}
        let result=(merge.window as! TextConflictNSWindow).mergedText!,typing=result as! MergeTypingProviding,mergedOriginal=merge.model.result
        print("Typing phase: three-pane editor loaded");fflush(stdout)
        let triple=merge.editorCommandMenu!;triple.keyWindow={merge.window};triple.applicationMenu={root};triple.install(in:root)
        merge.window!.makeFirstResponder(result);result.setSelectedRange(NSRange(location:1,length:0))
        typing.toggleMergeOverwrite();result.insertText("雪",replacementRange:NSRange(location:NSNotFound,length:0))
        try require(merge.model.result.hasPrefix("A雪e\u{301}Z\r\n"),"Merged overwrite did not preserve Unicode/CRLF")
        merge.model.undo();try require(merge.model.result==mergedOriginal,"Merged overwrite Undo")
        result.setSelectedRange(NSRange(location:1,length:0))
        let beforeStates=merge.model.resultPresentation.states(conflicts:merge.model.blocks.map(\.range)),beforeConflicts=merge.model.blocks.count
        typing.cycleCurrentEnding();try require(merge.model.result.hasPrefix("A🦎e\u{301}Z\r") && !merge.model.result.hasPrefix("A🦎e\u{301}Z\r\n"),"Merged current ending cycle")
        try require(merge.model.blocks.count==beforeConflicts,"Ending cycle dropped conflicts")
        merge.model.undo();try require(merge.model.result==mergedOriginal && merge.model.resultPresentation.states(conflicts:merge.model.blocks.map(\.range))==beforeStates,"Merged cycle Undo lost conflict metadata")
        merge.model.busy=true;let mergedMode=typing.mergeOverwrite;typing.toggleMergeOverwrite();typing.cycleCurrentEnding();try require(typing.mergeOverwrite==mergedMode && merge.model.result==mergedOriginal,"Merged busy command dispatched");merge.model.busy=false
        merge.close();typing.toggleMergeOverwrite();typing.cycleCurrentEnding();try require(merge.model.result==mergedOriginal,"Retired typing command dispatched")
        try require(try Data(contentsOf:a)==base && Data(contentsOf:b)==mine && Data(contentsOf:t)==theirs,"Typing checks wrote source files")
        print("PASS: Insert/Overwrite committed Unicode typing, selection/paste/line-ending boundaries, native source shortcuts and marks, current-row and combined removed-row ending cycles, conflict metadata and one-step Undo, exact mixed-ending Save As, busy/retired fences and unchanged inputs; owned windows closed")
    }
}
