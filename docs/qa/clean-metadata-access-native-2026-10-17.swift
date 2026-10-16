import AppKit
import TurtleGitCore

private final class CleanBookmarks:RepositoryBookmarkProvider {
    var starts=0,stops=0,successfulStarts=0;var available=true
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {starts += 1;if available {successfulStarts += 1};return available}
    func stopAccessing(_ url:URL) {stops += 1}
}
@main struct CleanMetadataAccessVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    static func require(_ condition:@autoclosure()->Bool,_ message:String)throws {if !condition(){throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {for _ in 0..<3000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Clean metadata: linked/common/alternates/recursive access before Git, retained grants, refusal/retry, cancellation and forced picker retirement")}catch {fputs("Clean metadata failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        for (key,value) in GitRuntime.environment(executable:git) {setenv(key,value,1)}
        let suite="TurtleGit.CleanMetadata."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ConfirmKillProcess")
        defer {prefs.removePersistentDomain(forName:suite)}
        func make(_ name:String)async throws->GitRepository {
            let folder=base.appendingPathComponent(name);try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git,askpass:nil);_=try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Access QA"),("user.email","access@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
            try Data("tracked\n".utf8).write(to:folder.appendingPathComponent("tracked"));try await repo.stage(["tracked"]);_=try await repo.commit(message:"base");return repo
        }
        let source=try await make("source"),linked=base.appendingPathComponent("linked"),shared=base.appendingPathComponent("shared")
        _=try await source.run(["worktree","add","-b","linked",linked.path]);_=try await source.run(["clone","--shared",source.root.path,shared.path])
        let parent=try await make("parent"),childSource=try await make("child-source"),grand=try await make("grand-source")
        _=try await childSource.run(["-c","protocol.file.allow=always","submodule","add",grand.root.path,"nested"]);_=try await childSource.commit(message:"nested")
        _=try await parent.run(["-c","protocol.file.allow=always","submodule","add",childSource.root.path,"child"]);_=try await parent.commit(message:"child")
        _=try await parent.run(["-c","protocol.file.allow=always","submodule","update","--init","--recursive"])
        let child=parent.root.appendingPathComponent("child"),nested=child.appendingPathComponent("nested"),external=base.appendingPathComponent("external-admin")
        let original=parent.root.appendingPathComponent(".git/modules/child")
        _=try await parent.run(["--git-dir",original.path,"config","core.worktree",child.path])
        _=try await parent.run(["--git-dir",original.appendingPathComponent("modules/nested").path,"config","core.worktree",nested.path])
        try fm.moveItem(at:original,to:external)
        try Data(("gitdir: "+external.path+"\n").utf8).write(to:child.appendingPathComponent(".git"))
        try Data(("gitdir: "+external.appendingPathComponent("modules/nested").path+"\n").utf8).write(to:nested.appendingPathComponent(".git"))
        for folder in [linked,shared,parent.root,child,nested] {try Data("candidate bytes".utf8).write(to:folder.appendingPathComponent("junk"))}
        let gates=base.appendingPathComponent("gates"),violation=base.appendingPathComponent("unapproved-read"),wrapper=base.appendingPathComponent("checked-git")
        try fm.createDirectory(at:gates,withIntermediateDirectories:true)
        try Data(#"""
        #!/bin/sh
        checkout_name=${3##*/}
        case "$checkout_name" in
          linked|shared|child|nested)
            if [ ! -f "$TG_CLEAN_GATES/$checkout_name" ]; then
              echo "$3" >> "$TG_CLEAN_VIOLATION"; exit 97
            fi ;;
        esac
        exec "$TG_CLEAN_REAL_GIT" "$@"
        """#.utf8).write(to:wrapper);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        setenv("TG_CLEAN_GATES",gates.path,1);setenv("TG_CLEAN_VIOLATION",violation.path,1);setenv("TG_CLEAN_REAL_GIT",git.path,1)
        defer {for key in ["TG_CLEAN_GATES","TG_CLEAN_VIOLATION","TG_CLEAN_REAL_GIT"] {unsetenv(key)}}
        func allow(_ name:String)throws {try Data().write(to:gates.appendingPathComponent(name))}
        func deny(_ name:String) {try? fm.removeItem(at:gates.appendingPathComponent(name))}
        let provider=CleanBookmarks()
        func request(_ recursive:Bool=false,_ dry:Bool=true)->CleanDialogRequest {CleanDialogRequest(options:CleanOptions(),paths:[],dryRun:dry,submodules:recursive,permanently:true)}
        func model(_ folder:URL,_ recursive:Bool=false,_ lease:RepositoryAccessLease?=nil)->CleanProgressWindowModel {
            let result=CleanProgressWindowModel(repository:GitRepository(root:folder,executable:wrapper,askpass:nil),access:lease ?? RepositoryAccessLease(url:folder,provider:provider),request:request(recursive),preferences:prefs)
            result.requiresSecurityScope=true;result.bookmarkProvider=provider;return result
        }
        do {
        let index=try Data(contentsOf:source.root.appendingPathComponent(".git/index")),head=try await source.run(["rev-parse","HEAD"]).stdout
        // Narrow linked-worktree metadata requires a second common-folder choice.
        let linkedModel=model(linked);var kinds:[RepositoryMetadataAccessRequirement.Kind]=[]
        linkedModel.chooseMetadataFolder={requirement,_ in
            kinds.append(requirement.kind)
            if requirement.kind == .commonDirectory {try allow("linked")}
            return requirement.folder
        }
        linkedModel.start();try await wait {!linkedModel.busy && CleanProgressWindowModel.activeOperations == 0}
        try require(linkedModel.previewSucceeded && !linkedModel.failed,"Linked preparation failed: "+linkedModel.output)
        try require(kinds == [.gitDirectory,.commonDirectory] && linkedModel.additionalAccess.count == 2,"Linked layering changed")
        linkedModel.failed=true;linkedModel.retry();try await wait {!linkedModel.busy && CleanProgressWindowModel.activeOperations == 0}
        try require(linkedModel.previewSucceeded && kinds.count == 2,"Retry reprompted retained grants")
        linkedModel.invalidate()
        // A compound workspace lease already owns common metadata; no picker.
        let primary=RepositoryAccessLease(url:linked,provider:provider),metadata=RepositoryAccessLease(url:source.root.appendingPathComponent(".git"),provider:provider)
        let compound=model(linked,false,primary.retainingRelatedScopes([metadata]));compound.chooseMetadataFolder={_,_ in throw Failure.assertion("Compound scope prompted")}
        compound.start();try await wait {!compound.busy && CleanProgressWindowModel.activeOperations == 0};try require(compound.previewSucceeded,"Compound metadata scope ignored");compound.invalidate()
        // Shared objects: cancellation, wrong folder and unavailable scope never run Git.
        for mode in 0..<3 {
            deny("shared");let refused=model(shared)
            refused.chooseMetadataFolder={requirement,_ in mode == 0 ? nil : mode == 1 ? shared : requirement.folder}
            if mode == 2 {provider.available=false}
            refused.start();try await wait {!refused.busy && CleanProgressWindowModel.activeOperations == 0};provider.available=true
            try require(refused.failed && refused.additionalAccess.isEmpty,"Refused scope adopted")
            try require(!fm.fileExists(atPath:violation.path),"Git ran before permission")
            refused.invalidate()
        }
        let sharedModel=model(shared);var objectRequests=0
        sharedModel.chooseMetadataFolder={requirement,_ in try require(requirement.kind == .objectDirectory,"Wrong shared dependency");objectRequests += 1;try allow("shared");return requirement.folder}
        sharedModel.start();try await wait {!sharedModel.busy && CleanProgressWindowModel.activeOperations == 0};try require(sharedModel.previewSucceeded && objectRequests == 1,"Shared objects failed");sharedModel.invalidate()
        // Parent access covers child files, but not relocated administrative data.
        let recursive=model(parent.root,true);var childRequests=0
        recursive.chooseMetadataFolder={requirement,_ in try require(requirement.folder.path == external.resolvingSymlinksInPath().path,"Wrong recursive metadata request");childRequests += 1;try allow("child");try allow("nested");return external}
        recursive.start();try await wait {!recursive.busy && CleanProgressWindowModel.activeOperations == 0}
        try require(recursive.previewSucceeded && childRequests == 1 && recursive.output.contains(nested.path),"Recursive preparation failed: "+recursive.output);recursive.invalidate()
        // Controller sheets own Quit, cancellation and one-response fencing.
        for closeOwner in [false,true] {
            deny("linked")
            let owner=CleanProgressWindowController(repository:GitRepository(root:linked,executable:wrapper,askpass:nil),access:RepositoryAccessLease(url:linked,provider:provider),request:request(),preferences:prefs)
            owner.model.requiresSecurityScope=true;owner.model.bookmarkProvider=provider
            var answer:((NSApplication.ModalResponse)->Void)?;var finished=0
            owner.presentAuthorization={_,_,reply in answer=reply};owner.selectedAuthorizationURL={_ in source.root.appendingPathComponent(".git")};owner.model.onFinished={_,_ in finished += 1}
            owner.model.start();try await wait {answer != nil}
            try require(owner.model.authorizing && owner.authorizationPanel != nil && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Picker lost ownership")
            let late=answer
            if closeOwner {owner.close()} else {owner.model.cancel()}
            try await wait {CleanProgressWindowModel.activeOperations == 0}
            late?(.OK);late?(.OK)
            try require(owner.authorizationPanel == nil && owner.model.additionalAccess.isEmpty,"Late picker adopted scope")
            try require(closeOwner ? finished == 0 : owner.model.failed && owner.model.current == "Cancelled","Picker cancellation result changed")
            owner.close()
        }
        try require(!fm.fileExists(atPath:violation.path),"Unapproved Git read")
        for folder in [linked,shared,parent.root,child,nested] {let bytes=try Data(contentsOf:folder.appendingPathComponent("junk"));try require(bytes == Data("candidate bytes".utf8),"Dry-run changed files")}
        let after=try await source.run(["rev-parse","HEAD"]).stdout
        let afterIndex=try Data(contentsOf:source.root.appendingPathComponent(".git/index"))
        try require(head == after && index == afterIndex,"Preparation changed HEAD/index")
        }
        try await Task.sleep(nanoseconds:10_000_000)
        try require(provider.successfulStarts == provider.stops,"Retired models leaked acquired scopes: \(provider.starts)/\(provider.stops)")
    }
}
