// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func setupQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));setupQAOrder(mode,relativeTo:number)}
}
@MainActor @main enum RepositorySetupTransitionsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Repository setup \(line): "+message)}}
    static func wait(_ name:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Repository setup timeout: "+name)}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Context {
        let suite="TurtleGit.SetupTransition.QA."+UUID().uuidString,prefs:UserDefaults,folder:URL,git=URL(fileURLWithPath:CommandLine.arguments[2]),board=NSPasteboard.withUniqueName()
        var root:URL{folder.appendingPathComponent("repository")}
        var repo:GitRepository{GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(mask:0))}
        var directories:[URL]=[]
        var owners:[NSWindowController]=[],releases:[()->Void]=[],pids:[Int32]=[],base="",head="",index=Data(),config=Data(),working=Data(),unrelatedIndex=Data()
        init(_ name:String)throws {
            prefs=UserDefaults(suiteName:suite)!;folder=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(false,forKey:"RevertWithRecycleBin")
        }
        func hash(_ revision:String,repository:GitRepository?=nil)async throws->String{try await (repository ?? repo).run(["rev-parse","--verify",revision]).text.trimmingCharacters(in:.whitespacesAndNewlines)}
        func prepare()async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Setup QA"),("user.email","setup@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("tracked.txt"));try Data("unrelated base\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await repo.stage(["."]);_=try await repo.commit(message:"private base")
            base=try await hash("HEAD");_=try await repo.run(["branch","older",base]);try Data("next\n".utf8).write(to:root.appendingPathComponent("tracked.txt"));try await repo.stage(["tracked.txt"]);_=try await repo.commit(message:"private next")
            head=try await hash("HEAD");working=try Data(contentsOf:root.appendingPathComponent("tracked.txt"));index=try Data(contentsOf:root.appendingPathComponent(".git/index"));config=try Data(contentsOf:root.appendingPathComponent(".git/config"));unrelatedIndex=try await repo.run(["ls-files","--stage","--","unrelated.txt"]).stdout
        }
        func show(_ owner:NSWindowController){owners.append(owner);owner.window?.alphaValue=0;owner.showWindow(nil)}
        func unchanged()async throws {
            let now=try await hash("HEAD"),after=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:root.appendingPathComponent("tracked.txt"))
            try require(now==head && after==index && bytes==working,"Setup changed original source HEAD/index/working bytes")
        }
        func clean()async throws {
            releases.forEach{$0()};releases=[];owners.forEach{$0.close()}
            try await wait("owned setup windows/workers/helpers drain"){
                CloneProgressWindowModel.activeOperations==0 && CloneProgressWindowController.activeReleases==0 && CreateRepositoryWindowController.activeReleases==0 && CreateRepositoryWindowModel.activeOperations==0 && SubmoduleAddProgressWindowModel.activeOperations==0 && SwitchWindowModel.activeReads==0 && SwitchWindowController.activeChildReleases==0 && ResetWindowModel.activeReads==0 && ResetWindowController.activeChildReleases==0 && SwitchProgressWindowModel.activeOperations==0 && ResetProgressWindowModel.activeOperations==0 && LocalGitCommandProgress.activeOperations==0 && SSHTransportCoordinator.activeOperations==0 && directories.allSatisfy{(try? FileManager.default.contentsOfDirectory(atPath:$0.path).isEmpty)==true} && pids.allSatisfy{kill($0,0) != 0} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
            }
            for directory in directories{try FileManager.default.removeItem(at:directory)};directories=[]
            prefs.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
    }
    struct Gate {let executable:URL,marker:URL,calls:URL}
    static func wrapped(_ c:Context,label:String,command:String,after:Bool=true)throws->Gate {
        let executable=c.folder.appendingPathComponent(label+"-git"),marker=URL(fileURLWithPath:executable.path+".started"),calls=URL(fileURLWithPath:executable.path+".calls")
        let action=after ? """
        \(quote(c.git.path)) "$@"
        task_status=$?
        if [ "$task_status" -ne 0 ]; then exit "$task_status"; fi
        """ : ":"
        let predicate=command == "submodule-add" ? #"test "${1-}" = submodule && test "${2-}" = add"# : #"test "${1-}" = "#+quote(command)
        let script="""
        #!/bin/sh
        task_matches() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          while [ "${1-}" = -c ]; do shift 2; done
          \(predicate)
        }
        if task_matches "$@"; then
          printf '%s\\n' operation >> "$0.calls"
          \(action)
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit \(after ? "0":"143")' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
          exit \(after ? "0":"143")
        fi
        exec \(quote(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path);return .init(executable:executable,marker:marker,calls:calls)
    }
    static func processes(_ gate:Gate,_ c:Context)async throws->[Int32]{
        try await wait("real command publication gate"){
            guard let data=try? Data(contentsOf:gate.marker) else{return false}
            return String(decoding:data,as:UTF8.self).split(whereSeparator:{$0.isWhitespace}).count==2
        }
        let pids=String(decoding:try Data(contentsOf:gate.marker),as:UTF8.self).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try require(pids.count==2,"Actual command/sleeper identity missing");c.pids += pids;return pids
    }
    static func calls(_ gate:Gate)throws->Int{try String(contentsOf:gate.calls).split(separator:"\n").count}
    static func clone(_ c:Context)async throws {
        for variant in ["cancel","retire","inspection","precommand","failure"] {
            let destination=c.folder.appendingPathComponent("cloned-"+variant),gate=try wrapped(c,label:"clone-"+variant,command:"clone",after:variant != "precommand")
            var options=CloneOptions();options.source=variant=="failure" ? c.folder.appendingPathComponent("missing-clone-source").path:c.root.path
            let model=CloneProgressWindowModel(options:options,destination:destination,executable:["inspection","failure"].contains(variant) ? c.git:gate.executable,destinationAccess:RepositoryAccessLease(url:c.folder),sourceAccess:RepositoryAccessLease(url:c.root),keyAccess:nil,preferences:c.prefs,backend:.init(mask:0))
            model.outputClipboard=c.board
            var mutations=0,inspections=0,registered=0,optional=0,failInspection=variant=="inspection"
            let originalInspection=model.inspectRepository
            model.inspectRepository={repo,bare,token in inspections += 1;if failInspection{throw Failure(description:"Private accepted clone inspection refusal")};return try await originalInspection(repo,bare,token)}
            model.onCloned={_,_ in registered += 1};model.onPostAction={_,_ in optional += 1}
            if variant=="inspection" {model.performClone={repo,options,path,token in mutations += 1;return try await repo.cloneOutcome(options,to:path,cancellation:token,backend:.init(mask:0))}}
            let owner=CloneProgressWindowController(model:model);c.show(owner);model.start()
            if ["cancel","retire","precommand"].contains(variant) {
                let pids=try await processes(gate,c)
                if variant != "precommand"{let cloned=GitRepository(root:destination,executable:c.git,askpass:nil,libgit2Configuration:.init(mask:0));let oid=try await c.hash("HEAD",repository:cloned);try require(oid==c.head,"Clone gate preceded actual publication")}
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted actual Clone process")
                if variant=="retire"{owner.close()}else{model.cancel()}
                try await wait("Clone process/read ownership drain"){!model.hasPendingWork && pids.allSatisfy{kill($0,0) != 0}}
            }else{try await wait("Clone accepted inspection failure"){!model.busy && !model.hasPendingWork}}
            if ["precommand","failure"].contains(variant) {
                try require(model.completedOutcome==nil && !model.success && registered==0 && inspections==0 && !FileManager.default.fileExists(atPath:destination.appendingPathComponent(".git").path),"Precommand/nonzero Clone adopted a repository")
            }else {
                try require(model.completedOutcome?.verified==true && registered==0 && optional==0,"Accepted Clone receipt/adoption boundary lost")
                if variant=="retire" {model.perform(.inspect);try require(registered==0 && inspections==0,"Retired Clone opened/adopted a repository")}
                else {
                    try require((variant=="inspection" ? !model.success && inspections==1:model.success && model.cancelled && inspections==0),"Clone completion status or optional inspection boundary differs")
                    model.perform(.retry);await Task.yield()
                    let retryMutations=variant=="inspection" ? mutations:try calls(gate)
                    try require(retryMutations==1,"Accepted Clone offered reclone retry")
                    failInspection=false;model.perform(.inspect);try await wait("explicit accepted Clone inspection retry"){!model.busy && !model.hasPendingWork && model.success}
                    let completedMutations=variant=="inspection" ? mutations:try calls(gate)
                    try require(registered==1 && optional==0 && completedMutations==1,"Clone inspection retry repeated mutation/adoption")
                    model.perform(.inspect);try require(registered==1,"Clone inspection repeated parent registration")
                }
            }
            owner.close();try await c.unchanged()
        }
    }
    private actor PrivateSSHCredentials:SSHAuthenticationStore {
        func read(identity:String)->String?{nil}
        func save(identity:String,name:String,passphrase:String){}
        func entries()->[SSHAuthenticationEntry]{[]}
        func remove(identity:String){}
    }
    static func cloneConfiguration(_ c:Context)async throws {
        let destination=c.folder.appendingPathComponent("clone-key-recovery"),key=c.folder.appendingPathComponent("private-key"),wrapper=c.folder.appendingPathComponent("clone-key-git"),fail=URL(fileURLWithPath:c.folder.appendingPathComponent("clone-key-git").path+".fail")
        let generator=Process();generator.executableURL=URL(fileURLWithPath:"/usr/bin/ssh-keygen");generator.arguments=["-q","-t","ed25519","-N","","-C","private-setup-QA","-f",key.path];generator.standardOutput=Pipe();generator.standardError=Pipe();try generator.run();generator.waitUntilExit();try require(generator.terminationStatus==0,"Private Clone key generation failed")
        let script="""
        #!/bin/sh
        for argument do
          case "$argument" in clone) printf '%s\\n' clone >> "$0.clones";; remote.origin.turtlegitsshkeyfile) printf '%s\\n' key >> "$0.keys"; if [ -f "$0.fail" ]; then printf '%s\\n' 'Private Clone key configuration failed' >&2; exit 73; fi;; esac
        done
        exec \(quote(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path);try Data().write(to:fail)
        let identities=SSHIdentityAccessStore(storageURL:c.folder.appendingPathComponent("private-identity-grants.json"));try identities.remember(key,requireSecurityScope:false)
        let agentRoot=URL(fileURLWithPath:"/tmp/tg-setup-"+String(UUID().uuidString.prefix(8)));try FileManager.default.createDirectory(at:agentRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var coordinators:[SSHTransportCoordinator]=[],factories=0
        c.releases.append{coordinators.forEach{$0.close()}}
        c.directories.append(agentRoot)
        var options=CloneOptions();options.source=c.root.path;options.sshKey=key;options.loadSSHKeyWithAgent=true
        let model=CloneProgressWindowModel(options:options,destination:destination,executable:wrapper,destinationAccess:RepositoryAccessLease(url:c.folder),sourceAccess:RepositoryAccessLease(url:c.root),keyAccess:RepositoryAccessLease(url:key),preferences:c.prefs,backend:.init(mask:0))
        model.outputClipboard=c.board
        model.makeSSHCoordinator={repo in
            factories += 1
            let coordinator=SSHTransportCoordinator(repository:repo,identities:identities,temporaryRoot:agentRoot,credentials:PrivateSSHCredentials(),runtime:{SSHAgentRuntime(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:URL(fileURLWithPath:"/usr/bin/ssh-add"))})
            coordinators.append(coordinator);return coordinator
        }
        var registered=0;model.onCloned={_,_ in registered += 1}
        let owner=CloneProgressWindowController(model:model);c.show(owner);model.start()
        try await wait("actual Clone success/configuration failure"){!model.busy && !model.hasPendingWork && SSHTransportCoordinator.activeOperations==0}
        try require(model.completedOutcome?.verified==true && model.completedOutcome?.configurationPending==true && model.success && registered==1 && model.postActions.contains(.configure),"Accepted Clone key failure lost config-only recovery")
        try FileManager.default.removeItem(at:fail);model.perform(.configure);model.perform(.configure)
        try await wait("explicit Clone key-only recovery"){!model.busy && !model.hasPendingWork && model.completedOutcome?.configurationPending==false}
        let cloned=GitRepository(root:destination,executable:c.git),saved=try await cloned.run(["config","--local","--get","remote.origin.turtlegitsshkeyfile"]).text
        let cloneCalls=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".clones")),keyCalls=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".keys"))
        try require(saved==key.path+"\n" && cloneCalls=="clone\n" && keyCalls=="key\nkey\n" && registered==1 && factories==1,"Clone key retry repeated clone/transport/adoption or changed key path")
        owner.close();coordinators.forEach{$0.close()};try await wait("private Clone agent/helper drain"){SSHTransportCoordinator.activeOperations==0 && (try? FileManager.default.contentsOfDirectory(atPath:agentRoot.path).isEmpty)==true};try await c.unchanged()
    }
    static func initialize(_ c:Context)async throws {
        for variant in ["cancel","retire","inspection","precommand","failure"] {
            let folder=c.folder.appendingPathComponent("initialized-"+variant);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let owner=CreateRepositoryWindowController(folder:folder,access:RepositoryAccessLease(url:c.folder),preferences:c.prefs),model=owner.model;c.show(owner)
            var attempts=0,registered=0,questions=0,errors=0
            model.executable=c.git;model.onInitialized={_,_,_,_ in registered += 1};model.showSuccess={questions += 1;model.acknowledgeSuccess()};model.showError={_,reply in errors += 1;reply()}
            model.prepare()
            try await wait("Init form ready"){model.ready && !model.busy}
            if variant=="inspection" {
                let executable=c.folder.appendingPathComponent("init-inspection-git"),flag=URL(fileURLWithPath:executable.path+".fail"),counter=URL(fileURLWithPath:executable.path+".calls")
                let script="""
                #!/bin/sh
                task_init=
                task_inspect=
                for argument do
                  if [ "$argument" = init ]; then task_init=1; fi
                  if [ "$argument" = rev-parse ]; then task_inspect=1; fi
                done
                if [ -n "$task_init" ]; then printf '%s\\n' init >> "$0.calls"; fi
                if [ -n "$task_inspect" ] && [ -f "$0.fail" ]; then printf '%s\\n' 'Private initialization inspection refused' >&2; exit 73; fi
                exec \(quote(c.git.path)) "$@"
                """
                try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path);try Data().write(to:flag);model.executable=executable
                model.initialize();try await wait("accepted Init verification failure"){!model.busy && !model.hasPendingWork}
                try require(model.acceptedCreation != nil && model.acceptedCreation?.verified==false && registered==0 && FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git").path),"Initialization inspection failure discarded actual created repository")
                model.initialize();try require(try String(contentsOf:counter)=="init\n","Init retried mutation after accepted result")
                try FileManager.default.removeItem(at:flag);model.retryInspection();model.retryInspection();try await wait("Init inspection-only retry/adoption drain"){!model.busy && !model.hasPendingWork && registered==1}
                try require(try String(contentsOf:counter)=="init\n" && questions==1,"Init inspection retry repeated initialization/registration")
            }else if variant=="retire" {
                let gate=try wrapped(c,label:"init-retire",command:"init");model.executable=gate.executable;model.initialize();let pids=try await processes(gate,c)
                try require(FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git").path),"Init retirement gate preceded actual mutation")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted held initialization")
                owner.close();try await wait("retired Init actual drain"){!model.hasPendingWork && pids.allSatisfy{kill($0,0) != 0}}
                try require(model.acceptedCreation != nil && registered==0 && questions==0,"Retired Init lost accepted receipt or opened a late workspace/success sheet")
                model.retryInspection();try require(registered==0,"Retired Init adopted repository")
            }else {
                model.initializeAcceptedOperation={repo,path,bare,warnings,token in
                    attempts += 1
                    if variant=="precommand"{token.cancel()}
                    if variant=="failure"{_=try await repo.run(["init","--turtlegit-invalid-option",path.path]);throw Failure(description:"Invalid Init unexpectedly succeeded")}
                    let receipt=try await repo.initializeOutcome(at:path,bare:bare,confirmedWarnings:warnings,cancellation:token)
                    token.cancel();return receipt
                }
                model.initialize();try await wait("typed Init operation drain"){!model.busy && !model.hasPendingWork}
                if variant=="cancel" {
                    try require(model.acceptedCreation?.verified==true && model.completed && registered==0 && questions==0,"Late-cancel Init lost completed identity or auto-opened result")
                    model.initialize();model.retryInspection();try await wait("explicit Init inspection retry"){!model.hasPendingWork && registered==1}
                    try require(attempts==1 && questions==1,"Explicit Init inspection repeated mutation or acknowledgement")
                }else{try require(model.acceptedCreation==nil && !model.completed && registered==0 && !FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git").path),"Precommand/nonzero Init falsely adopted")}
            }
            owner.close();try await c.unchanged()
        }
    }
    static func submoduleAdd(_ c:Context)async throws {
        for variant in ["cancel","retire","inspection","precommand","failure"] {
            let root=c.folder.appendingPathComponent("super-"+variant)
            _=try await c.repo.run(["clone",c.root.path,root.path])
            let plain=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(mask:0))
            try Data("unrelated staged contents\n".utf8).write(to:root.appendingPathComponent("unrelated.txt"));try await plain.stage(["unrelated.txt"])
            let beforeUnrelated=try await plain.run(["ls-files","--stage","--","unrelated.txt"]).stdout,head=try await c.hash("HEAD",repository:plain)
            var options=SubmoduleAddOptions();options.source=variant=="failure" ? c.folder.appendingPathComponent("missing-source").path:c.root.path;options.path="modules/selected"
            let gate=try wrapped(c,label:"add-"+variant,command:"submodule-add",after:variant != "precommand")
            var executable=(variant=="failure" ? c.git:gate.executable),inspectionFailure:URL?,inspectionCalls:URL?
            if variant=="inspection" {
                executable=c.folder.appendingPathComponent("add-inspection-git");inspectionFailure=URL(fileURLWithPath:executable.path+".fail");inspectionCalls=URL(fileURLWithPath:executable.path+".calls")
                let script="""
                #!/bin/sh
                task_add=
                task_inspect=
                previous=
                for argument do
                  if [ "$previous" = submodule ] && [ "$argument" = add ]; then task_add=1; fi
                  if [ "$argument" = rev-parse ]; then task_inspect=1; fi
                  previous=$argument
                done
                if [ -n "$task_add" ]; then
                  printf '%s\\n' add >> "$0.calls"
                  \(quote(c.git.path)) "$@"
                  result=$?
                  if [ "$result" -eq 0 ]; then : > "$0.added"; fi
                  exit "$result"
                fi
                if [ -f "$0.added" ] && [ -f "$0.fail" ] && [ -n "$task_inspect" ]; then printf '%s\\n' 'Private accepted submodule inspection refused' >&2; exit 73; fi
                exec \(quote(c.git.path)) "$@"
                """
                try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path);try Data().write(to:inspectionFailure!)
            }
            let repo=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:.init(mask:0))
            let model=SubmoduleAddProgressWindowModel(repository:repo,access:nil,sourceAccess:nil,keyAccess:nil,options:options,preferences:c.prefs)
            var refreshes:[SubmoduleAddOutcome]=[],completed=0;model.onAttemptCompleted={refreshes.append($0)};model.onAdded={_ in completed += 1}
            let owner=SubmoduleAddProgressWindowController(model:model);c.show(owner);model.start()
            if ["cancel","retire","precommand"].contains(variant) {
                let pids=try await processes(gate,c)
                if variant != "precommand" {let child=GitRepository(root:root.appendingPathComponent(options.path),executable:c.git);let oid=try await c.hash("HEAD",repository:child);try require(oid==c.head,"Submodule Add gate preceded actual clone/gitlink mutation")}
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted actual Add worker")
                if variant=="retire"{owner.close()}else{model.cancel()}
                try await wait("Submodule accepted command/helper drain"){model.pendingOperations==0 && pids.allSatisfy{kill($0,0) != 0}}
            }else{try await wait("Submodule actual failure/inspection drain"){!model.busy && model.pendingOperations==0}}
            if ["precommand","failure"].contains(variant) {
                try require(!model.lastOutcome.added && !model.success && completed==0 && !FileManager.default.fileExists(atPath:root.appendingPathComponent(options.path).path),"Failed/precommand Add falsely adopted checkout")
            }else {
                try require(model.lastOutcome.added && refreshes.count==1 && refreshes[0].added && completed==0,"Accepted Add outcome/once parent refresh lost or optional callback ran")
                let staged=try await plain.run(["ls-files","--stage","--",options.path]).text
                try require(staged=="160000 "+c.head+" 0\t"+options.path+"\n","Accepted Add index gitlink identity changed")
                let afterAdd=try Data(contentsOf:root.appendingPathComponent(".git/index"))
                if variant=="inspection" {
                    try require(!model.lastOutcome.verified && model.canRetry && model.retryTitle=="Retry opening submodule","Accepted unverified Add offered mutation retry")
                    try FileManager.default.removeItem(at:inspectionFailure!);model.retry();model.retry();try await wait("Submodule inspection-only retry"){!model.busy && model.pendingOperations==0 && model.lastOutcome.verified}
                    let count=try String(contentsOf:inspectionCalls!)
                    try require(count=="add\n" && refreshes.count==1 && completed==0,"Submodule inspection retried Add or replayed parent refresh")
                }else {
                    model.retry()
                    try require(try calls(gate)==1 && refreshes.count==1 && completed==0,"Accepted Add repeated mutation or parent completion")
                }
                let afterRetry=try Data(contentsOf:root.appendingPathComponent(".git/index"));try require(afterAdd==afterRetry,"Inspection/retry changed accepted Add index packet")
            }
            let afterUnrelated=try await plain.run(["ls-files","--stage","--","unrelated.txt"]).stdout,afterHead=try await c.hash("HEAD",repository:plain),working=try Data(contentsOf:root.appendingPathComponent("tracked.txt"))
            try require(afterUnrelated==beforeUnrelated && afterHead==head && working==c.working,"Submodule workflow changed unrelated staged/working bytes or parent HEAD")
            owner.close();try await c.unchanged()
        }
    }
    static func switchRepository(_ c:Context)async throws {
        for variant in ["cancel","inspection","retire","precommand","failure"] {
            _=try await c.repo.run(["checkout","main"])
            let model=SwitchProgressWindowModel(repository:c.repo,access:nil,reference:"refs/heads/older",preferences:c.prefs),owner=SwitchProgressWindowController(model:model);c.show(owner);model.outputClipboard=c.board
            var mutations=0,refreshes=0,optional=0,readCalls=0,failRead=variant=="inspection",held:CheckedContinuation<Void,Never>?
            var callbackAccepted:[Bool]=[]
            let repo=c.repo
            model.onFinished={_,accepted in refreshes += 1;callbackAccepted.append(accepted)}
            model.onPostAction={_,_ in optional += 1}
            model.readStatus={token in readCalls += 1;if failRead{throw Failure(description:"Private accepted Switch state read refused")};return try await repo.status(cancellation:token)}
            model.checkoutAcceptedOperation={options,token,emit in
                mutations += 1
                if variant=="precommand"{token.cancel()}
                if variant=="failure"{var bad=options;bad.revision="refs/heads/does-not-exist";return try await repo.checkoutAccepted(bad,cancellation:token,onOutput:emit)}
                let receipt=try await repo.checkoutAccepted(options,cancellation:token,onOutput:emit)
                if variant=="retire"{await withCheckedContinuation{held=$0}}
                if variant=="cancel"{token.cancel()};return receipt
            }
            c.releases.append{held?.resume();held=nil}
            model.start()
            if variant=="retire" {
                try await wait("actual Switch receipt held"){held != nil};let head=try await c.hash("HEAD");try require(head==c.base,"Switch hold preceded actual checkout")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted held Switch")
                owner.close();held?.resume();held=nil
            }
            try await wait("Switch native completion drain"){!model.hasPendingWork && !model.busy}
            if ["precommand","failure"].contains(variant){let head=try await c.hash("HEAD");try require(model.acceptedCommand==nil && !model.success && head==c.head && optional==0,"Failed/precommand Switch falsely accepted")}
            else {
                try require(callbackAccepted == [true],"Accepted Switch callback reported failure for \(variant): \(callbackAccepted); \(model.output)")
                let head=try await c.hash("HEAD"),bytes=try Data(contentsOf:c.root.appendingPathComponent("tracked.txt")),index=try await c.repo.run(["rev-parse",":tracked.txt"]).text.trimmingCharacters(in:.whitespacesAndNewlines),expected=try await c.hash(c.base+":tracked.txt")
                try require(model.acceptedCommand != nil && head==c.base && bytes==Data("base\n".utf8) && index==expected && refreshes==1 && optional==0,"Accepted Switch actual HEAD/index/bytes or once parent refresh lost")
                if variant != "retire" {
                    try require(model.success && model.inspectionPending && model.postActions.contains(.inspectResult),"Switch accepted result lost explicit inspection recovery")
                    if variant=="cancel"{try require(readCalls==0,"Late Cancel started Switch result inspection")}
                    model.perform(.retry);model.perform(.switchWithMerge);try require(mutations==1,"Accepted Switch offered checkout replay")
                    failRead=false;model.perform(.inspectResult);try await wait("Switch fresh inspection-only recovery"){!model.busy && !model.hasPendingWork && !model.inspectionPending}
                    try require(mutations==1 && refreshes==1 && optional==0 && model.success,"Switch inspection repeated mutation/callback or optional handoff")
                }else{model.perform(.inspectResult);try require(optional==0 && refreshes==1,"Retired Switch revived optional work")}
            }
            owner.close();_=try await c.repo.run(["checkout","main"])
        }
        let head=try await c.hash("HEAD"),working=try Data(contentsOf:c.root.appendingPathComponent("tracked.txt"));try require(head==c.head && working==c.working,"Switch fixture did not retain expected final original worktree")
    }
    static func reset(_ c:Context)async throws {
        for variant in ["cancel","inspection","retire","precommand","failure"] {
            let plan=try await c.repo.prepareReset(to:c.base,mode:.soft),repo=c.repo
            let model=ResetProgressWindowModel(repository:repo,plan:plan,preferences:c.prefs,backend:.init(mask:0)),owner=ResetProgressWindowController(model:model);c.show(owner);model.outputClipboard=c.board
            var mutations=0,refreshes=0,optional=0,reads=0,failRead=variant=="inspection",held:CheckedContinuation<Void,Never>?
            model.onChanged={_ in refreshes += 1};model.onPostAction={_ in optional += 1}
            model.readBisect={token in reads += 1;if failRead{throw Failure(description:"Private accepted Reset state read refused")};return try await repo.bisectState(cancellation:token)}
            let lock=c.root.appendingPathComponent(".git/refs/heads/main.lock")
            model.runResetAccepted={plan,token,emit in
                mutations += 1
                if variant=="precommand"{token.cancel()}
                if variant=="failure"{try Data("external lock\n".utf8).write(to:lock)}
                let receipt=try await repo.resetAccepted(plan,cancellation:token,onOutput:emit,backend:.init(mask:0),recycle:false)
                if variant=="retire"{await withCheckedContinuation{held=$0}}
                if variant=="cancel"{token.cancel()};return receipt
            }
            c.releases.append{held?.resume();held=nil;try? FileManager.default.removeItem(at:lock)}
            model.start()
            if variant=="retire" {
                try await wait("actual Reset receipt held"){held != nil};let head=try await c.hash("HEAD");try require(head==c.base,"Reset hold preceded actual ref mutation")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit admitted held Reset")
                owner.close();held?.resume();held=nil
            }
            try await wait("Reset accepted command/native drain"){!model.busy && !model.hasPendingWork}
            try? FileManager.default.removeItem(at:lock)
            if ["precommand","failure"].contains(variant){let head=try await c.hash("HEAD");try require(model.acceptedCommand==nil && !model.success && head==c.head && optional==0,"Precommand/nonzero Reset falsely adopted")}
            else {
                let head=try await c.hash("HEAD"),index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:c.root.appendingPathComponent("tracked.txt"))
                try require(model.acceptedCommand != nil && head==c.base && index==c.index && bytes==c.working && refreshes==1 && optional==0,"Accepted soft Reset lost HEAD/index/work bytes or once parent refresh")
                if variant != "retire" {
                    try require(model.success && model.postActions.contains(.inspectResult),"Reset accepted result lost explicit read-only inspection recovery")
                    if variant=="cancel"{try require(reads==0,"Late Cancel started optional Reset inspection")}
                    model.perform(.retry);try require(mutations==1,"Accepted Reset exposed destructive retry")
                    failRead=false;model.perform(.inspectResult);try await wait("fresh Reset inspection-only retry"){!model.busy && !model.hasPendingWork && !model.postActions.contains(.inspectResult)}
                    try require(mutations==1 && refreshes==1 && optional==0,"Reset inspection repeated mutation or parent/optional callback")
                }else{model.perform(.inspectResult);try require(optional==0 && refreshes==1,"Retired Reset started optional inspection")}
            }
            owner.close();_=try await c.repo.run(["reset","--soft",c.head]);try await c.unchanged()
        }
        let direct=ResetWindowModel(repository:c.repo,access:nil,revision:c.base,preferences:c.prefs),repo=c.repo
        direct.load();try await wait("direct Reset initial reads"){!direct.busy && !direct.chooser.busy && direct.pendingBatchWorkers==0}
        var mutations=0,refreshes=0,completed=0,closed=0
        direct.onChanged={_ in refreshes += 1};direct.onReset={_ in completed += 1};direct.close={closed += 1}
        direct.performResetAccepted={plan,token in mutations += 1;let result=try await repo.resetAccepted(plan,cancellation:token,backend:.init(mask:0),recycle:false);token.cancel();return result}
        let plan=try await repo.prepareReset(to:c.base,mode:.soft);direct.apply(plan);try await wait("direct accepted late-cancel Reset drain"){!direct.busy && direct.pendingBatchWorkers==0}
        try require(direct.acceptedCommand != nil && mutations==1 && refreshes==1 && completed==0 && closed==0,"Direct Reset lost accepted mutation or ran optional completion after Cancel")
        direct.retryResultInspection();try await wait("direct Reset explicit result inspection"){!direct.busy && direct.pendingBatchWorkers==0}
        try require(mutations==1 && refreshes==1 && completed==1 && closed==1,"Direct Reset inspection repeated mutation/refresh or lost explicit completion")
        direct.invalidate();_=try await repo.run(["reset","--soft",c.head]);try await c.unchanged()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let a=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let b=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.setupQAOrder(_:relativeTo:))){method_exchangeImplementations(a,b)}
        let mode=CommandLine.arguments[3]
        do {
            let c=try Context(mode)
            do {
                try await c.prepare()
                switch mode {
                case "clone":try await clone(c);try await cloneConfiguration(c)
                case "init":try await initialize(c)
                case "submodule-add":try await submoduleAdd(c)
                case "switch":try await switchRepository(c)
                case "reset":try await reset(c)
                default:throw Failure(description:"Unknown setup case")
                }
                try await c.clean()
            }catch{try? await c.clean();throw error}
            if mode=="submodule-add"{try await SubmoduleAddRecoveryVerification.verify()}
            print("PASS repository setup transitions: "+mode+"; accepted actual mutations, cancellation/retirement, current inspection/key-only recovery, once parent callbacks, no mutation replay and owned helper drain")
        }catch{fputs("Repository setup transitions failed: \(error)\n",stderr);exit(1)}
    }
}
