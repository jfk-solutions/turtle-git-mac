// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergeConflictPresentationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2400 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Conflict pane presentation timeout at \(line)")
    }
    static func pane(_ window:NSWindow,_ role:TextConflictPaneRole)throws->NSTextView {
        let candidates=views(window.contentView).compactMap{$0 as? NSTextView}.filter{$0 is MergeFindProviding}
        let match=candidates.first {view in
            let title=view.accessibilityLabel() ?? ""
            switch role {
            case .theirs:return title.hasPrefix("Theirs")
            case .mine:return title.hasPrefix("Mine")
            case .base:return title=="Base"
            case .result:return title.hasPrefix("Merged ·")
            }
        }
        guard let match else {throw Failure(description:"Missing actual Merge pane: \(role)")};return match
    }
    static func header(_ window:NSWindow,_ prefix:String)throws->MergePaneHeaderView {
        guard let match=views(window.contentView).compactMap({$0 as? MergePaneHeaderView}).first(where:{$0.titleField.stringValue.replacingOccurrences(of:"* ",with:"").hasPrefix(prefix)}) else {throw Failure(description:"Missing actual pane header: "+prefix)}
        return match
    }
    static func run(root:URL,git:URL)async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.MergePane.Conflict."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"TurtleGitMerge.FirstDiffOnLoad");prefs.set(false,forKey:"TurtleGitMerge.FirstConflictOnLoad")
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        MergeComparisonOptions.exact.save(to:prefs)
        let common="alpha alpha beta\n\t😀 alpha beta\n"
        let base=root.appendingPathComponent("base\tname.txt"),mine=root.appendingPathComponent("mine\nname.txt"),theirs=root.appendingPathComponent("theirs.txt"),output=root.appendingPathComponent("result\nname.txt")
        let inputs=[base:Data((common+"base\n").utf8),mine:Data((common+"mine\n").utf8),theirs:Data((common+"theirs\n").utf8)]
        for(url,bytes)in inputs {try bytes.write(to:url)}
        let repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        let owner=TextConflictWindowController(repository:repository,access:nil,path:output.path,workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs)
        let model=owner.model
        var readonlyOwner:TextConflictWindowController?,projectionOwner:TextConflictWindowController?
        model.commentProfileURL=root.appendingPathComponent("private-profiles");model.regexDefaults=prefs
        func clean()async {
            owner.close();readonlyOwner?.close();projectionOwner?.close()
            for _ in 0..<2400 {if !model.mergeToolHasPendingWork && readonlyOwner?.model.mergeToolHasPendingWork != true && projectionOwner?.model.mergeToolHasPendingWork != true{return};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do {
            model.showBase=true;owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.load()
            guard let window=owner.window else {throw Failure(description:"Missing native Merge window")}
            try await wait(window){!model.busy && model.document != nil && model.sourceToolsAllowed && (try? pane(window,.base)) != nil}
            let left=try pane(window,.theirs),right=try pane(window,.mine),bottom=try pane(window,.result)
            let original=model.result,originalDirty=model.dirty
            try require(views(window.contentView).compactMap{$0 as? MergePaneHeaderView}.count==4,"Source and optional Base headers missing")
            let rightHeader=try header(window,"Mine"),resultHeader=try header(window,"Merged")
            // Model readiness is published before SwiftUI updates the native
            // header's enabled state on older SDKs. Await that rendered state;
            // activation itself is still attempted exactly once below.
            try await wait(window){rightHeader.window === window && rightHeader.isAccessibilityEnabled()}
            try require(rightHeader.toolTip?.contains(mine.path)==true && resultHeader.toolTip?.contains(output.path)==true,"Raw pane paths were rewritten in tooltip")
            try require(!resultHeader.titleField.stringValue.contains("\n") && resultHeader.titleField.stringValue.contains("↵"),"Native result title contains a raw line break")
            try require(resultHeader.frame.height>20 && resultHeader.frame.height<60 && resultHeader.titleField.maximumNumberOfLines==1,"Merge header lost bounded single-line geometry")
            let headerAccepted=rightHeader.accessibilityPerformPress()
            if !headerAccepted {
                print("Merge header activation diagnostic: enabled=\(rightHeader.isAccessibilityEnabled()) attached=\(rightHeader.window === window) hidden=\(rightHeader.isHiddenOrHasHiddenAncestor) frame=\(rightHeader.frame) tools=\(model.sourceToolsAllowed) busy=\(model.busy) sheet=\(String(describing:window.attachedSheet)) modal=\(String(describing:NSApp.modalWindow))")
            }
            try require(headerAccepted,"Actual source header refused activation")
            try await wait(window){model.activePresentationPane == .mine && window.firstResponder === right}
            guard let range=right.string.range(of:"\t😀 alpha") else {throw Failure(description:"Actual aligned source lost tab/emoji")}
            let start=NSRange(range,in:right.string).location
            right.setSelectedRange(.init(location:start+3,length:0))
            try await wait(window){model.presentationColumn==4}
            model.focusPresentationPane(.base)
            try await wait(window){model.activePresentationPane == .base}
            let staleBase=model.paneHeaderAction(.base)
            model.showBase=false;model.showBase=true
            try await wait(window){(try? pane(window,.base)) != nil}
            model.focusPresentationPane(.result)
            try require(!staleBase(),"Replaced Base activation falsely reported success")
            try require(model.activePresentationPane == .result,"Old optional Base action survived pane replacement")
            model.focusPresentationPane(.base)
            try await wait(window){model.activePresentationPane == .base}
            for word in ["alpha","beta"] {
                for view in [left,right,bottom] {(view as! MergeFindProviding).mergeFindHighlights.mark(word,in:view)}
                try await MergePanePresentationVerification.marked(window,labels:["L","R","B"],counts:[2,2,2],actual:{model.presentationMarkedCounts})
                let occurrences=word=="alpha" ? 3:2
                try require([left,right,bottom].allSatisfy{($0 as! MergeFindProviding).mergeFindHighlights.markedRanges.count==occurrences},"Screen-row status changed same-row occurrence painting")
            }
            let statuses=views(window.contentView).compactMap{$0 as? NSTextField}
            try require(statuses.contains{$0.identifier?.rawValue=="Merge.Status.MarkedWords" && $0.stringValue.contains("L: 2 | R: 2 | B: 2")},"Actual marked status omits same-row occurrences")
            model.focusPresentationPane(.result)
            bottom.insertText("manual ",replacementRange:.init(location:0,length:0))
            try await wait(window){model.dirty && ((try? header(window,"Merged"))?.titleField.stringValue.hasPrefix("* ")==true)}
            try require(!(try header(window,"Mine")).titleField.stringValue.hasPrefix("* "),"Result edit marked read-only source dirty")
            try await MergePatchCapture.save(window,"merge-pane-status")
            let undoReady=model.canUndo
            model.undo()
            print("Merge Undo diagnostic: initialDirty=\(originalDirty) canUndoBefore=\(undoReady) canUndoAfter=\(model.canUndo) allowed=\(model.sourceMutationsAllowed) editable=\(bottom.isEditable) sameResult=\(model.result==original) dirty=\(model.dirty) originalLength=\(original.utf16.count) resultLength=\(model.result.utf16.count)")
            try await wait(window){model.dirty==originalDirty && model.result==original && model.canRedo}
            try require((try header(window,"Merged")).titleField.stringValue.hasPrefix("* ")==originalDirty,"Undo did not restore the original result dirty indicator")
            let stale=model.paneHeaderAction(.mine)
            model.confirmingQuit=true;model.confirmingQuit=false
            try require(!stale(),"Retired Merge activation falsely reported success")
            try require(window.firstResponder === bottom,"Header callback revived across Quit epoch")
            model.setStatusBarVisible(false)
            try await wait(window){!views(window.contentView).contains{$0.identifier?.rawValue=="Merge.Status.Column"}}
            model.setStatusBarVisible(true)
            try await wait(window){views(window.contentView).contains{$0.identifier?.rawValue=="Merge.Status.Column"}}
            let retiredHeader=try header(window,"Mine")
            owner.close();try require(!retiredHeader.accessibilityPerformPress(),"Closed Merge header kept focus authority")
            // Read-only is an immutable launch policy: configure it before load,
            // just as the actual command receiver does, rather than invoking a
            // guarded initial-configuration method on an already loaded owner.
            let read=TextConflictWindowController(repository:repository,access:nil,path:output.path,workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs,deferInitialLoad:true)
            readonlyOwner=read;read.model.configureMergeToolReadOnly(true)
            try require(read.model.mergeToolReadOnly,"Deferred readonly launch policy was not captured")
            read.model.commentProfileURL=root.appendingPathComponent("private-profiles");read.model.regexDefaults=prefs
            read.window?.alphaValue=0;read.window?.orderFront(nil);read.model.beginTransferredDocument()
            guard let readWindow=read.window else {throw Failure(description:"Readonly Merge window missing")}
            try await wait(readWindow){!read.model.busy && read.model.document != nil && read.model.sourceToolsAllowed && (try? pane(readWindow,.mine)) != nil}
            var readinessAttempts=0
            try await wait(readWindow){
                readinessAttempts += 1
                if readinessAttempts==100 {
                    let descriptions=views(readWindow.contentView).compactMap{$0 as? NSTextView}.filter{$0 is MergeFindProviding}.map {view in "label=\(view.accessibilityLabel() ?? "nil") editable=\(view.isEditable) ready=\((view as? MergeContextMenuProviding)?.mergeSourceRowsReady == true) text=\(String(reflecting:String(view.string.prefix(120))))"}
                    print("Readonly Merge readiness: policy=\(read.model.mergeToolReadOnly) pending=\(String(describing:read.model.selectionRequest)) rows=\(read.model.sourceComparison?.rows.count ?? -1) result=\(String(reflecting:read.model.resultDisplayText)) views=\(descriptions)")
                }
                guard read.model.selectionRequest==nil,let rows=read.model.sourceComparison?.rows,
                      let mine=try? pane(readWindow,.mine),let theirs=try? pane(readWindow,.theirs),let result=try? pane(readWindow,.result) else{return false}
                return mine.string==rows.map{ $0.mine.displayText }.joined(separator:"\n")+(rows.isEmpty ? "":"\n") && theirs.string==rows.map{ $0.theirs.displayText }.joined(separator:"\n")+(rows.isEmpty ? "":"\n") && result.string==read.model.resultDisplayText && !result.isEditable && [mine,theirs,result].allSatisfy{($0 as? MergeContextMenuProviding)?.mergeSourceRowsReady==true}
            }
            await Task.yield()
            let readonlyResult=try pane(readWindow,.result),readonlyMine=try pane(readWindow,.mine)
            read.model.focusPresentationPane(.mine)
            var diagnosed=false
            try await wait(readWindow){
                let ready=read.model.activePresentationPane == .mine && readWindow.firstResponder === readonlyMine && !readonlyResult.isEditable
                if !ready && !diagnosed {diagnosed=true;print("Readonly Merge focus diagnostic: role=\(String(describing:read.model.activePresentationPane)) actual=\(readWindow.firstResponder === readonlyMine) responder=\(String(describing:readWindow.firstResponder)) attached=\(readonlyMine.window === readWindow) editable=\(readonlyResult.isEditable) policy=\(read.model.mergeToolReadOnly) allowed=\(read.model.sourceToolsAllowed)")}
                return ready
            }
            try require(!read.model.sourceMutationsAllowed,"Read-only Merge retained mutation authority")
            let unchanged=read.model.result;readonlyResult.insertText("forbidden",replacementRange:.init(location:0,length:0))
            try require(read.model.result==unchanged && !read.model.dirty,"Readonly pane accepted an actual text edit")
            (readonlyMine as! MergeFindProviding).mergeFindHighlights.mark("beta",in:readonlyMine)
            try await MergePanePresentationVerification.marked(readWindow,labels:["L","R","B"],counts:[0,2,0],actual:{read.model.presentationMarkedCounts})
            let markedBase=root.appendingPathComponent("marked-base.txt"),markedMine=root.appendingPathComponent("marked-mine.txt"),markedTheirs=root.appendingPathComponent("marked-theirs.txt"),markedOutput=root.appendingPathComponent("marked-result.txt")
            let fixture=MergePanePresentationVerification.markedFixture(false),changed=MergePanePresentationVerification.markedFixture(true)
            try Data(fixture.utf8).write(to:markedBase);try Data(changed.utf8).write(to:markedMine);try Data(fixture.utf8).write(to:markedTheirs)
            let projected=TextConflictWindowController(repository:repository,access:nil,path:markedOutput.path,workingMerge:try WorkingTextMerge(base:markedBase,theirs:markedTheirs,mine:markedMine),preferences:prefs)
            projectionOwner=projected;projected.model.commentProfileURL=root.appendingPathComponent("unused-marked-profiles");projected.window?.alphaValue=0;projected.showWindow(nil);projected.model.load()
            guard let markedWindow=projected.window else{throw Failure(description:"Marked Merge window missing")}
            func projectedPanes()->[NSTextView]{[TextConflictPaneRole.theirs,.mine,.result].compactMap{try? pane(markedWindow,$0)}}
            func projectedReady()async throws {
                try await wait(markedWindow){!projected.model.busy && !projected.model.lineWrapping.isGeometryPending && projected.model.document != nil && projectedPanes().count==3 && projectedPanes().allSatisfy{($0 as? MergeContextMenuProviding)?.mergeSourceRowsReady==true}}
                await Task.yield();try await Task.sleep(nanoseconds:30_000_000)
            }
            try await projectedReady()
            // The changed Mine line contributes removed-old and added-new
            // display rows; Mine/result have51 alpha rows and102 paint ranges.
            try require(projectedPanes().map{MergePanePresentationVerification.fragmentCount("alpha",in:$0)}==[50,51,51],"Aligned native source rows lost removed/added display evidence")
            try await MergePanePresentationVerification.projectedMarks(window:markedWindow,panes:projectedPanes,actual:{projected.model.presentationMarkedCounts},labels:["L","R","B"],unwrappedCounts:[50,51,51],longWordCounts:[1,2,2],wrap:projected.model.setWrapLines,collapse:projected.model.setCollapsed,settle:projectedReady)
            projected.model.showBase=true;try await wait(markedWindow){(try? pane(markedWindow,.base)) != nil}
            projected.model.showBase=false;projected.model.showBase=true
            try await projectedReady()
            try await MergePanePresentationVerification.marked(markedWindow,labels:["L","R","B"],counts:[50,51,51],actual:{projected.model.presentationMarkedCounts})
            try require(projectedPanes().map{($0 as! MergeFindProviding).mergeFindHighlights.markedRanges.count}==[100,102,102],"Optional Base replacement changed live pane painting")
            await clean()
            for(url,bytes)in inputs {try require(try Data(contentsOf:url)==bytes,"Pane UI changed an input file")}
            try require(!FileManager.default.fileExists(atPath:output.path),"Pane UI wrote an output")
            try require(!model.mergeToolHasPendingWork,"Merge presentation workers survived close")
        }catch {await clean();throw error}
        print("PASS: Conflict pane headers, raw identities, active caret, same-row marked counts, dirty/Undo, Base replacement, readonly and retirement")
    }
}
