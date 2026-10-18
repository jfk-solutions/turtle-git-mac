import AppKit
import SwiftUI
import TurtleGitCore

struct MergeEditHistoryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String) throws {if !value {throw Failure(description:text)}}
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.EditHistory."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let a=folder.appendingPathComponent("base.txt"),b=folder.appendingPathComponent("mine.txt")
        try Data("same\r\nold\r\nlast".utf8).write(to:a);try Data("same\r\nnew\r\nlast".utf8).write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        let originalViews=MergeMarkedWordInterface.panes(in:window.contentView)
        weak var departed:AnyObject?=originalViews.first {$0.string.contains("new")}?.delegate
        model.resetHistory();model.activatePane(base:true);model.editingEnabled=true
        let host=NSHostingController(rootView:FileComparisonEditor(model:model,cells:model.displayCells(base:true),base:true))
        window.makeFirstResponder(nil);window.contentViewController=host
        try await TwoPaneEngineVerification.wait {MergeMarkedWordInterface.panes(in:window.contentView).contains {$0.string.contains("old")} && departed==nil}
        let reused=MergeMarkedWordInterface.panes(in:window.contentView).first!
        let priorActions=model.editingActions(for:true)
        try require(priorActions != nil,"Base editor did not expose its captured actions")
        let coordinator=reused.delegate as AnyObject?
        model.activatePane(base:false)
        host.rootView=FileComparisonEditor(model:model,cells:model.displayCells(base:false),base:false)
        try await TwoPaneEngineVerification.wait {reused.string.contains("new")}
        try require(reused.delegate as AnyObject? === coordinator,"Host did not reuse its native coordinator across role change")
        let leftBefore=model.draftText(base:true),rightBefore=model.draftText(base:false)
        priorActions?.type("stale role",0)
        try require(model.draftText(base:true)==leftBefore && model.draftText(base:false)==rightBefore,"Captured Base callback retargeted a reused Destination editor")
        window.makeFirstResponder(reused);reused.setSelectedRange(NSRange(location:0,length:0))
        let before=model.draftText(base:false)
        (reused as! MergeTypingProviding).cycleCurrentEnding()
        try require(model.draftText(base:false) != before && model.canUndo,"Reused editor did not register a real line-ending edit")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==before,"Reused native role kept a departed pane's Undo callback")
        try require(reused.accessibilityLabel()=="Destination file","Reused role retained Base accessibility identity")
        model.redo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false) != before && model.annotations(base:false).edited.contains(0),"Reused role Redo lost ending metadata")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        reused.setSelectedRange(NSRange(location:1,length:0))
        reused.insertText("🐢e\u{301}",replacementRange:NSRange(location:1,length:0))
        let typed=Data(model.draftText(base:false).utf8)
        try require(typed != Data(before.utf8) && !model.canRedo,"Typing failed to invalidate the abandoned Redo branch")
        let states=model.displayCells(base:false).map(\.state)
        // Detach the native editor while document history remains live.
        let editorSize=window.contentView!.bounds.size
        window.makeFirstResponder(nil);window.contentViewController=NSViewController()
        try await TwoPaneEngineVerification.wait {reused.window==nil}
        model.undo()
        try require(Data(model.draftText(base:false).utf8)==Data(before.utf8),"Document Undo required a retired native view")
        let replacement=NSHostingController(rootView:FileComparisonEditor(model:model,cells:model.displayCells(base:false),base:false))
        replacement.view.setFrameSize(editorSize);window.contentViewController=replacement;window.setContentSize(editorSize)
        var attachmentPolls=0
        try await TwoPaneEngineVerification.wait {
            attachmentPolls += 1; window.contentView?.layoutSubtreeIfNeeded()
            let view=MergeMarkedWordInterface.panes(in:window.contentView).first
            if attachmentPolls==999 {print("History replacement: caret=\(String(describing:view?.selectedRange())), pending=\(model.hasHistoryCaret(base:false)), filtering=\(model.filtering), size=\(String(describing:view?.enclosingScrollView?.contentSize)), attached=\(view?.window === window), text=\(String(describing:view?.string))");fflush(stdout)}
            return view?.selectedRange().location==1
        }
        let attached=MergeMarkedWordInterface.panes(in:window.contentView).first!
        try require(attached.string.hasPrefix("same") && !model.hasHistoryCaret(base:false),"Replacement did not consume Undo caret")
        model.redo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:false).utf8)==typed && model.displayCells(base:false).map(\.state)==states,"Replacement Redo lost text or row metadata")
        model.busy=true;model.undo();try require(Data(model.draftText(base:false).utf8)==typed,"Busy document accepted Undo");model.busy=false
        model.confirmingQuit=true;model.undo();try require(Data(model.draftText(base:false).utf8)==typed,"Quit question accepted Undo");model.confirmingQuit=false
        model.undo();try await TwoPaneEngineVerification.settled(model)
        // A new edit can follow Undo without waiting for a SwiftUI body refresh.
        attached.insertText("R",replacementRange:NSRange(location:1,length:0))
        try require(model.draftText(base:false).hasPrefix("sRame"),"Immediate post-Undo edit used stale displayed cells")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        owner.close();model.redo();try require(Data(model.draftText(base:false).utf8)==Data(before.utf8) && !model.canUndo && !model.canRedo,"Closed document retained actionable history")
        try require(try Data(contentsOf:a)==Data("same\r\nold\r\nlast".utf8) && Data(contentsOf:b)==Data("same\r\nnew\r\nlast".utf8),"Owner history checks wrote original inputs")
        try await verifySharedAndCombined(folder:folder,prefs:prefs)
        try await verifyPendingComparison(folder:folder,prefs:prefs)
        print("PASS: edit history native owner: reused Base/Destination coordinator and accessibility; document-owned Undo/Redo after pane detachment; exact Unicode, ending/row metadata and caret; redo branching, immediate typing, shared pane order, combined removed rows, pending comparison Undo/Redo, busy/quit/close fences and unchanged inputs")
    }
    @MainActor private static func verifySharedAndCombined(folder:URL,prefs:UserDefaults) async throws {
        let a=folder.appendingPathComponent("shared-base.txt"),b=folder.appendingPathComponent("shared-mine.txt")
        let left="head\r\nold\r\ntail",right="head\r\nnew\r\ntail"
        try Data(left.utf8).write(to:a);try Data(right.utf8).write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        func pane(_ word:String)->NSTextView {MergeMarkedWordInterface.panes(in:window.contentView).first {$0.string.contains(word)}!}
        let old=pane("old"),new=pane("new")
        window.makeFirstResponder(new);new.insertText("right",replacementRange:(new.string as NSString).range(of:"new"))
        let changedRight=Data(model.draftText(base:false).utf8)
        try require(changedRight != Data(right.utf8),"Right-pane edit did not reach document history")
        model.activatePane(base:true);model.editingEnabled=true;window.makeFirstResponder(old)
        try await TwoPaneEngineVerification.wait {old.isEditable && model.activeBase}
        old.insertText("left",replacementRange:(old.string as NSString).range(of:"old"))
        let changedLeft=Data(model.draftText(base:true).utf8)
        try require(changedLeft != Data(left.utf8),"Left-pane edit did not reach document history")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:true).utf8)==Data(left.utf8) && Data(model.draftText(base:false).utf8)==changedRight,"Shared Undo did not restore last edited pane first: left=\(model.draftText(base:true).debugDescription), right=\(model.draftText(base:false).debugDescription)")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:false).utf8)==Data(right.utf8) && !model.dirty,"Shared history failed to restore exact document baseline")
        model.redo();model.redo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:true).utf8)==changedLeft && Data(model.draftText(base:false).utf8)==changedRight,"Shared Redo lost cross-pane ordering")
        model.undo();model.undo();try await TwoPaneEngineVerification.settled(model)
        model.resetHistory();model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        let combined=pane("new")
        window.makeFirstResponder(combined);combined.setSelectedRange(NSRange(location:(combined.string as NSString).range(of:"old").location,length:0))
        let original=Data(model.draftText(base:false).utf8),sourceStates=model.displayCells(base:false).map(\.state)
        (combined as! MergeTypingProviding).cycleCurrentEnding()
        let cycled=Data(model.draftText(base:false).utf8),cycledStates=model.displayCells(base:false).map(\.state)
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:false).utf8)==original && model.displayCells(base:false).map(\.state)==sourceStates,"Combined Undo lost serialized bytes or removed-row states")
        model.redo();try await TwoPaneEngineVerification.settled(model)
        try require(Data(model.draftText(base:false).utf8)==cycled && model.displayCells(base:false).map(\.state)==cycledStates,"Combined Redo lost included removed row or ending")
        try require(try Data(contentsOf:a)==Data(left.utf8) && Data(contentsOf:b)==Data(right.utf8),"Edit history wrote source files")
    }
    @MainActor private static func verifyPendingComparison(folder:URL,prefs:UserDefaults) async throws {
        prefs.set(false,forKey:"TurtleGitMerge.OnePane")
        let a=folder.appendingPathComponent("pending-base.txt"),b=folder.appendingPathComponent("pending-mine.txt")
        let left="head\nUPPER\nold\ntail\n",right="head\nupper\nnew\ntail\n"
        try Data(left.utf8).write(to:a);try Data(right.utf8).write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        model.setComparisonOptions(.init(whitespace:.compare,ignoreCase:true,ignoreEndings:false))
        try await TwoPaneEngineVerification.settled(model)
        try require(model.alignment?.differences == [2..<3],"Ignore-case fixture did not isolate the editable block")
        model.selectedRows=2..<3;model.useOtherBlock()
        let chosen=model.draftText(base:false)
        try require(chosen=="head\nupper\nold\ntail\n" && model.filtering,"Block choice did not enter pending authoritative comparison")
        model.undo()
        try require(model.draftText(base:false)==right,"Pending block comparison refused immediate Undo")
        model.redo()
        try require(model.draftText(base:false)==chosen && model.filtering,"Pending projection Redo was treated as an authoritative comparison")
        try await TwoPaneEngineVerification.settled(model)
        try require(model.alignment?.differences.isEmpty==true,"Redo lost ignore-case comparison semantics")
        try require(try Data(contentsOf:a)==Data(left.utf8) && Data(contentsOf:b)==Data(right.utf8),"Pending history wrote source files")
    }
}
