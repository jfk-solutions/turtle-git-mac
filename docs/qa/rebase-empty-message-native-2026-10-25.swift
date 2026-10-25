// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func emptyMessageOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));emptyMessageOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RebaseEmptyMessageVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Rebase empty message \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase empty message timeout \(line)")}
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
        var held:[CheckedContinuation<Bool,Never>]=[]
        var empty:LogEntry!,originalHead=""
        init(_ name:String)throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent(name,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.EmptyMessage."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"Gravatar");prefs.set(false,forKey:"ConfirmKillProcess")
            editor=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"]!)
        }
        func commit(_ path:String,_ message:String)async throws->LogEntry {
            try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path])
            let file=root.appendingPathComponent(".git/empty-native-message");try Data(message.utf8).write(to:file)
            _=try await repository.run(["commit","--allow-empty-message","--cleanup=verbatim","-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":path=="empty.txt" ? "Empty Native Author":"Other Native Author","GIT_AUTHOR_EMAIL":"empty-native@example.invalid","GIT_AUTHOR_DATE":path=="empty.txt" ? "2026-10-12T10:00:00+0200":"2026-10-10T10:00:00+0200"])
            try FileManager.default.removeItem(at:file);return try await repository.rebaseCommit("HEAD")
        }
        func seed(_ message:String="")async throws {
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
            for answer in held {answer.resume(returning:false)};held=[]
            for owner in owners {owner.model.retire();owner.close()}
            try? await wait{drained()}
            if (try? await repository.rebaseState().active)==true {_=try? await repository.abortRebase()}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func review()async throws {
        let c=try Context("review");do {
            try await c.seed("\nBody retained for explicit review\n")
            let owner=try await c.open(),model=owner.model
            c.begin(model)
            try await wait{owner.window?.attachedSheet != nil && model.hasReplayQuestion}
            let sheet=owner.window!.attachedSheet!,content=sheet.contentView!
            // NSAlert.Style.warning is checked in the controller's source
            // wiring; inspect the actual sheet through public views/actions
            // without reaching into AppKit or the owner's private alert state.
            let fields=views(content).compactMap{$0 as? NSTextField}.map(\.stringValue)
            let buttons=views(content).compactMap{$0 as? NSButton}.filter{!$0.title.isEmpty}
            let state=try await c.repository.rebaseState()
            try require(fields.contains("Found an empty commit message. You have to enter one or rebase cannot proceed."),"Actual controller warning lost source text")
            let buttonDiagnostics=buttons.map { button in
                "title="+String(reflecting:button.title)+",key="+String(reflecting:button.keyEquivalent)+",unicode="+button.keyEquivalent.unicodeScalars.map{String(format:"U+%04X",$0.value)}.joined(separator:",")+",defaultCell="+String(sheet.defaultButtonCell === button.cell)+",enabled="+String(button.isEnabled)+",hidden="+String(button.isHidden)+",hiddenAncestor="+String(button.isHiddenOrHasHiddenAncestor)
            }.joined(separator:"; ")
            // AppKit clears a duplicate Return key equivalent when the sheet
            // owns the button's default cell. Verify the actual default action.
            try require(buttons.count==1 && buttons[0].title=="OK" && buttons[0].isEnabled && sheet.defaultButtonCell === buttons[0].cell,"Actual warning did not have one default OK; count=\(buttons.count); buttons=[\(buttonDiagnostics)]")
            try require(sheet.alphaValue==0 && sheet.sheetParent===owner.window && state.emptyMessageWarning?.commit==c.empty.hash,"Warning was not the hidden owned pre-entry sheet")
            try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("empty.txt").path),"Warning applied the empty row before acknowledgement")
            guard let action=buttons[0].action else{throw Failure(description:"Actual OK has no action")}
            try require(NSApp.sendAction(action,to:buttons[0].target,from:buttons[0]),"Actual warning OK did not dispatch")
            try await wait{!model.busy && model.state?.isEditPause==true && drained()}
            try require(sheet.sheetParent==nil && owner.window?.attachedSheet==nil && model.error==nil,"Actual warning did not detach/drain into Edit")
            try require(model.amendMessage.contains("Body retained") && model.replayMessageCommit?.author==c.empty.author,"Review lost raw body/author")
            try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("last.txt").path),"Future row applied before review")
            let id=model.replayMessageEditorID,draft="Approved empty subject\n\nBody kept\n",stale=model.messageBinding(model.formContext)
            stale.wrappedValue=draft;model.refreshState();try await wait{!model.busy && drained()}
            try require(model.amendMessage==draft && model.replayMessageEditorID==id,"Refresh replaced editable draft/Undo owner")
            owner.close();try await wait{drained()}
            let reopened=try await c.open(),next=reopened.model
            try require(next.amendMessage==draft && next.state?.isEditPause==true,"Reopen lost persisted empty-message draft")
            stale.wrappedValue="Retired editor must not write"
            try require(next.amendMessage==draft,"Retired binding changed reopened draft")
            next.request("continue");try await wait{!next.busy && next.finished && drained()}
            let approved=try await c.repository.rebaseCommit("HEAD~1")
            try require(approved.subject=="Approved empty subject" && approved.author==c.empty.author && approved.date==c.empty.date,"Continue lost approved message/author/date")
            try require(next.error==nil,"Reviewed replay failed")
            await c.cleanup()
        }catch {await c.cleanup();throw error}
    }
    static func sequence()async throws {
        let c=try Context("sequence");do {
            try await c.seed();let owner=try await c.open(),model=owner.model
            let empty=c.empty!,id=model.plan!.entries.first{$0.commit.hash==empty.hash}!.id
            model.selection=[id];model.setAction(.skip)
            var questions=0;model.confirmEmptyMessageReview={questions+=1;return true}
            c.begin(model);try await wait{!model.busy && model.finished && drained()}
            try require(questions==0 && model.error==nil,"Skipped empty subject warned")
            try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("empty.txt").path),"Skipped empty subject applied")
            await c.cleanup()
        }catch {await c.cleanup();throw error}
        let cherry=try Context("cherry");do {
            try await cherry.seed();_=try await cherry.repository.run(["switch","main"])
            let owner=try await cherry.open(cherryPick:[cherry.empty.hash]),model=owner.model
            var questions=0;model.confirmEmptyMessageReview={questions+=1;return true}
            cherry.begin(model);try await wait{!model.busy && model.state?.isEditPause==true && drained()}
            try require(questions==1 && model.state?.isCherryPick==true && model.replayMessageCommit?.author==cherry.empty.author,"Cherry Pick missed source warning/author")
            model.messageBinding(model.formContext).wrappedValue="Approved native cherry"
            model.request("continue");try await wait{!model.busy && model.finished && drained()}
            let head=try await cherry.repository.rebaseCommit("HEAD")
            try require(head.subject=="Approved native cherry" && head.date==cherry.empty.date,"Cherry Pick approval lost message/date")
            await cherry.cleanup()
        }catch {await cherry.cleanup();throw error}
        let group=try Context("group");do {
            try await group.seed("\nEmpty native middle body\n");let owner=try await group.open(),model=owner.model
            let ids=Set(model.plan!.entries.filter{$0.commit.hash==group.empty.hash || $0.commit.subject=="last"}.map(\.id))
            model.selection=ids;model.setAction(.squash)
            var questions=0;model.confirmEmptyMessageReview={questions+=1;return true}
            group.begin(model);try await wait{!model.busy && model.state?.squashMessage != nil && drained()}
            try require(questions==1 && model.canEditMessage && !FileManager.default.fileExists(atPath:group.root.appendingPathComponent("last.txt").path),"Middle empty Squash did not stop before following member")
            model.messageBinding(model.formContext).wrappedValue="Reviewed middle group\n\nEmpty native middle body\n"
            model.request("continue")
            try await wait{!model.busy && model.state?.squashMessage != nil && FileManager.default.fileExists(atPath:group.root.appendingPathComponent("last.txt").path) && drained()}
            let combined=model.amendMessage
            try require(combined.components(separatedBy:"Empty native middle body").count-1==1 && combined.contains("last"),"Intermediate native review duplicated body or lost next group member")
            let approved=combined.replacingOccurrences(of:"Reviewed middle group",with:"Reviewed complete native group")
            model.messageBinding(model.formContext).wrappedValue=approved
            model.request("continue");try await wait{!model.busy && model.finished && drained()}
            let head=try await group.repository.rebaseCommit("HEAD")
            try require(head.subject=="Reviewed complete native group" && head.author=="Other Native Author" && head.message.trimmingCharacters(in:.newlines)==approved.trimmingCharacters(in:.newlines) && head.message.components(separatedBy:"Empty native middle body").count-1==1 && model.error==nil,"Squash approval lost original first-author grouping")
            await group.cleanup()
        }catch {await group.cleanup();throw error}
    }
    static func ownership()async throws {
        for route in ["decline","retire","changed"] {
            let c=try Context(route);do {
                try await c.seed();let owner=try await c.open(),model=owner.model
                model.confirmEmptyMessageReview={await withCheckedContinuation{c.held.append($0)}}
                c.begin(model);try await wait{!c.held.isEmpty && model.hasReplayQuestion}
                let state=try await c.repository.rebaseState(),head=try await c.repository.rebaseCommit("HEAD")
                try require(state.emptyMessageWarning?.commit==c.empty.hash && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("empty.txt").path),"Held warning applied commit")
                if route=="retire" {model.retire();owner.close()}
                if route=="changed" {_=try await c.repository.abortRebase()}
                let reply=c.held.removeFirst();reply.resume(returning:route != "decline")
                try await wait{!model.busy && drained()}
                let after=try await c.repository.rebaseCommit("HEAD")
                try require(after.hash==(route=="changed" ? c.originalHead:head.hash),"Late/declined warning mutated HEAD")
                if route=="decline" {
                    try require(model.state?.emptyMessageWarning != nil && !model.retired,"Decline abandoned recoverable session")
                    model.confirmEmptyMessageReview={true};model.request("continue")
                    try await wait{!model.busy && model.state?.isEditPause==true && drained()}
                    try require(model.error==nil,"Explicit retry after decline failed")
                }
                await c.cleanup()
            }catch {await c.cleanup();throw error}
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.emptyMessageOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let mode=CommandLine.arguments[3]
        switch mode {case "review":try await review();case "sequence":try await sequence();case "ownership":try await ownership();default:throw Failure(description:"Unknown empty-message case")}
        print("PASS: Rebase empty message "+mode)
    }
}
