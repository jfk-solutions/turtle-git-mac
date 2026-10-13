import AppKit
import TurtleGitCore

@main struct BlameFindVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ description:String) throws { if !condition { throw Failure(description:description) } }
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Find state did not settle")
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
        let owner=BlameWindowController(repository:repo,access:nil,path:"search.txt",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { owner.close() }
        let model=owner.model,window=owner.window!
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
        view.setSelectedRange(string.range(of:"needle"));try await wait { model.selectedSourceText?()=="needle" }
        model.onFind?();guard let panel=owner.findWindow else { throw Failure(description:"Find panel did not reopen") }
        try require(panel.draft.text=="needle" && !panel.draft.matchCase,"Reopen draft/source preference mismatch")
        try await wait { (panel.window?.firstResponder as? NSTextView)?.isFieldEditor==true }
        model.goToLine(1);try require(model.selection==1 && panel.window?.isVisible==true && window.attachedSheet==nil,"Modeless Find blocked parent navigation")
        panel.draft.matchCase=true;panel.search();try await wait { model.selection==2 && string.substring(with:view.selectedRange())=="needle 雪\n" }
        try require(GitBlameFindPreferences.load(from:prefs)==GitBlameFindPreferences(text:"needle",matchCase:true),"Applied query not stored privately")
        panel.search();try await wait { model.selection==4 }
        panel.search();try await wait { model.selection==2 && panel.flashCount==1 }
        try require(model.navigationMessage.contains("Wrapped"),"Wrap feedback absent")
        try await wait { panel.window?.contentView?.layer?.borderWidth==2 }
        panel.draft.text="not present";panel.search()
        try await wait { model.searchFeedbackBusy && owner.findAlert?.window.sheetParent === panel.window }
        guard let alert=owner.findAlert else { throw Failure(description:"Missing native no-match alert") }
        try require(alert.alertStyle == .informational && alert.informativeText=="\"not present\" was not found." && alert.buttons.count==1,"Native no-match feedback differs")
        let selection=model.selection,message=model.navigationMessage
        model.findLine(previous:true);panel.window?.performClose(nil);window.performClose(nil)
        try require(model.selection==selection && model.navigationMessage==message && !model.retired && owner.findWindow===panel,"Alert did not gate search/ordinary close")
        alert.buttons[0].performClick(nil);try await wait { !model.searchFeedbackBusy && owner.findAlert==nil && panel.window?.attachedSheet==nil }
        panel.draft.text="draft not applied";panel.window?.performClose(nil);try await wait { owner.findWindow==nil }
        try require(model.find=="not present","Cancel overwrote last applied search")
        // Parent retirement closes an active native alert/panel and fences late UI work.
        model.onFind?();guard let retiring=owner.findWindow else { throw Failure(description:"Retirement panel missing") }
        retiring.draft.text="absent again";retiring.search();try await wait { owner.findAlert?.window.sheetParent != nil }
        let saved=GitBlameFindPreferences.load(from:prefs)
        owner.close();try await wait { model.retired && !model.searchFeedbackBusy && owner.findWindow==nil && owner.findAlert==nil }
        model.applyFind(text:"late mutation",matchCase:false,previous:false);model.goToLine(5)
        try require(GitBlameFindPreferences.load(from:prefs)==saved && GitBlameFindPreferences.load()==global,"Retired search or private fixture changed unrelated defaults")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        try require(afterHead==head && afterIndex==index && afterFile==Data(contents.utf8),"Find changed repository bytes")
        print("Blame Find: private selection draft/Cancel/reopen, modeless reuse and parent interaction, field focus, whole-line selection, native wrap pulse, actual no-match information sheet and close/search guards, parent retirement/late fencing, defaults isolation and HEAD/index/file preservation passed. All owned panels/sheets closed.")
    }
}
