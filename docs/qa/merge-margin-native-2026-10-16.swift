import AppKit
import TurtleGitCore

struct MergeMarginVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value {throw Failure(description:message)} }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Margin timeout at line \(line)")
    }
    @MainActor static func capture(_ owner:NSWindow,_ name:String)async throws {
        guard let output=ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] else {return}
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            owner.appearance=NSAppearance(named:appearance);owner.alphaValue=1;owner.orderFront(nil)
            try await Task.sleep(nanoseconds:250_000_000)
            owner.contentView?.layoutSubtreeIfNeeded();owner.contentView?.displayIfNeeded()
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments=["-x","-o","-l",String(owner.windowNumber),URL(fileURLWithPath:output).appendingPathComponent(name+"-"+suffix+".png").path]
            try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Margin capture helper failed")
        }
        owner.alphaValue=0
    }
    @MainActor static func verify()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMargin-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.Margin."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        MergeEditorPreferences(showLineNumbers:false).save(to:prefs);MergeComparisonOptions.exact.save(to:prefs)
        let a=root.appendingPathComponent("before.txt"),b=root.appendingPathComponent("after.txt")
        let old=Data("header\nvalue = 1;\nold record\nfooter\n".utf8),new=Data("header\nvalue=1;\nnew record\nfooter\n".utf8)
        try old.write(to:a);try new.write(to:b)
        let pair=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=pair.model
        defer {pair.close()};pair.window!.alphaValue=0;pair.window!.setContentSize(.init(width:1100,height:650));pair.window!.orderFront(nil)
        model.commentProfileURL=root.appendingPathComponent("comments.txt");model.load()
        try await TwoPaneEngineVerification.settled(model)
        func views()->[NSTextView] {TwoPaneEngineVerification.editors(pair.window?.contentView).filter {$0 is ComparisonContextMenuProviding}}
        try await wait {views().count==2 && views().allSatisfy {($0.enclosingScrollView?.verticalRulerView as? MergeLineRuler)?.presentation.symbols.count==5}}
        let left=views().first {$0.string.contains("old record")}!,right=views().first {$0.string.contains("new record")}!
        let lr=left.enclosingScrollView!.verticalRulerView as! MergeLineRuler,rr=right.enclosingScrollView!.verticalRulerView as! MergeLineRuler
        try require(lr.symbol(at:1) == .whitespace && rr.symbol(at:1) == .whitespace && lr.symbol(at:2) == .removed && rr.symbol(at:2) == .added,"Actual two-pane margin states/whitespace differ")
        try require(!lr.showNumbers && left.enclosingScrollView!.rulersVisible && lr.ruleThickness==20,"Hiding numbers removed source icon margin")
        for icon in [MenuIcon.mergeLineAdded,.mergeLineRemoved,.mergeLineConflict,.mergeLineIgnored,.mergeLineEdited,.mergeLineEqual,.mergeLineWhitespace] {try require(icon.image()?.isTemplate==false,"Original colored margin artwork missing")}
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            pair.window!.appearance=NSAppearance(named:appearance);pair.window!.contentView?.layoutSubtreeIfNeeded()
            lr.needsDisplay=true;lr.displayIfNeeded()
            let range=MergeLineEndings.lineRanges(in:left.string)[1],layout=left.layoutManager!,container=left.textContainer!
            layout.ensureLayout(for:container)
            let frame=layout.lineFragmentRect(forGlyphAt:layout.glyphIndexForCharacter(at:range.location),effectiveRange:nil)
            let point=lr.convert(NSPoint(x:0,y:frame.midY+left.textContainerOrigin.y),from:left)
            try require(lr.view(lr,stringForToolTip:0,point:NSPoint(x:5,y:point.y),userData:nil)=="Whitespace-only changes","Actual visible margin tooltip missing")
        }
        try await capture(pair.window!,"merge-margin-compare")
        model.activatePane(base:false);model.editingEnabled=true;try await wait {right.isEditable}
        model.selectedRows=2..<3;model.markBlock(true,targetBase:false)
        try await wait {rr.markedRows.contains(2)}
        try require(rr.symbol(at:2) == .marked,"Marked block did not override state icon")
        model.undo();try await wait {!rr.markedRows.contains(2)}
        let range=(right.string as NSString).range(of:"new record")
        right.insertText("typed record",replacementRange:range)
        try await wait {rr.symbol(at:2) == .edited}
        model.undo();try await wait {rr.symbol(at:2) == .added && !model.dirty}
        model.showLineNumbers=true;try await wait {lr.showNumbers && lr.ruleThickness>20}
        var hiddenRegistrations=0
        model.onRegisterScroll={_,base in if base {hiddenRegistrations += 1}}
        model.switchPaneMode(true)
        // Reproduce the hosted interleaving: an outgoing split child registers
        // after One Pane has already removed its visible slot.
        model.register(left.enclosingScrollView!,base:true)
        try await TwoPaneEngineVerification.settled(model)
        try require(hiddenRegistrations == 0 && model.alignmentSelections.isEmpty,"Hidden left pane registered/restored after combined switch")
        model.onRegisterScroll={_,_ in}
        try await wait {views().count==1 && (views()[0].enclosingScrollView?.verticalRulerView as? MergeLineRuler)?.presentation.symbols.contains(.added)==true}
        let combined=views()[0].enclosingScrollView!.verticalRulerView as! MergeLineRuler
        try require(combined.presentation.symbols.contains(.removed) && !combined.presentation.symbols.contains(.whitespace),"Combined margin invented an opposite pane")
        pair.close()
        // Actual three-pane sources and marker-free aligned result.
        let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt")
        for (url,text) in [(base,"head\nbase\nfoot\n"),(mine,"head\nmine\nfoot\n"),(theirs,"head\ntheirs\nfoot\n")] {try Data(text.utf8).write(to:url)}
        let three=TextConflictWindowController(repository:GitRepository(root:root),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs),merge=three.model
        defer {three.close()};three.window!.alphaValue=0;three.window!.setContentSize(.init(width:1200,height:800));three.window!.orderFront(nil);merge.load()
        try await wait {!merge.busy && !merge.preparing && merge.blocks.count==1}
        func panes()->[NSTextView] {ThreePaneEngineVerification.textViews(three.window?.contentView).filter {$0 is MergeContextMenuProviding}}
        try await wait {panes().count==3 && panes().allSatisfy {($0.enclosingScrollView?.verticalRulerView as? MergeLineRuler)?.presentation.symbols.isEmpty==false}}
        let result=panes().first {$0.isEditable}!,ruler=result.enclosingScrollView!.verticalRulerView as! MergeLineRuler
        try require(ruler.presentation.symbols.contains(.conflict) && ruler.presentation.symbols.contains(.removed),"Aligned result omitted conflict/removed margin icons")
        try require(panes().filter {!$0.isEditable}.allSatisfy {($0.enclosingScrollView?.verticalRulerView as? MergeLineRuler)?.presentation.symbols.contains(.added)==true},"Source conflict additions omitted gutter symbols")
        try await capture(three.window!,"merge-margin-conflict")
        let baseline=merge.resultPresentation,initialDirty=merge.dirty
        let first=(result.string as NSString).range(of:"head")
        result.insertText("edited head",replacementRange:first);try await wait {ruler.symbol(at:0) == .edited}
        merge.undo();try await wait {ruler.symbol(at:0)==nil && merge.resultPresentation==baseline && merge.dirty==initialDirty}
        merge.selectConflict(0);merge.choose(.mine);try await wait {!merge.hasUnresolvedConflicts && !ruler.presentation.symbols.contains(.conflict)}
        merge.undo();try await wait {ruler.presentation.symbols.contains(.conflict)}
        try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==new && String(contentsOf:mine)=="head\nmine\nfoot\n","Margin/edits/history altered source bytes")
        three.close()
        print("PASS: original margin artwork, actual two/combined/three-pane states and whitespace blocks, light/dark draw/tooltips, icon-only margin, marked/edited priority and Undo, aligned unresolved/resolved result refresh, unchanged files; owned windows and capture helpers closed")
    }
}
