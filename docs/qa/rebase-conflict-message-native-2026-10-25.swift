// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func conflictMessageOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));conflictMessageOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RebaseConflictMessageVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Rebase conflict message \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase conflict message timeout \(line)")}
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
        var owners=[RebaseWindowController](),held=[()->Void]()
        var original:LogEntry!,originalHead=""
        init(_ name:String)throws {
            let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            root=base.appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let wrapper=base.appendingPathComponent("held-helper"),git=CommandLine.arguments[2]
            let script="""
            #!/bin/sh
            is_commit() {
              while [ "$#" -gt 0 ]; do
                case "$1" in -c|-C|--git-dir|--work-tree) shift; shift;; --no-optional-locks|--literal-pathspecs) shift;; *) break;; esac
              done
              [ "$1" = commit ]
            }
            if ! is_commit "$@"; then exec \(quote(git)) "$@"; fi
            trace=\(quote(root.appendingPathComponent(".git/phase-trace").path))
            mkdir -p "$trace"
            n=0; [ ! -f "$trace/count" ] || read n < "$trace/count"
            n=$((n + 1)); printf '%s\\n' "$n" > "$trace/count"
            printf '%s\\0' "$@" > "$trace/args-$n"
            kind=initial
            for arg in "$@"; do [ "$arg" != --amend ] || kind=amend; done
            export TURTLEGIT_CONFLICT_KIND="$kind"
            export TURTLEGIT_CONFLICT_ATTEMPT="$n"
            \(quote(git)) "$@"
            result=$?
            printf '%s\\n' "$result" > "$trace/exit-$n"
            \(quote(git)) -C \(quote(root.path)) rev-parse HEAD > "$trace/head-$n"
            \(quote(git)) -C \(quote(root.path)) rev-parse HEAD^{tree} > "$trace/tree-$n"
            \(quote(git)) -C \(quote(root.path)) cat-file commit HEAD > "$trace/object-$n"
            exit "$result"
            """
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            repository=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ConflictMessage."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"Gravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            editor=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"]!)
        }
        func commit(_ message:String)async throws->LogEntry {
            try await repository.stage(["shared.txt"])
            _=try await repository.run(["commit","-m",message],environmentOverrides:["GIT_AUTHOR_NAME":"Original Conflict Author","GIT_AUTHOR_EMAIL":"original@example.invalid","GIT_AUTHOR_DATE":"2026-10-12T10:00:00+0200"])
            return try await repository.rebaseCommit("HEAD")
        }
        func seed()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Conflict QA"),("user.email","conflict@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.updateRefs","false")] {_=try await repository.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("shared.txt"));let base=try await commit("Base")
            _=try await repository.run(["switch","-c","upstream"])
            try Data("upstream\n".utf8).write(to:root.appendingPathComponent("shared.txt"));_=try await commit("Upstream")
            _=try await repository.run(["switch","-c","topic",base.hash])
            try Data("topic\n".utf8).write(to:root.appendingPathComponent("shared.txt"));original=try await commit("Original conflict subject\n\nOriginal conflict body")
            originalHead=original.hash
        }
        func open()async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repository,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.orderFront(nil)
            owner.model.editorExecutable=editor;owner.model.confirmConflictHints={true};owner.model.load(upstream:"upstream")
            try await wait{!owner.model.busy && (owner.model.plan != nil || owner.model.active) && drained()};return owner
        }
        func conflict()async throws->RebaseWindowController {
            let owner=try await open(),model=owner.model
            model.request("start");if let question=model.pendingConfirmation {model.answerConfirmation(question,proceed:true)}
            try await wait{!model.busy && model.fileRecovery && model.state?.conflicts.isEmpty==false && drained()}
            try await acknowledgeError(owner)
            try Data("resolved\n".utf8).write(to:root.appendingPathComponent("shared.txt"))
            // The standalone controller's Resolve menu delegates to its owning
            // workspace. Admit the private resolution explicitly here; this
            // fixture exercises checked conflict Commit, not that parent route.
            try await repository.stage(["shared.txt"])
            model.refreshState();try await wait{!model.busy && model.supportsConflictSelection && model.state?.conflicts.isEmpty==true && model.conflictRows.contains{$0.path=="shared.txt" && $0.state != .conflicted} && drained()}
            try require(model.state?.conflicts.isEmpty==true,"Resolution did not clear actual unmerged index stages")
            model.checkedConflicts=["shared.txt"]
            try Data("Private untracked content\n".utf8).write(to:root.appendingPathComponent("untracked.txt"))
            let trace=root.appendingPathComponent(".git/phase-trace",isDirectory:true)
            if FileManager.default.fileExists(atPath:trace.path) {try FileManager.default.removeItem(at:trace)}
            return owner
        }
        func hook(_ mode:String)async throws {
            let directory=root.appendingPathComponent(".git/private-hooks",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let hook=directory.appendingPathComponent("pre-commit")
            let script="""
            #!/bin/sh
            [ "$TURTLEGIT_CONFLICT_KIND" = \(quote(mode=="initial" ? "initial":"amend")) ] || exit 0
            \(mode=="dirty" ? "printf 'dirty after second failure\\n' >> "+quote(root.appendingPathComponent("shared.txt").path):"true")
            printf 'private-conflict-message-sentinel\\n' >&2
            exit 73
            """
            try Data(script.utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
            _=try await repository.run(["config","core.hooksPath",directory.path])
        }
        func count()throws->Int {let url=root.appendingPathComponent(".git/phase-trace/count");return FileManager.default.fileExists(atPath:url.path) ? Int(try String(contentsOf:url,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines))! : 0}
        func args(_ number:Int)throws->[String] {try Data(contentsOf:root.appendingPathComponent(".git/phase-trace/args-\(number)")).split(separator:0).map{String(decoding:$0,as:UTF8.self)}}
        func trace(_ name:String,_ number:Int)throws->String {try String(contentsOf:root.appendingPathComponent(".git/phase-trace/\(name)-\(number)"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)}
        func cleanup()async {
            for owner in owners {owner.model.retire();owner.close()};for answer in held {answer()};held=[]
            try? await wait{drained()};if (try? await repository.rebaseState().active)==true {_=try? await repository.abortRebase()}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func completed(_ model:RebaseWindowModel)async throws {try await wait{!model.busy && drained()}}
    static func sheet(_ c:Context,_ owner:RebaseWindowController)async throws->(NSWindow,NSButton,NSButton) {
        try await wait{owner.window?.attachedSheet != nil && owner.model.hasReplayQuestion}
        guard let parent=owner.window,let sheet=parent.attachedSheet,let content=sheet.contentView else{throw Failure(description:"Real failure sheet missing")}
        let descendants=views(content),fields=descendants.compactMap{$0 as? NSTextField}.map(\.stringValue),diagnostics=descendants.compactMap{$0 as? NSTextView}
        let buttons=descendants.compactMap{$0 as? NSButton}.filter{!$0.isHidden}
        guard let retry=buttons.first(where:{$0.title=="Retry"}),let ignore=buttons.first(where:{$0.title=="Ignore"}) else{throw Failure(description:"Retry/Ignore native buttons missing: \(buttons.map(\.title))")}
        try require(fields.contains("Git command failed") && buttons.count==2,"Source error sheet text/button count changed")
        try require(sheet.defaultButtonCell===retry.cell && retry.isEnabled && ignore.isEnabled,"Retry is not the actual enabled default")
        try require(retry.image != nil && ignore.image != nil,"Source Retry/Ignore command artwork missing")
        try require(sheet.alphaValue==0 && sheet.sheetParent===parent,"Failure sheet escaped its invisible owner")
        try require(diagnostics.contains{$0.isSelectable && !$0.isEditable && $0.string.contains("private-conflict-message-sentinel")},"Selectable raw Git diagnostic missing")
        try require(owner.model.cleanCommitFailure?.diagnostic.contains("private-conflict-message-sentinel")==true,"Typed retained receipt lost Git diagnostic")
        return(sheet,retry,ignore)
    }
    static func acknowledgeError(_ owner:RebaseWindowController)async throws {
        guard owner.model.error != nil else{return}
        try await wait{owner.window?.attachedSheet != nil}
        guard let window=owner.window,let sheet=window.attachedSheet,let content=sheet.contentView else {throw Failure(description:"Owned error sheet missing")}
        try await wait{views(content).compactMap{$0 as? NSButton}.contains{$0.title=="OK" && $0.isEnabled}}
        guard let button=views(content).compactMap({$0 as? NSButton}).first(where:{$0.title=="OK" && $0.isEnabled}) else {throw Failure(description:"Owned error OK missing")}
        try require(sheet.sheetParent === window,"Error sheet owner changed")
        try press(button)
        try await wait{sheet.sheetParent==nil && window.attachedSheet !== sheet && owner.model.error==nil}
    }
    static func press(_ button:NSButton)throws {guard let action=button.action else{throw Failure(description:"Native action absent")};try require(NSApp.sendAction(action,to:button.target,from:button),"Native sheet dispatch failed")}
    static func phases()async throws {
        for mode in ["unchanged","edited","empty"] {
            let c=try Context(mode);do {
                try await c.seed();let owner=try await c.conflict(),model=owner.model
                let draft=mode=="unchanged" ? c.original.message:mode=="empty" ? " \n\t":"Edited conflict subject 🦎\n\nEdited body\n"
                model.messageBinding(model.formContext).wrappedValue=draft;model.request("continue");try await completed(model)
                try require(try c.args(1).contains("-C") && c.args(1).contains(c.original.hash) && c.args(1).contains("--allow-empty-message"),"Initial conflict commit did not retain selected source -C identity")
                if mode=="empty" {
                    try require(model.error != nil && !model.completedSuccessfully && model.state?.conflictMessage != nil && c.count()==1,"Empty edited draft did not stop AFTER exactly one original commit")
                    let first=try await c.repository.rebaseCommit("HEAD")
                    try require(first.message.trimmingCharacters(in:.whitespacesAndNewlines)==c.original.message.trimmingCharacters(in:.whitespacesAndNewlines),"Empty draft changed original first commit")
                    try await acknowledgeError(owner)
                    model.messageBinding(model.formContext).wrappedValue="Corrected empty draft";model.request("continue");try await completed(model)
                }
                let firstObject=try c.trace("object",1)
                try require(firstObject.contains("Original conflict subject") && firstObject.contains("Original conflict body") && firstObject.contains("Original Conflict Author"),"Initial -C phase lost original message/author")
                let untracked=try Data(contentsOf:c.root.appendingPathComponent("untracked.txt"));try require(untracked==Data("Private untracked content\n".utf8),"Conflict phases consumed untracked work")
                let final=try await c.repository.rebaseCommit("HEAD"),expectedCount=mode=="unchanged" ? 1:2
                let actualCount=try c.count(),actualState=try await c.repository.rebaseState()
                let ownerFlags="retired=\(model.retired) replaying=\(model.replaying) cancelling=\(model.cancellingReplay) owner=\(model.revisionMenuLog.window === owner.window) sheet=\(String(describing:owner.window?.attachedSheet)) modal=\(String(describing:NSApp.modalWindow)) containing=\(model.containingReferenceBlocked) find=\(model.revisionFindBlocked) history=\(model.revisionHistoryBlocked) logQuit=\(model.revisionMenuLog.confirmingQuit) logBusy=\(model.revisionMenuLog.busy) jumping=\(model.revisionMenuLog.jumping) unified=\(model.revisionMenuLog.unifiedViewerBusy) copying=\(model.revisionMenuLog.copyingDetails) loadNote=\(model.revisionMenuLog.loadingNote) saveNote=\(model.revisionMenuLog.savingNote) note=\(model.revisionMenuLog.noteRequest != nil)"
                let diagnostic="owners[\(ownerFlags)] mode=\(mode) count=\(actualCount)/\(expectedCount) completed=\(model.completedSuccessfully) finished=\(model.finished) active=\(model.active)/\(actualState.active) busy=\(model.busy) step=\(actualState.currentStep)/\(actualState.total) stopped=\(String(describing:actualState.stoppedAction)) phase=\(String(describing:actualState.conflictMessage?.phase)) requested=\(String(describing:actualState.conflictMessage?.requestedAction)) split=\(String(describing:actualState.split)) error=\(model.error ?? "nil") output=\(String(model.output.suffix(4000)))"
                if !model.completedSuccessfully || model.error != nil || actualCount != expectedCount {print("CONFLICT PHASE DIAGNOSTIC: "+diagnostic)}
                try require(model.completedSuccessfully && model.error==nil && actualCount==expectedCount,"Conflict phases did not finish exactly once: "+diagnostic)
                try require(final.author==c.original.author && final.date==c.original.date,"Conflict commit/amend lost original author/date")
                if expectedCount==2 {try require(try c.args(2).contains("--amend") && c.args(2).contains("-F") && c.trace("tree",1)==c.trace("tree",2),"Second phase was not message-only amend after original commit")}
                try require(final.message.contains(mode=="unchanged" ? "Original conflict subject":mode=="empty" ? "Corrected empty draft":"Edited conflict subject"),"Final message lost selected draft")
                let content=try Data(contentsOf:c.root.appendingPathComponent("shared.txt"));try require(content==Data("resolved\n".utf8),"Conflict resolution bytes changed")
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func failures()async throws {
        for mode in ["initial","sheet","dirty"] {
            let c=try Context(mode);do {
                try await c.seed();let owner=try await c.conflict(),model=owner.model;try await c.hook(mode)
                var questions=0
                if mode != "sheet" {model.chooseCleanCommitFailure={_ in questions += 1;return .ignore}}
                let draft="Edited hook draft 🦎\n\nRetain raw text\n";model.messageBinding(model.formContext).wrappedValue=draft;model.request("continue")
                if mode=="sheet" {
                    let(first,retry,_)=try await sheet(c,owner)
                    let head=try await c.repository.rebaseCommit("HEAD"),tree=try await c.repository.run(["write-tree"]).stdout,index=try await c.repository.run(["ls-files","--stage","-z"]).stdout,working=try Data(contentsOf:c.root.appendingPathComponent("shared.txt"))
                    try require(c.count()==2 && model.state?.conflictMessage != nil,"Second failure lost durable initial phase")
                    try press(retry);try await completed(model)
                    try require(first.sheetParent==nil && model.cleanCommitFailure==nil && model.amendMessage==draft && model.canEditMessage && c.count()==2,"Retry reran a command or lost editable draft")
                    model.request("continue");let(second,_,ignore)=try await sheet(c,owner)
                    try require(c.count()==3 && c.args(3).contains("--amend"),"Next Continue repeated initial commit instead of amend")
                    try press(ignore);try await completed(model)
                    let after=try await c.repository.rebaseCommit("HEAD"),afterTree=try await c.repository.run(["write-tree"]).stdout,afterIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout,afterWorking=try Data(contentsOf:c.root.appendingPathComponent("shared.txt"))
                    try require(second.sheetParent==nil && model.completedSuccessfully && c.count()==3 && after.hash==head.hash && afterTree==tree && afterIndex==index && afterWorking==working,"Ignore reran or altered committed conflict tree/index/work")
                }else {
                    try await completed(model)
                    try require(questions==0 && model.error?.contains("private-conflict-message-sentinel")==true && !model.completedSuccessfully,"Initial/dirty failure incorrectly offered clean Ignore")
                    try require(c.count()==(mode=="initial" ? 1:2),"Failure repeated a commit")
                    if mode=="initial" {try require(model.state?.conflictMessage==nil,"Failed initial commit published second-phase receipt")}
                    else {let bytes=try String(contentsOf:c.root.appendingPathComponent("shared.txt"),encoding:.utf8);try require(bytes.contains("dirty after second failure"),"Dirty second failure discarded working content")}
                }
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func ownership()async throws {
        for route in ["reopen","retire","stale","cancel"] {
            let c=try Context(route);do {
                try await c.seed();let owner=try await c.conflict(),model=owner.model;try await c.hook("amend")
                model.chooseCleanCommitFailure={_ in await withCheckedContinuation{continuation in c.held.append{continuation.resume(returning:.ignore)}}}
                let draft="Held conflict draft \(route)\n";model.messageBinding(model.formContext).wrappedValue=draft;model.request("continue")
                try await wait{!c.held.isEmpty && model.hasReplayQuestion}
                let head=try await c.repository.rebaseCommit("HEAD"),index=try await c.repository.run(["ls-files","--stage","-z"]).stdout,working=try Data(contentsOf:c.root.appendingPathComponent("shared.txt"))
                if route=="stale" {_=try await c.repository.abortRebase()}
                else {
                    if route=="cancel" {model.cancelReplay();try require(model.hasReplayQuestion && !model.cancellingReplay,"Cancel bypassed owned question")}
                    model.retire();owner.close()
                }
                c.held.removeFirst()();try await completed(model)
                try require(c.count()==2,"Late answer repeated initial or failed amend")
                if route=="reopen" {
                    let next=try await c.open();try require(next.model.state?.conflictMessage != nil && next.model.cleanCommitFailure != nil && next.model.amendMessage==draft,"Reopen lost durable conflict phase/draft")
                    next.model.chooseCleanCommitFailure={_ in .ignore};next.model.request("continue");try await completed(next.model)
                    try require(next.model.completedSuccessfully && c.count()==2,"Reopened Ignore repeated a commit")
                }
                let after=try await c.repository.rebaseCommit("HEAD")
                if route=="stale" {try require(after.hash==c.originalHead && !model.completedSuccessfully,"Stale answer mutated replacement session")}
                else {
                    let afterIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout,afterWorking=try Data(contentsOf:c.root.appendingPathComponent("shared.txt"))
                    try require(after.hash==head.hash && afterIndex==index && afterWorking==working,"Retirement/reopen answer altered preserved HEAD/index/worktree")
                }
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.conflictMessageOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let mode=CommandLine.arguments[3]
        switch mode {case "phases":try await phases();case "failures":try await failures();case "ownership":try await ownership();default:throw Failure(description:"Unknown conflict message case")}
        print("PASS: Rebase conflict message "+mode)
    }
}
