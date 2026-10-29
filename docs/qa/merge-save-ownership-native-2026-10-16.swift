import AppKit
import TurtleGitCore

struct MergeSaveOwnershipVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.SaveOwnership."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        MergeFileSaveOptions.saveBackupPreference(true,to:defaults)
        try await comparison(root:root,defaults:defaults)
        try await conflict(root:root,git:git,defaults:defaults)
        print("PASS: native read-only Save As binding and Cancel, later backups, actual empty Keep/Delete/cancel sheets, recreation and failure retry, unresolved sheet ownership, repository-copy index preservation, held-choice Close/Quit and forced-retirement fences; owned windows closed")
    }
    @MainActor static func comparison(root:URL,defaults:UserDefaults) async throws {
        let left=root.appendingPathComponent("left"),right=root.appendingPathComponent("readonly"),copy=root.appendingPathComponent("chosen"),backup=URL(fileURLWithPath:copy.path+".bak")
        try Data("left\n".utf8).write(to:left);try Data("original\n".utf8).write(to:right)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:right.path)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[]),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.comparisonDefaults=defaults;model.editorConfigEnabled=[true:false,false:false];model.load()
        try await SaveAsTargetsVerification.wait([window]) {!model.busy && !model.filtering && model.document != nil}
        let editor=SaveAsTargetsVerification.textView(window,label:"Destination file")
        model.changeEncoding(.utf8,base:false)
        SaveAsTargetsVerification.type(editor,"draft 🐢\n");try await SaveAsTargetsVerification.wait([window]) {!model.filtering && model.dirty}
        var answer:CheckedContinuation<URL?,Never>?,completed:Bool?
        model.chooseExportLocation={_,_,_ in await withCheckedContinuation {answer=$0}}
        model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {answer != nil}
        try require(model.busy && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel,"Read-only Save As lost ownership")
        model.save();model.load();answer?.resume(returning:nil);answer=nil
        try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==false && model.dirty && !FileManager.default.fileExists(atPath:copy.path),"Read-only Save As Cancel")
        completed=nil;model.chooseExportLocation={_,_,_ in copy};model.save {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.filtering}
        try require(completed==true && model.savedPaneURL(base:false)==copy && !model.dirty && !FileManager.default.fileExists(atPath:backup.path),"Read-only Save As did not bind cleanly without backup: completed=\(String(describing:completed)), target=\(String(describing:model.savedPaneURL(base:false))), dirty=\(model.dirty), error=\(String(describing:model.error)), draft=\(model.draftText(base:false))")
        try require(try Data(contentsOf:right)==Data("original\n".utf8),"Read-only original overwritten")
        SaveAsTargetsVerification.type(editor,"later\n");try await SaveAsTargetsVerification.wait([window]) {!model.filtering}
        // Failed backup preparation retains the edited result and permits retry.
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:false)
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==false && model.error != nil && model.dirty && Data(contentsOf:copy)==Data("draft 🐢\n".utf8),"Failed save lost draft/current file")
        model.error=nil;try FileManager.default.removeItem(at:backup)
        try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet==nil}
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.filtering}
        try require(completed==true && Data(contentsOf:backup)==Data("draft 🐢\n".utf8),"Save retry backup")
        SaveAsTargetsVerification.type(editor,"");try await SaveAsTargetsVerification.wait([window]) {!model.filtering}
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet != nil}
        let empty=window.attachedSheet!
        try require(!owner.windowShouldClose(window) && model.busy,"Empty sheet did not guard owner")
        window.endSheet(empty,returnCode:.alertSecondButtonReturn)
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && window.attachedSheet==nil && !model.filtering}
        try require(completed==true && Data(contentsOf:copy)==Data() && Data(contentsOf:backup)==Data("later\n".utf8),"Empty Keep / backup")
        model.changeEncoding(.utf8BOM,base:false);completed=nil;model.save {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet != nil}
        model.cancelPaneSave();try await SaveAsTargetsVerification.wait([window]) {completed != nil && window.attachedSheet==nil}
        try require(completed==false && model.dirty && Data(contentsOf:copy)==Data(),"Programmatic cancel wrote empty file")
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet != nil}
        window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && window.attachedSheet==nil && !model.filtering}
        try require(completed==true && model.document?.destination.isDeleted==true && !FileManager.default.fileExists(atPath:copy.path),"Empty Delete")
        SaveAsTargetsVerification.type(editor,"recreated\n");try await SaveAsTargetsVerification.wait([window]) {!model.filtering}
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.filtering}
        try require(completed==true && Data(contentsOf:copy)==ComparisonTextEncoding.utf8BOM.encode("recreated\n") && Data(contentsOf:backup)==Data(),"Recreation changed original backup")
        owner.close()
    }
    @MainActor static func conflict(root:URL,git:URL,defaults:UserDefaults) async throws {
        let folder=root.appendingPathComponent("repository");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git),file=folder.appendingPathComponent("file.txt"),copy=folder.appendingPathComponent("chosen-result")
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Save QA"),("user.email","save@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","other"]);try Data("theirs\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data("mine\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","other"],successfulExitCodes:0...1)
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:file.path)
        let original=try Data(contentsOf:file),index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
        let owner=TextConflictWindowController(repository:repo,access:nil,path:"file.txt",preferences:defaults),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load()
        try await SaveAsTargetsVerification.wait([window]) {!model.busy && model.document != nil}
        var completed:Bool?
        model.save(markResolved:false) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet != nil}
        guard let warning=window.attachedSheet,let content=warning.contentView,
              let cancel=SaveAsTargetsVerification.descendants(content).compactMap({$0 as? NSButton}).first(where:{$0.title=="Cancel"}) else{throw Failure(description:"Actual unresolved Cancel action missing")}
        try require(warning.defaultButtonCell?.title=="Continue Resolving" && (warning.defaultButtonCell?.controlView as? NSButton)?.title=="Continue Resolving" && cancel.keyEquivalent=="\u{1b}" && !owner.windowShouldClose(window),"Unresolved prompt default/owner")
        cancel.performClick(nil)
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && window.attachedSheet==nil}
        try require(completed==false && Data(contentsOf:file)==original,"Unresolved Cancel saved")
        model.encoding = .utf8;model.result="resolved copy 🐢\n";model.chooseStandaloneOutput={_,_ in copy};completed=nil
        model.save(markResolved:false,chooseNewOutput:true) {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==true && model.mergedResultTarget?.url==copy && model.repositoryResolutionAllowed && !model.dirty,"Read-only conflict Save As binding/index guard")
        try require(try Data(contentsOf:file)==original && Data(contentsOf:folder.appendingPathComponent(".git/index"))==index,"Conflict copy changed original/index")
        model.result="later copy\n";completed=nil;model.save(markResolved:false) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==true && Data(contentsOf:copy)==Data("later copy\n".utf8) && Data(contentsOf:URL(fileURLWithPath:copy.path+".bak"))==Data("resolved copy 🐢\n".utf8),"Bound conflict later Save/backup")
        // The selected result owns Reload even when the original conflict ends.
        _=try await repo.run(["add","--","file.txt"])
        try Data("external copy\n".utf8).write(to:copy);model.load()
        try await SaveAsTargetsVerification.wait([window]) {!model.busy && model.document?.initialResult=="external copy\n"}
        try require(model.result=="external copy\n" && !model.dirty,"Bound result Reload depended on old conflict")
        model.result="";var reply:CheckedContinuation<MergeEmptyResult,Never>?
        model.chooseEmptyResult={_ in await withCheckedContinuation {reply=$0}};completed=nil
        model.save(markResolved:false) {completed=$0};try await SaveAsTargetsVerification.wait([window]) {reply != nil}
        let active=MergeRegexOperations.activeRequests
        try require(!owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel,"Held merge Save lost Close/Quit ownership")
        owner.close();try require(model.retired && MergeRegexOperations.activeRequests==active,"Retired merge prematurely released held save")
        reply?.resume(returning:.delete);reply=nil;try await SaveAsTargetsVerification.wait([]) {completed != nil && MergeRegexOperations.activeRequests==active-1}
        try require(completed==false && Data(contentsOf:copy)==Data("external copy\n".utf8) && Data(contentsOf:file)==original,"Late empty choice wrote after retirement")
    }
}
