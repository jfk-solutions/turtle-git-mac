import AppKit
import TurtleGitCore

@main struct CleanOwnedAccessVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () -> Bool,_ text:String) throws { if !value() { throw Failure.assertion(text) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws { for _ in 0..<2000 { if ready(){return};try await Task.sleep(nanoseconds:10_000_000) };throw Failure.timeout(line) }
    @MainActor static func main() async {do {try await verify();print("PASS: Clean options once/retirement, owned folder permission/cancel/late response/Retry and actual forced-close Git cancellation/Quit/repository preservation")}catch {fputs("Clean ownership failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,askpass:nil)
        _ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Clean QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false")] {_ = try await repo.run(["config",k,v])}
        let tracked=root.appendingPathComponent("tracked"),untracked=root.appendingPathComponent("untracked");try Data("keep\n".utf8).write(to:tracked);try await repo.stage(["tracked"]);_ = try await repo.commit(message:"base");try Data("untracked bytes".utf8).write(to:untracked)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:untracked)
        let suite="TurtleGit.CleanOwned."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer {prefs.removePersistentDomain(forName:suite)}
        let choices=CleanWindowModel(repository:repo,defaults:prefs);var accepted=0;choices.onAccepted={_ in accepted += 1};choices.accept();choices.accept();try require(accepted == 1,"Clean submitted twice");choices.retire();choices.accept();try require(accepted == 1,"Retired options submitted")
        let request=CleanDialogRequest(options:CleanOptions(),paths:[],dryRun:true,submodules:false,permanently:true)
        let owner=CleanProgressWindowController(repository:repo,access:nil,request:request,preferences:prefs);defer {for file in owner.model.trashedFiles {try? FileManager.default.removeItem(at:file)};owner.close()};owner.model.offerAdditionalPermission=true;owner.model.requiresSecurityScope=true;owner.model.start();try await wait {!owner.model.busy && CleanProgressWindowModel.activeOperations == 0};try require(owner.model.failed,"Missing initial grant did not fail");owner.model.requiresSecurityScope=false
        var response:((NSApplication.ModalResponse)->Void)?;owner.presentAuthorization={_,_,completion in response=completion};owner.selectedAuthorizationURL={_ in root}
        owner.chooseAuthorizationFolder();try await wait {response != nil};try require(owner.model.authorizing && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Authorization was not owned")
        response?(.cancel);try require(!owner.model.authorizing && owner.model.additionalAccess.isEmpty,"Cancelled authorization adopted scope")
        response=nil;owner.chooseAuthorizationFolder();try await wait {response != nil};response?(.OK);try require(owner.model.additionalAccess.count == 1,"Selected permission not retained")
        owner.model.retry();try await wait {!owner.model.busy && CleanProgressWindowModel.activeOperations == 0};try require(owner.model.previewSucceeded && owner.model.output.contains("untracked"),"Authorized retry did not prepare a fresh plan")
        owner.model.failed=true;response=nil;owner.chooseAuthorizationFolder();try await wait {response != nil};let late=response;owner.close();late?(.OK);try require(owner.model.additionalAccess.isEmpty && owner.authorizationPanel == nil && owner.model.postActions.isEmpty,"Closed authorization published a grant/result")
        let helper=root.appendingPathComponent("clean-git"),ready=root.appendingPathComponent("clean-ready")
        try Data(#"""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = clean ]; then : > "$TG_CLEAN_READY"; /bin/sleep 30; break; fi
        done
        exec "$TG_CLEAN_GIT" "$@"
        """#.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_CLEAN_GIT",git.path,1);setenv("TG_CLEAN_READY",ready.path,1);defer {unsetenv("TG_CLEAN_GIT");unsetenv("TG_CLEAN_READY")}
        let held=CleanProgressWindowController(repository:GitRepository(root:root,executable:helper,askpass:nil),access:nil,request:request,preferences:prefs);defer {held.close()};var completions=0;held.model.onFinished={_,_ in completions += 1};held.model.start();try await wait {FileManager.default.fileExists(atPath:ready.path)}
        try require(CleanProgressWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Clean worker lost Quit ownership")
        held.close();try await wait {CleanProgressWindowModel.activeOperations == 0};try require(completions == 0 && held.model.postActions.isEmpty,"Retired cleanup published completion")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterBytes=try Data(contentsOf:untracked)
        try require(head == afterHead && index == afterIndex && bytes == afterBytes,"Authorization/dry run changed repository")
    }
}
