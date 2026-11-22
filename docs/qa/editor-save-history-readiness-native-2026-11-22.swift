// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum EditorSaveHistoryReadinessVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static var phase="setup"
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        guard value else{throw Failure(description:"Editor Save/history line=\(line) phase=\(phase): "+message)}
    }
    static func unwrap<T>(_ value:T?,_ message:String,line:Int = #line)throws->T {
        guard let value else{throw Failure(description:"Editor Save/history line=\(line) phase=\(phase): "+message)};return value
    }
    static func wait(_ ready:()->Bool,line:Int = #line)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Editor Save/history wait line=\(line) phase=\(phase)")
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func sameTarget(_ actual:URL?,_ expected:URL)->Bool {
        actual.map{GitReferenceName.equal($0.standardizedFileURL.resolvingSymlinksInPath().path,expected.standardizedFileURL.resolvingSymlinksInPath().path)} ?? false
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.EditorSaveHistory."+UUID().uuidString,prefs:UserDefaults
        var owners:[NSWindowController]=[],releases:[()->Void]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;MergeComparisonOptions.exact.save(to:prefs);MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)}
        func folder(_ name:String)throws->URL{let value=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true);return value}
        func keep<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.window?.alphaValue=0;owner.window?.ignoresMouseEvents=true;owner.window?.setFrameOrigin(NSPoint(x:-24000,y:-24000));owner.window?.orderFront(nil);return owner}
        func cleanup()async throws {
            releases.forEach{$0()};releases=[]
            owners.reversed().forEach{$0.close()}
            for window in NSApp.windows {if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.orderOut(nil);window.close()}
            try await wait {MergeNavigationRequests.activeRequests==0 && MergeRegexOperations.activeRequests==0 && MergeSourceExport.activeExports==0 && MergeExternalReloadCoordinator.activeRequests==0 && FileComparisonWindowModel.activePaneExports==0 && FileComparisonWindowModel.activeProjectionChoices==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}}
        }
    }
    static func compareReady(_ owner:FileComparisonWindowController)->Bool {
        let model=owner.model
        guard !model.busy,!model.filtering,!model.hasPendingEditorChoice,let scroll=model.connectionEditors().1,let view=scroll.documentView as? NSTextView else{return false}
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return view.window===owner.window && model.ownsEditor(scroll,base:false) && model.ownsViewport(scroll,base:false) && scroll.contentSize.width>32 && scroll.contentSize.height>32
    }
    static func compareView(_ owner:FileComparisonWindowController)throws->NSTextView {
        try unwrap(owner.model.connectionEditors().1?.documentView as? NSTextView,"Current owned Compare result missing")
    }
    static func mergeReady(_ owner:TextConflictWindowController)->Bool {
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return !owner.model.busy && !owner.model.preparing && !owner.model.formatPending && owner.model.nativeEditorReady && owner.model.connectionEditors(mine:true).0?.window===owner.window
    }
    static func mergeView(_ owner:TextConflictWindowController)throws->NSTextView {
        try unwrap(owner.model.connectionEditors(mine:true).0?.documentView as? NSTextView,"Current owned Merge result missing")
    }

    static func compare(_ c:Context,curved:Bool)async throws {
        phase="Compare \(curved ? "curved":"classic") Save completion"
        c.prefs.set(curved,forKey:"TurtleGit.Comparison.CurvedInterface")
        let folder=try c.folder(curved ? "compare-curved":"compare-classic"),left=folder.appendingPathComponent("left"),right=folder.appendingPathComponent("right")
        let original="head 🐢\nnew\nlast",base="head 🐢\nold\nlast"
        try Data(base.utf8).write(to:left);try Data(original.utf8).write(to:right)
        let owner=c.keep(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:c.prefs)),model=owner.model
        defer{owner.close()}
        model.editorConfigEnabled=[true:false,false:false];model.load()
        try await wait{compareReady(owner)}
        model.activatePane(base:false);model.editingEnabled=true
        try await wait{(try? compareView(owner).isEditable)==true}
        let initial=try compareView(owner)
        owner.window?.makeFirstResponder(initial);initial.insertText("edited ",replacementRange:NSRange(location:0,length:0))
        try await wait{compareReady(owner)}
        let changed="edited "+original
        try require(model.draftText(base:false)==changed && model.canUndo,"Actual native edit did not retain exact original endings")

        phase="Compare combined format history"
        let encoding=try unwrap(model.encoding(base:false),"Compare initial encoding unavailable")
        model.chooseFormat={_,_,_ in .init(encoding:.utf16LEBOM,ending:.crlf)}
        model.showFormatDialog(base:false);try await wait{compareReady(owner)}
        let formatted=MergeLineEndings.converting(changed,to:.crlf)
        try require(model.draftText(base:false)==formatted && model.encoding(base:false) == .utf16LEBOM,"Combined format choice was not atomic")
        model.undo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==changed && model.encoding(base:false)==encoding,"Format Undo lost encoding or text")
        model.redo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==formatted && model.encoding(base:false) == .utf16LEBOM,"Format Redo lost encoding or text")
        model.undo();try await wait{compareReady(owner)}

        var completed:Bool?,writableAtCompletion=false,undoAtCompletion=false
        model.save {accepted in
            completed=accepted;writableAtCompletion=(try? compareView(owner).isEditable)==true
            undoAtCompletion=model.canUndo
            if accepted {model.undo()}
        }
        try await wait{completed != nil && compareReady(owner)}
        try require(completed==true && writableAtCompletion && undoAtCompletion,"Save completed before the current native editor/history was writable")
        try require(model.draftText(base:false)==original && model.dirty,"Immediate Save-completion Undo was refused or lost saved baseline")
        try require(try Data(contentsOf:right)==Data(changed.utf8),"Undo rewrote the accepted saved file")
        model.redo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==changed && !model.dirty,"Redo failed to return to accepted Save baseline")
        phase="Compare post-Save whole-source choice"
        model.useOtherFile(targetBase:false);try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==base && model.dirty,"Whole-source action after Save was refused")
        model.undo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==changed && !model.dirty,"Whole-source Undo lost saved baseline")
        model.redo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==base,"Whole-source Redo lost selected input")
        model.undo();try await wait{compareReady(owner)}

        phase="Compare layout replacement retains history"
        c.prefs.set(!curved,forKey:"TurtleGit.Comparison.CurvedInterface")
        try await wait{compareReady(owner) && views(owner.window?.contentView).contains{$0 is CurvedDiffConnectionView} == !curved}
        let replacement=try compareView(owner)
        if replacement !== initial {
            initial.insertText("STALE",replacementRange:NSRange(location:0,length:0))
            try require(model.draftText(base:false)==changed && (initial as? MergeFindProviding)?.mergeFindWritable==false,"Departed Compare view retained editing or Find replacement")
        }
        model.undo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==original && model.dirty,"Layout switch lost document Undo")
        model.redo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==changed && !model.dirty,"Layout switch lost Redo savepoint")

        phase="Compare Quit and Save As cancellation/failure"
        model.confirmingQuit=true
        let quitText=model.draftText(base:false);replacement.insertText("QUIT",replacementRange:NSRange(location:0,length:0));model.undo()
        try require(!replacement.isEditable && model.draftText(base:false)==quitText,"Quit retained a native mutation route")
        model.confirmingQuit=false
        try require(replacement.isEditable,"Cancelled Quit did not synchronously restore native editing")
        var reply:CheckedContinuation<URL?,Never>?
        c.releases.append{reply?.resume(returning:nil);reply=nil}
        model.chooseExportLocation={_,_,_ in await withCheckedContinuation{reply=$0}}
        model.saveAs(base:false);try await wait{reply != nil}
        try require(!replacement.isEditable && !owner.windowShouldClose(owner.window!),"Owned Save As chooser did not exclude native editing/close")
        reply?.resume(returning:nil);reply=nil
        try await wait{!model.exporting && !model.busy && !model.hasPendingEditorChoice}
        try require(replacement.isEditable && model.draftText(base:false)==changed && !model.dirty && model.savedPaneURL(base:false)==nil,"Cancelled Save As changed target/history/readiness")
        model.chooseExportLocation={_,_,_ in folder};model.saveAs(base:false)
        try await wait{!model.exporting && !model.busy && model.error != nil}
        try require(model.draftText(base:false)==changed && !model.dirty && model.savedPaneURL(base:false)==nil,"Failed Save As changed baseline or target")
        model.error=nil;try await wait{owner.window?.attachedSheet==nil && compareReady(owner)}
        let copy=folder.appendingPathComponent("copy")
        model.chooseExportLocation={_,_,_ in copy};model.saveAs(base:false)
        try await wait{compareReady(owner) && sameTarget(model.savedPaneURL(base:false),copy)}
        try require(try Data(contentsOf:copy)==Data(changed.utf8),"Reviewed Save As retry wrote wrong bytes")
        model.undo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==original && model.dirty,"Save As retry lost retained Undo")
        model.redo();try await wait{compareReady(owner)}
        try require(model.draftText(base:false)==changed && !model.dirty,"Save As retry lost accepted clean baseline")
        try require(try Data(contentsOf:left)==Data(base.utf8) && Data(contentsOf:right)==Data(changed.utf8),"Compare Save As rewrote unrelated input")
        owner.close();replacement.insertText("CLOSED",replacementRange:NSRange(location:0,length:0));model.undo()
        try require(model.draftText(base:false)==changed && !model.canUndo && !model.canRedo && (replacement as? MergeFindProviding)?.mergeFindWritable==false,"Closed Compare retained actionable history or Find replacement")
        print("PASS: Compare Save/history \(curved ? "curved":"classic")")
    }

    static func merge(_ c:Context,curved:Bool)async throws {
        phase="Merge \(curved ? "curved":"classic") Save completion"
        c.prefs.set(curved,forKey:"TurtleGit.Comparison.CurvedInterface")
        let folder=try c.folder(curved ? "merge-curved":"merge-classic"),base=folder.appendingPathComponent("base"),mine=folder.appendingPathComponent("mine"),theirs=folder.appendingPathComponent("theirs"),output=folder.appendingPathComponent("result")
        let original="head 🐢\nnew\nlast",unchanged="head 🐢\nold\nlast"
        for (file,text) in [(base,unchanged),(mine,original),(theirs,unchanged)] {try Data(text.utf8).write(to:file)}
        let owner=c.keep(TextConflictWindowController(repository:GitRepository(root:folder,executable:c.git),access:nil,path:"mine",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:c.prefs)),model=owner.model
        defer{owner.close()};model.load();try await wait{mergeReady(owner)}
        let initial=try mergeView(owner);try require(initial.isEditable && model.result==original,"Current Merge result did not become writable")
        owner.window?.makeFirstResponder(initial);initial.insertText("edited ",replacementRange:NSRange(location:0,length:0))
        try await wait{mergeReady(owner)}
        let changed="edited "+original
        try require(model.result==changed && model.canUndo,"Native result edit did not register retained history")
        let originalEncoding=model.encoding
        model.applyFormatChoice(.init(encoding:.utf16LEBOM,ending:.crlf))
        let formatted=MergeLineEndings.converting(changed,to:.crlf)
        try await wait{mergeReady(owner)}
        try require(model.result==formatted && model.encoding == .utf16LEBOM,"Merge combined format choice lost text/encoding")
        model.undo();try await wait{mergeReady(owner)}
        try require(model.result==changed && model.encoding==originalEncoding,"Merge format Undo did not restore exact snapshot")
        model.redo();try await wait{mergeReady(owner)}
        try require(model.result==formatted && model.encoding == .utf16LEBOM,"Merge format Redo did not restore exact snapshot")
        model.undo();try await wait{mergeReady(owner)}
        var completed:Bool?,writableAtCompletion=false,undoAtCompletion=false
        model.chooseStandaloneOutput={_,_ in output}
        model.save(markResolved:false) {accepted in
            completed=accepted;writableAtCompletion=(try? mergeView(owner).isEditable)==true;undoAtCompletion=model.canUndo
            if accepted {model.undo()}
        }
        try await wait{completed != nil && mergeReady(owner)}
        try require(completed==true && writableAtCompletion && undoAtCompletion,"Merge Save completion preceded native/history readiness")
        try require(model.result==original && model.dirty,"Immediate Merge Save-completion Undo was refused")
        try require(try Data(contentsOf:output)==Data(changed.utf8),"Merge Undo rewrote saved output")
        model.redo();try await wait{mergeReady(owner)}
        try require(model.result==changed && !model.dirty,"Merge Redo did not return to Save baseline")
        phase="Merge post-Save whole-source choice"
        if curved {model.p4UseFile(.theirs)}else{
            let source=try unwrap(model.connectionEditors(mine:false).0?.documentView as? NSTextView,"Current Theirs source missing")
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
            let provider=try unwrap(source as? MergeContextMenuProviding,"Theirs source menu missing")
            let menu=provider.mergeContextMenu(defaults:c.prefs,pasteboard:board)
            let item=try unwrap(menu.item(withTitle:"Use this whole file"),"Whole-source menu action missing")
            try require(item.isEnabled && item.image != nil && NSApp.sendAction(item.action!,to:item.target,from:item),"Whole-source native menu did not dispatch")
        }
        try await wait{mergeReady(owner)}
        try require(model.result==unchanged && model.dirty,"Whole-source action after Merge Save was refused")
        model.undo();try await wait{mergeReady(owner)}
        try require(model.result==changed && !model.dirty,"Merge source-choice Undo lost Save baseline")
        model.redo();try await wait{mergeReady(owner)}
        try require(model.result==unchanged,"Merge source-choice Redo lost selected input")
        model.undo();try await wait{mergeReady(owner)}

        phase="Merge layout replacement retains history"
        c.prefs.set(!curved,forKey:"TurtleGit.Comparison.CurvedInterface")
        // nativeEditorReady includes the actual result pane's layout mode;
        // a renderer may legitimately reuse the native editor for that mode.
        try await wait{mergeReady(owner)}
        let replacement=try mergeView(owner)
        if replacement !== initial {
            (initial as? MergeResultHistoryProviding)?.undoMergeEdit();initial.insertText("STALE",replacementRange:NSRange(location:0,length:0))
            try require(model.result==changed && initial.undoManager==nil && (initial as? MergeFindProviding)?.mergeFindWritable==false,"Departed Merge pane retained a mutation/history/Find route")
        }
        model.undo();try await wait{mergeReady(owner)}
        try require(model.result==original && model.dirty,"Layout switch discarded Merge document history")
        model.redo();try await wait{mergeReady(owner)}
        try require(model.result==changed && !model.dirty,"Layout switch discarded Merge Redo/savepoint")
        model.confirmingQuit=true;replacement.insertText("QUIT",replacementRange:NSRange(location:0,length:0));model.undo()
        try require(!replacement.isEditable && model.result==changed,"Merge Quit retained native mutation/history")
        model.confirmingQuit=false;try require(replacement.isEditable,"Cancelled Merge Quit retained stale read-only state")

        phase="Merge Save As cancellation/failure/retry"
        var reply:CheckedContinuation<URL?,Never>?,saveAs:Bool?
        c.releases.append{reply?.resume(returning:nil);reply=nil}
        model.chooseStandaloneOutput={_,_ in await withCheckedContinuation{reply=$0}}
        model.save(markResolved:false,chooseNewOutput:true){saveAs=$0}
        try await wait{reply != nil}
        try require(!replacement.isEditable && !owner.windowShouldClose(owner.window!),"Merge Save As chooser retained native editing/close")
        reply?.resume(returning:nil);reply=nil
        try await wait{saveAs != nil && !model.busy}
        try require(saveAs==false && replacement.isEditable && model.result==changed && !model.dirty,"Cancelled Merge Save As lost readiness or baseline")
        model.chooseStandaloneOutput={_,_ in folder};saveAs=nil
        model.save(markResolved:false,chooseNewOutput:true){saveAs=$0}
        try await wait{saveAs != nil && !model.busy}
        try require(saveAs==false && model.error != nil && model.result==changed && !model.dirty,"Failed Merge Save As modified retained baseline")
        model.error=nil;try await wait{owner.window?.attachedSheet==nil && mergeReady(owner)}
        let copy=folder.appendingPathComponent("copy");model.chooseStandaloneOutput={_,_ in copy};saveAs=nil
        model.save(markResolved:false,chooseNewOutput:true){saveAs=$0}
        try await wait{saveAs != nil && mergeReady(owner)}
        try require(saveAs==true && !model.dirty && (try Data(contentsOf:copy))==Data(changed.utf8),"Fresh reviewed Merge Save As retry lost exact bytes")
        model.undo();try await wait{mergeReady(owner)}
        try require(model.result==original && model.dirty,"Merge Save As retry discarded retained Undo")
        model.redo();try await wait{mergeReady(owner)}
        try require(model.result==changed && !model.dirty,"Merge Save As retry discarded retained Redo baseline")
        for (file,text) in [(base,unchanged),(mine,original),(theirs,unchanged)] {try require(try Data(contentsOf:file)==Data(text.utf8),"Merge saved result rewrote an input")}
        owner.close();(replacement as? MergeResultHistoryProviding)?.undoMergeEdit();replacement.insertText("CLOSED",replacementRange:NSRange(location:0,length:0));model.undo()
        try require(model.result==changed && !model.canUndo && !model.canRedo && (replacement as? MergeFindProviding)?.mergeFindWritable==false,"Closed Merge retained document history or Find replacement")
        print("PASS: Merge Save/history \(curved ? "curved":"classic")")
    }

    static func readOnly(_ c:Context,mode:String,curved:Bool)async throws {
        phase="\(mode) immutable read-only policy \(curved)"
        c.prefs.set(curved,forKey:"TurtleGit.Comparison.CurvedInterface")
        let folder=try c.folder("readonly-\(mode)-\(curved)"),left=folder.appendingPathComponent("left"),right=folder.appendingPathComponent("right")
        try Data("left\n".utf8).write(to:left);try Data("right\n".utf8).write(to:right)
        if mode=="compare" {
            let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:c.prefs,deferInitialLoad:true)
            // Install invocation policy before hosting appearance may start a
            // read; an in-flight document correctly refuses that policy change.
            owner.model.configureMergeToolReadOnly(true)
            try require(owner.model.mergeToolReadOnly,"Deferred Compare did not accept immutable read-only policy before load")
            _=c.keep(owner);owner.model.beginTransferredDocument();try await wait{compareReady(owner)}
            let model=owner.model,view=try compareView(owner),original=model.draftText(base:false),encoding=model.encoding(base:false)
            view.insertText("REFUSED",replacementRange:NSRange(location:0,length:0));model.changeEncoding(.utf16LEBOM,base:false);model.undo();model.redo()
            try require(!view.isEditable,"Read-only Compare native editor became writable")
            try require(model.draftText(base:false)==original,"Read-only Compare native input changed exact draft bytes")
            try require(model.encoding(base:false)==encoding,"Read-only Compare format action changed encoding")
            try require(!model.dirty,"Read-only Compare became dirty")
            try require(!model.canUndo,"Read-only Compare registered Undo")
            try require(!model.canRedo,"Read-only Compare registered Redo")
            owner.close()
        } else {
            let owner=TextConflictWindowController(repository:GitRepository(root:folder,executable:c.git),access:nil,path:"right",workingMerge:try WorkingTextMerge(base:left,theirs:left,mine:right),preferences:c.prefs,deferInitialLoad:true)
            owner.model.configureMergeToolReadOnly(true)
            try require(owner.model.mergeToolReadOnly,"Deferred Merge did not accept immutable read-only policy before load")
            _=c.keep(owner);owner.model.beginTransferredDocument();try await wait{mergeReady(owner)}
            let model=owner.model,view=try mergeView(owner),original=model.result,encoding=model.encoding
            view.insertText("REFUSED",replacementRange:NSRange(location:0,length:0));model.changeEncoding(.utf16LEBOM);model.undo();model.redo()
            try require(!view.isEditable,"Read-only Merge native editor became writable")
            try require(model.result==original,"Read-only Merge native input changed exact result bytes")
            try require(model.encoding==encoding,"Read-only Merge format action changed encoding")
            try require(!model.canUndo,"Read-only Merge registered Undo")
            try require(!model.canRedo,"Read-only Merge registered Redo")
            owner.close()
        }
        try require(try Data(contentsOf:left)==Data("left\n".utf8) && Data(contentsOf:right)==Data("right\n".utf8),"Read-only editor rewrote an input")
    }
    static func run(_ mode:String)async throws {
        let c=Context()
        let requested=ProcessInfo.processInfo.environment["TURTLEGIT_EDITOR_SAVE_HISTORY_LAYOUT"]
        let layouts=requested=="classic" ? [false]:requested=="p4" ? [true]:[false,true]
        do {
            for curved in layouts {
                if mode=="compare"{try await compare(c,curved:curved)}else{try await merge(c,curved:curved)}
                try await readOnly(c,mode:mode,curved:curved)
            }
            try await c.cleanup()
        }catch{
            let original=error
            do{try await c.cleanup()}catch{c.prefs.removePersistentDomain(forName:c.suite);throw Failure(description:"\(original); owned cleanup also failed: \(error)")}
            c.prefs.removePersistentDomain(forName:c.suite);throw original
        }
        c.prefs.removePersistentDomain(forName:c.suite)
    }
}
