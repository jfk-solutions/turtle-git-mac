// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func issueConsumerOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));issueConsumerOrder(mode,relativeTo:number)
    }
}
@MainActor
@main enum IssueRegexConsumersVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ text:String,line:UInt = #line)throws {if !condition {throw Failure(description:"Issue consumers \(line): \(text)")}}
    static func wait(line:UInt = #line,_ condition:()->Bool)async throws {for _ in 0..<3000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Issue consumers timeout \(line)")}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.IssueConsumers."+UUID().uuidString,prefs:UserDefaults
        var commits=[CommitWindowController](),logs=[LogWindowController]()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"CommitMessageContainsConflictHint")}
        var repo:GitRepository {GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))}
        func prepare()async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Issue QA"),("user.email","issue@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("bugtraq.message","Issue: %BUGID%"),("bugtraq.url","https://issues.invalid/%BUGID%"),("bugtraq.warnifnoissue","true")] {_=try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Base #42")
            try Data("working\n".utf8).write(to:root.appendingPathComponent("file"))
        }
        func pattern(_ value:String)async throws {_=try await repo.run(["config","bugtraq.logregex",value])}
        func owner()async throws->CommitWindowController {
            let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);commits.append(owner);owner.window?.isReleasedWhenClosed=false;owner.showWindow(nil);owner.model.reload(paths:["."])
            try await IssueRegexConsumersVerification.wait {!owner.model.busy && owner.model.changelistsLoaded && owner.model.canReceiveFileDrop}
            try IssueRegexConsumersVerification.require(owner.model.error==nil,owner.model.error ?? "Load failed")
            owner.model.checked=["file"];owner.model.message="Draft #42";try await IssueRegexConsumersVerification.wait {owner.model.canCommit};return owner
        }
        func cleanup()async throws {
            defer {prefs.removePersistentDomain(forName:suite)}
            for owner in commits {owner.model.message="";owner.model.invalidateForClose();owner.close()}
            for owner in logs {owner.model.invalidate();owner.close()}
            try await IssueRegexConsumersVerification.wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeCommitPreflights==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeReferenceReads==0 && MessageEditorStylingSession.activeOperations==0 && IssueRegexTesterModel.activeRequests==0}
        }
    }
    static func commit(_ c:Context)async throws {
        try await c.pattern("(")
        let owner=try await c.owner(),model=owner.model
        try require(model.issueProperties.checkExpression=="(","Initial configured malformed expression was not loaded")
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        var warnings=0,answer:((Bool)->Void)?
        defer {answer?(false)}
        model.confirmMissingIssue={callback in warnings += 1;answer=callback}
        model.commit();try await wait {answer != nil}
        try require(model.busy && model.message=="Draft #42","Missing-issue question lost draft/busy ownership")
        answer?(false);answer=nil;try await wait {!model.busy && !model.attemptWorkPending}
        let unchanged=try await c.repo.run(["rev-parse","HEAD"]).stdout
        let afterIndex=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try require(unchanged==head && index==afterIndex && model.error==nil,"Declined malformed-check warning mutated Git or became regex failure")
        var committed=0,progress:CommitProgressWindowModel?
        let present=model.onCommitProgress;model.onCommitProgress={value in progress=value;present?(value)};model.onCommitted={_ in committed += 1}
        model.commit();try await wait {answer != nil};answer?(true);answer=nil
        try await wait {progress?.busy==false || model.error != nil}
        try require(progress?.success==true && model.error==nil,"Accepted malformed-check commit failed: \(model.error ?? progress?.output ?? "no output")")
        progress?.choose(nil);try await wait {!model.attemptWorkPending}
        let message=try await c.repo.run(["log","-1","--format=%B"]).stdout
        try require(committed==1 && warnings==2 && String(decoding:message,as:UTF8.self).hasPrefix("Draft #42"),"Accepted warning did not create exact private commit")
        // A valid check matches even when the second expression cannot compile.
        try Data("second\n".utf8).write(to:c.root.appendingPathComponent("file"));try await c.pattern("#[0-9]+\n(")
        let second=try await c.owner(),next=second.model
        var unexpectedWarnings=0;next.confirmMissingIssue={callback in unexpectedWarnings += 1;callback(false)}
        var secondCommit=0,nextProgress:CommitProgressWindowModel?
        let presentNext=next.onCommitProgress;next.onCommitProgress={value in nextProgress=value;presentNext?(value)};next.onCommitted={_ in secondCommit += 1};next.commit()
        try await wait {nextProgress?.busy==false || next.error != nil || unexpectedWarnings>0}
        try require(unexpectedWarnings==0 && next.error==nil && nextProgress?.success==true,"Invalid extraction suppressed valid check or blocked commit: \(next.error ?? "")")
        nextProgress?.choose(nil);try await wait {!next.attemptWorkPending}
        try require(secondCommit==1,"Second actual commit did not complete")
    }
    static func log(_ c:Context)async throws {
        let owner=LogWindowController(repository:c.repo,access:nil,labelDefaults:c.prefs,savesColumnLayout:false,savesGeometry:false);c.logs.append(owner);owner.window?.isReleasedWhenClosed=false;owner.showWindow(nil);owner.model.showWorkingTree=false
        for pattern in ["(","#[0-9]+\n(","#([0-9]+)"] {
            try await c.pattern(pattern);owner.model.reload();try await wait {!owner.model.busy && LogWindowModel.activeHistoryLoads==0}
            try require(owner.model.error==nil && owner.model.entries.count==1,"Configured syntax failure blocked actual Log history: \(owner.model.error ?? "")")
            try require(owner.model.issueProperties.showsBugIDColumn,"Configured issue column disappeared")
            try require(owner.model.entries[0].issueIDs == (pattern=="#([0-9]+)" ? "42":""),"Log IDs did not recover from configured pattern change")
        }
        let m=try await c.owner();m.model.issueID="";m.model.message="Inserted #42";m.model.updateIssueFromHistory("History #42",insertedInto:m.model.message)
        try await wait {m.model.issueID=="42"}
        var p=m.model.issueProperties;p.extractionExpression="(";m.model.issueProperties=p;m.model.issueID="91";m.model.updateIssueFromHistory("History #42",insertedInto:m.model.message)
        // Subsequent valid history extraction is the barrier for the cancelled/invalid request.
        p.extractionExpression="";m.model.issueProperties=p;m.model.updateIssueFromHistory("History #7",insertedInto:m.model.message);try await wait {m.model.issueID=="7"}
        try require(m.model.message=="Inserted #42" && m.model.error==nil,"History processing rewrote draft or raised blocking error")
        p.checkExpression="(";m.model.issueProperties=p;m.model.message="Draft #42 https://example.invalid/path"
        try await wait {m.model.issueMessageStyles.contains {$0.kind == .url} && m.messageEditor()?.string==m.model.message}
        guard let editor=m.messageEditor() else {throw Failure(description:"Actual native Commit editor missing")}
        let urlRange=(editor.string as NSString).range(of:"https://example.invalid/path")
        try await wait {editor.textStorage?.attribute(.link,at:urlRange.location,effectiveRange:nil) != nil}
        try require(editor.isEditable && m.model.error==nil,"Malformed issue rule blocked editable URL styling")
        editor.setSelectedRange(.init(location:3,length:0));p.checkExpression="#([0-9]+)";m.model.issueProperties=p
        try await wait {m.model.issueMessageStyles.contains {$0.kind == .identifier} && editor.textStorage?.attribute(.link,at:7,effectiveRange:nil) != nil}
        try require(editor.selectedRange().location==3 && editor.string==m.model.message,"Regex recovery changed native caret or draft")
    }
    static func ownership(_ c:Context)async throws {
        try await c.pattern("#([0-9]+)");let owner=try await c.owner(),model=owner.model
        var held:CheckedContinuation<String,Never>?,token:OperationCancellation?,finished=0
        defer {held?.resume(returning:"99")}
        model.queryHistoryIssue={_,_,value in token=value;let result=await withCheckedContinuation {held=$0};finished += 1;return result}
        model.message="Inserted #42";model.issueID="5";model.updateIssueFromHistory("History #99",insertedInto:model.message);try await wait {held != nil}
        model.message="Newer draft";try require(token?.isCancelled==true,"New draft did not cancel history extraction")
        held?.resume(returning:"99");held=nil;try await wait {finished==1};try require(model.issueID=="5","Stale history response changed ID")
        model.updateIssueFromHistory("History #99",insertedInto:model.message);try await wait {held != nil};model.invalidateForClose();held?.resume(returning:"99");held=nil;try await wait {finished==2}
        try require(model.issueID=="5" && !model.messageFocusAvailable,"Closed owner accepted history result");owner.close()
        try await c.pattern("(")
        let late=try await c.owner(),head=try await c.repo.run(["rev-parse","HEAD"]).stdout
        var lateAnswer:((Bool)->Void)?;defer {lateAnswer?(false)}
        late.model.confirmMissingIssue={lateAnswer=$0};late.model.commit();try await wait {lateAnswer != nil}
        late.model.invalidateForClose();late.close();lateAnswer?(true);lateAnswer=nil
        try await wait {CommitWindowModel.activeCommitPreflights==0}
        let after=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && !late.model.messageFocusAvailable,"Late missing-issue answer started retired commit")
        // Retained strict tester includes actual native editor, last valid PAIR,
        // failed compile recovery, late worker cancellation and close completion.
        try await IssueRegexTesterVerification.verify()
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.issueConsumerOrder(_:relativeTo:))) {method_exchangeImplementations(original,replacement)}
        let c=Context()
        do {try await c.prepare();switch CommandLine.arguments[3] {case "commit":try await commit(c);case "log":try await log(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown case")};try await c.cleanup();print("PASS: Issue regex consumers \(CommandLine.arguments[3])")}
        catch {try? await c.cleanup();fputs("Issue consumers failed: \(error)\n",stderr);exit(1)}
    }
}
