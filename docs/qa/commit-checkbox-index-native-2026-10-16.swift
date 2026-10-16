import AppKit
import TurtleGitCore

@main struct CommitCheckboxIndexVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String) throws{if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Checkbox index timeout at \(line)")}
    @MainActor static func main() async{do{try await verify()}catch{fputs("Checkbox index failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.CheckboxIndex."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"HintStagingMode");prefs.set(false,forKey:"EnableGravatar")
        var owners:[CommitWindowModel]=[]
        defer{for model in owners{model.commitProgress?.cancellation.cancel();model.commitProgress?.choose(nil)};prefs.removePersistentDomain(forName:suite)}
        for (name,restore,staging) in [("restore",true,false),("discard",false,false),("staged",false,true)] {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Checkbox index QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport",staging ? "true":"false")] {_ = try await repo.run(["config",key,value])}
            for file in ["checked","unchecked","deleted"]{try Data("base\n".utf8).write(to:folder.appendingPathComponent(file))};try await repo.stage(["checked","unchecked","deleted"]);_ = try await repo.commit(message:"base")
            try Data("selected\n".utf8).write(to:folder.appendingPathComponent("checked"));try Data("staged unchecked\n".utf8).write(to:folder.appendingPathComponent("unchecked"));try Data("staged added\n".utf8).write(to:folder.appendingPathComponent("added 雪\n[*]"))
            try await repo.stage(["unchecked","added 雪\n[*]"]);_ = try await repo.run(["rm","--","deleted"])
            try Data("working unchecked\n".utf8).write(to:folder.appendingPathComponent("unchecked"));try Data("working added\n".utf8).write(to:folder.appendingPathComponent("added 雪\n[*]"))
            prefs.set(restore,forKey:"ReaddUnselectedAddedFilesAfterCommit")
            let model=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs);owners.append(model)
            model.reload(paths:["."]);try await wait{!model.busy && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate}
            model.message="native checkbox policy";model.checked=["checked"]
            var policy:CommitCheckboxIndexPolicy?,successes=0,progressStaging=false
            model.onCommitted={_ in successes += 1}
            model.onCommitProgress={progress in policy=progress.options.checkboxIndexPolicy;progressStaging=progress.staging;progress.dismissWithoutWindow=true;prefs.set(!restore,forKey:"ReaddUnselectedAddedFilesAfterCommit")}
            try await wait{model.canCommit};model.commit();try await wait{!model.busy && CommitWindowModel.activeCommitPreflights==0}
            try require(successes==1 && model.error==nil && progressStaging==staging,"Actual Commit owner did not settle successful captured mode")
            if staging {
                try require(policy==nil,"Staging attempt acquired checkbox index policy")
                let added=try await repo.run(["show","HEAD:added 雪\n[*]"]).text,unchecked=try await repo.run(["show","HEAD:unchecked"]).text
                try require(added=="staged added\n" && unchecked=="staged unchecked\n","Staging mode rewrote partial index content")
            } else {
                try require(policy?.readdUnchecked==restore && policy?.paths.contains("unchecked")==true && policy?.paths.contains("added 雪\n[*]")==true,"Commit lost scope or reread changed preference")
                let checked=try await repo.run(["show","HEAD:checked"]).text,unchecked=try await repo.run(["show",":unchecked"]).text
                try require(checked=="selected\n" && unchecked=="base\n","Checkbox mode committed or retained unchecked staged modifications")
                let status=try await repo.status()
                if restore {let added=try await repo.run(["show",":added 雪\n[*]"]).text;try require(added=="working added\n" && status.contains{$0.path=="deleted" && $0.index=="D"},"Source restoration did not re-add latest bytes/deletion")}
                else {try require(status.contains{$0.path=="added 雪\n[*]" && $0.state == .untracked} && status.contains{$0.path=="deleted" && $0.index==" "},"Disabled restoration kept unchecked additions/deletions staged")}
            }
            try require(try String(contentsOf:folder.appendingPathComponent("unchecked"))=="working unchecked\n" && String(contentsOf:folder.appendingPathComponent("added 雪\n[*]"))=="working added\n","Index preparation changed working bytes")
        }
        print("PASS: actual Commit checkbox index preparation/restoration, captured preference and literal rows, unchecked modified/add/delete states, staging-mode exact index bytes and settled progress; working files unchanged")
    }
}
