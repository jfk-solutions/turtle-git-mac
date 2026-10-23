// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SourceTextPatchNativeVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(_ window:NSWindow? = nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2200 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Source patch native timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func show(_ owner:NSWindowController) {owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.showWindow(nil)}
    static let first="literal [*] 雪.txt",second="second [*].txt"
    static var patchText:String {
        let left = "diff --git \"a/\(first)\" \"b/\(first)\"\n--- \"a/\(first)\"\n+++ \"b/\(first)\"\n@@ -1,1 +1,1 @@\n-$Id: patch payload$\n+patched 雪\n"
        let right = "diff --git \"a/\(second)\" \"b/\(second)\"\n--- \"a/\(second)\"\n+++ \"b/\(second)\"\n@@ -1,1 +1,1 @@\n-before\n+after\n"
        return left + right
    }
    @MainActor final class Context {
        let root:URL,git:URL,suite:String,prefs:UserDefaults,board:NSPasteboard
        var workflows:[ReviewPatchWorkflow]=[],reviews:[WorkingTreePatchWindowController]=[],documents:[PatchWindowController]=[]
        var releases:[()->Void]=[]
        init(root:URL,git:URL) {
            self.root=root;self.git=git;suite="TurtleGit.SourceTextPatch."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!;board=NSPasteboard.withUniqueName()
            prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"TurtleGitMerge.UseUTF8");prefs.set(false,forKey:"TurtleGitMerge.Backup")
            var editor=MergeEditorPreferences.load(from:prefs);editor.autoAdd=false;editor.save(to:prefs)
        }
        func repository(_ name:String)async throws->GitRepository {
            let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo=GitRepository(root:path,executable:git,libgit2Configuration:.init(enabled:false))
            _ = try await repo.run(["init","-b","main"])
            for(key,value) in [("user.name","Source Patch QA"),("user.email","patch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try ComparisonTextEncoding.utf16LEBOM.encode("$Id: target payload$\r\n").write(to:path.appendingPathComponent(SourceTextPatchNativeVerification.first))
            try ComparisonTextEncoding.utf32BE.encode("before\r").write(to:path.appendingPathComponent(SourceTextPatchNativeVerification.second))
            try ComparisonTextEncoding.utf16BEBOM.encode("$Id: live SVN payload$\n").write(to:path.appendingPathComponent("svn.txt"))
            try await repo.stage([SourceTextPatchNativeVerification.first,SourceTextPatchNativeVerification.second,"svn.txt"]);_ = try await repo.commit(message:"private baseline")
            return repo
        }
        func prepare(file:URL,start:URL,readonly:Bool=false,suggestion:((URL,URL)->Void)?=nil)async throws->WorkingTreePatchWindowController {
            let workflow=ReviewPatchWorkflow(file:nil,target:nil,preferred:start,executable:git,preferences:prefs,pasteboard:board)
            workflows.append(workflow)
            workflow.chooseFile={file};workflow.chooseTarget={start}
            workflow.chooseBetterTarget={original,proposed in suggestion?(original,proposed);return .suggested}
            workflow.configureReview={$0.mergeToolReadOnly=readonly}
            var published:WorkingTreePatchWindowController?
            workflow.preparedPresentation={[weak self] controller in self?.reviews.append(controller);published=controller;SourceTextPatchNativeVerification.show(controller)}
            SourceTextPatchNativeVerification.show(workflow);workflow.start()
            try await SourceTextPatchNativeVerification.wait(workflow.window){published != nil || workflow.error != nil}
            try SourceTextPatchNativeVerification.require(workflow.error==nil,"Review workflow rejected decoded patch: "+(workflow.error ?? ""))
            guard let published else {throw Failure(description:"Review workflow did not publish its checked owner")}
            try await SourceTextPatchNativeVerification.wait(published.window){!published.model.busy && published.model.review != nil}
            return published
        }
        func close()async {
            releases.forEach{$0()};releases=[]
            workflows.forEach{$0.cancel()};reviews.forEach{$0.model.cancelOperation();$0.close()};documents.forEach{$0.close()}
            for _ in 0..<2200 {
                if ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 && WorkingTreePatchWindowModel.activeOperations==0 && WorkingTreePatchWindowController.activeReleases==0 && documents.allSatisfy{!$0.model.busy} {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    static func originals(_ owner:WorkingTreePatchWindowController,bytes:Data,context:Context,name:String)async throws {
        let model=owner.model;model.previewTab=1
        try await wait(owner.window){views(owner.window?.contentView).contains{$0 is NSTextView}}
        model.previewDocument.copyPatch(to:context.board)
        try require(PatchClipboard.snapshot(from:context.board)==bytes,"Original patch Copy transcoded the Unicode container")
        try require(model.previewDocument.exportDocument.bytes==bytes,"Review original-document receipt lost raw bytes")
        try require(model.previewDocument.document.text.contains("patched 雪"),"Original patch tab lost decoded Unicode display despite retaining raw bytes")
        try await SourcePatchCapture.save(owner.window!,name+"-original-patch")
        // The embedded viewer and the standalone source document share this exact
        // immutable byte receipt. Save exercises the real owned Save pipeline.
        let document=PatchWindowController(repository:model.repository,access:nil,preferences:context.prefs);context.documents.append(document)
        document.presentDocument(bytes,title:"Original patch",comparison:"Original patch",information:"Private source bytes")
        let output=context.root.appendingPathComponent(name+"-saved.patch")
        document.documentSession.chooseSave={_,_,reply in reply(output)}
        show(document);document.documentSession.saveDocument(as:true)
        try await wait(document.window){!document.model.busy && FileManager.default.fileExists(atPath:output.path)}
        try require(try Data(contentsOf:output)==bytes,"Actual patch document Save transcoded the original container")
        document.close();model.previewTab=0
    }
    static func workflow(_ context:Context)async throws {
        let repo=try await context.repository("discovery/repo"),root=repo.root
        let bytes=try ComparisonTextEncoding.utf16LE.encode(patchText),file=context.root.appendingPathComponent("source-utf16-no-bom.patch")
        try bytes.write(to:file)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        var suggested=false
        let owner=try await context.prepare(file:file,start:root.deletingLastPathComponent(),suggestion:{_,proposal in suggested=GitReferenceName.equal(proposal.standardizedFileURL.path,root.standardizedFileURL.path)})
        let model=owner.model
        try require(suggested && GitReferenceName.equal(model.repository.root.standardizedFileURL.path,root.standardizedFileURL.path),"Decoded Unicode path target discovery did not reach real repository")
        guard let review=model.review else{throw Failure(description:"Missing source review")}
        try require(Set(review.files.map(\.pathBytes))==Set([Data(first.utf8),Data(second.utf8)]),"Literal patch paths were normalized as pathspecs")
        guard let firstFile=review.files.first(where:{$0.pathBytes==Data(first.utf8)}) else{throw Failure(description:"Source file rows missing")}
        model.previewFiles([firstFile.id],generation:model.fileListGeneration)
        try await wait(owner.window){!model.busy && model.editor?.alignment != nil && model.editor?.filtering==false && model.editor?.document?.destination.text=="patched 雪\r\n"}
        try require(model.comparison?.requiresMerge==false && model.editor?.document?.base.text=="$Id: target payload$\r\n","Source expanded keyword match incorrectly opened conflict recovery")
        try await SourcePatchCapture.save(owner.window!,"source-patch-utf16-review")
        try await originals(owner,bytes:bytes,context:context,name:"utf16")
        model.highlightFiles([firstFile.id]);model.patchFiles(model.highlightedFiles,generation:model.fileListGeneration)
        try await wait(owner.window){!model.busy && model.appliedPaths.contains(Data(first.utf8))}
        try require(try Data(contentsOf:root.appendingPathComponent(first))==ComparisonTextEncoding.utf16LEBOM.encode("patched 雪\r\n"),"Selected apply changed target UTF16/BOM/EOL")
        try require(try Data(contentsOf:root.appendingPathComponent(second))==ComparisonTextEncoding.utf32BE.encode("before\r"),"Selected apply included an unchecked file")
        model.patchFiles(Set(review.files.map(\.id)),generation:model.fileListGeneration)
        try await wait(owner.window){!model.busy && model.appliedPaths.count==2}
        try require(try Data(contentsOf:root.appendingPathComponent(second))==ComparisonTextEncoding.utf32BE.encode("after\r"),"Patch all changed target UTF32/EOL")
        model.setReversed(true);model.refresh()
        try await wait(owner.window){!model.busy && !model.requiresRefresh && model.review != nil}
        guard let reverseFile=model.review?.files.first(where:{$0.pathBytes==Data(second.utf8)}) else{throw Failure(description:"Reverse lost literal target")}
        model.patchFiles([reverseFile.id],generation:model.fileListGeneration)
        try await wait(owner.window){!model.busy && model.appliedPaths.contains(Data(second.utf8))}
        try require(try Data(contentsOf:root.appendingPathComponent(second))==ComparisonTextEncoding.utf32BE.encode("before\r"),"Reversed source text did not restore target codec/bytes")
        model.setStripCount(0);model.refresh()
        try await wait(owner.window){!model.busy && !model.requiresRefresh}
        try require(model.stripCount==0,"Explicit strip option was discarded")
        model.setStripCount(1);model.refresh()
        try await wait(owner.window){!model.busy && !model.requiresRefresh}
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(finalHead==head && finalIndex==index,"Worktree-only text patch changed HEAD/index")
        try require(try Data(contentsOf:file)==bytes,"Review/Copy/Save/apply rewrote the source patch")
        let readonlyRepo=try await context.repository("readonly"),readonly=try await context.prepare(file:file,start:readonlyRepo.root,readonly:true)
        try await wait(readonly.window){readonly.model.editor != nil && !readonly.model.busy}
        let before=try Data(contentsOf:readonlyRepo.root.appendingPathComponent(first))
        readonly.model.patchFiles(Set(readonly.model.review?.files.map(\.id) ?? []),generation:readonly.model.fileListGeneration)
        try require(!readonly.model.canPatchFiles && readonly.model.editor?.canTransfer(toBase:false)==false,"Readonly Review exposed source patch mutations")
        try require(try Data(contentsOf:readonlyRepo.root.appendingPathComponent(first))==before,"Readonly Review changed target bytes")
    }
    static func svn(_ context:Context)async throws {
        let repo=try await context.repository("svn-target"),file=context.root.appendingPathComponent("source-utf32.patch")
        let text="Index: svn.txt\n===================================================================\n--- svn.txt\t(revision 7)\n+++ svn.txt\t(working copy)\n@@ -1,1 +1,1 @@\n-$Id: repository payload$\n+SVN patched 雪\n"
        let bytes=try ComparisonTextEncoding.utf32LE.encode(text);try bytes.write(to:file)
        let owner=try await context.prepare(file:file,start:repo.root),model=owner.model
        try await wait(owner.window){!model.busy && model.editor?.alignment != nil && model.editor?.filtering==false}
        try require(model.stripCount==0 && model.review?.files.map(\.pathBytes)==[Data("svn.txt".utf8)],"SVN decoded target path/strip metadata lost")
        try require(model.editor?.document?.destination.text=="SVN patched 雪\n" && model.comparison?.requiresMerge==false,"SVN source keyword comparison did not produce an ordinary preview")
        try await SourcePatchCapture.save(owner.window!,"source-patch-svn-utf32-review")
        try await originals(owner,bytes:bytes,context:context,name:"utf32")
        model.patchFiles(Set(model.review?.files.map(\.id) ?? []),generation:model.fileListGeneration)
        try await wait(owner.window){!model.busy && model.appliedPaths.contains(Data("svn.txt".utf8))}
        try require(try Data(contentsOf:repo.root.appendingPathComponent("svn.txt"))==ComparisonTextEncoding.utf16BEBOM.encode("SVN patched 雪\n"),"SVN source application lost target UTF16BE format")
    }
    static func lifecycle(_ context:Context)async throws {
        let repo=try await context.repository("late-target"),file=context.root.appendingPathComponent("late.patch")
        let bytes=try ComparisonTextEncoding.utf32BE.encode(patchText);try bytes.write(to:file)
        let before=try Data(contentsOf:repo.root.appendingPathComponent(first))
        var pending:CheckedContinuation<URL?,Never>?,entered=false,presented=false
        let workflow=ReviewPatchWorkflow(file:file,target:nil,executable:context.git,preferences:context.prefs,pasteboard:context.board)
        context.workflows.append(workflow)
        workflow.chooseTarget={await withCheckedContinuation{pending=$0;entered=true}}
        workflow.preparedPresentation={controller in context.reviews.append(controller);presented=true}
        context.releases.append{let reply=pending;pending=nil;reply?.resume(returning:repo.root)}
        show(workflow);workflow.start();try await wait(workflow.window){entered}
        workflow.cancel()
        try require(workflow.hasPendingWork,"Cancelled owner released an outstanding target response")
        let reply=pending;pending=nil;reply?.resume(returning:repo.root)
        try await wait { !workflow.hasPendingWork && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 }
        try require(!presented && !workflow.canReuse,"Retired target callback published another patch window")
        try require(try Data(contentsOf:file)==bytes && Data(contentsOf:repo.root.appendingPathComponent(first))==before,"Cancelled preparation changed patch or target")
        // A separate actual Git wrapper holds discovery, so cancellation also
        // proves the subprocess drain rather than only a delayed chooser reply.
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let enteredFile=context.root.appendingPathComponent("entered-discovery"),releaseFile=context.root.appendingPathComponent("release-discovery"),wrapper=context.root.appendingPathComponent("held-source-git")
        let script="""
        #!/bin/bash
        trap 'exit 143' TERM INT
        for argument in "$@"; do
          if [ "$argument" = rev-parse ]; then
            /usr/bin/touch \(quote(enteredFile.path))
            while [ ! -f \(quote(releaseFile.path)) ]; do /bin/sleep 0.02; done
          fi
        done
        exec \(quote(context.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        context.releases.append{try? Data().write(to:releaseFile)}
        let held=ReviewPatchWorkflow(file:file,target:repo.root,executable:wrapper,preferences:context.prefs,pasteboard:context.board)
        context.workflows.append(held)
        var heldPublished=false
        held.preparedPresentation={controller in context.reviews.append(controller);heldPublished=true}
        show(held);held.start()
        try await wait(held.window){FileManager.default.fileExists(atPath:enteredFile.path)}
        try require(held.loading && ReviewPatchWorkflow.activeLoads>0,"Discovery wrapper did not hold actual native preparation")
        held.cancel()
        try await wait { !held.hasPendingWork && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 }
        try require(!heldPublished && !held.canReuse,"Cancelled Git discovery published a late review")
        try require(try Data(contentsOf:repo.root.appendingPathComponent(first))==before,"Cancelled Git discovery changed target")

    }
    static func run(root:URL,git:URL,kind:String)async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let context=Context(root:root,git:git)
        do {
            switch kind {case "workflow":try await workflow(context);case "svn":try await svn(context);case "lifecycle":try await lifecycle(context);default:throw Failure(description:"Unknown source patch fixture")}
            await context.close()
        } catch {await context.close();throw error}
        try require(ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 && WorkingTreePatchWindowModel.activeOperations==0 && WorkingTreePatchWindowController.activeReleases==0,"Source patch owned work did not drain")
        print("PASS: native source text patch "+kind)
    }
}
