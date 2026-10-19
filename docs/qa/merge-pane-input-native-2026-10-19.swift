// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergePaneInputVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Pane input timeout at \(line)")
    }
    static func drain()async throws {
        try await wait {MergeNavigationRequests.activeRequests==0 && MergeRegexOperations.activeRequests==0 && MergeSourceExport.activeExports==0 && MergeExternalReloadCoordinator.activeRequests==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}}
    }
    static func layout(_ view:NSTextView)throws->MergeFoldTextLayout {
        guard let target=view as? MergePaneInputProviding else {throw Failure(description:"Actual editor missing shared pane input")};return target.paneInputLayout
    }
    static func cells(_ view:NSTextView)throws->[MergeSourceCell] {
        guard let target=view as? MergeLineNavigationProviding,let cells=target.navigationCells else {throw Failure(description:"Actual source-row projection missing")};return cells
    }
    static func offset(_ row:Int,_ cells:[MergeSourceCell])->Int {cells.prefix(row).reduce(0){$0+$1.displayText.utf16.count+1}}
    static func row(_ offset:Int,_ cells:[MergeSourceCell])->Int {
        var start=0
        for (index,cell) in cells.enumerated() {if offset<=start+cell.displayText.utf16.count{return index};start += cell.displayText.utf16.count+1}
        return max(0,cells.count-1)
    }
    static func settle(_ view:NSTextView)async throws {
        try await wait {guard let cells=(view as? MergeLineNavigationProviding)?.navigationCells else{return false};return view.string==cells.map(\.displayText).joined(separator:"\n")+(cells.isEmpty ? "":"\n")}
    }
    static func collapsedReady(_ view:NSTextView)->Bool {
        guard let native=try? layout(view),let controller=native.controller,controller.collapsed,let data=try? cells(view),let hidden=controller.folding.visibility.indices.first(where:{controller.folding.visibility[$0] == .hidden}) else{return false}
        return view.textStorage?.attribute(.mergeFoldHidden,at:offset(hidden,data),effectiveRange:nil) != nil
    }
    static func wrapReady(_ views:[NSTextView],wrapped:Bool)->Bool {
        !views.isEmpty && views.allSatisfy {view in
            guard let container=view.textContainer,container.widthTracksTextView==wrapped,view.isHorizontallyResizable == !wrapped else{return false}
            view.layoutManager?.ensureLayout(for:container)
            return true
        }
    }
    static func key(_ view:NSTextView,scalar:Int,code:UInt16,flags:NSEvent.ModifierFlags=[])throws {
        guard let window=view.window,let unicode=UnicodeScalar(scalar),let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:String(unicode),charactersIgnoringModifiers:String(unicode),isARepeat:false,keyCode:code) else {throw Failure(description:"Pane input event unavailable")}
        view.keyDown(with:event)
    }
    @MainActor final class Fixture {
        let root:URL,git:URL,prefs:UserDefaults,suite:String
        var pairs:[FileComparisonWindowController]=[],merges:[TextConflictWindowController]=[]
        var sources:[(URL,Data)]=[]
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]);git=URL(fileURLWithPath:CommandLine.arguments[2]);suite="TurtleGit.PaneInput."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);MergeFoldingPreferences(collapsed:false).saveCollapsed(to:prefs)
            prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)
        }
        func files(_ name:String,_ texts:[String])throws->[URL] {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            return try texts.enumerated().map{index,text in let url=folder.appendingPathComponent("input\(index).txt"),data=Data(text.utf8);try data.write(to:url);sources.append((url,data));return url}
        }
        func pair(_ name:String,_ base:String,_ mine:String)async throws->FileComparisonWindowController {
            prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
            let urls=try files(name,[base,mine]),owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:urls[0],destination:urls[1]),permissions:[],preferences:prefs)
            pairs.append(owner);owner.window?.orderFront(nil);owner.model.load()
            try await wait {!owner.model.busy && !owner.model.filtering && owner.model.alignment != nil && MergeMarkedWordInterface.panes(in:owner.window?.contentView).count==2}
            for view in MergeMarkedWordInterface.panes(in:owner.window?.contentView){try await settle(view)}
            owner.model.setWrapLines(false)
            try await wait {!owner.model.lineWrapping.isGeometryPending && wrapReady(MergeMarkedWordInterface.panes(in:owner.window?.contentView),wrapped:false)}
            try await wait {MergeMarkedWordInterface.panes(in:owner.window?.contentView).allSatisfy{($0 as? MergePaneInputTextView)?.paneInputAllowed==true}}
            return owner
        }
        func merge(_ name:String,_ base:String,_ mine:String)async throws->TextConflictWindowController {
            prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
            let urls=try files(name,[base,mine,base]),owner=TextConflictWindowController(repository:GitRepository(root:root,executable:git),access:nil,path:urls[1].path,workingMerge:try WorkingTextMerge(base:urls[0],theirs:urls[2],mine:urls[1]),preferences:prefs)
            merges.append(owner);owner.window?.orderFront(nil);owner.model.load()
            try await wait {!owner.model.busy && !owner.model.preparing && owner.model.document != nil && owner.model.nativeEditorReady && (owner.window as? TextConflictNSWindow)?.mergedText != nil}
            for view in MergeMarkedWordInterface.panes(in:owner.window?.contentView){try await settle(view)}
            owner.model.setWrapLines(false)
            try await wait {!owner.model.lineWrapping.isGeometryPending && wrapReady(MergeMarkedWordInterface.panes(in:owner.window?.contentView),wrapped:false)}
            try await wait {MergeMarkedWordInterface.panes(in:owner.window?.contentView).allSatisfy{($0 as? MergePaneInputTextView)?.paneInputAllowed==true}}
            return owner
        }
        func cleanup()async throws {
            for owner in pairs{owner.close()};for owner in merges{owner.close()}
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.close()}
            try await drain()
            for (url,data) in sources{try require(try Data(contentsOf:url)==data,"Pane input saved an original source file")}
            prefs.removePersistentDomain(forName:suite);prefs.synchronize()
        }
    }
    static func contents()->(String,String) {
        let original=(0..<110).map{String(format:"row %03d alpha beta gamma ",$0)+String(repeating:"wrapped words ",count:5)+"\n"}
        var changed=original;changed[20]="\t  mine first changed row\n";changed[90]="mine second changed row\n"
        return (original.joined(),changed.joined())
    }
    static func traversal(_ view:NSTextView,wrapped:Bool=false)async throws {
        try require(wrapReady([view],wrapped:wrapped),"Actual pane wrap mode differs from the requested traversal case")
        let native=try layout(view);guard let controller=native.controller else{throw Failure(description:"Fold owner missing")}
        let data=try cells(view),shown=controller.folding.visibility.indices.filter{controller.folding.visibility[$0] == .shown}
        guard let pair=zip(shown,shown.dropFirst()).first(where:{pair in pair.1>pair.0+1}) else{throw Failure(description:"Expected real folded interval absent")}
        let before=pair.0,after=pair.1,start=offset(before,data)+data[before].displayText.utf16.count,end=offset(after,data)
        let paneID=(view as? MergeFindProviding)?.mergeFindPaneID ?? -1
        FileHandle.standardError.write(Data("Pane traversal start: pane=\(paneID) wrapped=\(wrapped) beforeRow=\(before) beforeStart=\(offset(before,data)) beforeEnd=\(start) afterRow=\(after) afterStart=\(end)\n".utf8))
        let visibility=controller.folding.visibility,revision=controller.revision,text=view.string
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location:start,length:0));view.moveRight(nil)
        try require(view.selectedRange()==NSRange(location:end,length:0),"Right arrow entered folded source text")
        view.moveLeft(nil);try require(view.selectedRange()==NSRange(location:start,length:0),"Left arrow entered folded source text")
        view.moveRightAndModifySelection(nil);try require(view.selectedRange()==NSRange(location:start,length:end-start),"Shift-Right lost original source anchor")
        view.moveLeftAndModifySelection(nil);try require(view.selectedRange()==NSRange(location:start,length:0),"Shift reversal lost selection anchor")
        view.setSelectedRange(NSRange(location:start,length:0));view.moveWordRight(nil)
        try require(row(view.selectedRange().location,data)>=after,"Word movement stopped inside folded interval")
        view.setSelectedRange(NSRange(location:end+1,length:0));view.moveLeft(nil);view.moveWordLeft(nil)
        try require(row(view.selectedRange().location,data)<=before,"Backward word movement stopped inside folded interval")
        view.setSelectedRange(NSRange(location:start,length:0));view.doCommand(by:NSSelectorFromString("moveWordForward:"))
        try require(row(view.selectedRange().location,data)>=after,"Native word-forward alias stopped inside folded interval")
        view.setSelectedRange(NSRange(location:end+1,length:0));view.moveLeft(nil);view.doCommand(by:NSSelectorFromString("moveWordBackward:"))
        try require(row(view.selectedRange().location,data)<=before,"Native word-backward alias stopped inside folded interval")
        view.setSelectedRange(NSRange(location:start,length:0));view.moveWordRightAndModifySelection(nil)
        try require(view.selectedRange().location==start && view.selectedRange().length>0 && row(NSMaxRange(view.selectedRange()),data)>=after,"Shift-word movement lost its anchor or stopped in a fold")
        view.moveWordLeftAndModifySelection(nil);try require(view.selectedRange().location==start || NSMaxRange(view.selectedRange())==start,"Shift-word reversal replaced its anchor")
        view.setSelectedRange(NSRange(location:offset(before,data),length:0))
        let downStart=view.selectedRange()
        func caretRect(_ position:Int)->NSRect {
            var actual=NSRange(location:0,length:0)
            return view.firstRect(forCharacterRange:NSRange(location:position,length:0),actualRange:&actual)
        }
        let downStartRect=caretRect(downStart.location)
        view.moveDown(nil)
        let downDestination=view.selectedRange(),downRow=row(downDestination.location,data)
        let downAccepted=wrapped ? downDestination.location>offset(before,data) && controller.folding.visibility[downRow] == .shown:downRow==after
        if !downAccepted {
            let nearby=(max(0,downRow-2)..<min(data.count,downRow+3)).map{index in "\(index):\(controller.folding.visibility[index]):\(offset(index,data)):len\(data[index].displayText.utf16.count):\(data[index].state)"}.joined(separator:";")
            let pane=(view as? MergeFindProviding)?.mergeFindPaneID ?? -1,container=view.textContainer
            FileHandle.standardError.write(Data(("Pane Down diagnostic: pane=\(pane) wrappedExpected=\(wrapped) beforeRow=\(before) beforeOffset=\(offset(before,data)) expectedAfterRow=\(after) expectedAfterOffset=\(end) actual=\(downDestination) actualRow=\(downRow) actualState=\(controller.folding.visibility[downRow]) foldRevision=\(controller.revision) initialRevision=\(revision) beforeRect=\(downStartRect) afterRect=\(caretRect(downDestination.location)) container=\(String(describing:container?.containerSize)) tracksWidth=\(String(describing:container?.widthTracksTextView)) horizontalResizable=\(view.isHorizontallyResizable) viewFrame=\(view.frame) visible=\(view.visibleRect) nearby=[\(nearby)]\n").utf8))
        }
        if wrapped {
            try require(view.selectedRange().location>offset(before,data) && controller.folding.visibility[row(view.selectedRange().location,data)] == .shown,"Wrapped Down did not advance to a shown visual line")
        } else {try require(row(view.selectedRange().location,data)==after,"Down arrow entered folded interval")}
        view.moveUp(nil)
        let upDestination=view.selectedRange(),upRow=row(upDestination.location,data)
        if upRow != before {
            let nearby=(max(0,upRow-2)..<min(data.count,upRow+3)).map{index in "\(index):\(controller.folding.visibility[index]):\(offset(index,data)):len\(data[index].displayText.utf16.count):\(data[index].state)"}.joined(separator:";")
            FileHandle.standardError.write(Data(("Pane Up diagnostic: pane=\(paneID) wrappedExpected=\(wrapped) expectedBeforeRow=\(before) expectedBeforeStart=\(offset(before,data)) expectedAfterRow=\(after) downRange=\(downDestination) downRow=\(downRow) downState=\(controller.folding.visibility[downRow]) upRange=\(upDestination) upRow=\(upRow) upState=\(controller.folding.visibility[upRow]) downRect=\(caretRect(downDestination.location)) upRect=\(caretRect(upDestination.location)) container=\(String(describing:view.textContainer?.containerSize)) tracksWidth=\(String(describing:view.textContainer?.widthTracksTextView)) horizontalResizable=\(view.isHorizontallyResizable) visible=\(view.visibleRect) foldRevision=\(controller.revision) initialRevision=\(revision) nearby=[\(nearby)]\n").utf8))
        }
        try require(upRow==before,"Up arrow entered folded interval")
        view.setSelectedRange(NSRange(location:offset(before,data),length:0));view.moveDownAndModifySelection(nil)
        try require(view.selectedRange().location==offset(before,data) && view.selectedRange().length>0 && (wrapped || NSMaxRange(view.selectedRange())>=end),"Shift-Down lost original source anchor")
        view.setSelectedRange(NSRange(location:offset(before,data),length:0));view.scrollRangeToVisible(view.selectedRange());let pageStart=view.selectedRange();view.pageDown(nil)
        try require(view.selectedRange().location>pageStart.location,"Page Down scrolled without moving caret")
        try require(controller.folding.visibility[row(view.selectedRange().location,data)] == .shown,"Page Down stopped on marker/hidden text")
        let pageEnd=view.selectedRange();view.pageUp(nil);try require(view.selectedRange().location<pageEnd.location,"Page Up scrolled without moving caret");try require(controller.folding.visibility[row(view.selectedRange().location,data)] == .shown,"Page Up stopped on marker/hidden text")
        let pageAnchor=offset(before,data);view.setSelectedRange(NSRange(location:pageAnchor,length:0));view.pageDownAndModifySelection(nil)
        try require(view.selectedRange().location==pageAnchor && view.selectedRange().length>0,"Shift-Page Down did not move caret with its original anchor")
        view.pageUpAndModifySelection(nil)
        try require(view.selectedRange().location==pageAnchor || NSMaxRange(view.selectedRange())==pageAnchor,"Shift-Page reversal replaced its anchor")
        await Task.yield();await Task.yield()
        try require(controller.revision==revision && controller.folding.visibility==visibility && view.string==text,"Keyboard navigation/selection expanded folds or modified text")
        FileHandle.standardError.write(Data("Pane traversal completed: pane=\(paneID) wrapped=\(wrapped) beforeRow=\(before) afterRow=\(after)\n".utf8))
    }
    static func smartHome(_ view:NSTextView)throws {
        let data=try cells(view)
        guard let line=data.indices.first(where:{data[$0].displayText.hasPrefix("\t  mine")}) else {throw Failure(description:"Indented smart Home row missing")}
        let start=offset(line,data),end=start+data[line].displayText.utf16.count
        view.window?.makeFirstResponder(view);view.setSelectedRange(NSRange(location:end,length:0));view.moveToBeginningOfLine(nil)
        try require(view.selectedRange().location==start+3,"Home did not choose first non-space/tab")
        view.moveToBeginningOfLine(nil);try require(view.selectedRange().location==start,"Repeated Home did not toggle to column zero")
        view.moveToBeginningOfLine(nil);try require(view.selectedRange().location==start+3,"Repeated Home did not toggle back to indentation")
        view.setSelectedRange(NSRange(location:end,length:0));view.moveToBeginningOfLineAndModifySelection(nil)
        try require(view.selectedRange()==NSRange(location:start+3,length:end-start-3),"Shift-Home lost caret anchor")
        view.setSelectedRange(NSRange(location:end,length:0));view.moveToLeftEndOfLine(nil)
        try require(view.selectedRange().location==start+3,"Native Command-Left alias did not use smart Home")
        view.setSelectedRange(NSRange(location:end,length:0));view.moveToBeginningOfParagraph(nil)
        try require(view.selectedRange().location==start+3,"Native Control-A alias did not use smart Home")
        view.setSelectedRange(NSRange(location:end,length:0));try key(view,scalar:NSHomeFunctionKey,code:115)
        try require(view.selectedRange().location==start+3,"Physical Home/Fn-Left did not use smart Home")
        try key(view,scalar:NSHomeFunctionKey,code:115);try require(view.selectedRange().location==start,"Physical Home did not toggle")
        view.setSelectedRange(NSRange(location:end,length:0));try key(view,scalar:NSHomeFunctionKey,code:115,flags:.shift)
        try require(view.selectedRange()==NSRange(location:start+3,length:end-start-3),"Physical Shift-Home lost selection anchor")
    }
    static func explicitReveal(_ view:NSTextView)async throws {
        let native=try layout(view);guard let controller=native.controller else{throw Failure(description:"No reveal owner")}
        let data=try cells(view)
        guard let findRow=controller.folding.visibility.indices.first(where:{controller.folding.visibility[$0] == .hidden && !data[$0].displayText.isEmpty}) else {throw Failure(description:"Hidden Find target missing")}
        let provider=view as! MergeFindProviding,find=MergeFindWindowController(text:view,defaults:provider.mergeFindDefaults)
        provider.mergeFindController=find;find.present(show:false);find.search.stringValue=data[findRow].displayText
        view.setSelectedRange(NSRange(location:0,length:0));find.find(upwards:false)
        try await wait {controller.folding.visibility[findRow] == .shown}
        try require(view.selectedRange().location==offset(findRow,data),"Find did not explicitly reveal its hidden source match")
        find.close()
        guard let hidden=controller.folding.visibility.indices.first(where:{controller.folding.visibility[$0] == .hidden && data[$0].lineNumber != nil}) else {throw Failure(description:"Hidden source target missing")}
        let expected=offset(hidden,data),target=view as! (NSTextView & MergeLineNavigationProviding)
        target.chooseNavigationLine={_,_ in data[hidden].lineNumber};target.navigateToSourceLine()
        try await wait {!target.navigationPending && controller.folding.visibility[hidden] == .shown}
        try require(view.selectedRange().location==expected,"Go To Line did not preserve explicit source destination")
    }
    static func navigation(_ f:Fixture)async throws {
        let text=contents(),pair=try await f.pair("navigation pair",text.0,text.1)
        pair.model.setCollapsed(true)
        let views=MergeMarkedWordInterface.panes(in:pair.window?.contentView)
        try await wait {views.allSatisfy(collapsedReady)}
        for view in views{try await traversal(view)}
        let mine=views.first{$0.string.contains("mine first")}!;try smartHome(mine)
        try require(!pair.model.dirty && !pair.model.canUndo,"Navigation created editing history")
        pair.model.setWrapLines(true);try await wait {!pair.model.lineWrapping.isGeometryPending && wrapReady(views,wrapped:true)}
        pair.model.setCollapsed(false);pair.model.setCollapsed(true);try await traversal(mine,wrapped:true)
        try await explicitReveal(mine)
        let merge=try await f.merge("navigation merge",text.0,text.1);merge.model.setCollapsed(true)
        let triple=MergeMarkedWordInterface.panes(in:merge.window?.contentView)
        try await wait {triple.allSatisfy(collapsedReady)}
        for view in triple{try await traversal(view)}
        try smartHome((merge.window as! TextConflictNSWindow).mergedText!)
        merge.model.setWrapLines(true);try await wait {!merge.model.lineWrapping.isGeometryPending && wrapReady(triple,wrapped:true)}
        for view in triple{try await traversal(view,wrapped:true)}
        try await explicitReveal((merge.window as! TextConflictNSWindow).mergedText!)
    }
    static func editing(_ f:Fixture)async throws {
        for forward in [false,true] {
            let pair=try await f.pair("ghost pair \(forward)","A\nX\nB\n","A\nB\n"),model=pair.model
            let view=MergeMarkedWordInterface.panes(in:pair.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!,data=try cells(view)
            try require(data.contains{$0.state.isViewEmpty},"Actual Compare alignment omitted expected ghost")
            let original=model.draftText(base:false),peer=model.draftText(base:true),whereB=(view.string as NSString).range(of:"B").location
            view.window?.makeFirstResponder(view);view.setSelectedRange(NSRange(location:forward ? 1:whereB,length:0))
            if forward{view.deleteForward(nil)}else{view.deleteBackward(nil)}
            try require(model.draftText(base:false)=="AB\n" && model.draftText(base:true)==peer,"Ghost deletion failed to join real neighbors or changed peer")
            model.undo();try await settle(view);try require(model.draftText(base:false)==original,"Ghost deletion Undo lost source")
            model.redo();try await settle(view);try require(model.draftText(base:false)=="AB\n","Ghost deletion Redo differs")
            let merge=try await f.merge("ghost merge \(forward)","A\nX\nB\nC\n","A\nX\nB\nC\n"),result=(merge.window as! TextConflictNSWindow).mergedText!
            let sourceRows=merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}
            // A natural removed merge line can be ResolvedEmpty, which the
            // source deliberately treats differently from Empty. Create actual
            // Empty view records through the normal aligned result editor.
            merge.window?.makeFirstResponder(result)
            let preparation=NSRange(location:1,length:3)
            result.setSelectedRange(preparation);result.insertText("",replacementRange:preparation)
            try await settle(result)
            let before=merge.model.result,preparedCells=try cells(result)
            try require(before=="AB\nC\n" && preparedCells.contains{$0.state.isViewEmpty},"Native aligned preparation did not produce authentic Empty records: \(preparedCells.map{String(describing:$0.state)})")
            try require(merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==sourceRows,"Preparing Empty result records changed source peers")
            result.setSelectedRange(NSRange(location:forward ? 2:(result.string as NSString).range(of:"C").location,length:0))
            if forward{result.deleteForward(nil)}else{result.deleteBackward(nil)}
            try require(merge.model.result=="ABC\n" && merge.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==sourceRows,"Merge ghost deletion changed peers or lost join")
            merge.model.undo();try await settle(result);try require(merge.model.result==before,"Merge ghost Undo lost source")
            merge.model.redo();try await settle(result);try require(merge.model.result=="ABC\n","Merge ghost Redo differs")
        }
        let blank=try await f.pair("ordinary blank","A\n\nB\n","A\n\nB\n"),view=MergeMarkedWordInterface.panes(in:blank.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        blank.window?.makeFirstResponder(view);view.setSelectedRange(NSRange(location:(view.string as NSString).range(of:"B").location,length:0));view.deleteBackward(nil)
        try require(blank.model.draftText(base:false)=="A\nB\n","Real blank line was skipped as an alignment ghost")
        let texts=contents(),folded=try await f.pair("folded delete",texts.0,texts.1),foldedView=MergeMarkedWordInterface.panes(in:folded.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        folded.model.setCollapsed(true);try await wait {collapsedReady(foldedView)}
        let old=folded.model.draftText(base:false),peer=folded.model.draftText(base:true),join=try foldedJoin(foldedView),oldVisibility=try layout(foldedView).controller!.folding.visibility
        try require(join.baseline==old,"Collapsed Compare oracle does not reproduce the source save representation")
        folded.window?.makeFirstResponder(foldedView);foldedView.setSelectedRange(NSRange(location:join.start,length:0));foldedView.deleteForward(nil)
        try require(folded.model.draftText(base:false)==join.text && folded.model.draftText(base:true)==peer,"Collapsed Delete did not remove its complete source span")
        folded.model.undo();try await settle(foldedView);try require(folded.model.draftText(base:false)==old && (try layout(foldedView).controller!.folding.visibility)==oldVisibility,"Collapsed Delete Undo lost source/fold metadata")
        folded.model.redo();try await settle(foldedView);try require(folded.model.draftText(base:false)==join.text,"Collapsed Delete Redo differs")
        let triple=try await f.merge("folded merge delete",texts.0,texts.1),result=(triple.window as! TextConflictNSWindow).mergedText!
        triple.model.setCollapsed(true);try await wait {collapsedReady(result)}
        let previous=triple.model.result,mergedJoin=try foldedJoin(result,mergedResult:true),mergedVisibility=try layout(result).controller!.folding.visibility
        try require(mergedJoin.baseline==previous,"Collapsed Merge oracle does not reproduce the source save representation")
        let source=triple.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}
        triple.window?.makeFirstResponder(result);result.setSelectedRange(NSRange(location:mergedJoin.start,length:0));result.deleteForward(nil)
        let preservedPeers=triple.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==source
        if triple.model.result != mergedJoin.text || !preservedPeers {
            FileHandle.standardError.write(Data("Collapsed Merge Delete diagnostic: peersPreserved=\(preservedPeers) expectedBytes=\(mergedJoin.text.utf8.count) actualBytes=\(triple.model.result.utf8.count) expectedPrefix=\(String(reflecting:String(mergedJoin.text.prefix(200)))) actualPrefix=\(String(reflecting:String(triple.model.result.prefix(200)))) expectedSuffix=\(String(reflecting:String(mergedJoin.text.suffix(200)))) actualSuffix=\(String(reflecting:String(triple.model.result.suffix(200))))\n".utf8))
        }
        try require(triple.model.result==mergedJoin.text && preservedPeers,"Collapsed Merge Delete changed peers or omitted hidden payload")
        triple.model.undo();try await settle(result)
        let restoredVisibility=try layout(result).controller!.folding.visibility
        if triple.model.result != previous || restoredVisibility != mergedVisibility {
            let changedRows=(0..<max(mergedVisibility.count,restoredVisibility.count)).filter { row in
                row>=mergedVisibility.count || row>=restoredVisibility.count || mergedVisibility[row] != restoredVisibility[row]
            }
            let differences=changedRows.prefix(12).map { row in
                "\(row):\(row<mergedVisibility.count ? String(describing:mergedVisibility[row]):"absent")->\(row<restoredVisibility.count ? String(describing:restoredVisibility[row]):"absent")"
            }.joined(separator:",")
            let peersRestored=triple.model.sourceComparison!.rows.map{[Data($0.mine.text.utf8),Data($0.theirs.text.utf8)]}==source
            FileHandle.standardError.write(Data("Collapsed Merge Undo diagnostic: textEqual=\(triple.model.result==previous) peersEqual=\(peersRestored) expectedBytes=\(previous.utf8.count) actualBytes=\(triple.model.result.utf8.count) expectedRows=\(mergedVisibility.count) actualRows=\(restoredVisibility.count) changedRows=\(changedRows.count) firstDiffs=[\(differences)] caret=\(result.selectedRange()) originalCaret=\(mergedJoin.start) foldRevision=\(try layout(result).controller!.revision) expectedPrefix=\(String(reflecting:String(previous.prefix(160)))) actualPrefix=\(String(reflecting:String(triple.model.result.prefix(160))))\n".utf8))
        }
        try require(triple.model.result==previous && restoredVisibility==mergedVisibility,"Collapsed Merge Undo lost source/fold metadata")
        triple.model.redo();try await settle(result);try require(triple.model.result==mergedJoin.text,"Collapsed Merge Redo differs")
        let combined=try await f.pair("combined input","A\nX\nB\n\t  old\n","A\nB\n\t  mine first changed row\n")
        combined.model.switchPaneMode(true)
        try await wait {
            let panes=MergeMarkedWordInterface.panes(in:combined.window?.contentView)
            return combined.model.onePaneActive && !combined.model.filtering && !combined.model.lineWrapping.isGeometryPending && panes.count==1 && panes.allSatisfy{($0 as? MergePaneInputTextView)?.paneInputAllowed==true}
        }
        let combinedView=MergeMarkedWordInterface.panes(in:combined.window?.contentView).first!;try await settle(combinedView)
        let combinedCells=try cells(combinedView)
        guard let removed=combinedCells.indices.first(where:{combinedCells[$0].displayText=="X" && combinedCells[$0].state.isRemoval}) else {throw Failure(description:"Combined pane omitted real removed source record")}
        let unchanged=combined.model.draftText(base:false)
        combined.window?.makeFirstResponder(combinedView);combinedView.setSelectedRange(NSRange(location:1,length:0));combinedView.moveRight(nil)
        if combinedView.selectedRange().location != offset(removed,combinedCells) {
            let actual=combinedView.selectedRange(),actualRow=row(actual.location,combinedCells)
            FileHandle.standardError.write(Data("Combined navigation diagnostic: actual=\(actual) expected=\(offset(removed,combinedCells)) actualRow=\(actualRow) removedRow=\(removed) allowed=\((combinedView as? MergePaneInputTextView)?.paneInputAllowed==true) filtering=\(combined.model.filtering) text=\(String(reflecting:combinedView.string)) states=\(combinedCells.prefix(12).map{String(describing:$0.state)}) visibility=\(try layout(combinedView).controller!.folding.visibility.prefix(12))\n".utf8))
        }
        try require(combinedView.selectedRange().location==offset(removed,combinedCells),"Combined caret skipped a real removed record as a ghost")
        try smartHome(combinedView);try require(combined.model.draftText(base:false)==unchanged && !combined.model.canUndo,"Combined navigation changed document/history")
    }
    static func foldedJoin(_ view:NSTextView,mergedResult:Bool=false)throws->(start:Int,text:String,baseline:String) {
        let data=try cells(view),native=try layout(view)
        guard let controller=native.controller else {throw Failure(description:"Folded deletion has no native controller")}
        let shown=controller.folding.visibility.indices.filter{controller.folding.visibility[$0] == .shown}
        guard let pair=zip(shown,shown.dropFirst()).first(where:{pair in pair.1>pair.0+1}) else {throw Failure(description:"Folded deletion requires a real hidden source span")}
        let first=pair.0,last=pair.1
        // Merge's ordinary BaseView::SaveFile omits removed/resolved-empty
        // display records. Compare's pane bytes follow their source coordinates.
        func included(_ cell:MergeSourceCell)->Bool {mergedResult ? !cell.state.isExcludedFromResult:cell.hasSourceCoordinate}
        let prefix=data.prefix(first).filter(included).map(\.text).joined()
        let suffix=data.dropFirst(last+1).filter(included).map(\.text).joined()
        let baseline=data.filter(included).map(\.text).joined()
        return (offset(first,data)+data[first].displayText.utf16.count,prefix+data[first].displayText+data[last].text+suffix,baseline)
    }
    static func ownership(_ f:Fixture)async throws {
        let text=contents(),pair=try await f.pair("ownership pair",text.0,text.1),view=MergeMarkedWordInterface.panes(in:pair.window?.contentView).first{($0 as? MergeFindProviding)?.mergeFindPaneID==2}!
        pair.window?.makeFirstResponder(view);view.setSelectedRange(NSRange(location:20,length:0));view.moveToBeginningOfDocument(nil)
        try require(view.selectedRange()==NSRange(location:0,length:0),"Native document-start alias became smart Home")
        pair.window?.makeFirstResponder(view);view.setSelectedRange(NSRange(location:8,length:0));let original=pair.model.draftText(base:false),caret=view.selectedRange()
        pair.model.busy=true;view.moveRight(nil);view.deleteBackward(nil);try require(view.selectedRange()==caret && pair.model.draftText(base:false)==original,"Busy pane accepted movement/deletion");pair.model.busy=false
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:100,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        pair.window!.beginSheet(sheet,completionHandler:{_ in});view.moveRight(nil);view.deleteBackward(nil);try require(view.selectedRange()==caret && pair.model.draftText(base:false)==original,"Sheet-owned pane accepted movement/deletion")
        pair.window!.endSheet(sheet);sheet.close();try await wait {pair.window?.attachedSheet==nil}
        pair.model.configureMergeToolReadOnly(true);try await wait {!view.isEditable};view.moveRight(nil);try require(view.selectedRange().location==caret.location+1,"Read-only pane lost navigation");let readOnlyCaret=view.selectedRange();view.deleteBackward(nil);try require(pair.model.draftText(base:false)==original && view.selectedRange()==readOnlyCaret,"Read-only pane deleted source")
        pair.close();view.moveRight(nil);view.moveToBeginningOfLine(nil);view.deleteBackward(nil);try require(pair.model.draftText(base:false)==original && view.selectedRange()==readOnlyCaret,"Retired pane accepted stale input")
        let merge=try await f.merge("ownership merge",text.0,text.1),result=(merge.window as! TextConflictNSWindow).mergedText!
        merge.window?.makeFirstResponder(result);result.setSelectedRange(NSRange(location:8,length:0));let before=merge.model.result,selected=result.selectedRange()
        merge.model.busy=true;result.moveRight(nil);result.deleteBackward(nil);try require(result.selectedRange()==selected && merge.model.result==before,"Busy Merge pane accepted input");merge.model.busy=false
        merge.close();result.moveRight(nil);result.deleteBackward(nil);try require(result.selectedRange()==selected && merge.model.result==before,"Retired Merge pane accepted input")
    }
    static func verify(_ test:String)async throws {
        let f=try Fixture()
        do {switch test{case "navigation":try await navigation(f);case "editing":try await editing(f);case "ownership":try await ownership(f);default:throw Failure(description:"Unknown pane input case")};try await f.cleanup()}
        catch{let failure=error;do{try await f.cleanup()}catch{throw Failure(description:"\(failure); cleanup: \(error)")};throw failure}
    }
}
