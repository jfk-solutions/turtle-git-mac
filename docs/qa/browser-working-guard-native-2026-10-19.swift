import AppKit
import TurtleGitCore
import Darwin

struct BrowserWorkingGuardVerification {
    @MainActor static func verify()async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
        func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:message,code:2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        let folder=root.appendingPathComponent("guard-repository"),outside=root.appendingPathComponent("outside")
        try fm.createDirectory(at:folder.appendingPathComponent("nested"),withIntermediateDirectories:true);try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Browser Guard"),("user.email","guard@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let file=folder.appendingPathComponent("nested/File.txt"),original=Data("historical content\n".utf8),external=outside.appendingPathComponent("File.txt"),outsideBytes=Data("outside must remain unchanged\n".utf8)
        try original.write(to:file);try outsideBytes.write(to:external);try await repo.stage(["nested"]);_ = try await repo.commit(message:"Guard source")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BrowserGuard."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs);owner.window?.alphaValue=0;owner.showWindow(nil)
        defer{owner.close()};let model=owner.model
        try await wait("Guard browser failed to load"){!model.busy && model.snapshot != nil};model.openFolder("nested")
        try await wait("Guard folder did not load"){!model.busy && model.snapshot?.directory=="nested"}
        func acknowledgeError()async throws{
            // Expected Compare refusal is also surfaced by the real SwiftUI
            // error alert; clear its binding and wait for the actual sheet.
            try await wait("Expected Browser refusal alert did not attach"){owner.window?.attachedSheet != nil}
            model.error=nil
            if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.alertFirstButtonReturn);sheet.orderOut(nil)}
            try await wait("Expected Browser refusal alert did not detach"){owner.window?.attachedSheet==nil}
        }
        let entry=model.entries.first{$0.name=="File.txt"}!
        var comparisons=0,failures=0,results=0
        model.onCompare={_,_ in comparisons+=1};model.handleRevertFailure={_ in failures+=1;return false};model.showRevertResult={_ in results+=1}
        let moved=folder.appendingPathComponent("held-nested")
        try fm.moveItem(at:folder.appendingPathComponent("nested"),to:moved)
        try fm.createSymbolicLink(at:folder.appendingPathComponent("nested"),withDestinationURL:outside)
        model.compareEntryToWorkingTree(entry);try await wait("Symlink-parent Compare did not settle"){!model.busy && RepositoryBrowserWindowModel.activeOperations==0}
        try require(comparisons==0 && model.error != nil,"Compare followed a replacement symlink parent")
        try await acknowledgeError();model.revert([entry]);try await wait("Symlink-parent Revert did not settle"){!model.mutating && !model.busy && RepositoryBrowserWindowModel.activeOperations==0}
        try require(failures==1 && (try Data(contentsOf:external))==outsideBytes && (try Data(contentsOf:moved.appendingPathComponent("File.txt")))==original,"Revert followed symlink parent or changed retained content")
        try fm.removeItem(at:folder.appendingPathComponent("nested"));try fm.moveItem(at:moved,to:folder.appendingPathComponent("nested"))
        try fm.removeItem(at:file)
        let folded=folder.appendingPathComponent("nested/file.txt");try outsideBytes.write(to:folded)
        var requested=stat(),actual=stat()
        let aliases=file.path.withCString{lstat($0,&requested)}==0 && folded.path.withCString{lstat($0,&actual)}==0 && requested.st_dev==actual.st_dev && requested.st_ino==actual.st_ino
        if aliases {
            model.error=nil;model.compareEntryToWorkingTree(entry);try await wait("Case-alias Compare did not settle"){!model.busy && RepositoryBrowserWindowModel.activeOperations==0}
            try require(comparisons==0 && model.error != nil,"Compare accepted a different current case spelling resolving to the historical path inode")
            try await acknowledgeError();model.revert([entry]);try await wait("Case-alias Revert did not settle"){!model.mutating && !model.busy && RepositoryBrowserWindowModel.activeOperations==0}
            try require(failures==2 && (try Data(contentsOf:folded))==outsideBytes,"Revert altered an untracked filesystem alias")
        }else{print("Case alias native branch unavailable on this case-sensitive volume; Core sensitive-volume coverage retained.")}
        try fm.removeItem(at:folded);try original.write(to:file)
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:folder.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==original,"Refused Browser actions changed HEAD/index or restored file bytes")
        owner.close();try await wait("Guard browser remained active"){!model.active && RepositoryBrowserWindowModel.activeOperations==0}
        try require(results==(aliases ? 2:1),"Revert refusals lost source result reporting")
        print("Browser native Compare/Revert reject changed filesystem parent/alias without changing outside bytes, HEAD or index.")
    }
}
