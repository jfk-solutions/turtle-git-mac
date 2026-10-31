import AppKit
import Darwin
import TurtleGitCore

@main struct BlameFindVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    final class ScopeProvider:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{starts+=1;return true}
        func stopAccessing(_ url:URL){stops+=1}
    }
    static func require(_ condition:Bool,_ description:String) throws { if !condition {print("Blame Find assertion: "+description);fflush(stdout); throw Failure(description:description) } }
    @MainActor static var phase="initial document"
    @MainActor static func wait(_ condition:@escaping ()->Bool,line:Int = #line) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Find state did not settle: line=\(line) phase=\(phase)")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Blame Find failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Find QA"),("user.email","find@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let contents="alpha\nneedle 雪\nomega\nneedle second\nfinal without LF",file=root.appendingPathComponent("search.txt")
        try Data(contents.utf8).write(to:file);try await repo.stage(["search.txt"]);_ = try await repo.commit(message:"Find baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let name="TurtleGit.Find.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        GitBlameFindPreferences(text:"alpha",matchCase:false).save(to:prefs)
        let global=GitBlameFindPreferences.load()
        let scopeProvider=ScopeProvider()
        var scope:RepositoryAccessLease?=RepositoryAccessLease(url:root,provider:scopeProvider)
        weak var scopeWitness=scope
        let owner=BlameWindowController(repository:repo,access:scope,path:"search.txt",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        scope=nil
        defer { owner.close() }
        let model=owner.model,window=owner.window!
        window.alphaValue=0;window.ignoresMouseEvents=true
        window.contentView?.layoutSubtreeIfNeeded()
        func source()->NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        try await wait { !model.busy && !model.syntaxWorking && source()?.string==contents }
        let view=source()!,string=contents as NSString
        view.setSelectedRange(string.range(of:"雪"));try await wait { model.selectedSourceText?()=="雪" }
        model.onFind?();guard let first=owner.findWindow else { throw Failure(description:"Find panel not created") }
        try require(first.draft.text=="雪" && model.find=="alpha" && GitBlameFindPreferences.load(from:prefs).text=="alpha","Selection prefill changed applied query")
        first.draft.text="cancelled draft";first.draft.matchCase=true
        model.onFind?();try require(owner.findWindow===first && first.draft.text=="cancelled draft","Repeated Find replaced its modeless panel/draft")
        first.window?.performClose(nil);try await wait { owner.findWindow==nil }
        try require(window.childWindows?.isEmpty != false && model.find=="alpha","Cancel retained child or changed applied query")
        let closedSelection=model.selection,closedPreferences=GitBlameFindPreferences.load(from:prefs),closedFlash=first.flashCount
        let foreignModel=BlameWindowModel(repository:repo,access:nil,path:"search.txt",revision:"HEAD",labelDefaults:prefs)
        first.search();first.flash();first.rebind(foreignModel)
        try require(first.retired && first.model==nil && !first.hasPendingWork && first.flashCount==closedFlash && model.selection==closedSelection && GitBlameFindPreferences.load(from:prefs)==closedPreferences && owner.findWindow==nil,"Retained closed Find callbacks searched/rebound/flashed the live document")
        foreignModel.retire()
        view.setSelectedRange(string.range(of:"needle"));try await wait { model.selectedSourceText?()=="needle" }
        model.onFind?();guard let panel=owner.findWindow else { throw Failure(description:"Find panel did not reopen") }
        try require(panel.draft.text=="needle" && !panel.draft.matchCase,"Reopen draft/source preference mismatch")
        try await wait { (panel.window?.firstResponder as? NSTextView)?.isFieldEditor==true }
        model.goToLine(1);try await wait{view.selectedRange().location==0};try require(model.selection==1 && panel.window?.isVisible==true && window.attachedSheet==nil,"Modeless Find blocked parent navigation")
        panel.draft.matchCase=true;panel.search();try await wait { model.selection==2 && string.substring(with:view.selectedRange())=="needle 雪\n" }
        try require(GitBlameFindPreferences.load(from:prefs)==GitBlameFindPreferences(text:"needle",matchCase:true),"Applied query not stored privately")
        panel.search();try await wait { model.selection==4 && string.substring(with:view.selectedRange())=="needle second\n" }
        panel.search();try await wait { model.selection==2 && string.substring(with:view.selectedRange())=="needle 雪\n" }
        try require(panel.flashCount==0,"Terminal current-row normalization incorrectly reported traversal wrap")
        phase="actual manual caret / inclusive current-row Find / repeated progression"
        window.makeFirstResponder(view);view.setSelectedRange(NSRange(location:string.range(of:"needle second").location,length:0))
        try await wait{model.selection==4 && model.sourceSearchCaretRow?()==3};panel.search()
        try await wait{model.selection==4 && string.substring(with:view.selectedRange())=="needle second\n"}
        try require(panel.flashCount==0 && model.sourceSearchCaretRow?()==4,"Find skipped actual current-row match, lost active end, or invented a wrap")
        panel.search();try await wait{model.selection==2 && string.substring(with:view.selectedRange())=="needle 雪\n"}
        // Previous begins two rows before the accepted selection's native end;
        // this traverses the file boundary and therefore really wraps to row 4.
        panel.draft.previous=true;panel.search()
        try await wait { model.selection==4 && panel.flashCount==1 && string.substring(with:view.selectedRange())=="needle second\n" }
        try require(model.navigationMessage.contains("Wrapped"),"Wrap feedback absent")
        try await wait { panel.window?.contentView?.layer?.borderWidth==2 }
        let beforeNoMatchFlash=panel.flashCount
        panel.draft.text="not present";panel.search()
        try await wait { model.searchFeedbackBusy && owner.findAlert?.window.sheetParent === panel.window }
        guard let alert=owner.findAlert else { throw Failure(description:"Missing native no-match alert") }
        try require(panel.flashCount==beforeNoMatchFlash+1,"Failed full-file traversal did not pulse exactly once before native Not Found feedback")
        try require(alert.alertStyle == .informational && alert.informativeText=="\"not present\" was not found." && alert.buttons.count==1,"Native no-match feedback differs")
        let selection=model.selection,message=model.navigationMessage
        model.findLine(previous:true);panel.window?.performClose(nil);window.performClose(nil)
        try require(model.selection==selection && model.navigationMessage==message && !model.retired && owner.findWindow===panel,"Alert did not gate search/ordinary close")
        alert.buttons[0].performClick(nil);try await wait { !model.searchFeedbackBusy && owner.findAlert==nil && panel.window?.attachedSheet==nil }
        panel.draft.text="draft not applied";panel.window?.performClose(nil);try await wait { owner.findWindow==nil }
        try require(model.find=="not present","Cancel overwrote last applied search")
        // Parent retirement closes an active native alert/panel and fences late UI work.
        phase="held actual feedback / early duplicate response / root retirement"
        let ordinaryFeedback=owner.presentFindFeedback
        var feedbackReply:((NSApplication.ModalResponse)->Void)?
        defer{owner.presentFindFeedback=ordinaryFeedback;feedbackReply=nil}
        owner.presentFindFeedback={alert,parent,reply in feedbackReply=reply;parent.beginSheet(alert.window,completionHandler:{_ in})}
        model.onFind?();guard let retiring=owner.findWindow else { throw Failure(description:"Retirement panel missing") }
        retiring.draft.text="absent again";retiring.search();try await wait { owner.findAlert?.window.sheetParent != nil }
        let retiringAlert=owner.findAlert!,retiringParent=retiring.window!,retiringSelection=model.selection,retiringMessage=model.navigationMessage
        feedbackReply?(.OK);feedbackReply?(.cancel)
        try require(owner.findAlert === retiringAlert && retiringAlert.window.sheetParent === retiringParent && retiringParent.attachedSheet === retiringAlert.window && model.searchFeedbackBusy && owner.navigationWorkPending && BlameWindowController.activeNavigationOperations>0,"Early/duplicate feedback answer released the actual attached sheet")
        try require(scopeWitness != nil && model.repositoryAccess === scopeWitness && scopeProvider.starts==1 && scopeProvider.stops==0,"Pending feedback lost its captured document permission")
        model.confirmingQuit=true;retiring.search();model.goToLine(5)
        try require(model.selection==retiringSelection && model.navigationMessage==retiringMessage && owner.navigationWorkPending,"Quit admission allowed navigation through pending feedback")
        model.confirmingQuit=false
        let saved=GitBlameFindPreferences.load(from:prefs)
        var closed=0;owner.onClosed={closed+=1}
        owner.close()
        try require(model.retired && owner.navigationWorkPending && BlameWindowController.activeNavigationOperations>0 && closed==0 && scopeWitness != nil && scopeProvider.stops==0,"Root closed/released permission before accepted feedback/native Find retirement drained")
        try await wait { model.retired && !model.searchFeedbackBusy && owner.findWindow==nil && owner.findAlert==nil && !owner.navigationWorkPending && BlameWindowController.activeNavigationOperations==0 && closed==1 }
        feedbackReply?(.OK);feedbackReply?(.cancel);retiring.draft.text="retired panel callback";retiring.search();retiring.flash();retiring.rebind(foreignModel)
        model.applyFind(text:"late mutation",matchCase:false,previous:false);model.goToLine(5)
        try require(GitBlameFindPreferences.load(from:prefs)==saved && GitBlameFindPreferences.load()==global,"Retired search or private fixture changed unrelated defaults")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        try require(afterHead==head && afterIndex==index && afterFile==Data(contents.utf8),"Find changed repository bytes")
        print("Blame Find: private selection draft/Cancel/reopen, modeless reuse and parent interaction, field focus, whole-line selection, native wrap pulse, actual no-match information sheet and close/search guards, parent retirement/late fencing, defaults isolation and HEAD/index/file preservation passed. All owned panels/sheets closed.")
    }
}
