// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func amendRecoveryOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));amendRecoveryOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RebaseAmendRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Rebase amend recovery \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase amend recovery timeout \(line)")}
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
    @MainActor final class Context {
        let root:URL,repository:GitRepository,prefs:UserDefaults,suite:String,editor:URL
        var owners=[RebaseWindowController]()
        var held:[()->Void]=[]
        var empty:LogEntry!,originalHead=""
        init(_ name:String)throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.AmendRecovery."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"Gravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            editor=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"]!)
        }
        func commit(_ path:String,_ message:String)async throws->LogEntry {
            try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path])
            let file=root.appendingPathComponent(".git/empty-native-message");try Data(message.utf8).write(to:file)
            _=try await repository.run(["commit","--allow-empty-message","--cleanup=verbatim","-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":path=="empty.txt" ? "Empty Native Author":"Other Native Author","GIT_AUTHOR_EMAIL":"empty-native@example.invalid","GIT_AUTHOR_DATE":path=="empty.txt" ? "2026-10-12T10:00:00+0200":"2026-10-10T10:00:00+0200"])
            try FileManager.default.removeItem(at:file);return try await repository.rebaseCommit("HEAD")
        }
        func seed(_ message:String="Retained middle subject\n\nRetained middle body\n")async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Empty QA"),("user.email","empty@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.updateRefs","false")] {_=try await repository.run(["config",key,value])}
            let base=try await commit("base.txt","base")
            _=try await repository.run(["switch","-c","upstream"]);_=try await commit("upstream.txt","upstream")
            _=try await repository.run(["switch","-c","topic",base.hash])
            _=try await commit("first.txt","first");empty=try await commit("empty.txt",message);_=try await commit("last.txt","last")
            originalHead=try await repository.rebaseCommit("HEAD").hash
        }
        func open(cherryPick:[String]?=nil)async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repository,access:nil,preferences:prefs);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.orderFront(nil)
            owner.model.editorExecutable=editor
            owner.model.load(upstream:cherryPick == nil ? "upstream":nil,cherryPick:cherryPick)
            try await wait{!owner.model.busy && (owner.model.plan != nil || owner.model.active) && drained()}
            return owner
        }
        func begin(_ model:RebaseWindowModel) {
            model.request("start")
            if let question=model.pendingConfirmation {model.answerConfirmation(question,proceed:true)}
        }
        func cleanup()async {
            for owner in owners {owner.model.retire();owner.close()}
            for answer in held {answer()};held=[]
            try? await wait{drained()}
            if (try? await repository.rebaseState().active)==true {_=try? await repository.abortRebase()}
            prefs.removePersistentDomain(forName:suite)
        }
    }

    static func hook(_ c:Context,dirty:Bool=false)async throws->URL {
        let directory=c.root.appendingPathComponent(".git/private-hooks",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let count=c.root.appendingPathComponent(".git/amend-hook-count"),hook=directory.appendingPathComponent("pre-commit")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        var script="#!/bin/sh\nprintf 'attempt\\n' >> "+quote(count.path)+"\nprintf 'private-amend-recovery-sentinel\\n' >&2\n"
        if dirty {script += "printf 'dirty after failed hook\\n' >> "+quote(c.root.appendingPathComponent("empty.txt").path)+"\n"}
        script += "exit 73\n"
        try Data(script.utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _=try await c.repository.run(["config","core.hooksPath",directory.path]);return count
    }
    static func count(_ path:URL)throws->Int {try String(contentsOf:path,encoding:.utf8).split(separator:"\n").count}
    static func pause(_ c:Context,cherry:Bool=false,squash:Bool=false)async throws->RebaseWindowController {
        if cherry {c.prefs.set(true,forKey:"CherrypickAddCherryPickedFrom");_=try await c.repository.run(["switch","upstream"])}
        let owner=try await c.open(cherryPick:cherry ? [c.empty.hash]:nil),model=owner.model
        guard let plan=model.plan else{throw Failure(description:"Missing actual replay plan")}
        if squash {model.selection=Set(plan.entries.filter{$0.commit.hash==c.empty.hash || $0.commit.subject=="last"}.map(\.id));model.setAction(.squash)}
        else {model.selection=Set(plan.entries.filter{$0.commit.hash==c.empty.hash}.map(\.id));model.setAction(.edit)}
        c.begin(model)
        try await wait{!model.busy && (squash ? model.state?.squashMessage != nil:model.state?.isEditPause==true) && drained()}
        try require(model.error==nil && model.canEditMessage,"Replay did not reach editable recovery: "+(model.error ?? "nil"))
        return owner
    }
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
        try require(diagnostics.contains{$0.isSelectable && !$0.isEditable && $0.string.contains("private-amend-recovery-sentinel")},"Selectable raw Git diagnostic missing")
        try require(owner.model.cleanCommitFailure?.diagnostic.contains("private-amend-recovery-sentinel")==true,"Typed retained receipt lost Git diagnostic")
        return(sheet,retry,ignore)
    }
    static func press(_ button:NSButton)throws {guard let action=button.action else{throw Failure(description:"Native action absent")};try require(NSApp.sendAction(action,to:button.target,from:button),"Native sheet dispatch failed")}
    static func actualSheet()async throws {
        let c=try Context("sheet");do {
            try await c.seed();let owner=try await pause(c),model=owner.model
            let head=try await c.repository.rebaseCommit("HEAD"),countURL=try await hook(c)
            let indexBefore=try await c.repository.run(["write-tree"]).stdout,trackedBefore=try Data(contentsOf:c.root.appendingPathComponent("empty.txt"))
            let untracked=c.root.appendingPathComponent("untracked-private.txt"),untrackedBytes=Data("Untracked must remain untouched\n".utf8)
            try untrackedBytes.write(to:untracked)
            let draft="Uncommitted replacement draft 🦎\n\nPreserve on Retry\n"
            model.messageBinding(model.formContext).wrappedValue=draft;model.request("continue")
            let(first,retry,_)=try await sheet(c,owner)
            try require(model.cleanCommitFailure?.message==draft && model.cleanCommitFailure?.command.contains("--amend")==true,"Failure receipt lost exact draft or attempted amend command")
            try require(try count(countURL)==1,"Failed amend was unexpectedly repeated")
            try press(retry);try await wait{!model.busy && !model.hasReplayQuestion && drained()}
            let afterRetry=try await c.repository.rebaseCommit("HEAD")
            try require(first.sheetParent==nil && owner.window?.attachedSheet==nil && model.amendMessage==draft && model.canEditMessage && model.cleanCommitFailure==nil && afterRetry.hash==head.hash,"Retry did not return unchanged editable recovery")
            try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("last.txt").path),"Retry advanced the following row")
            let indexAfterRetry=try await c.repository.run(["write-tree"]).stdout,trackedAfterRetry=try Data(contentsOf:c.root.appendingPathComponent("empty.txt"))
            try require(indexAfterRetry==indexBefore && trackedAfterRetry==trackedBefore,"Retry changed staged tree or tracked working bytes")
            model.request("continue");let(second,_,ignore)=try await sheet(c,owner)
            try require(try count(countURL)==2,"Explicit Continue did not retry once")
            try press(ignore);try await wait{!model.busy && model.finished && drained()}
            let log=try await c.repository.run(["log","--format=%B","upstream..HEAD"]).text
            try require(second.sheetParent==nil && model.error==nil && log.contains("Retained middle subject") && !log.contains("Uncommitted replacement draft"),"Ignore amended the failed message or lost original history")
            try require(try count(countURL)==2,"Ignore repeated the failed amend command")
            let retainedUntracked=try Data(contentsOf:untracked),untrackedStatus=try await c.repository.run(["ls-files","--others","--exclude-standard"]).text
            try require(retainedUntracked==untrackedBytes && untrackedStatus.contains("untracked-private.txt"),"Ignore modified or staged permitted untracked content")
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    static func modes()async throws {
        for name in ["squash","cherry","dirty"] {
            let c=try Context(name);do {
                try await c.seed();let owner=try await pause(c,cherry:name=="cherry",squash:name=="squash"),model=owner.model
                if name=="squash" {
                    // A usual Squash pause has staged changes and is NOT a clean
                    // Ignore case. Explicitly clean this private recovery state;
                    // Ignore must not recreate the discarded members afterward.
                    _=try await c.repository.run(["reset","--hard","HEAD"])
                    model.refreshState();try await wait{!model.busy && model.state?.squashMessage != nil && drained()}
                }
                let before=try await c.repository.rebaseCommit("HEAD"),countURL=try await hook(c,dirty:name=="dirty")
                let beforeTree=try await c.repository.run(["write-tree"]).stdout,beforeIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout
                let witnessedPaths=["base.txt","upstream.txt","first.txt","empty.txt","last.txt"]
                func workingSnapshot()throws->[String:Data] {
                    var files=[String:Data]()
                    for path in witnessedPaths where FileManager.default.fileExists(atPath:c.root.appendingPathComponent(path).path) {files[path]=try Data(contentsOf:c.root.appendingPathComponent(path))}
                    return files
                }
                let beforeWorking=try workingSnapshot()
                var decisions=0,received:RebaseCleanCommitFailure?
                model.chooseCleanCommitFailure={failure in decisions += 1;received=failure;return .ignore}
                model.messageBinding(model.formContext).wrappedValue="Ignored \(name) draft\n";model.request("continue")
                try await wait{!model.busy && drained()}
                if name=="dirty" {
                    try require(decisions==0 && model.error?.contains("private-amend-recovery-sentinel")==true && !model.finished,"Dirty failure was offered clean Ignore or silently advanced")
                    let after=try await c.repository.rebaseCommit("HEAD"),working=try String(contentsOf:c.root.appendingPathComponent("empty.txt"),encoding:.utf8)
                    try require(after.hash==before.hash && working.contains("dirty after failed hook"),"Dirty failure reset user work or HEAD")
                }else {
                    let after=try await c.repository.rebaseCommit("HEAD")
                    try require(received?.head==before.hash,"Receipt HEAD changed")
                    try require(decisions==1 && model.finished && model.error==nil && !after.message.contains("Ignored \(name) draft"),"Clean \(name) Ignore did not advance without failed message")
                    try require(try count(countURL)==1,"Clean \(name) Ignore reran commit")
                    if name=="cherry" {try require(after.author==c.empty.author && after.date==c.empty.date && after.message.contains("(cherry picked from commit "+c.empty.hash+")"),"Advanced Cherry Pick Ignore lost retained original author/date/attribution")}
                    if name=="squash" {
                        try require(after.hash==before.hash && after.author==before.author && after.date==before.date,"Clean Squash Ignore rewrote the retained HEAD/author/date")
                        let afterTree=try await c.repository.run(["write-tree"]).stdout,afterIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout,afterWorking=try workingSnapshot()
                        try require(afterTree==beforeTree && afterIndex==beforeIndex && afterWorking==beforeWorking,"Clean Squash Ignore changed the captured staged tree/index or working file presence/bytes")
                    }
                }
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func ownership()async throws {
        let reopen=try Context("reopen");do {
            try await reopen.seed();let owner=try await pause(reopen),model=owner.model,countURL=try await hook(reopen)
            model.chooseCleanCommitFailure={_ in await withCheckedContinuation{continuation in reopen.held.append{continuation.resume(returning:.retry)}}}
            let draft="Retained reopened amend draft\n";model.messageBinding(model.formContext).wrappedValue=draft;model.request("continue")
            try await wait{model.cleanCommitFailure != nil && !reopen.held.isEmpty && model.hasReplayQuestion}
            let witness=model.cleanCommitFailure!,head=try await reopen.repository.rebaseCommit("HEAD")
            model.retire();owner.close();reopen.held.removeFirst()();try await wait{!model.busy && drained()}
            let replacement=try await reopen.open()
            try require(replacement.model.cleanCommitFailure==witness && replacement.model.amendMessage==draft,"Reopen lost durable failure or draft")
            replacement.model.chooseCleanCommitFailure={_ in .ignore};replacement.model.request("continue")
            try await wait{!replacement.model.busy && replacement.model.finished && drained()}
            try require(try count(countURL)==1,"Reopened Ignore retried failed amend")
            try require(!(try await reopen.repository.rebaseState()).active && head.hash != reopen.originalHead,"Reopen did not retain/finish intended session")
            await reopen.cleanup()
        }catch{await reopen.cleanup();throw error}
        for route in ["retire","stale","cancel"] {
            let c=try Context(route);do {
                try await c.seed();let owner=try await pause(c),model=owner.model,countURL=try await hook(c)
                model.chooseCleanCommitFailure={_ in await withCheckedContinuation{continuation in c.held.append{continuation.resume(returning:.ignore)}}}
                model.messageBinding(model.formContext).wrappedValue="Held draft \(route)\n";model.request("continue")
                try await wait{!c.held.isEmpty && model.hasReplayQuestion}
                let before=try await c.repository.rebaseCommit("HEAD")
                if route=="retire" {model.retire();owner.close()}
                if route=="stale" {_=try await c.repository.abortRebase()}
                if route=="cancel" {
                    model.cancelReplay()
                    try require(model.hasReplayQuestion && !model.cancellingReplay,"Running cancel bypassed owned recovery sheet")
                    model.retire();owner.close()
                }
                c.held.removeFirst()();try await wait{!model.busy && drained()}
                let after=try await c.repository.rebaseCommit("HEAD")
                try require(try count(countURL)==1,"Late response repeated failed commit")
                if route=="stale" {try require(after.hash==c.originalHead && !model.completedSuccessfully,"Stale Ignore changed replacement session or reported success")}
                else {try require(after.hash==before.hash && !model.finished,"Retired/cancelled answer advanced replay")}
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.amendRecoveryOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let mode=CommandLine.arguments[3]
        switch mode {case "sheet":try await actualSheet();case "modes":try await modes();case "ownership":try await ownership();default:throw Failure(description:"Unknown amend recovery case")}
        print("PASS: Rebase amend recovery "+mode)
    }
}
