import AppKit
import TurtleGitCore

struct PatchSpecialRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Special recovery QA"),("user.email","special@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let binary=root.appendingPathComponent("binary"),link=root.appendingPathComponent("link"),deleted=root.appendingPathComponent("delete.txt"),normal=root.appendingPathComponent("normal.txt")
        try Data([0,1,2,3]).write(to:binary);try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"old missing")
        try Data("old\n".utf8).write(to:deleted);try Data("before\n".utf8).write(to:normal)
        try await repo.stage(["binary","link","delete.txt","normal.txt"]);_=try await repo.commit(message:"base")
        try Data([0,4,5,6]).write(to:binary);try FileManager.default.removeItem(at:link);try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"patched 雪")
        try FileManager.default.removeItem(at:deleted);try Data("after\n".utf8).write(to:normal)
        let patch=try await repo.run(["diff","--binary","--full-index","--"]).stdout
        try Data([0,9,8,7]).write(to:binary);try FileManager.default.removeItem(at:link);try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"current missing")
        try Data("local\n".utf8).write(to:deleted);try Data("before\n".utf8).write(to:normal)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.SpecialPatch."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Special-file patch recovery",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        try await PatchFilePanelVerification.wait{!model.busy && model.specialComparison != nil}
        let files=model.review!.files
        func file(_ name:String)->WorkingTreePatchReview.File {files.first{$0.path==name}!}
        func preview(_ name:String) async throws {
            let selected=file(name);model.highlightFiles([selected.id]);model.previewFiles([selected.id],generation:model.fileListGeneration)
            try await PatchFilePanelVerification.wait{!model.busy && model.focusedFile==selected.id && model.specialComparison != nil}
        }
        try require(model.specialComparison?.recoveryKind == .binary && model.conflictEditor==nil && model.editor==nil,"Binary opened a text editor")
        try await PatchFilePanelVerification.capture(window,name:"patch-special-recovery")
        let menu=NSMenu(title:"Special patch"),commands=owner.editorCommandMenu!
        commands.keyWindow={window};commands.applicationMenu={menu};commands.install(in:menu)
        try require(commands.performKeyEquivalent(MergeCommandMenusVerification.event(String(UnicodeScalar(NSF10FunctionKey)!),code:109,flags:.control,window:window)),"Keep current shortcut unavailable")
        try await PatchFilePanelVerification.wait{!model.busy}
        try require(model.specialResolutionChoice == .current && model.fileState(file("binary"))=="kept current" && !model.canResolveSpecial && Data(contentsOf:binary)==Data([0,9,8,7]),"Keep current completion")
        model.resolveSpecial(.patched);try require(!model.busy,"Completed choice re-entered")
        try await preview("link")
        try require(model.specialComparison?.recoveryKind == .symbolicLink && model.specialComparison?.document.destination.bytes==Data("patched 雪".utf8),"Symlink target preview")
        model.resolveSpecial(.patched);try await PatchFilePanelVerification.wait{!model.busy}
        try require(try FileManager.default.destinationOfSymbolicLink(atPath:link.path)=="patched 雪","Patched link not selected")
        try await preview("delete.txt")
        model.resolveSpecial(.patched);try await PatchFilePanelVerification.wait{window.attachedSheet != nil}
        let sheet=window.attachedSheet!
        try require(sheet.defaultButtonCell?.title=="Cancel","Delete prompt default was destructive")
        window.endSheet(sheet,returnCode:.alertFirstButtonReturn)
        try await PatchFilePanelVerification.wait{!model.busy && window.attachedSheet==nil}
        try require(model.canResolveSpecial && Data(contentsOf:deleted)==Data("local\n".utf8),"Delete Cancel changed file")
        model.resolveSpecial(.patched);try await PatchFilePanelVerification.wait{window.attachedSheet != nil}
        window.endSheet(window.attachedSheet!,returnCode:.alertSecondButtonReturn)
        try await PatchFilePanelVerification.wait{!model.busy && window.attachedSheet==nil}
        try require(!FileManager.default.fileExists(atPath:deleted.path) && model.specialResolutionChoice == .patched,"Confirmed deletion failed")
        model.patchFiles(Set(files.map(\.id)),generation:model.fileListGeneration)
        try await PatchFilePanelVerification.wait{!model.busy}
        try require(try Data(contentsOf:normal)==Data("after\n".utf8),"Later normal file did not apply")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Special choices changed HEAD/index")
        owner.close();try require(model.retired,"Owner not retired")
        // A held explicit choice owns the operation until its callback settles.
        try Data([0,9,8,7]).write(to:binary)
        let heldOwner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Held special choice",preferences:prefs),held=heldOwner.model,heldWindow=heldOwner.window!
        defer {heldOwner.close()};heldWindow.alphaValue=0;heldWindow.orderFront(nil)
        try await PatchFilePanelVerification.wait{!held.busy && held.specialComparison?.recoveryKind == .binary}
        var reply:CheckedContinuation<Bool,Never>?
        held.chooseSpecialResolution={_,_ in await withCheckedContinuation {reply=$0}}
        held.resolveSpecial(.patched);try await PatchFilePanelVerification.wait{reply != nil}
        let generation=held.fileListGeneration
        held.refresh();held.resolveSpecial(.current);held.highlightFiles([file("link").id])
        try require(held.busy && held.fileListGeneration==generation && !heldOwner.windowShouldClose(heldWindow),"Held choice lost ownership")
        heldOwner.close();try require(held.retired && held.busy,"Retirement prematurely released held choice")
        reply?.resume(returning:true);reply=nil
        try await PatchFilePanelVerification.wait{!held.busy}
        try require(try Data(contentsOf:binary)==Data([0,9,8,7]),"Late choice wrote after retirement")
        print("PASS: native binary and symlink previews, Control-F10 current choice, completed gates, patched symlink, actual deletion Cancel/default/confirm sheet, later-file batch continuation, unchanged HEAD/index, held-choice duplicate/Refresh/selection/close fences and retirement/late-reply refusal; owned windows closed")
    }
}
