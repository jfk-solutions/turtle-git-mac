import AppKit
import TurtleGitCore

struct MergeResultCopyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func dismissFailure(_ model:TextConflictWindowModel,_ window:NSWindow) async throws {
        try await SaveAsTargetsVerification.wait([window]) {window.attachedSheet != nil}
        guard let sheet=window.attachedSheet,let ok=SaveAsTargetsVerification.descendants(sheet.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title=="OK"}) else {throw Failure(description:"Missing operation failure OK")}
        ok.performClick(nil)
        try await SaveAsTargetsVerification.wait([window]) {model.error==nil && window.attachedSheet==nil}
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ResultCopy."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let repo=GitRepository(root:root,executable:git),file=root.appendingPathComponent("file.txt"),copy=root.appendingPathComponent("copy.txt")
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Copy QA"),("user.email","copy@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","other"]);try Data("theirs\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data("mine\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","other"],successfulExitCodes:0...1)
        let original=try Data(contentsOf:file),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner=TextConflictWindowController(repository:repo,access:nil,path:"file.txt",preferences:defaults),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load()
        try await SaveAsTargetsVerification.wait([window]) {!model.busy && model.document != nil && model.nativeEditorReady}
        var target=copy,answer:((NSApplication.ModalResponse)->Void)?
        model.sourceExporter.present={_,_,completion in answer=completion}
        model.sourceExporter.selectedURL={_ in target}
        model.result="copy 🐢\r\n";model.encoding = .utf16LEBOM
        try require(model.dirty,"Initial draft is clean")
        try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.cancel);answer?(.OK)
        try require(model.dirty && !FileManager.default.fileExists(atPath:copy.path),"Cancel/duplicate answer changed draft")
        try Data("previous\n".utf8).write(to:copy);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:copy.path)
        try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK)
        try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource && MergeSourceExport.activeExports==0}
        try require(model.error==nil && !model.dirty && model.mergedResultTarget==nil && model.workingMergeOutput==nil,"Copy did not clean without rebinding: \(String(describing:model.error))")
        try require(try Data(contentsOf:copy)==ComparisonTextEncoding.utf16LEBOM.encode("copy 🐢\r\n") && Data(contentsOf:file)==original && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"External copy changed original or index")
        let mode=try FileManager.default.attributesOfItem(atPath:copy.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue==0o755 && !FileManager.default.fileExists(atPath:copy.path+".bak"),"Copy lost executable mode or created backup")
        model.result="later\n";try require(model.dirty,"Edit after copy remained clean")
        model.result="copy 🐢\r\n";try require(!model.dirty,"Return to copy savepoint remained dirty")
        model.encoding = .utf8;model.result="normal target\n"
        var completed:Bool?;model.save(markResolved:false) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.busy}
        try require(completed==true && !model.dirty && Data(contentsOf:file)==Data("normal target\n".utf8),"Normal Save no longer uses original target")
        target=file;model.result="own target copy\n";try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK)
        try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource}
        try require(!model.dirty && model.document?.workingContents==Data("own target copy\n".utf8),"Own-target copy left stale snapshot")
        model.result="post copy save\n";completed=nil;model.save(markResolved:false) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.busy}
        try require(completed==true && Data(contentsOf:file)==Data("post copy save\n".utf8),"Own write caused false stale refusal")
        // A successful working-file write stays clean when the subsequent Add fails.
        try Data().write(to:root.appendingPathComponent(".git/index.lock"))
        model.result="saved despite Add failure\n";completed=nil;model.save(markResolved:true) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.busy}
        try require(completed==false && !model.dirty && model.error?.contains("index.lock")==true && Data(contentsOf:file)==Data("saved despite Add failure\n".utf8),"Post-write Add failure lost actual save baseline")
        try await dismissFailure(model,window)
        try FileManager.default.removeItem(at:root.appendingPathComponent(".git/index.lock"))
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Save/copy staged unresolved conflict")
        model.result="refuse target\n";target=copy
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:copy.path)
        let preserved=try Data(contentsOf:copy)
        try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK);try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource}
        try require(model.dirty && Data(contentsOf:copy)==preserved,"Read-only copy changed contents or cleaned draft")
        try await dismissFailure(model,window)
        target=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:target,withDestinationURL:copy)
        try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK);try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource}
        try require(model.dirty && Data(contentsOf:copy)==preserved && FileManager.default.destinationOfSymbolicLink(atPath:target.path)==copy.path,"Symlink copy followed/replaced target")
        try await dismissFailure(model,window)
        target=root.appendingPathComponent("empty");model.result="";try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK)
        try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource}
        try require(!model.dirty && FileManager.default.fileExists(atPath:target.path) && Data(contentsOf:target).isEmpty,"Explicit empty copy deleted target or stayed dirty")
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        model.sourceExporter.write={bytes,url,token in entered.signal();release.wait();try token.check();try MergePaneSaveAs.write(bytes,to:url)}
        target=root.appendingPathComponent("retired");model.result="held writer\n";try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed};model.export();answer?(.OK)
        try await SaveAsTargetsVerification.wait([window]) {entered.wait(timeout:.now()) == .success}
        defer {release.signal()}
        try require(!owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Background copy did not own Close/Quit")
        model.retire();release.signal()
        try await SaveAsTargetsVerification.wait([]) {MergeSourceExport.activeExports==0}
        try require(!FileManager.default.fileExists(atPath:target.path) && model.dirty,"Retired held copy wrote or cleaned draft")
        print("PASS: result-copy clean savepoint, retained normal target, encoding/mode, own-write adoption, Add failure, read-only/link refusal, empty creation, background responsiveness, Close/Quit and retired cancellation")
    }
}
