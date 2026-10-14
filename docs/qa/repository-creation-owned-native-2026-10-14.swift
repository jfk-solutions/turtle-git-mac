import AppKit
import TurtleGitCore

@main struct RepositoryCreationOwnedVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () -> Bool, _ text: String) throws { if !value() { throw Failure.assertion(text) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure.timeout(line) }
    @MainActor static func main() async { do { try await verify(); print("PASS: owned Clone source/destination chooser locks/cancel/late reply, captured Clone metadata cancellation and Init result/retirement/Quit") } catch { fputs("Creation ownership failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),lease=RepositoryAccessLease(url:root)
        let suite="TurtleGit.CreationOwned."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer {prefs.removePersistentDomain(forName:suite)}
        let owner=CloneWindowController(directory:root,access:lease,preferences:prefs,executable:git);defer {owner.close()}
        var reply:((NSApplication.ModalResponse)->Void)?;owner.model.presentOpenPanel={_,_,completion in reply=completion};owner.model.selectedPanelURL={_ in root}
        owner.model.browseSource();try await wait {reply != nil};try require(owner.model.activeOperation && !owner.windowShouldClose(owner.window!),"Chooser did not block competing operation/close")
        reply?(.OK);try await wait {!owner.model.activeOperation};try require(owner.model.source == root.path,"Source chooser did not adopt its URL")
        reply=nil;owner.model.browseDirectory();try await wait {reply != nil};reply?(.cancel);try await wait {!owner.model.activeOperation}
        reply=nil;owner.model.browseSource();try await wait {reply != nil};let old=owner.model.source;owner.close();reply?(.OK);try await wait {CloneWindowModel.activeOperations == 0};try require(owner.model.source == old && owner.model.openPanel == nil,"Retired chooser published a reply")
        let source=root.appendingPathComponent("source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let repo=GitRepository(root:source,executable:git,askpass:nil);_ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Creation QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false")] {_ = try await repo.run(["config",k,v])}
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let helper=root.appendingPathComponent("metadata-git"),ready=root.appendingPathComponent("metadata-ready")
        try Data(#"""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = --show-toplevel ]; then : > "$TG_CREATION_READY"; /bin/sleep 30; fi
        done
        exec "$TG_CREATION_GIT" "$@"
        """#.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_CREATION_GIT",git.path,1);setenv("TG_CREATION_READY",ready.path,1);defer {unsetenv("TG_CREATION_GIT");unsetenv("TG_CREATION_READY")}
        let clone=CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:helper);defer {clone.invalidate()};clone.source=source.path;clone.directory=root.appendingPathComponent("cloned").path
        var adoptions=0;clone.onCloned={_,_,_,_,_ in adoptions += 1};clone.clone();try await wait {FileManager.default.fileExists(atPath:ready.path)}
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Clone metadata lost Quit ownership")
        clone.invalidate();try await wait {CloneWindowModel.activeOperations == 0};try require(adoptions == 0 && clone.completed == nil,"Retired Clone metadata adopted a repository")
        try? FileManager.default.removeItem(at:ready)
        let target=root.appendingPathComponent("init-target");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let initModel=CreateRepositoryWindowModel(folder:target,access:lease);initModel.executable=helper;initModel.prepare();initModel.onInitialized={_,_,_,_ in adoptions += 1};initModel.initialize();try await wait {FileManager.default.fileExists(atPath:ready.path)}
        initModel.retire();try await wait {CreateRepositoryWindowModel.activeOperations == 0};try require(!initModel.completed && initModel.error == nil && adoptions == 0,"Retired Init metadata published")
        let doneFolder=root.appendingPathComponent("normal-init");try FileManager.default.createDirectory(at:doneFolder,withIntermediateDirectories:true)
        let done=CreateRepositoryWindowModel(folder:doneFolder,access:lease);done.executable=git;done.prepare();done.showSuccess={};done.initialize();try await wait {!done.busy}
        try require(done.completed && done.confirmingSuccess && !done.canClose,"Init confirmation did not own result")
        var closes=0;done.close={closes += 1};done.acknowledgeSuccess();done.acknowledgeSuccess();try require(closes == 1 && done.canClose,"Init success callback was duplicated");done.retire()
    }
}
