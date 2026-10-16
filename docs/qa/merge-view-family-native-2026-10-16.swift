import AppKit
import TurtleGitCore

struct MergeViewFamilyVerification {
    struct Failure: Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func splits(_ view:NSView?) -> [MergeComparisonSplitView] {
        guard let view else { return [] };return (view as? MergeComparisonSplitView).map{[$0]} ?? view.subviews.flatMap{splits($0)}
    }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.MergeView."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        prefs.set(0.36,forKey:MergeComparisonSplitView.key)
        let a=folder.appendingPathComponent("left.txt"),b=folder.appendingPathComponent("right.txt"),output=folder.appendingPathComponent("saved-copy.txt")
        let leftBytes=try ComparisonTextEncoding.utf16LEBOM.encode("head\r\nleft café\r\ntail\r\n"),rightBytes=Data("head\nright 🐢\ntail\n".utf8)
        try leftBytes.write(to:a);try rightBytes.write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model
        defer { owner.close() }
        let window=owner.window!;window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait { !splits(window.contentView).isEmpty }
        let split=splits(window.contentView)[0]
        try require(abs(split.arrangedSubviews[0].frame.width / (split.bounds.width - split.dividerThickness) - 0.36)<0.02,"Saved split fraction not applied")
        split.setPosition((split.bounds.width-split.dividerThickness)*0.42,ofDividerAt:0)
        try require(abs(prefs.double(forKey:MergeComparisonSplitView.key)-0.42)<0.02,"Divider change not saved privately")
        model.switchPaneMode(true);try await TwoPaneEngineVerification.settled(model)
        model.switchPaneMode(false);try await TwoPaneEngineVerification.settled(model)
        try await TwoPaneEngineVerification.wait { !splits(window.contentView).isEmpty }
        try require(abs(splits(window.contentView)[0].fraction-0.42)<0.02,"Combined view lost two-pane split")
        let toolbar=owner.editorToolbar!.toolbar
        model.setToolbarVisible(false);model.setStatusBarVisible(false);owner.editorToolbar!.refresh()
        try require(window.toolbar === toolbar && !toolbar.isVisible && model.nativeToolbarInstalled && !model.showStatusBar,"Hidden toolbar reintroduced fallback or lost owner")
        toolbar.isVisible=true
        try await TwoPaneEngineVerification.wait { model.showToolbar }
        try require(MergeEditorChrome.visible("Toolbar",defaults:prefs) && !MergeEditorChrome.visible("StatusBar",defaults:prefs),"Native visibility did not update private preferences")
        model.setStatusBarVisible(true)
        let heldOpen=MergeEditorOpenWorkflow(window:window,permissions:[],preferences:prefs)
        owner.editorOpenWorkflow=heldOpen
        try require(!model.canSwitchSides,"File/Open ownership did not disable Switch")
        model.switchSides();try require(!model.sidesReversed,"Owned File/Open allowed side exchange")
        heldOpen.retire();owner.editorOpenWorkflow=nil
        owner.editorToolbar!.toolbar.insertItem(withItemIdentifier:MergeToolbarCommand.switchSides.identifier,at:owner.editorToolbar!.toolbar.items.count)
        owner.editorToolbar!.perform(.switchSides);try await TwoPaneEngineVerification.settled(model)
        try require(model.sidesReversed && model.document?.base.bytes==rightBytes && model.document?.destination.bytes==leftBytes,"Switch did not exchange exact source bytes")
        try require(model.document?.destination.encoding == .utf16LEBOM,"Switch lost encoding")
        model.activatePane(base:false);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { model.activeFindText?.isEditable == true }
        var view=model.activeFindText!;view.setSelectedRange(.init(location:0,length:0));view.insertText("saved ",replacementRange:view.selectedRange())
        model.save();try await TwoPaneEngineVerification.settled(model)
        let savedLeft=try Data(contentsOf:a)
        try require(ComparisonTextEncoding.utf16LEBOM.decode(savedLeft)?.hasPrefix("saved head")==true && (try Data(contentsOf:b))==rightBytes,"Reversed Save wrote wrong file or encoding")
        model.load();try await TwoPaneEngineVerification.settled(model)
        try require(model.document?.destination.bytes==savedLeft && model.sidesReversed,"Reload lost orientation")
        model.activatePane(base:false);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { model.activeFindText?.isEditable == true }
        view=model.activeFindText!;view.insertText("draft ",replacementRange:.init(location:0,length:0))
        var reply:((NSApplication.ModalResponse)->Void)?,question:NSAlert?
        model.presentProjectionQuestion={alert,_,answer in question=alert;reply=answer}
        model.switchSides()
        try require(model.confirmingQuit && question?.messageText.contains("switching left and right")==true,"Switch Save question missing")
        reply?(.alertThirdButtonReturn)
        try require(model.sidesReversed && model.dirty && !model.confirmingQuit,"Switch Cancel lost draft/orientation")
        model.switchSides();reply?(.alertSecondButtonReturn);try await TwoPaneEngineVerification.settled(model)
        try require(!model.sidesReversed && !model.dirty && !model.canUndo,"Switch discard did not reload/reset Undo")
        model.chooseExportLocation={_,_,_ in output};model.saveAs(base:false)
        try await TwoPaneEngineVerification.settled(model)
        try require(model.savedPaneURL(base:false)==output,"Save As did not rebind")
        model.switchSides();try await TwoPaneEngineVerification.settled(model)
        try require(model.savedPaneURL(base:true)==output && model.document?.base.path==output.path,"Switch lost Save As target")
        model.activatePane(base:true);model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { model.activeFindText?.isEditable == true }
        model.activeFindText!.insertText("copy ",replacementRange:.init(location:0,length:0));model.save();try await TwoPaneEngineVerification.settled(model)
        try require(String(data:try Data(contentsOf:output),encoding:.utf8)?.hasPrefix("copy head")==true && (try Data(contentsOf:b))==rightBytes,"Swapped rebound Save overwrote original")
        model.load();try await TwoPaneEngineVerification.settled(model)
        try require(model.document?.base.path==output.path,"Rebound reload lost displayed target")
        // Repository revision/worktree and historical/working-file routes retain
        // their original API order at the storage boundary after exchanging UI.
        let repo=GitRepository(root:folder,executable:git)
        _=try await repo.run(["init"]);_=try await repo.run(["config","user.name","View Fixture"]);_=try await repo.run(["config","user.email","view@example.invalid"])
        _=try await repo.run(["add","left.txt"]);_=try await repo.run(["commit","-m","initial"])
        let head=try await repo.run(["rev-parse","HEAD"]).text
        try Data("working\n".utf8).write(to:a)
        let snapshot=try await repo.revisionFileComparison(from:.revision("HEAD"),to:.workingTree,paths:["left.txt"])
        let historical=FileComparisonWindowController(repository:repo,access:nil,snapshot:snapshot,path:"left.txt")
        historical.model.comparisonDefaults=prefs;defer { historical.close() }
        // Viewport restoration needs an actual native host, including hidden QA.
        historical.window?.alphaValue=0;historical.window?.orderFront(nil)
        historical.model.load();try await TwoPaneEngineVerification.settled(historical.model)
        historical.model.switchSides();try await TwoPaneEngineVerification.settled(historical.model)
        try require(historical.model.document?.base.revision == .workingTree && historical.model.document?.base.bytes==Data("working\n".utf8),"Revision/worktree switch routing")
        historical.model.activatePane(base:true);historical.model.editingEnabled=true
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(historical.window?.contentView).contains{$0.isEditable} }
        let historicalEditor=TwoPaneEngineVerification.editors(historical.window?.contentView).first{$0.isEditable}!
        historical.window?.makeFirstResponder(historicalEditor)
        historicalEditor.insertText("repo ",replacementRange:.init(location:0,length:0));historical.model.save();try await TwoPaneEngineVerification.settled(historical.model)
        try require(try Data(contentsOf:a)==Data("repo working\n".utf8),"Reversed repository Save target")
        let permission=RepositoryAccessLease(url:b)
        let pair=try await repo.historicalWorkingFileComparison(revision:"HEAD",path:"left.txt",workingFile:b)
        let external=FileComparisonWindowController(repository:repo,access:nil,comparison:pair,permission:permission)
        external.model.comparisonDefaults=prefs;defer {external.close()}
        external.window?.alphaValue=0;external.window?.orderFront(nil)
        external.model.load();try await TwoPaneEngineVerification.settled(external.model)
        external.model.switchSides();try await TwoPaneEngineVerification.settled(external.model)
        external.model.activatePane(base:false);external.model.editingEnabled=true
        try await TwoPaneEngineVerification.wait {TwoPaneEngineVerification.editors(external.window?.contentView).contains{$0.isEditable}}
        let externalEditor=TwoPaneEngineVerification.editors(external.window?.contentView).first{$0.isEditable}!
        external.window?.makeFirstResponder(externalEditor)
        externalEditor.insertText("external ",replacementRange:.init(location:0,length:0));external.model.save();try await TwoPaneEngineVerification.settled(external.model)
        try require(String(data:try Data(contentsOf:b),encoding:.utf8)?.hasPrefix("external head")==true,"Historical/working-file reversed Save target")
        try require(try await repo.run(["rev-parse","HEAD"]).text==head,"View commands changed HEAD")
        let theirs=folder.appendingPathComponent("theirs.txt");try Data("theirs\n".utf8).write(to:theirs)
        let merge=TextConflictWindowController(repository:repo,access:nil,path:b.path,workingMerge:try WorkingTextMerge(base:a,theirs:theirs,mine:b),preferences:prefs)
        defer {merge.close()};merge.model.load();try await ThreePaneEngineVerification.wait{!merge.model.busy && merge.model.document != nil}
        merge.model.setToolbarVisible(false);merge.model.setStatusBarVisible(false);merge.editorToolbar!.refresh()
        try require(merge.window?.toolbar?.isVisible==false && merge.model.nativeToolbarInstalled && !merge.model.showStatusBar,"Three-pane chrome controls")
        merge.model.setToolbarVisible(true);merge.model.setStatusBarVisible(true)
        model.setToolbarVisible(false);owner.editorToolbar!.refresh()
        let frame=window.frame
        try owner.replaceEditor(.compare(base:a,mine:b,single:false),permissions:[])
        let replacement=window.delegate as! FileComparisonWindowController
        defer {replacement.close()};try await TwoPaneEngineVerification.settled(replacement.model)
        try require(window.frame==frame && !replacement.model.showToolbar && window.toolbar?.isVisible==false && replacement.model.nativeToolbarInstalled,"Open replacement lost hidden toolbar/frame")
        owner.editorToolbar?.perform(.switchSides)
        try require(!replacement.model.sidesReversed,"Retired toolbar switched replacement")
        replacement.model.setToolbarVisible(true);replacement.model.setStatusBarVisible(true);replacement.editorToolbar!.refresh()
        if let captures=ProcessInfo.processInfo.environment["TURTLEGIT_VIEW_CAPTURE"] {
            window.alphaValue=1
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:350_000_000)
                let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-o","-l",String(window.windowNumber),URL(fileURLWithPath:captures).appendingPathComponent("merge-view-controls-"+name+".png").path]
                try p.run();p.waitUntilExit();try require(p.terminationStatus==0,"View capture helper")
            }
        }
        print("PASS: switched exact inputs/reload/Save/Save As/repository/historical routes, dirty Cancel/discard, private toolbar/status visibility, native visibility tracking, split restoration, replacement and retirement; owned windows closed")
    }
}
