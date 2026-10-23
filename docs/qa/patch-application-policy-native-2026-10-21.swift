// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Called by the grouped Compare/Merge receiver; no user defaults, repositories,
/// visible windows or helper processes are shared with the desktop session.
enum PatchApplicationPolicyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value{throw Failure(description:"\(line): \(message)")}}
    @MainActor static func wait(_ owner:WorkingTreePatchWindowController?=nil,_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {owner?.window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:message)
    }
    @MainActor static func table(_ view:NSView?)->NSTableView? {
        guard let view else{return nil};if let value=view as? NSTableView,value.identifier?.rawValue=="TurtleGit.Patch.Files" {return value}
        return view.subviews.compactMap{table($0)}.first
    }
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static let newFiles=Data("""
    diff --git a/a-new.txt b/a-new.txt
    new file mode 100644
    --- /dev/null
    +++ b/a-new.txt
    @@ -0,0 +1 @@
    +first new
    diff --git a/b-new.txt b/b-new.txt
    new file mode 100644
    --- /dev/null
    +++ b/b-new.txt
    @@ -0,0 +1 @@
    +second new

    """.utf8)
    static let editedFile=Data("""
    diff --git a/existing.txt b/existing.txt
    --- a/existing.txt
    +++ b/existing.txt
    @@ -1 +1 @@
    -original
    +patched

    """.utf8)
    @MainActor final class Context {
        let root:URL,git:URL,preferences:UserDefaults,suite:String
        var owners:[WorkingTreePatchWindowController]=[],controls:[URL]=[],releases:[()->Void]=[]
        init(root:URL,git:URL){self.root=root;self.git=git;suite="TurtleGit.PatchApplicationPolicy."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"ShowAppContextMenuIcons")
            var settings=MergeEditorPreferences.load(from:preferences);settings.autoAdd=true;settings.save(to:preferences)
        }
        func repository(_ name:String)async throws->GitRepository {
            let directory=root.appendingPathComponent(name),control=root.appendingPathComponent(name+"-control")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:control,withIntermediateDirectories:true);controls.append(control)
            let initial=GitRepository(root:directory,executable:git,libgit2Configuration:.init(enabled:false))
            _=try await initial.run(["init","-b","main"])
            for(key,value)in [("user.name","Patch Policy QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")]{_=try await initial.run(["config",key,value])}
            try Data("original\n".utf8).write(to:directory.appendingPathComponent("existing.txt"));try await initial.stage(["existing.txt"])
            _=try await initial.run(["commit","-m","private patch baseline"])
            let wrapper=control.appendingPathComponent("git-wrapper")
            let script="""
            #!/bin/bash
            trap 'exit 143' TERM INT
            for value in "$@"; do
              if [ "$value" = add ]; then
                if [ -f \(PatchApplicationPolicyVerification.quote(control.appendingPathComponent("hold-add").path)) ]; then
                  /usr/bin/touch \(PatchApplicationPolicyVerification.quote(control.appendingPathComponent("entered-add").path))
                  while [ ! -f \(PatchApplicationPolicyVerification.quote(control.appendingPathComponent("release-add").path)) ]; do /bin/sleep 0.02; done
                fi
                if [ -f \(PatchApplicationPolicyVerification.quote(control.appendingPathComponent("fail-add").path)) ]; then echo 'private deliberate Add failure' >&2; exit 73; fi
              fi
            done
            exec \(PatchApplicationPolicyVerification.quote(git.path)) "$@"

            """
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            return GitRepository(root:directory,executable:wrapper,libgit2Configuration:.init(enabled:false))
        }
        func owner(_ repository:GitRepository,_ bytes:Data)async throws->WorkingTreePatchWindowController {
            let owner=WorkingTreePatchWindowController(repository:repository,access:nil,fileAccess:nil,bytes:bytes,title:"Private patch policies",preferences:preferences)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.showWindow(nil)
            try await PatchApplicationPolicyVerification.wait(owner,"Patch review did not settle"){!owner.model.busy && owner.model.review != nil && owner.model.editor?.filtering != true}
            return owner
        }
        func autoAdd(_ value:Bool){var settings=MergeEditorPreferences.load(from:preferences);settings.autoAdd=value;settings.save(to:preferences)}
        func clean()async throws {
            owners.forEach{$0.close()}
            releases.forEach{$0()};releases=[]
            owners.forEach{$0.model.presentSaveQuestion=nil}
            for control in controls {try Data().write(to:control.appendingPathComponent("release-add"))}
            try await PatchApplicationPolicyVerification.wait(nil,"Owned patch workers or sheets did not drain"){
                WorkingTreePatchWindowModel.activeOperations==0 && WorkingTreePatchWindowController.activeReleases==0 && self.owners.allSatisfy{!$0.hasPendingWork}
            }
            preferences.removePersistentDomain(forName:suite)
        }
    }
    @MainActor static func automatic(_ context:Context)async throws {
        let repository=try await context.repository("captured-add"),owner=try await context.owner(repository,newFiles),model=owner.model
        let all=Set(model.review!.files.map(\.id)),generation=model.fileListGeneration
        model.mergeToolReadOnly=true
        try require(!model.canPatchFiles,"Readonly patch review exposed automatic mutation")
        model.patchFiles(all,generation:generation)
        try require(!model.busy && !FileManager.default.fileExists(atPath:repository.root.appendingPathComponent("a-new.txt").path),"Readonly Patch All mutated files")
        model.mergeToolReadOnly=false;context.autoAdd(true)
        let control=context.controls.last!;try Data().write(to:control.appendingPathComponent("hold-add"))
        model.patchFiles(all,generation:generation)
        try await wait(owner,"Actual Add subprocess/progress did not enter hold"){
            FileManager.default.fileExists(atPath:control.appendingPathComponent("entered-add").path) && model.batchProgress?.pathBytes==Data("a-new.txt".utf8)
        }
        try require(model.batchTotal==2 && model.batchProgress?.completedIndex==0 && model.busy,"Source current-file/count receipt differs")
        try await MergePatchCapture.save(owner.window!,"patch-automatic-progress")
        context.autoAdd(false) // an accepted operation must keep its original policy
        try Data().write(to:control.appendingPathComponent("release-add"))
        try await wait(owner,"Automatic patch/Add did not settle"){!model.busy}
        let names=try await repository.run(["ls-files","--","a-new.txt","b-new.txt"]).text
        try require(names=="a-new.txt\nb-new.txt\n" && model.batchCompleted==2 && !model.batchCancelled,"Captured automatic Add policy drifted or progress lost completion")
        try require(try Data(contentsOf:repository.root.appendingPathComponent("a-new.txt"))==Data("first new\n".utf8),"Automatic patch bytes differ")
        owner.close()

        let noAdd=try await context.repository("no-add"),noOwner=try await context.owner(noAdd,newFiles)
        context.autoAdd(false);noOwner.model.patchFiles(Set(noOwner.model.review!.files.map(\.id)),generation:noOwner.model.fileListGeneration)
        try await wait(noOwner,"No-Add batch did not settle"){!noOwner.model.busy}
        try require(try await noAdd.run(["ls-files","--","a-new.txt","b-new.txt"]).stdout.isEmpty,"Disabled AutoAdd staged new files")
        try require(noOwner.model.appliedPaths.count==2,"No-Add did not complete real patching")
        noOwner.close()

        let failing=try await context.repository("failed-add"),failureOwner=try await context.owner(failing,newFiles)
        context.autoAdd(true);try Data().write(to:context.controls.last!.appendingPathComponent("fail-add"))
        failureOwner.model.patchFiles(Set(failureOwner.model.review!.files.map(\.id)),generation:failureOwner.model.fileListGeneration)
        try await wait(failureOwner,"Add failure did not continue/settle"){!failureOwner.model.busy}
        try require(failureOwner.model.fileResults.count==2 && failureOwner.model.fileResults.values.allSatisfy{$0.success && $0.addError?.contains("private deliberate Add failure")==true},"Add failure hid successful publication or stopped the next file")
        try require(failureOwner.model.output.contains("Saved patched file, but Add failed"),"Add warning was not visible in native output")
        try await MergePatchCapture.save(failureOwner.window!,"patch-automatic-results")
        failureOwner.close()
    }
    @MainActor static func cancel(_ context:Context)async throws {
        context.autoAdd(true)
        let repository=try await context.repository("cancel-add"),owner=try await context.owner(repository,newFiles),model=owner.model,control=context.controls.last!
        try Data().write(to:control.appendingPathComponent("hold-add"))
        model.patchFiles(Set(model.review!.files.map(\.id)),generation:model.fileListGeneration)
        try await wait(owner,"Cancellation actual Add hold not reached"){FileManager.default.fileExists(atPath:control.appendingPathComponent("entered-add").path) && model.batchProgress != nil}
        let retained=model.fileListGeneration;model.confirmingQuit=true;model.confirmingQuit=false
        try await wait(owner,"Canceled batch process did not reap"){!model.busy}
        try require(model.requiresRefresh && model.batchCancelled && model.batchCompleted==1,"Cancelled batch lost already-patched receipt or allowed stale continuation")
        try require(FileManager.default.fileExists(atPath:repository.root.appendingPathComponent("a-new.txt").path) && !FileManager.default.fileExists(atPath:repository.root.appendingPathComponent("b-new.txt").path),"Cancellation discarded completed file or patched the next file")
        model.patchFiles(Set(model.review!.files.map(\.id)),generation:retained)
        try require(!model.busy,"Retained pre-Quit batch action revived")
        owner.close()
    }
    @MainActor static func explicitSave(_ context:Context)async throws {
        for (name,response,exists) in [("keep-empty",NSApplication.ModalResponse.alertSecondButtonReturn,true),("delete-empty",.alertFirstButtonReturn,false)] {
            let repository=try await context.repository(name),owner=try await context.owner(repository,editedFile),model=owner.model
            MergeFileSaveOptions.saveBackupPreference(true,to:context.preferences)
            model.setEditing(true);model.editor?.updateDraft("",base:false)
            try require(model.canSaveDraft && model.dirty,"Real patch editor did not accept empty draft")
            var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?,completed:Bool?
            model.presentSaveQuestion={ [weak context] alert,answer in
                question=alert;reply=answer;context?.releases.append{answer(.abort)}
                alert.beginSheetModal(for:owner.window!){_ in}
            }
            model.saveDraft{completed=$0}
            try await wait(owner,"Actual empty result question missing"){question?.window.sheetParent === owner.window}
            try require(question?.buttons.map(\.title)==["Delete","Cancel — Keep Empty File"],"Explicit Save empty-result choices differ")
            if name=="keep-empty" {try await MergePatchCapture.save(question!.window,"patch-empty-result-choice")}
            MergeFileSaveOptions.saveBackupPreference(false,to:context.preferences) // capture must precede the reply
            owner.window!.endSheet(question!.window,returnCode:response);reply?(response);reply?(response)
            try await wait(owner,"Explicit patch Save did not drain its question/work"){completed != nil && !model.busy && owner.window?.attachedSheet==nil}
            let file=repository.root.appendingPathComponent("existing.txt"),backup=repository.root.appendingPathComponent("existing.txt.bak")
            try require(completed==true && FileManager.default.fileExists(atPath:file.path)==exists,"Explicit Keep/Delete outcome differs")
            if exists {try require(try Data(contentsOf:file).isEmpty,"Keep Empty File retained text")}
            try require(try Data(contentsOf:backup)==Data("original\n".utf8),"Captured Backup preference or original bytes lost")
            owner.close()
        }
        let repository=try await context.repository("late-empty"),owner=try await context.owner(repository,editedFile),model=owner.model
        model.setEditing(true);model.editor?.updateDraft("",base:false)
        var reply:((NSApplication.ModalResponse)->Void)?,completed:Bool?,closed=false
        model.presentSaveQuestion={ [weak context] _,answer in reply=answer;context?.releases.append{answer(.abort)}}
        owner.onClosed={closed=true};model.saveDraft{completed=$0}
        try await wait(owner,"Held native question did not enter"){reply != nil}
        owner.close()
        try require(!closed && owner.hasPendingWork,"Forced close abandoned the real pending Save reply")
        reply?(.alertFirstButtonReturn)
        try await wait(owner,"Retired empty Save did not drain"){closed && completed != nil && !owner.hasPendingWork}
        try require(completed==false && Data(contentsOf:repository.root.appendingPathComponent("existing.txt"))==Data("original\n".utf8),"Late Delete changed retired owner files")
    }
    @MainActor static func run(root:URL,git:URL)async throws {
        let context=Context(root:root,git:git)
        do {try await automatic(context);try await cancel(context);try await explicitSave(context);try await context.clean()
            print("PASS: native patch AutoAdd capture/disabled/failure continuation, current-file progress, readonly/Quit cancellation, explicit Backup/empty Keep/Delete and late-sheet ownership")
        }catch{try? await context.clean();throw error}
    }
}
