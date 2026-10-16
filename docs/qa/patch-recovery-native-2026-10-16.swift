import AppKit
import TurtleGitCore

struct PatchRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch recovery QA"),("user.email","recovery@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let paths=["a.txt","b.txt","c.txt","d.txt"],base="head\nold\nkeep\ntail\n",patched="head\nnew\nkeep\ntail\n"
        for path in paths {try Data(base.utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_=try await repo.commit(message:"base")
        for path in paths {try Data(patched.utf8).write(to:root.appendingPathComponent(path))}
        let diff=try await repo.run(["diff","--full-index","--"]).stdout
        let patch=Data(String(decoding:diff,as:UTF8.self).components(separatedBy:"diff --git ").map {block in
            block.hasPrefix("a/c.txt b/c.txt\n") ? block.components(separatedBy:"\n").filter{!$0.hasPrefix("index ")}.joined(separator:"\n") : block
        }.joined(separator:"diff --git ").utf8)
        let currentB="head\ncurrent B 🐢\nkeep\ntail\n",currentC="head\ncurrent C\nkeep\ntail\n",currentD="head\nold\nkeep\nlocal tail\n"
        for (name,text) in [("a.txt",base),("b.txt",currentB),("c.txt",currentC),("d.txt",currentD)] {try Data(text.utf8).write(to:root.appendingPathComponent(name))}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let input=root.appendingPathComponent("input.diff");try patch.write(to:input)
        let suite="TurtleGit.PatchRecovery."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);prefs.set(true,forKey:"TurtleGitMerge.UseUTF8")
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Recorded-base patch recovery",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        try await PatchFilePanelVerification.wait{!model.busy && model.editor?.filtering==false}
        let files=model.review!.files,b=files.first{$0.path=="b.txt"}!,c=files.first{$0.path=="c.txt"}!
        try require(model.fileState(files.first{$0.path=="a.txt"}!).isEmpty && model.fileState(b)=="conflict" && model.fileState(c)=="error","Initial ready/conflict/error rows")
        model.highlightFiles([b.id]);model.previewFiles([b.id],generation:model.fileListGeneration)
        try await PatchFilePanelVerification.wait{!model.busy && model.conflictEditor?.sourceToolsAllowed==true && (window as! TextConflictNSWindow).mergedText != nil}
        var conflict=model.conflictEditor!
        try require(conflict.document?.base==base && conflict.document?.mine==currentB && conflict.document?.theirs==patched && conflict.blocks.count==1,"Recorded/current/patched three-pane contents")
        try require(owner.editorToolbar != nil && conflict.nativeToolbarInstalled && !conflict.repositoryResolutionAllowed,"Embedded native toolbar and no index-resolution action")
        try require(try Data(contentsOf:root.appendingPathComponent("b.txt"))==Data(currentB.utf8),"Preview wrote working contents")
        try await PatchFilePanelVerification.capture(window,name:"patch-recovery")
        conflict.choose(.mine);try require(model.dirty && conflict.result==currentB,"Mine block choice")
        let undo=MergeCommandMenusVerification.event("z",code:6,flags:.command,window:window)
        try require(window.performKeyEquivalent(with:undo) && conflict.hasUnresolvedConflicts,"Embedded Command-Z")
        let redo=MergeCommandMenusVerification.event("z",code:6,flags:[.command,.shift],window:window)
        try require(window.performKeyEquivalent(with:redo) && conflict.result==currentB,"Embedded Redo")
        _=window.performKeyEquivalent(with:undo)
        conflict.confirmUnresolvedSave={_ in false}
        let cancelled=await withCheckedContinuation {continuation in model.saveDraft {continuation.resume(returning:$0)}}
        try require(!cancelled && conflict.hasUnresolvedConflicts,"Unresolved Save Cancel")
        conflict.continueResolving();try require(conflict.canChooseConflict,"Current conflict choice unavailable after Undo");conflict.choose(.theirs);model.highlightFiles([c.id]);try require(model.dirty && model.highlightedFiles==[b.id],"Dirty conflict selection changed: dirty=\(model.dirty), selected=\(model.highlightedFiles), result=\(conflict.result), blocks=\(conflict.blocks.count)")
        model.chooseDraft={.cancel};try require(await model.resolveDraft()==false && model.dirty,"Dirty close Cancel")
        model.chooseDraft={.discard};try require(await model.resolveDraft(),"Dirty discard refused")
        try await PatchFilePanelVerification.wait{model.conflictEditor?.sourceToolsAllowed==true}
        try require(conflict.retired && model.conflictEditor !== conflict,"Discard retained old conflict owner")
        conflict=model.conflictEditor!;try require(conflict.hasUnresolvedConflicts,"Discard lost regenerated conflict")
        conflict.continueResolving();conflict.choose(.theirs)
        let saved=await withCheckedContinuation {continuation in model.saveDraft {continuation.resume(returning:$0)}}
        try require(saved && conflict.patchResultCompleted && !model.dirty && !model.canSaveDraft && !conflict.canUndo,"Completed conflict baseline/history/gates")
        try require(try Data(contentsOf:root.appendingPathComponent("b.txt"))==Data(patched.utf8),"Resolved Save bytes")
        model.patchFiles(Set(files.map(\.id)),generation:model.fileListGeneration)
        try await PatchFilePanelVerification.wait{!model.busy && !model.conflictOperationActive}
        try require(model.appliedPaths.count==3 && model.fileState(c)=="error","Patch all clean-recovery/error continuation")
        try require(try Data(contentsOf:root.appendingPathComponent("d.txt"))==Data("head\nnew\nkeep\nlocal tail\n".utf8),"Clean recovery lost independent context edit")
        try require(try Data(contentsOf:root.appendingPathComponent("a.txt"))==Data(patched.utf8) && Data(contentsOf:root.appendingPathComponent("c.txt"))==Data(currentC.utf8),"Patch all normal/error bytes")
        model.previewTab=1;try await PatchFilePanelVerification.capture(window,name:"patch-recovery-results")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:input)==patch,"Recovery changed HEAD/index/source patch")
        owner.close();conflict.choose(.mine);try require(model.retired && conflict.retired,"Retired recovery owner")
        print("PASS: initial ready/conflict/error states, recorded-base embedded three-pane and native toolbar, side choices/Undo/Redo, unresolved Save Cancel, dirty Cancel/discard/regeneration, exact resolved Save and completed gates, clean Patch all recovery with independent edit, missing-base error continuation, unchanged HEAD/index/source patch and retirement; owned window closed")
    }
}
