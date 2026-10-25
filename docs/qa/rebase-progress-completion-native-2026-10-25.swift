// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func replayProgressOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));replayProgressOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RebaseProgressCompletionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Rebase progress completion \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase progress completion timeout \(line)")}
    static func drained()->Bool {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0}
    static func views(_ view:NSView)->[NSView] {
        // Snapshot the public Objective-C collection before walking AppKit's
        // decorated SwiftUI descendants; avoid a lazy live-array bridge.
        let selector = #selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {
            let object=children.object(at:index) as AnyObject
            guard let native=object as? NSObject,native.isKind(of:NSView.self) else {continue}
            result += views(unsafeBitCast(object,to:NSView.self))
        }
        return result
    }
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    @MainActor final class Context {
        let root:URL,repository:GitRepository,prefs:UserDefaults,suite:String,editor:URL
        var owners=[RebaseWindowController](),commits=[LogEntry](),originalHead=""
        var pendingFinishes=[()->Void]()
        let gate:URL
        init(_ name:String)throws {
            let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            root=base.appendingPathComponent(name,isDirectory:true);gate=root.appendingPathComponent(".git/progress-gates",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let git=CommandLine.arguments[2],wrapper=base.appendingPathComponent("held-helper")
            let script="""
            #!/bin/sh
            if [ "${1-}" = --prepare-message ]; then
              gate=\(quote(gate.path))
              mkdir -p "$gate"
              n=0; [ ! -f "$gate/count" ] || read n < "$gate/count"
              n=$((n + 1)); printf '%s\\n' "$n" > "$gate/count"
              : > "$gate/entered-$n"
              exec 9> "$gate/owned-resource"
              while [ ! -f "$gate/release-$n" ]; do /bin/sleep .02; done
              [ ! -f "$gate/fail-$n" ] || exit 73
              exit 0
            fi
            is_stash_pop() {
              while [ "$#" -gt 0 ]; do
                case "$1" in -c|-C|--git-dir|--work-tree) shift; shift;; --literal-pathspecs|--no-literal-pathspecs|--no-optional-locks) shift;; *) break;; esac
              done
              [ "${1-}" = stash ] && [ "${2-}" = pop ]
            }
            gate=\(quote(gate.path))
            if is_stash_pop "$@" && [ -f "$gate/hold-stash" ]; then
              : > "$gate/stash-entered"
              exec 9> "$gate/stash-owned-resource"
              while [ ! -f "$gate/stash-release" ]; do /bin/sleep .02; done
            fi
            exec \(quote(git)) "$@"
            """
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            repository=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ReplayProgress."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"Gravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            editor=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"]!)
        }
        func commit(_ path:String,_ content:String)async throws->LogEntry {
            try Data(content.utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path])
            _=try await repository.run(["commit","-m",path]);return try await repository.rebaseCommit("HEAD")
        }
        func seed(repeated:Bool=false)async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Progress QA"),("user.email","progress@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.updateRefs","false")] {_=try await repository.run(["config",key,value])}
            let base=try await commit("base.txt","base\n")
            _=try await repository.run(["switch","-c","upstream"]);_=try await commit("upstream.txt","upstream\n")
            _=try await repository.run(["switch","-c","topic",base.hash])
            if repeated {
                let add=try await commit("repeat.txt","repeat\n");_=try await repository.run(["rm","repeat.txt"]);_=try await repository.run(["commit","-m","Remove repeated file"])
                let remove=try await repository.rebaseCommit("HEAD");commits=[add,remove,add]
            }else {for name in ["alpha.txt","beta.txt","gamma.txt"] {commits.append(try await commit(name,name+"\n"))}}
            originalHead=try await repository.rebaseCommit("HEAD").hash
            if repeated {_=try await repository.run(["switch","upstream"])}
        }
        func installGate()async throws {
            let folder=root.appendingPathComponent(".git/private-hooks",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let wrapper=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent("held-helper")
            let hook=folder.appendingPathComponent("prepare-commit-msg")
            try Data(("#!/bin/sh\nexec "+quote(wrapper.path)+" --prepare-message \"$@\"\n").utf8).write(to:hook)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path);_=try await repository.run(["config","core.hooksPath",folder.path])
        }
        func release(_ number:Int)throws {try FileManager.default.createDirectory(at:gate,withIntermediateDirectories:true);try Data().write(to:gate.appendingPathComponent("release-\(number)"))}
        func entered(_ number:Int)->Bool {FileManager.default.fileExists(atPath:gate.appendingPathComponent("entered-\(number)").path)}
        func open(repeated:Bool=false,automatic:Bool=false,afterFetch:Bool=false)async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repository,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.orderFront(nil)
            owner.model.editorExecutable=editor;owner.model.completionAfterFetch=afterFetch
            // Initial picker selections are unique and newest-first. Repeated
            // occurrences enter through the actual Add workflow afterward.
            owner.model.load(upstream:repeated ? nil:"upstream",autoStart:automatic,cherryPick:repeated ? [commits[1].hash,commits[0].hash]:nil)
            if !automatic {try await wait{!owner.model.busy && owner.model.plan != nil && drained()}}
            if repeated {
                owner.model.addCommits([commits[0].hash])
                try await wait{!owner.model.busy && !owner.model.addingCommits && owner.model.plan?.entries.count==3 && drained()}
                try require(owner.model.error==nil,"Add repeated occurrence failed: "+(owner.model.error ?? "nil"))
            }
            return owner
        }
        func start(_ model:RebaseWindowModel) {model.request("start");if let question=model.pendingConfirmation {model.answerConfirmation(question,proceed:true)}}
        func cleanup()async {
            for number in 1...12 {try? release(number)}
            try? Data().write(to:gate.appendingPathComponent("stash-release"))
            for owner in owners {owner.model.retire();owner.close()}
            let pending=pendingFinishes;pendingFinishes=[];for finish in pending {finish()}
            try? await wait{drained() && StashRestoreWindowModel.activeOperations==0}
            if (try? await repository.rebaseState().active)==true {_=try? await repository.abortRebase()}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func progress()async throws {
        for repeated in [false,true] {
            let c=try Context(repeated ? "repeated":"normal");do {
                try await c.seed(repeated:repeated);let owner=try await c.open(repeated:repeated),model=owner.model
                let expected=model.plan!.entries.map(\.id),actions=model.plan!.entries.map(\.action)
                if repeated {try require(expected.count==3 && expected[0] != expected[2] && model.plan!.entries[0].commit.hash==model.plan!.entries[2].commit.hash,"Repeated source occurrences were collapsed")}
                try await c.installGate();model.selection=[expected.last!];let selection=model.selection;c.start(model)
                var previousSession:String?,lastScroll=0
                for step in 1...3 {
                    try await wait{c.entered(step) && model.replayProgress?.currentStep==step}
                    guard let receipt=model.replayProgress else{throw Failure(description:"Missing live logical progress")}
                    try require(model.busy && receipt.total==3 && receipt.completed==step-1 && receipt.currentEntryID==expected[step-1] && !receipt.finished,"Live receipt is not the held logical occurrence")
                    try require(receipt.entries.map(\.id)==expected && receipt.entries.map(\.action)==actions,"Live progress rewrote original actions/IDs")
                    if let previousSession {try require(previousSession==receipt.sessionID,"Progress session changed midoperation")};previousSession=receipt.sessionID
                    try require(model.logicalProgressTotal==3 && model.logicalProgressCompleted==step-1,"Determinate bar did not use logical counts")
                    try require(model.replayRows.first(where:{$0.id==expected[step-1]})?.progress == .current && model.scrollRevisionOccurrence==expected[step-1] && model.scrollRevisionRequest>lastScroll,"Current row/scroll request did not track live occurrence")
                    try require(model.selection==selection,"Live progress changed semantic selection")
                    if !repeated,step==2 {
                        // Exercise the presentation state produced by an earlier
                        // completed manual Skip while this actual Git operation
                        // is held. This is a display-override regression, not a
                        // claim that this seed executed Git --skip.
                        var displayed=model.replayRows
                        displayed[0].action = .skip;displayed[0].progress = .completed
                        model.replayRows=displayed
                    }
                    if !repeated,step==3 {try require(model.replayRows[0].action == .skip,"Later original-action receipt erased completed Skip display")}
                    lastScroll=model.scrollRevisionRequest;try c.release(step)
                }
                try await wait{!model.busy && model.finished && drained()}
                try require(model.completedSuccessfully && model.replayProgress?.finished==true && model.logicalProgressCompleted==3 && model.logicalProgressTotal==3,"Terminal logical progress lost authoritative success")
                try require(model.replayRows.map(\.id)==expected && model.replayRows.allSatisfy{$0.progress == .completed},"Terminal rows lost original occurrence mapping")
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func completion()async throws {
        for route in ["manual","automatic","stash","stash-retire"] {
            let c=try Context(route);do {
                try await c.seed()
                if route.hasPrefix("stash") {
                    _=try await c.repository.run(["config","rebase.autostash","true"])
                    try Data("private dirty base\n".utf8).write(to:c.root.appendingPathComponent("base.txt"))
                    try FileManager.default.createDirectory(at:c.gate,withIntermediateDirectories:true)
                    try Data().write(to:c.gate.appendingPathComponent("hold-stash"))
                }
                let owner=try await c.open(automatic:route != "manual",afterFetch:route != "manual"),model=owner.model
                if route=="manual" {c.start(model)}
                if route.hasPrefix("stash") {
                    try await wait{FileManager.default.fileExists(atPath:c.gate.appendingPathComponent("stash-entered").path) && owner.window?.attachedSheet?.windowController is StashRestoreWindowController}
                    guard let child=owner.window?.attachedSheet?.windowController as? StashRestoreWindowController,
                          let originalFinish=child.model.finishAndPerform else{throw Failure(description:"Actual stash restore child/completion absent")}
                    // Pop mode0 normally auto-finishes. Hold the existing native
                    // completion only while actual Git is held, then release it
                    // unchanged after verifying the successful real Pop.
                    child.model.finishAndPerform={action in c.pendingFinishes.append{originalFinish(action)}}
                    try Data().write(to:c.gate.appendingPathComponent("stash-release"))
                    try await wait{!child.model.busy && child.model.success && !c.pendingFinishes.isEmpty && StashRestoreWindowModel.activeOperations==0}
                    try require(c.pendingFinishes.count==1 && owner.window?.attachedSheet===child.window && !model.retired && model.busy,"AutoFinish released owner before actual stash child completion")
                    if route=="stash-retire" {
                        model.retire();owner.close()
                        try await wait{RebaseWindowModel.activeStashRestorations==0 && StashRestoreWindowModel.activeOperations==0}
                        let replacement=try await c.open()
                        c.pendingFinishes.removeFirst()()
                        try require(!replacement.model.retired && replacement.window?.isVisible==true,"Late stash restoration closed replacement owner")
                    }else {c.pendingFinishes.removeFirst()()}
                }
                try await wait{!model.busy && drained() && (route=="manual" ? model.finished:model.retired)}
                try require(model.completedSuccessfully,"Successful completion lost result")
                if route=="manual" {
                    try require(!model.retired && model.retainsOnlyProgressTab && model.tab==2,"Manual normal completion did not retain only result log")
                    model.tabBinding(model.formContext).wrappedValue=0;try require(model.tab==2,"Completed replay reopened obsolete input tab")
                }else {try require(model.retired && owner.window?.isVisible != true,"Automatic Fetch replay did not finish through owned close")}
                if route.hasPrefix("stash") {let bytes=try Data(contentsOf:c.root.appendingPathComponent("base.txt")),list=try await c.repository.run(["stash","list"]).text;try require(bytes==Data("private dirty base\n".utf8) && list.isEmpty,"Automatic completion lost/doubled saved work")}
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
        let c=try Context("log");do {
            try await c.seed();let owner=try await c.open(),model=owner.model
            guard let entry=model.entries.first(where:{$0.commit.hash==c.commits[1].hash}) else{throw Failure(description:"Unnamed ordinary revision absent")}
            var received=[String]();model.onShowRevisionLog={received.append($0)}
            let ids:Set<String>=[entry.id]
            try require(model.revisionCommandVisible(.log,ids:ids) && model.canPerformRevisionMenu(.log,ids:ids),"Show log missing from ordinary unnamed row")
            try require(RebaseRevisionCommand.log.sourceCommand(single:true) == .showLog && RebaseCompletionAction.log.icon == .log,"Show log source identity/artwork changed")
            model.performRevisionMenu(.log,ids:ids);try require(received==[entry.commit.hash],"Show log did not use captured immutable target")
            model.retire();model.performRevisionMenu(.log,ids:ids);try require(received.count==1,"Retired Show log callback revived owner")
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    static func ownership()async throws {
        for route in ["cancel","retire","stale","failure"] {
            let c=try Context(route);do {
                print("OWNERSHIP START: "+route)
                try await c.seed();let owner=try await c.open(),model=owner.model
                var failedPickQuestions=0
                if route=="failure" {model.chooseFailedPickRecovery={_ in failedPickQuestions += 1;return .cancel}}
                try await c.installGate();c.start(model)
                try await wait{c.entered(1) && model.replayProgress?.currentStep==1}
                let receipt=model.replayProgress!,scroll=model.scrollRevisionRequest
                if route=="failure" {try Data().write(to:c.gate.appendingPathComponent("fail-1"));try c.release(1)}
                else if route=="stale" {model.retire();owner.close();try c.release(1)}
                else if route=="retire" {model.retire();owner.close()}
                else {model.confirmReplayCancellation={true};model.cancelReplay();try await wait{model.cancellingReplay || !model.busy}}
                for number in 1...6 {try c.release(number)}
                do {try await wait{!model.busy && drained()}}
                catch {
                    print("OWNERSHIP WAIT FAILED: route=\(route) busy=\(model.busy) retired=\(model.retired) replaying=\(model.replaying) question=\(model.hasReplayQuestion) failedPickQuestions=\(failedPickQuestions) active=\(model.active) finished=\(model.finished) error=\(model.error ?? "nil") preparation=\(RebaseWindowModel.activePreparationReads) columns=\(RebaseWindowModel.activeColumnReads) replay=\(RebaseWindowModel.activeReplayOperations) output=\(String(model.output.suffix(2000)))")
                    throw error
                }
                print("OWNERSHIP DRAINED: route=\(route) active=\(model.active) completed=\(model.completedSuccessfully) failedPickQuestions=\(failedPickQuestions)")
                if route=="failure" {try require(failedPickQuestions==1 && model.active && !model.completedSuccessfully,"Actual failed Pick was not retained after Cancel recovery choice")}
                if route=="stale" {_=try await c.repository.abortRebase();let actual=try await c.repository.rebaseCommit("HEAD");try require(actual.hash==c.originalHead,"Retired callback changed external abort target")}
                try require(!model.completedSuccessfully,"Cancelled/failed/retired replay claimed terminal success")
                if route=="retire" || route=="stale" {try require(model.scrollRevisionRequest==scroll && model.replayProgress?.sessionID==receipt.sessionID,"Late progress mutated retired owner")}
                else {try require(!model.retainsOnlyProgressTab,"Failure/cancel adopted success-only result layout")}
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.replayProgressOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let mode=CommandLine.arguments[3]
        switch mode {case "progress":try await progress();case "completion":try await completion();case "ownership":try await ownership();default:throw Failure(description:"Unknown progress completion case")}
        print("PASS: Rebase progress completion "+mode)
    }
}
