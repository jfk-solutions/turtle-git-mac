import AppKit
import TurtleGitCore

@main struct ResolveMutationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<2000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Resolve mutation wait at line \(line)")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Mutation Fixture"),("user.email","mutations@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let paths=["-first 雪\n[*].txt","second.txt","missing.txt"]
        func write(_ value:String)throws {for path in paths {try Data(value.utf8).write(to:root.appendingPathComponent(path))}}
        try write("base\n");try await repo.stage(paths);_=try await repo.commit(message:"base")
        let anchor=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["update-index","--add","--cacheinfo","160000,"+anchor+",module.ext"]);_=try await repo.commit(message:"gitlink base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["checkout","-b","side"]);try write("theirs\n");try await repo.stage(paths);_=try await repo.commit(message:"side")
        let side=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["checkout","main"]);try write("mine\n");try await repo.stage(paths);_=try await repo.commit(message:"main")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflicts")}catch is GitFailure {}
        try FileManager.default.removeItem(at:root.appendingPathComponent(paths[2]))
        let zero=String(repeating:"0",count:anchor.count)
        let record="0 \(zero)\tmodule.ext\u{0}160000 \(anchor) 1\tmodule.ext\u{0}160000 \(base) 2\tmodule.ext\u{0}160000 \(side) 3\tmodule.ext\u{0}"
        _=try await repo.run(["update-index","-z","--index-info"],input:Data(record.utf8))
        let module=root.appendingPathComponent("module.ext");try FileManager.default.createDirectory(at:module,withIntermediateDirectories:true)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try paths.prefix(2).map{try Data(contentsOf:root.appendingPathComponent($0))}
        let suite="TurtleGit.ResolveMutations."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=ResolveWindowController(repository:repo,access:nil,paths:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.load()
        try await wait {!model.busy && model.entries.count==4}
        var accepted=false,questions=0,outputs:[String]=[],trash:[URL]=[],children:[RevertProgressWindowModel]=[]
        defer{for url in Set(trash) {try? FileManager.default.removeItem(at:url)}}
        owner.presentQuestion={_,alert,reply in
            questions += 1
            if alert.buttons.first?.title != "No" {return false}
            reply(accepted ? .alertSecondButtonReturn:.alertFirstButtonReturn);return true
        }
        owner.onChanged={outputs.append($0)}
        owner.configureFileRevert={child in
            children.append(child)
            let prior=child.onFinished
            child.onFinished={ [weak child] text,success in trash += child?.trashedFiles ?? [];prior(text,success)}
        }
        let both=Set(paths.prefix(2)),missing=paths[2]
        try require(model.fileMenu(both).commands.contains(.revert) && !model.fileMenu(both).commands.contains(.delete),"Ordinary conflict mutation mask differs")
        model.focusedFilePath=missing
        let deleteMenu=model.fileMenu([paths[1],missing])
        try require(deleteMenu.mark==missing && deleteMenu.commands.contains(.delete) && !deleteMenu.permanently,"Missing selection mark did not enable captured Trash delete")
        try require(!model.fileMenu([paths[1],missing],markedPath:paths[1]).commands.contains(.delete),"Missing unmarked row enabled Delete")
        model.fileCommand(.revert,menu:model.fileMenu([paths[0]]));try await wait {!model.busy}
        try require(questions==1 && children.isEmpty && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Revert No changed files or launched progress")
        accepted=true
        model.fileCommand(.revert,menu:model.fileMenu([paths[0]]));try await wait {!model.busy && owner.fileRevertWindow==nil}
        try require(children.count==1 && model.entries.count==3 && String(data:try Data(contentsOf:root.appendingPathComponent(paths[0])),encoding:.utf8)=="mine\n","Real Revert did not restore checked conflict from HEAD")
        try require(!trash.isEmpty && trash.contains{(try? Data(contentsOf:$0))==bytes[0]},"Revert did not retain recoverable working bytes")
        let otherAfter=try await repo.conflicts(paths:[paths[1],missing,"module.ext"])
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(otherAfter.count==3 && afterHead==head,"Revert changed unrelated stages/HEAD")
        accepted=false;let beforeDelete=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        model.fileCommand(.delete,menu:model.fileMenu([paths[1],missing],markedPath:missing));try await wait {!model.busy}
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==beforeDelete && Data(contentsOf:root.appendingPathComponent(paths[1]))==bytes[1],"Delete No changed index/worktree")
        accepted=true;model.selection=[paths[0]]
        model.fileCommand(.delete,menu:deleteMenu);try await wait {!model.busy}
        // The earlier refresh invalidated deleteMenu; obtain an actual fresh popup.
        try require(model.deletionResult==nil,"Stale Delete popup ran")
        model.fileCommand(.delete,menu:model.fileMenu([paths[1],missing],markedPath:missing));try await wait {!model.busy}
        let deleted=try requireResult(model.deletionResult);trash += deleted.trashedFiles
        try require(Set(deleted.removedIndexPaths)==[paths[1],missing] && deleted.trashedFiles.count==1 && model.entries.map(\.path)==["module.ext"],"Delete did not update exact selected index stages")
        try require(try Data(contentsOf:deleted.trashedFiles[0])==bytes[1],"Delete Trash bytes changed")
        var submoduleResults:[(String,[String])]=[]
        model.onFileSubmoduleRevert={submoduleResults.append(($0,$1))}
        model.fileCommand(.revert,menu:model.fileMenu(["module.ext"]))
        try await wait {owner.fileRevertWindow?.model.busy==false && owner.fileRevertWindow?.model.submodulePaths==["module.ext"]}
        owner.fileRevertWindow!.model.handleSubmodules()
        try await wait {!model.busy && owner.fileRevertWindow==nil}
        try require(submoduleResults.count==1 && submoduleResults[0].0==String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines) && submoduleResults[0].1==["module.ext"] && model.entries.isEmpty,"Submodule Revert post-action lost captured revision/path")
        func restore() async throws {
            try index.write(to:root.appendingPathComponent(".git/index"))
            for (path,value) in zip(paths.prefix(2),bytes) {try value.write(to:root.appendingPathComponent(path))}
            try? FileManager.default.removeItem(at:root.appendingPathComponent(missing))
            model.error=nil;try await wait {owner.window?.attachedSheet==nil};model.load();try await wait {!model.busy && model.entries.count==4}
        }
        try await restore()
        // Capture the policy before the owned question. A Settings-domain
        // change in that question must not change the custom child executor.
        let ordinaryQuestion=owner.presentQuestion,previousChildren=children.count,previousTrash=trash.count,previousOutputs=outputs.count
        let otherStages=try await repo.run(["ls-files","--stage","-z","--",paths[1],missing,"module.ext"]).stdout
        prefs.set(false,forKey:"RevertWithRecycleBin");prefs.set(false,forKey:"RevertRenamedFilesWithRecycleBin")
        var policyQuestion=""
        owner.presentQuestion={_,alert,reply in
            policyQuestion=alert.informativeText
            prefs.set(true,forKey:"RevertWithRecycleBin");prefs.set(true,forKey:"RevertRenamedFilesWithRecycleBin")
            reply(.alertSecondButtonReturn);return true
        }
        model.fileCommand(.revert,menu:model.fileMenu([paths[0]]));try await wait {!model.busy && owner.fileRevertWindow==nil}
        try require(policyQuestion.contains("will not be saved to Trash") && children.count==previousChildren+1,"Resolve did not present captured no-Trash confirmation")
        let noTrashChild=children[previousChildren]
        try require(noTrashChild.policy == .init(recycle:false,recycleRenamedFiles:false) && !noTrashChild.failed && noTrashChild.trashedFiles.isEmpty && trash.count==previousTrash,"Resolve custom executor bypassed accepted no-Trash policy")
        try require(outputs.dropFirst(previousOutputs).allSatisfy{!$0.contains("Moved to Trash:")} && String(data:try Data(contentsOf:root.appendingPathComponent(paths[0])),encoding:.utf8)=="mine\n","Resolve reported invented recovery or failed HEAD restoration")
        let preservedStages=try await repo.run(["ls-files","--stage","-z","--",paths[1],missing,"module.ext"]).stdout
        let policyHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(preservedStages==otherStages && policyHead==head,"Resolve no-Trash changed unrelated stages/HEAD")
        owner.presentQuestion=ordinaryQuestion;prefs.removeObject(forKey:"RevertWithRecycleBin");prefs.removeObject(forKey:"RevertRenamedFilesWithRecycleBin")
        try await restore()
        model.fileCommand(.delete,menu:model.fileMenu([paths[1],missing],markedPath:missing,permanently:true));try await wait {!model.busy}
        try require(model.deletionResult?.trashedFiles.isEmpty==true && model.deletionResult?.removedIndexPaths.count==2 && !FileManager.default.fileExists(atPath:root.appendingPathComponent(paths[1]).path),"Captured permanent Delete did not reach backend")
        try await restore()
        let ordinaryConfiguration=owner.configureFileRevert
        owner.configureFileRevert={child in
            ordinaryConfiguration(child)
            let execute=child.execute!;var attempts=0
            child.execute={rows,token,progress,emit in
                attempts += 1;let firstAttempt=attempts==1
                return try await execute(rows,token,{event in
                    progress(event)
                    if firstAttempt,event.step == .recycle,event.finished {token.cancel()}
                },emit)
            }
        }
        model.fileCommand(.revert,menu:model.fileMenu(both))
        try await wait {owner.fileRevertWindow?.model.busy==false && owner.fileRevertWindow?.model.cancelled==true}
        try require(ResolveWindowModel.activeOperations>0 && model.hasChild,"Cancelled child result released parent before review")
        owner.fileRevertWindow!.model.retry()
        try await wait {!model.busy && owner.fileRevertWindow==nil}
        try require(model.entries.count==2 && paths.prefix(2).allSatisfy{(try? String(contentsOf:root.appendingPathComponent($0)))=="mine\n"},"Retry did not read current selected status/restore HEAD")
        owner.configureFileRevert=ordinaryConfiguration
        try await restore()
        // Hold confirmation, change actual stages, then accept: no child may start.
        var reply:((NSApplication.ModalResponse)->Void)?
        owner.presentQuestion={_,_,answer in reply=answer;return true}
        let childCount=children.count
        model.fileCommand(.revert,menu:model.fileMenu([paths[0]]));try await wait {reply != nil}
        _=try await repo.resolveConflicts(model.entries.filter{$0.path==paths[0]},using:.current)
        reply?(.alertSecondButtonReturn);reply=nil;try await wait {!model.busy}
        try require(children.count==childCount && model.error != nil,"Changed-stage confirmation launched Revert")
        try await restore()
        // A retired pending mutation owns its reader until its one-use question settles.
        model.fileCommand(.delete,menu:model.fileMenu([paths[1],missing],markedPath:missing,permanently:true));try await wait {reply != nil}
        owner.close();reply?(.alertSecondButtonReturn);reply=nil
        try await wait {ResolveWindowModel.activeOperations==0 && RevertProgressWindowModel.activeOperations==0}
        try require(!model.active && owner.fileRevertWindow==nil && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(paths[1]))==bytes[1],"Retired confirmation mutated or leaked child")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && !outputs.isEmpty,"Mutation committed or lost result callbacks")
        print("PASS: Resolve source mutation mask/marked missing row, No/stale/retired refusal, real Revert HEAD and recoverable bytes, Trash Delete exact stages, submodule progress/post-action, actual list refresh and owned child/question/worker cleanup; private fixture Trash receipts removed")
    }
    static func requireResult(_ value:WorkingFileDeleteResult?)throws->WorkingFileDeleteResult {guard let value else {throw Failure(description:"Missing deletion result")};return value}
}
