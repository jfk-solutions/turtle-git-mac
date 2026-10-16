import AppKit
import TurtleGitCore

@main struct ResolveFileMenuVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<1500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Resolve file-menu readiness at line \(line)")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","File Menu"),("user.email","menu@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let paths=["-first 雪\n[*].txt","second.txt","missing.txt"]
        func write(_ value:String)throws {for path in paths {try Data(value.utf8).write(to:root.appendingPathComponent(path))}}
        try write("base\n");try await repo.stage(paths);_=try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["checkout","-b","side"]);try write("theirs\n");try await repo.stage(paths);_=try await repo.commit(message:"side")
        let side=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["checkout","main"]);try write("mine\n");try await repo.stage(paths);_=try await repo.commit(message:"main")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflicts")}catch is GitFailure {}
        try FileManager.default.removeItem(at:root.appendingPathComponent(paths[2]))
        // An actual unmerged gitlink record exercises the containing/child menu split.
        let records="160000 \(base) 1\tmodule.ext\u{0}160000 \(base) 2\tmodule.ext\u{0}160000 \(side) 3\tmodule.ext\u{0}"
        _=try await repo.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        let initial=try await repo.conflicts(),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let contents=try paths.prefix(2).map{try Data(contentsOf:root.appendingPathComponent($0))}
        let suite="TurtleGit.ResolveFileMenu."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"ShowAppContextMenuIcons");defer{prefs.removePersistentDomain(forName:suite)}
        let owner=ResolveWindowController(repository:repo,access:nil,paths:[],preferences:prefs),model=owner.model
        defer{owner.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.load()
        try await wait {!model.busy && model.entries.count==4}
        var logs:[String]=[],blames:[(String,String)]=[],pairs:[[String]]=[],opened:[(URL,URL?)]=[],edited:[URL]=[],revealed:[[URL]]=[],patch:Data?,alternate:Bool?,copied="",prepared:ConflictBaseComparison?
        model.onFileLog={logs.append($0)};model.onFileBlame={blames.append(($0,$1))};model.onFilePair={pairs.append($0)}
        model.openFile={opened.append(($0,$1))};model.openFileEditor={edited.append($0)};model.revealFiles={revealed.append($0)}
        model.onFileUnified={bytes,shift,_ in patch=bytes;alternate=shift};model.writeFileClipboard={copied=$0};model.onComparison={prepared=$0}
        let first=model.fileMenu([paths[0]])
        try require(first.commands==[.compareBase,.unified,.revert,.log,.blame,.editor,.open,.openWith,.reveal] && first.commands.allSatisfy{$0.icon.image() != nil},"Ordinary source menu/icons differ")
        let absent=model.fileMenu([paths[2]])
        try require(!absent.commands.contains(.open) && !absent.commands.contains(.blame) && absent.commands.contains(.reveal),"Missing working-file gates differ")
        let module=model.fileMenu(["module.ext"])
        try require(module.commands==[.revert,.log,.submoduleLog,.reveal,.delete],"Missing gitlink menu confused child and ordinary file actions")
        model.selection=[paths[1]];model.fileCommand(.log,menu:first);try await wait {!model.busy}
        try require(logs==[paths[0]],"Captured menu followed later selection")
        model.fileCommand(.reveal,menu:first);try require(revealed.isEmpty,"Retained menu invoked twice")
        let old=model.fileMenu([paths[0]]);model.load();try await wait {!model.busy};model.fileCommand(.log,menu:old)
        try require(logs.count==1,"Refreshed menu remained live")
        for command in [ResolveFileCommand.open,.editor,.blame] {model.fileCommand(command,menu:model.fileMenu([paths[0]]));try await wait {!model.busy}}
        try require(opened.first?.0==root.appendingPathComponent(paths[0]) && edited==[root.appendingPathComponent(paths[0])] && blames.count==1 && blames[0].0==paths[0] && blames[0].1==String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines),"Open/editor/Blame handoff changed literal path or revision")
        model.fileCommand(.reveal,menu:model.fileMenu([paths[2]]));try await wait {!model.busy};try require(revealed==[[root]],"Missing path reveal did not use existing parent")
        model.fileCommand(.compareTwo,menu:model.fileMenu(Set(paths.prefix(2))));try await wait {!model.busy}
        try require(pairs==[Array(paths.prefix(2))],"Compare two files lost captured display order")
        let shifted = ComparisonToolInvocation.$alternate.withValue(true) {model.fileMenu([paths[0]])}
        model.fileCommand(.unified,menu:shifted)
        try await wait {!model.busy};try require(patch?.contains(Data("diff --git".utf8))==true && alternate==true,"Unified bytes or captured Shift missing")
        model.fileCommand(.compareBase,menu:model.fileMenu([paths[0]]));try await wait {!model.busy};try require(prepared?.entry.path==paths[0] && prepared?.document.base.bytes==Data("base\n".utf8),"Base comparison did not retain stage 1")
        model.copyFileMenu(model.fileMenu(Set(paths.prefix(2))),copy:.relativePaths)
        try require(copied==paths.prefix(2).joined(separator:"\n")+"\n","Clipboard order/literal bytes differ")
        model.copyFileMenu(model.fileMenu(["module.ext"]),copy:.all);try require(copied=="Path\tExtension\tStatus\nmodule.ext\t\tConflicted\n","Directory clipboard extension/status differ")
        // Open With must revalidate after the asynchronous application choice.
        var choose:CheckedContinuation<URL?,Never>?
        model.chooseFileApplication={await withCheckedContinuation{choose=$0}}
        model.fileCommand(.openWith,menu:model.fileMenu([paths[0]]));try await wait {choose != nil}
        let beforeOpen=opened.count;model.cancel();try require(ResolveWindowModel.activeOperations>0,"Cancelled choice dropped live ownership")
        choose?.resume(returning:URL(fileURLWithPath:"/Applications/Fixture.app"));choose=nil
        try await wait {!model.busy};try require(opened.count==beforeOpen && model.error==nil,"Cancelled Open With launched/reported late")
        model.fileCommand(.openWith,menu:model.fileMenu([paths[0]]));try await wait {choose != nil}
        _=try await repo.resolveConflicts(initial.filter{$0.path==paths[0]},using:.current)
        choose?.resume(returning:URL(fileURLWithPath:"/Applications/Fixture.app"));choose=nil
        try await wait {!model.busy};try require(opened.count==beforeOpen && model.error != nil,"Changed conflict stages launched selected application")
        model.error=nil;try index.write(to:root.appendingPathComponent(".git/index"));model.load();try await wait {!model.busy}
        let childRoot=root.appendingPathComponent("module.ext");try FileManager.default.createDirectory(at:childRoot,withIntermediateDirectories:true)
        let childRepo=GitRepository(root:childRoot,executable:repo.executable);_=try await childRepo.run(["init"])
        var children:[URL]=[];model.submoduleFileLog.readCheckout={_,_ in childRepo};model.onFileSubmoduleLog={children.append($0.root)}
        model.fileCommand(.submoduleLog,menu:model.fileMenu(["module.ext"]));try await wait {!model.busy};try require(children==[childRoot],"Submodule log did not use child repository")
        let beforeClose=model.fileMenu([paths[1]])
        model.fileCommand(.openWith,menu:beforeClose);try await wait {choose != nil};owner.close()
        try require(ResolveWindowModel.activeOperations>0,"Retirement dropped live chooser worker")
        choose?.resume(returning:URL(fileURLWithPath:"/Applications/Fixture.app"));choose=nil
        try await wait {ResolveWindowModel.activeOperations==0}
        model.fileCommand(.open,menu:beforeClose);try require(opened.count==beforeOpen && !model.active,"Retired choice/menu handed off")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && paths.prefix(2).map{try Data(contentsOf:root.appendingPathComponent($0))}==contents && !FileManager.default.fileExists(atPath:root.appendingPathComponent(paths[2]).path),"File actions changed Git or working contents")
        print("PASS: Resolve captured source file menu/icons, single/multiple/missing/gitlink gates, Log/Blame exact revision, literal Open/editor/reveal/two-file/unified Shift and base bytes, clipboard order, consumed/refresh/changed-stage/Cancel/retired chooser fences and owned worker cleanup; no receiving app or shared clipboard used")
    }
}
