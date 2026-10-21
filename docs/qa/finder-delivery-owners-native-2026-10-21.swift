// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Composed into the Finder delivery receiver. Its caller hides every native
/// window, supplies a private home/TMPDIR and chooses the actual Git engine.
@MainActor enum FinderDeliveryOwnersVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"\(line): \(message)")}}
    static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2400 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): \(message)")
    }
    static func idle()->Bool {
        ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 &&
        SendPatchWindowModel.activeLoads==0 && SendPatchWindowController.activeTargetReads==0 && SendPatchWindowController.activeReleases==0 &&
        WorkingTreePatchWindowModel.activeOperations==0 && WorkingTreePatchWindowController.activeReleases==0 && FileComparisonWindowModel.activePaneExports==0 && PatchWindowModel.activeOperations==0
    }
    @MainActor final class Context {
        let suite="TurtleGit.FinderDeliveryOwners."+UUID().uuidString
        let preferences:UserDefaults
        var owners:[NSWindowController]=[]
        var unblock:[()->Void]=[]
        init(){preferences=UserDefaults(suiteName:suite)!}
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.showWindow(nil);return owner}
        func cleanup()async {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[]
            for _ in 0..<2400 {if idle(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.window?.orderOut(nil)}
            preferences.removePersistentDomain(forName:suite)
        }
    }
    static func quitHeld()->Bool {TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel}
    static func run(root:URL,git:URL)async throws {
        let context=Context()
        do {
            let directory=root.appendingPathComponent("delivery-owners-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repository=GitRepository(root:directory,executable:git),file=directory.appendingPathComponent("file.txt"),patchFile=directory.appendingPathComponent("review.patch")
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Delivery owner QA"),("user.email","delivery@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            let before=Data("before\n".utf8)
            try before.write(to:file);try await repository.stage(["file.txt"]);_=try await repository.commit(message:"Private delivery baseline")
            let patch=Data("diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".utf8)
            try patch.write(to:patchFile)
            let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index"))

            // A real source read completes, but its owned result is held. Force
            // close cancels the actual token and keeps the preparation owner.
            var preparationReply:CheckedContinuation<Void,Never>?,preparationToken:OperationCancellation?,preparedBytes:Data?
            let preparation=context.track(ReviewPatchWorkflow(file:nil,target:directory,grants:[],executable:git,preferences:context.preferences,clipboardLoader:{token in
                preparationToken=token;preparedBytes=try Data(contentsOf:patchFile)
                await withCheckedContinuation{preparationReply=$0}
                return preparedBytes!
            }))
            var preparationClosed=false,presented=0
            preparation.onFinished={preparationClosed=true};preparation.presentation={_ in presented += 1}
            context.unblock.append{preparationReply?.resume();preparationReply=nil}
            preparation.start();try await wait("Actual preparation read was not held"){preparationReply != nil}
            try require(preparedBytes==patch && preparation.hasPendingWork && preparation.presentationPreferences === context.preferences,"Preparation lost original bytes/preferences/ownership")
            preparation.close()
            try require(preparationToken?.isCancelled==true && !preparation.canReuse && !preparationClosed && preparation.hasPendingWork && ReviewPatchWorkflow.activeReleases>0 && quitHeld(),"Closed preparation released actual read or Quit before receipt")
            preparationReply?.resume();preparationReply=nil
            try await wait("Preparation receipt did not drain"){preparationClosed && !preparation.hasPendingWork && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0}
            try require(presented==0,"Retired preparation published a patch editor")

            // Exercise the actual native target sheet, including AppKit detach.
            let picking=context.track(ReviewPatchWorkflow(file:patchFile,target:nil,executable:git,preferences:context.preferences))
            var panel:NSOpenPanel?,pickingClosed=false
            picking.presentPicker={value,owner,reply in panel=value;value.beginSheetModal(for:owner,completionHandler:reply)}
            picking.onFinished={pickingClosed=true};picking.start()
            try await wait("Actual target picker did not attach"){panel?.sheetParent === picking.window}
            picking.close()
            try require(!picking.canReuse && !pickingClosed && picking.hasPendingWork && quitHeld(),"Target picker retirement completed before actual detach")
            try await wait("Target picker failed to detach/drain"){pickingClosed && panel?.sheetParent==nil && picking.window?.attachedSheet==nil && !picking.hasPendingWork}

            // SendPatch.loadPatch performs the production file read and owns its
            // async consumer until that consumer returns, even after close.
            let send=context.track(SendPatchWindowController(files:[patchFile],preferences:context.preferences,repository:repository))
            try await wait("Send preview did not settle"){send.model.pendingLoads==0}
            var sendReply:CheckedContinuation<Void,Never>?,sendBytes:Data?,sendClosed=false
            send.onClosed={sendClosed=true};context.unblock.append{sendReply?.resume();sendReply=nil}
            send.model.loadPatch(patchFile){bytes in sendBytes=bytes;await withCheckedContinuation{sendReply=$0}}
            try await wait("Actual Send patch read was not held"){sendReply != nil}
            try require(sendBytes==patch && send.model.pendingLoads==1 && send.model.presentationPreferences === context.preferences,"Send read changed bytes/preferences or lost real worker")
            send.close()
            try require(send.model.isRetired && !send.canReuse && !sendClosed && send.hasPendingWork && SendPatchWindowController.activeReleases>0 && quitHeld(),"Send closed callback preceded owned read completion")
            sendReply?.resume();sendReply=nil
            try await wait("Send read did not release"){sendClosed && !send.hasPendingWork && SendPatchWindowController.activeReleases==0}

            // Load an actual patch comparison, then retain the real editor's
            // output chooser receipt. Its canceled output must never write.
            let review=context.track(WorkingTreePatchWindowController(repository:repository,access:nil,fileAccess:nil,bytes:patch,title:"Owned patch",preferences:context.preferences))
            try await wait("Actual patch comparison did not load"){!review.model.busy && review.model.editor != nil}
            guard let editor=review.model.editor else{throw Failure(description:"Missing native patch editor")}
            let export=directory.appendingPathComponent("retired-export.txt")
            var exportReply:CheckedContinuation<URL?,Never>?,reviewClosed=false
            editor.chooseExportLocation={_,_,_ in await withCheckedContinuation{exportReply=$0}}
            review.onClosed={reviewClosed=true};context.unblock.append{exportReply?.resume(returning:nil);exportReply=nil}
            editor.export(base:false);try await wait("Actual comparison export did not request a destination"){exportReply != nil}
            review.close()
            try require(review.model.retired && !review.canReuse && !reviewClosed && review.hasPendingWork && editor.hasPendingEditorChoice && WorkingTreePatchWindowController.activeReleases>0 && quitHeld(),"Review closed callback preceded actual editor output receipt")
            exportReply?.resume(returning:export);exportReply=nil
            try await wait("Retired comparison output failed to drain"){reviewClosed && !review.hasPendingWork && !editor.exporting && WorkingTreePatchWindowController.activeReleases==0}
            try require(!FileManager.default.fileExists(atPath:export.path),"Retired editor wrote a late export")

            // An injected answer holds the production draft-decision state;
            // close must retain it and reject the late Save response.
            let draft=context.track(WorkingTreePatchWindowController(repository:repository,access:nil,fileAccess:nil,bytes:patch,title:"Owned draft",preferences:context.preferences))
            try await wait("Draft comparison did not load"){!draft.model.busy && draft.model.editor != nil}
            draft.model.setEditing(true);draft.model.editor?.updateDraft("edited\n",base:false)
            var draftReply:CheckedContinuation<WorkingTreePatchWindowModel.DraftChoice,Never>?,draftClosed=false
            draft.model.chooseDraft={await withCheckedContinuation{draftReply=$0}}
            draft.onClosed={draftClosed=true};context.unblock.append{draftReply?.resume(returning:.cancel);draftReply=nil}
            let decision=Task{await draft.model.resolveDraft()}
            try await wait("Actual draft decision did not suspend"){draftReply != nil}
            draft.close()
            try require(!draftClosed && draft.hasPendingWork && draft.model.draftDecisionPending && quitHeld(),"Draft close released pending answer")
            draftReply?.resume(returning:.save);draftReply=nil
            let accepted=await decision.value
            try await wait("Draft answer did not drain"){draftClosed && !draft.hasPendingWork}
            try require(!accepted,"Retired draft accepted a late Save")
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Ownership checks changed HEAD")
            try require(try Data(contentsOf:directory.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==before && Data(contentsOf:patchFile)==patch,"Ownership checks changed index, source, or patch bytes")
            await context.cleanup();try require(idle(),"Delivery owner workers/releases survived cleanup")
        } catch {await context.cleanup();throw error}
    }
}
