import AppKit
import TurtleGitCore

struct MergeMovedBlocksVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func verify() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMoved-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let suite="TurtleGit.MovedNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:folder) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        MergeComparisonOptions.exact.save(to:prefs)
        let a=folder.appendingPathComponent("before.txt"),b=folder.appendingPathComponent("after.txt")
        let block=["moved function 🐢 {","  return café;","}"]
        let common=(0..<12).map { "unchanged record \($0)" }
        let old=Data((["head"]+block+common+["tail"]).joined(separator:"\n").appending("\n").utf8)
        let new=Data((["head"]+common+block+["tail"]).joined(separator:"\n").appending("\n").utf8)
        try old.write(to:a);try new.write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model
        defer { owner.close() }
        owner.window!.alphaValue=0;owner.window!.setContentSize(.init(width:1300,height:800));owner.window!.orderFront(nil)
        model.commentProfileURL=folder.appendingPathComponent("comments.txt");model.load();try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait { model.window?.contentView?.layoutSubtreeIfNeeded();return TwoPaneEngineVerification.editors(model.window?.contentView).filter{$0 is ComparisonContextMenuProviding}.count==2 && !model.lineWrapping.isGeometryPending }
        let views=TwoPaneEngineVerification.editors(owner.window!.contentView).filter{$0 is ComparisonContextMenuProviding}
        let left=views.first { ($0.enclosingScrollView!.verticalRulerView as? MergeLineRuler)?.sourceNumbers?.firstIndex(of:2)==1 }!
        let right=views.first { $0 !== left }!
        let sourceRows=model.movedRowLinks(base:true),targetRows=model.movedRowLinks(base:false)
        try require(model.showMovedBlocks && model.movedBlockRecords==[.init(base:1..<4,mine:13..<16)],"Native source move coordinates/default")
        try require(sourceRows.count==3 && targetRows.count==3,"Missing bidirectional margin links")
        let sourceRow=sourceRows.keys.min()!,target=sourceRows[sourceRow]!,generation=model.alignmentGeneration
        try require(sourceRows[sourceRow]!.tooltip=="Moved to line 14","Moved-to tooltip")
        let ruler=left.enclosingScrollView!.verticalRulerView as! MergeLineRuler
        try await TwoPaneEngineVerification.wait { ruler.movedRows.count==3 }
        try require(MenuIcon.mergeMoved.image()?.isTemplate==false,"Original colored move artwork unavailable")
        let textSnapshot=views.map(\.string)
        model.followMovedBlock(row:sourceRow,base:true,generation:generation)
        try require(model.activeBase==false && owner.window!.firstResponder === right,"Move link did not activate peer")
        let selected=(right as! MergeBlockSelecting).mergeSelectedBlockRange!
        try require((right.string as NSString).substring(with:selected)==block.joined(separator:"\n"),"Move link did not select whole peer block")
        try require(model.selectedRows==target.rows && views.map(\.string)==textSnapshot && !model.dirty && !model.canUndo,"Move link mutated text/history")
        let back=targetRows.keys.min()!;model.followMovedBlock(row:back,base:false,generation:generation)
        try require(model.activeBase && owner.window!.firstResponder === left,"Reverse move link did not activate source")
        // The physical native ruler receives an owned double-click event; no
        // event is posted globally and no unrelated app is activated.
        left.scrollRangeToVisible(NSRange(location:0,length:0));left.enclosingScrollView!.reflectScrolledClipView(left.enclosingScrollView!.contentView)
        ruler.needsDisplay=true;ruler.displayIfNeeded()
        let range=MergeLineEndings.lineRanges(in:left.string)[sourceRow],layout=left.layoutManager!,container=left.textContainer!
        layout.ensureLayout(for:container)
        let rect=layout.lineFragmentRect(forGlyphAt:layout.glyphIndexForCharacter(at:range.location),effectiveRange:nil)
        let local=ruler.convert(NSPoint(x:0,y:rect.midY+left.textContainerOrigin.y),from:left)
        let point=ruler.convert(NSPoint(x:ruler.bounds.midX,y:local.y),to:nil)
        let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1)!
        ruler.mouseDown(with:event)
        try require(model.activeBase==false,"Native ruler double-click did not follow move")
        model.activatePane(base:false);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { right.isEditable }
        right.setSelectedRange(NSRange(location:0,length:0));right.insertText("typed ",replacementRange:right.selectedRange())
        try require(model.movedRowLinks(base:true).count==3 && model.movedRowLinks(base:false).count==3,"Typing lost unaffected move identities")
        let movedAfterTyping=model.movedRowLinks(base:true).keys.min()!
        let beforeStale=right.selectedRange();model.followMovedBlock(row:sourceRow,base:true,generation:generation)
        try require(right.selectedRange()==beforeStale,"Pre-edit menu generation accepted")
        model.followMovedBlock(row:movedAfterTyping,base:true,generation:model.alignmentGeneration)
        try require((right.string as NSString).substring(with:(right as! MergeBlockSelecting).mergeSelectedBlockRange!)==block.joined(separator:"\n"),"Remapped move selection after typing")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(!model.dirty && !model.movedBlockRecords.isEmpty,"Undo lost exact pre-edit move metadata")
        model.activatePane(base:false);model.editingEnabled=true
        right.setSelectedRange(NSRange(location:0,length:0));right.insertText("inserted\n",replacementRange:right.selectedRange())
        let shifted=model.movedRowLinks(base:true).first{$0.value.tooltip=="Moved to line 14"}
        try require(shifted != nil,"Multiline insertion lost surviving source move")
        try require(shifted!.key==sourceRow+1 && shifted!.value.targetRow==target.targetRow+1,"Multiline insertion did not shift both aligned move records")
        model.followMovedBlock(row:shifted!.key,base:true,generation:model.alignmentGeneration)
        try require((right.string as NSString).substring(with:(right as! MergeBlockSelecting).mergeSelectedBlockRange!)==block.joined(separator:"\n"),"Shifted move selected wrong records")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.movedRowLinks(base:true)[sourceRow]?.targetRow==target.targetRow,"Multiline Undo did not restore peer")

        // A captured old generation must never navigate a replacement projection.
        model.setMovedBlocks(false);try await TwoPaneEngineVerification.settled(model)
        try require(!model.showMovedBlocks && model.movedBlockRecords.isEmpty && !MergeMovedBlock.enabled(defaults:prefs),"Disabled move reload/persistence")
        let caret=right.selectedRange();model.followMovedBlock(row:sourceRow,base:true,generation:generation)
        try require(right.selectedRange()==caret,"Stale move target accepted")
        model.setMovedBlocks(true);try await TwoPaneEngineVerification.settled(model)
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(owner.window!.contentView).filter{$0 is ComparisonContextMenuProviding}.count==1 }
        let combined=TwoPaneEngineVerification.editors(owner.window!.contentView).first{$0 is ComparisonContextMenuProviding}!
        let links=model.movedRowLinks(base:false),from=links.first{$0.value.tooltip=="Moved to line 14"}!
        model.followMovedBlock(row:from.key,base:false,generation:model.alignmentGeneration)
        try require(owner.window!.firstResponder === combined && model.selectedRows != nil,"Combined move navigation lost owner")
        let menu=(combined as! ComparisonContextMenuProviding).comparisonContextMenu(defaults:prefs,pasteboard:NSPasteboard(name:.init("TurtleGit.Moved."+UUID().uuidString)))
        try require(menu.items.contains{$0.title=="Go to moved block" && $0.image != nil},"Accessible native move context command missing")
        model.setMovedBlocks(false);try await TwoPaneEngineVerification.settled(model)
        model.activatePane(base:false);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { combined.isEditable }
        combined.setSelectedRange(NSRange(location:0,length:0));combined.insertText("draft ",replacementRange:combined.selectedRange())
        try await TwoPaneEngineVerification.settled(model)
        var answer:((NSApplication.ModalResponse)->Void)?,question:NSAlert?
        model.presentProjectionQuestion={ alert,_,reply in question=alert;answer=reply }
        model.setMovedBlocks(true)
        try require(model.confirmingQuit && !model.showMovedBlocks && question != nil,"Dirty move toggle did not own Save question")
        answer?(.init(rawValue:NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+question!.buttons.count-1))
        try require(!model.confirmingQuit && model.dirty && !model.showMovedBlocks && !MergeMovedBlock.enabled(defaults:prefs),"Cancel lost draft/toggle preference")
        model.setMovedBlocks(true);answer?(.alertSecondButtonReturn);try await TwoPaneEngineVerification.settled(model)
        try require(model.showMovedBlocks && !model.dirty && !model.canUndo && !model.movedBlockRecords.isEmpty,"Discard/reload did not restore move mapping")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_WRAP_CAPTURE"] {
            model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
            model.showLineDiffBar=false
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                owner.window!.appearance=NSAppearance(named:appearance);owner.window!.alphaValue=1;owner.window!.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:350_000_000)
                let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");capture.arguments=["-x","-o","-l",String(owner.window!.windowNumber),URL(fileURLWithPath:output).appendingPathComponent("merge-moved-blocks-"+name+".png").path]
                try capture.run();capture.waitUntilExit();try require(capture.terminationStatus==0,"Move capture helper failed")
            }
        }
        try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==new,"Move family changed original files")
        owner.close();model.setMovedBlocks(false)
        try require(model.showMovedBlocks && model.movedRowLinks(base:false).isEmpty,"Retired move callbacks accepted")
        print("PASS: native move detection, original icons/tooltips, bidirectional whole-block margin and context navigation, two/combined projection, stale targets, Save/Cancel/discard reload, private persistence and unchanged files; owned window closed")
    }
}
