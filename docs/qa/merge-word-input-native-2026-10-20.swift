// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergeWordInputVerification {
    typealias Check = MergePaneInputVerification
    static func navigation(_ view:NSTextView,prefs:UserDefaults)throws {
        let text=view.string as NSString,token=text.range(of:"alpha.beta__gamma").location
        try Check.require(token != NSNotFound,"Word fixture token missing")
        view.window?.makeFirstResponder(view)
        prefs.removeObject(forKey:"TurtleGitMerge.WordSeparators")
        for selector in ["moveWordRight:","moveWordForward:"] {
            view.setSelectedRange(.init(location:token,length:0));view.doCommand(by:NSSelectorFromString(selector))
            try Check.require(view.selectedRange()==NSRange(location:token+5,length:0),"Default punctuation boundary ignored by \(selector)")
        }
        for selector in ["moveWordLeft:","moveWordBackward:"] {
            view.setSelectedRange(.init(location:token+16,length:0));view.doCommand(by:NSSelectorFromString(selector))
            try Check.require(view.selectedRange()==NSRange(location:token+6,length:0),"Underscore unexpectedly classified as a default separator")
        }
        for (right,left) in [("moveWordRightAndModifySelection:","moveWordLeftAndModifySelection:"),("moveWordForwardAndModifySelection:","moveWordBackwardAndModifySelection:")] {
            view.setSelectedRange(.init(location:token,length:0));view.doCommand(by:NSSelectorFromString(right))
            try Check.require(view.selectedRange()==NSRange(location:token,length:5),"Shift word lost original anchor")
            view.doCommand(by:NSSelectorFromString(left));try Check.require(view.selectedRange()==NSRange(location:token,length:0),"Shift word reversal lost anchor")
        }
        // Change the owning private preference after the first cached document.
        prefs.set("_",forKey:"TurtleGitMerge.WordSeparators")
        view.setSelectedRange(.init(location:token,length:0));view.moveWordRight(nil)
        try Check.require(view.selectedRange()==NSRange(location:token+10,length:0),"Word input did not read changed owning separators")
        view.moveWordRight(nil);try Check.require(view.selectedRange().location==token+12,"Consecutive configured separators were not one run")
        view.moveWordRight(nil);try Check.require(view.selectedRange().location==token+17,"Word end differs from source boundary")
        let emoji=text.range(of:"👩🏽‍💻e\u{301}.z").location
        prefs.set(".",forKey:"TurtleGitMerge.WordSeparators")
        view.setSelectedRange(.init(location:emoji,length:0));view.moveWordRight(nil)
        try Check.require(view.selectedRange().location==emoji+"👩🏽‍💻e\u{301}".utf16.count,"Word navigation split a native composed character")
    }
    static func words(_ f:Check.Fixture)async throws {
        let text="alpha.beta__gamma\n👩🏽‍💻e\u{301}.z\n"
        let pair=try await f.pair("word pair",text,text)
        for view in MergeMarkedWordInterface.panes(in:pair.window?.contentView){try navigation(view,prefs:f.prefs)}
        try Check.require(!pair.model.canUndo && !pair.model.dirty,"Word navigation created history")
        let merge=try await f.merge("word merge",text,text)
        for view in MergeMarkedWordInterface.panes(in:merge.window?.contentView){try navigation(view,prefs:f.prefs)}
        try Check.require(!merge.model.canUndo,"Source/result word navigation created history")
        // Same-length edits must invalidate the cached source document.
        let result=(merge.window as! TextConflictNSWindow).mergedText!
        merge.window?.makeFirstResponder(result);let edit=NSRange(location:0,length:5)
        result.insertText("ab cd",replacementRange:edit);try await Check.settle(result)
        f.prefs.set(".",forKey:"TurtleGitMerge.WordSeparators")
        result.setSelectedRange(.init(location:0,length:0));result.moveWordRight(nil)
        try Check.require(result.selectedRange().location==2,"Same-length edit retained stale word geometry")
        merge.model.undo();try await Check.settle(result);result.setSelectedRange(.init(location:0,length:0));result.moveWordRight(nil)
        try Check.require(result.selectedRange().location==5,"Undo retained stale word geometry")
    }
    static func editing(_ f:Check.Fixture)async throws {
        for backward in [false,true] {
            let pair=try await f.pair("word deletion pair \(backward)","alpha.beta__gamma\n","alpha.beta__gamma\n")
            let view=MergeMarkedWordInterface.panes(in:pair.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
            f.prefs.set("_",forKey:"TurtleGitMerge.WordSeparators")
            pair.window?.makeFirstResponder(view);view.setSelectedRange(.init(location:backward ? 10:0,length:0))
            if backward{view.deleteWordBackward(nil)}else{view.deleteWordForward(nil)}
            try Check.require(pair.model.draftText(base:false)=="__gamma\n" && pair.model.draftText(base:true)=="alpha.beta__gamma\n","Word deletion ignored source separators or changed peer")
            pair.model.undo();try await Check.settle(view);try Check.require(pair.model.draftText(base:false)=="alpha.beta__gamma\n","Word Undo lost source")
            pair.model.redo();try await Check.settle(view);try Check.require(pair.model.draftText(base:false)=="__gamma\n","Word Redo differs")
            pair.model.undo();try await Check.settle(view)
            view.setSelectedRange(.init(location:backward ? 10:0,length:0))
            try Check.key(view,scalar:backward ? 0x7f:NSDeleteFunctionKey,code:backward ? 51:117,flags:.control)
            try Check.require(pair.model.draftText(base:false)=="__gamma\n","Control word-delete alias bypassed owned source deletion")
            pair.model.undo();try await Check.settle(view)
            view.setSelectedRange(.init(location:1,length:2));if backward{view.deleteWordBackward(nil)}else{view.deleteWordForward(nil)}
            try Check.require(pair.model.draftText(base:false)=="aha.beta__gamma\n","Selected word deletion extended beyond original selection")
        }
        let merge=try await f.merge("word deletion merge","alpha.beta__gamma\n","alpha.beta__gamma\n"),result=(merge.window as! TextConflictNSWindow).mergedText!
        let peers=merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}
        f.prefs.set("_",forKey:"TurtleGitMerge.WordSeparators")
        merge.window?.makeFirstResponder(result);result.setSelectedRange(.init(location:0,length:0));result.deleteWordForward(nil)
        try Check.require(merge.model.result=="__gamma\n" && merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==peers,"Merge word delete changed source peers")
        merge.model.undo();try await Check.settle(result);try Check.require(merge.model.result=="alpha.beta__gamma\n","Merge word Undo lost source")
        merge.model.redo();try await Check.settle(result);try Check.require(merge.model.result=="__gamma\n","Merge word Redo differs")
        // At a line edge source word traversal crosses blank/Empty records.
        let gaps=try await f.pair("word gaps","one\nX\n\ntwo\n","one\n\ntwo\n")
        let gapView=MergeMarkedWordInterface.panes(in:gaps.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        gaps.window?.makeFirstResponder(gapView);gapView.setSelectedRange(.init(location:3,length:0));gapView.deleteWordForward(nil)
        try Check.require(gaps.model.draftText(base:false)=="onetwo\n","Word deletion failed to cross blank/Empty lines")
        gaps.model.undo();try await Check.settle(gapView);try Check.require(gaps.model.draftText(base:false)=="one\n\ntwo\n","Gap word Undo lost real blank line")
        let text=Check.contents(),folded=try await f.pair("folded word pair",text.0,text.1)
        let foldedView=MergeMarkedWordInterface.panes(in:folded.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        folded.model.setCollapsed(true);try await Check.wait{Check.collapsedReady(foldedView)}
        let join=try Check.foldedJoin(foldedView),visibility=try Check.layout(foldedView).controller!.folding.visibility,peer=folded.model.draftText(base:true)
        folded.window?.makeFirstResponder(foldedView);foldedView.setSelectedRange(.init(location:join.start,length:0));foldedView.deleteWordForward(nil)
        try Check.require(folded.model.draftText(base:false)==join.text && folded.model.draftText(base:true)==peer,"Folded word deletion omitted hidden payload or changed peer")
        folded.model.undo();try await Check.settle(foldedView)
        try Check.require(folded.model.draftText(base:false)==join.baseline && (try Check.layout(foldedView).controller!.folding.visibility)==visibility,"Folded word Undo lost bytes/folding")
    }
    static func foldedMerge(_ f:Check.Fixture)async throws {
        let text=Check.contents(),merge=try await f.merge("folded word merge",text.0,text.1),result=(merge.window as! TextConflictNSWindow).mergedText!
        merge.model.setCollapsed(true);try await Check.wait{Check.collapsedReady(result)}
        let join=try Check.foldedJoin(result,mergedResult:true),visibility=try Check.layout(result).controller!.folding.visibility
        let peers=merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}
        merge.window?.makeFirstResponder(result);result.setSelectedRange(.init(location:join.start,length:0));result.deleteWordForward(nil)
        try Check.require(merge.model.result==join.text && merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==peers,"Folded Merge word deletion omitted hidden payload or changed source peers")
        merge.model.undo();try await Check.settle(result)
        try Check.require(merge.model.result==join.baseline && (try Check.layout(result).controller!.folding.visibility)==visibility,"Folded Merge word Undo lost source/folding")
        merge.model.redo();try await Check.settle(result);try Check.require(merge.model.result==join.text,"Folded Merge word Redo differs")
    }
    static func ownership(_ f:Check.Fixture)async throws {
        let pair=try await f.pair("word owner","alpha.beta__gamma\n","alpha.beta__gamma\n")
        let view=MergeMarkedWordInterface.panes(in:pair.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        pair.window?.makeFirstResponder(view);view.setSelectedRange(.init(location:0,length:0));let text=view.string,caret=view.selectedRange()
        pair.model.busy=true;view.moveWordRight(nil);view.deleteWordForward(nil)
        try Check.require(view.string==text && view.selectedRange()==caret,"Busy owner accepted word input");pair.model.busy=false
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:100,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        pair.window!.beginSheet(sheet,completionHandler:{_ in});view.moveWordRight(nil);view.deleteWordForward(nil)
        try Check.require(view.string==text && view.selectedRange()==caret,"Sheet owner accepted word input")
        pair.window!.endSheet(sheet);sheet.close();try await Check.wait{pair.window?.attachedSheet==nil}
        pair.model.configureMergeToolReadOnly(true);try await Check.wait{!view.isEditable}
        view.moveWordRight(nil);try Check.require(view.selectedRange().location==5,"Read-only pane lost source word navigation")
        let selection=view.selectedRange();view.deleteWordBackward(nil);try Check.require(view.string==text && view.selectedRange()==selection,"Read-only word delete mutated text")
        pair.close();view.moveWordRight(nil);view.deleteWordBackward(nil)
        try Check.require(view.string==text && view.selectedRange()==selection,"Retired pane accepted stale word input")
        let merge=try await f.merge("word merge owner","alpha.beta__gamma\n","alpha.beta__gamma\n"),result=(merge.window as! TextConflictNSWindow).mergedText!
        merge.window?.makeFirstResponder(result);result.setSelectedRange(.init(location:0,length:0));let original=merge.model.result
        merge.model.busy=true;result.moveWordRight(nil);result.deleteWordForward(nil)
        try Check.require(merge.model.result==original && result.selectedRange().location==0,"Busy Merge accepted word input");merge.model.busy=false
        merge.close();result.moveWordRight(nil);result.deleteWordForward(nil)
        try Check.require(merge.model.result==original && result.selectedRange().location==0,"Retired Merge accepted word input")
    }
    static func verify(_ test:String)async throws {
        let f=try Check.Fixture()
        do {
            switch test {case "words":try await words(f);case "word-editing":try await editing(f);try await foldedMerge(f);case "word-ownership":try await ownership(f);default:throw Check.Failure(description:"Unknown word-input case")}
            try await f.cleanup()
        } catch {let failure=error;do{try await f.cleanup()}catch{throw Check.Failure(description:"\(failure); cleanup: \(error)")};throw failure}
    }
}
