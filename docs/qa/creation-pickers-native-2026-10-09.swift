import AppKit
import SwiftUI
import TurtleGitCore

@main struct CreationPickerVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func find<T:NSView>(_ type:T.Type,_ view:NSView,label:String?=nil)->T? {
        if let result=view as? T,label==nil || result.accessibilityLabel()==label { return result }
        for child in view.subviews { if let result=find(type,child,label:label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows:[NSWindow],_ ready:()->Bool) async throws {
        for _ in 0..<3000 { windows.forEach{$0.contentView?.layoutSubtreeIfNeeded()}; if ready(){return}; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"Timed out")
    }
    static func phase(_ message:String) { print("PHASE: "+message); fflush(stdout) }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite="TurtleGit.CreationPickers.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:URL(fileURLWithPath:CommandLine.arguments[1]),executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Creation Picker QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        func commit(_ message:String) async throws -> String { _ = try await repo.run(["commit","--allow-empty","-m",message]); return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"])
        let base=try await commit("base"),prior=try await commit("prior"),head=try await commit("latest")
        for name in ["refs/heads/nested/topic","refs/remotes/origin/team/topic","refs/notes/custom"] { _ = try await repo.run(["update-ref",name,base]) }
        _ = try await repo.run(["tag","release",prior]); _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/team/topic"])
        let nfc="refs/heads/Café",nfd="refs/heads/Cafe\u{301}"
        _ = try await repo.run(["update-ref",nfc,base]); _ = try await repo.run(["pack-refs","--all","--prune"])
        let packed=root.appendingPathComponent(".git/packed-refs")
        var contents=try String(contentsOf:packed,encoding:.utf8); contents=contents.replacingOccurrences(of:" sorted",with:"")+base+" "+nfd+"\n"; try Data(contents.utf8).write(to:packed)
        let shortLength=try await repo.run(["rev-parse","--short","HEAD"]).text.trimmingCharacters(in:.newlines).count
        for kind in 0...2 {
            phase(["Create Branch","Create Tag","New Worktree"][kind])
            let branch:BranchTagWindowController? = kind<2 ? BranchTagWindowController(repository:repo,access:nil,isTag:kind==1,preferences:prefs) : nil
            let worktree:WorktreeCreateWindowController? = kind==2 ? WorktreeCreateWindowController(repository:repo,access:nil,preferences:prefs) : nil
            let owner:NSWindowController=branch.map { $0 as NSWindowController } ?? worktree!,chooser=branch?.model.chooser ?? worktree!.model.chooser,window=owner.window!
            defer { owner.close() }
            if let branch { branch.model.load(revision:nil) }
            try await wait([window]) { !chooser.busy && (branch?.model.busy ?? worktree!.model.busy)==false && !chooser.references.isEmpty }
            var presentations=0,logCallbacks:[(LogEntry?)->Void]=[],commands:[String]=[],created=false
            let presenter:(NSWindow,NSWindow)->Bool={parent,child in presentations+=1; parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
            let configure:(ReferenceBrowserWindowModel)->Void={model in model.onLog={commands.append($0)}; model.onBrowse={commands.append($0)}; model.onCompare={commands.append($0)} }
            let logFactory:(GitRepository,RepositoryAccessLease?,@escaping(LogEntry?)->Void,UserDefaults)->LogWindowController={repo,access,choose,prefs in logCallbacks.append(choose); return LogWindowController(repository:repo,access:access,onChoose:choose,labelDefaults:prefs,savesColumnLayout:false) }
            if let branch { branch.presentPicker=presenter; branch.configureReferencePicker=configure; branch.makeCommitPicker=logFactory; branch.model.options.name="made-\(kind)"; branch.model.options.message="creation message"; branch.model.options.force=true; branch.model.switchAfterCreation=false; branch.model.pushAfterCreation=false; branch.model.onCreated={_ in created=true} }
            if let worktree { worktree.presentPicker=presenter; worktree.configureReferencePicker=configure; worktree.makeCommitPicker=logFactory; worktree.model.directory=root.appendingPathComponent("made-worktree").path; worktree.model.force=true; worktree.model.checkout=false; worktree.model.onCreated={_ in created=true} }
            func ref()->ReferenceBrowserWindowController? { branch?.referencePicker ?? worktree?.referencePicker }
            func log()->LogWindowController? { branch?.commitPicker ?? worktree?.commitPicker }
            func canClose()->Bool { branch?.windowShouldClose(window) ?? worktree!.windowShouldClose(window) }
            func create() { if let branch { branch.model.create() } else { worktree!.model.create() } }
            func setHead(_ value:Bool) { if let branch { branch.model.useHead=value } else { worktree!.model.useHead=value } }
            let config=try Data(contentsOf:root.appendingPathComponent(".git/config")),tree=try await repo.run(["write-tree"]).text
            chooser.browse(.branch); try require(ref()==nil && chooser.pickerTarget==nil,"HEAD base opened reference browser")
            setHead(false); chooser.commitRevision="saved draft"
            for (name,target,label) in [("refs/heads/nested/topic",CheckoutTarget.branch,"Base branch revision"),(nfc,.branch,"Base branch revision"),(nfd,.branch,"Base branch revision"),("refs/tags/release",.tag,"Base tag revision"),("refs/remotes/origin/HEAD",.branch,"Base branch revision"),("refs/notes/custom",.commit,"Base commit revision")] {
                chooser.options.target = .branch; chooser.browse(.branch)
                guard let child=ref() else { throw Failure(description:"Reference child missing") }; try await wait([child.window!]) { !child.model.busy && child.model.snapshot != nil }
                let count=presentations; create(); chooser.browse(.branch); chooser.browse(.commit)
                if let worktree { worktree.model.chooseDirectory(); worktree.model.load() }
                try require(presentations==count && !created && !canClose() && window.attachedSheet==nil && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Parent mutation/duplicate/directory/close/Quit escaped")
                if commands.isEmpty {
                    guard let table=find(NSTableView.self,child.window!.contentView!,label:"References"),let menu=table.menu else { throw Failure(description:"Reference context controls missing") }
                    try await wait([child.window!]) { table.selectedRow>=0 }; menu.delegate?.menuNeedsUpdate?(menu)
                    for title in ["Show log","Browse repository","Compare with working tree"] { let index=menu.indexOfItem(withTitle:title); try require(index>=0 && menu.items[index].image != nil && menu.items[index].isEnabled,"Context icon command missing"); menu.performActionForItem(at:index) }
                    try require(commands==Array(repeating:chooser.branchRevision,count:3),"Context lost canonical name")
                }
                let choice=child.model.snapshot!.initialSelection(name); child.model.setFolder(choice.folder); child.model.selected=choice.reference; child.model.accept()
                try await wait([window]) { chooser.pickerTarget==nil && !chooser.busy && chooser.options.target==target }
                guard let control=find(NSControl.self,window.contentView!,label:label) else { throw Failure(description:"Base revision control missing") }
                try await wait([window]) { if window.firstResponder === control { return true }; if let editor=(control as? NSTextField)?.currentEditor(){return window.firstResponder === editor}; return false }
                try require(ref()==nil && GitReferenceName.equal(chooser.revision,name),"Canonical base handoff differs")
                if target != .commit { try require(chooser.commitRevision=="saved draft","Unused draft overwritten") }
                if let branch { try require(branch.model.options.name=="made-\(kind)" && branch.model.options.message=="creation message" && branch.model.options.force && !branch.model.switchAfterCreation && !branch.model.pushAfterCreation,"Branch/Tag creation options overwritten") }
                if let worktree {
                    let expected=name=="refs/remotes/origin/HEAD" ? "team/topic" : target == .tag ? "Branch_release" : target == .commit ? "Branch_"+String(name.prefix(shortLength)) : "Branch_"+(GitReferenceName.removingPrefix("refs/heads/",from:name) ?? name)
                    try require(GitReferenceName.equal(worktree.model.branchName,expected) && worktree.model.createBranch==(target != .branch || chooser.remote) && !worktree.model.detach && worktree.model.force && !worktree.model.checkout,"Worktree base suggestions/options differ")
                }
            }
            chooser.options.target = .branch; chooser.branchRevision="refs/heads/nested/topic"; chooser.browse(.branch)
            guard let canceled=ref() else { throw Failure(description:"Cancel child missing") }; try await wait([canceled.window!]) { !canceled.model.busy }; canceled.model.cancel(); try await wait([window]) { chooser.pickerTarget==nil && !chooser.busy }
            try require(chooser.revision=="refs/heads/nested/topic","Cancel changed branch base")
            chooser.options.target = .commit; chooser.commitRevision=prior; chooser.browse(.commit)
            guard let first=log() else { throw Failure(description:"Full Log missing") }; try await wait([first.window!]) { !first.model.busy && first.model.entries.count==2 }
            guard let table=find(HistoryTableView.self,first.window!.contentView!) else { throw Failure(description:"Log table missing") }
            try require(!table.allowsMultipleSelection && table.numberOfRows==2 && first.model.graph.count==2 && !first.model.canShowWorkingTree && !first.model.showWorkingTree && Set(first.model.entries.map(\.hash)) == [base,prior],"Full typed Log graph/selection differs")
            create(); try require(!created && !canClose(),"Log escaped parent mutation/close lock")
            let entry=first.model.entries.first(where:{$0.hash==base})!; first.model.select([base]); first.model.accept(); try await wait([window]) { chooser.pickerTarget==nil && chooser.commitRevision==base }
            chooser.commitRevision=prior; chooser.browse(.commit); guard let second=log() else { throw Failure(description:"Second Log missing") }; try await wait([second.window!]) { !second.model.busy }
            logCallbacks[0](entry); try require(log() === second && chooser.commitRevision==prior && chooser.pickerTarget == .commit,"Stale Log result escaped")
            second.model.close(); try require(log()==nil && chooser.pickerTarget==nil && chooser.commitRevision==prior,"Log cancellation changed draft")
            if let branch { branch.presentPicker={_,_ in false} } else { worktree!.presentPicker={_,_ in false} }
            chooser.browse(.commit); try require(log()==nil && chooser.pickerTarget==nil,"Rejected Log retained child")
            chooser.options.target = .branch; chooser.browse(.branch); try require(ref()==nil && chooser.pickerTarget==nil && !chooser.busy,"Rejected browser retained child")
            if let branch { branch.presentPicker=presenter } else { worktree!.presentPicker=presenter }
            chooser.options.target = .commit; chooser.commitRevision=prior; chooser.browse(.commit)
            guard let finalSelection=log() else { throw Failure(description:"Final selection Log missing") }; try await wait([finalSelection.window!]) { !finalSelection.model.busy && finalSelection.model.entries.count==2 }
            finalSelection.model.select([base]); finalSelection.model.accept(); try await wait([window]) { chooser.pickerTarget==nil && chooser.commitRevision==base }
            let beforeHead=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),beforeTree=try await repo.run(["write-tree"]).text
            try require(beforeHead==head && beforeTree==tree && config==Data(contentsOf:root.appendingPathComponent(".git/config")),"Pickers mutated repository")
            // Execute creation only in this owned fixture, using the base chosen through full Log.
            if let worktree { worktree.model.createBranch=true; worktree.model.branchName="made-worktree"; worktree.model.changedBranch() }
            create(); try await wait([window]) { created && (branch?.model.busy ?? worktree!.model.busy)==false }
            if kind<2 { let revision=try await repo.run(["rev-parse",kind==0 ? "refs/heads/made-0" : "refs/tags/made-1^{}"]).text.trimmingCharacters(in:.newlines); try require(revision==base,"Created reference ignores selected base") }
            else { let revision=try await repo.run(["rev-parse","refs/heads/made-worktree"]).text.trimmingCharacters(in:.newlines); try require(revision==base && worktree!.model.success && !FileManager.default.fileExists(atPath:root.appendingPathComponent("made-worktree/file").path),"Worktree creation ignores selected base/options") }
            owner.close(); chooser.browse(.commit); logCallbacks.last?(entry); try require(ref()==nil && log()==nil && chooser.pickerTarget==nil && chooser.referenceFocusRequest==0,"Closed parent retained or reopened picker")
        }
        phase("Forced child cleanup")
        for forcedKind in 0..<4 {
            let commitPicker=forcedKind%2==1
            if forcedKind>=2 {
                let closing=WorktreeCreateWindowController(repository:repo,access:nil,preferences:prefs); defer { closing.close() }
                try await wait([closing.window!]) { !closing.model.busy && !closing.model.chooser.busy }; closing.model.useHead=false
                closing.presentPicker={parent,_ in parent.makeFirstResponder(nil);return true}; closing.makeCommitPicker={repo,access,choose,prefs in LogWindowController(repository:repo,access:access,onChoose:choose,labelDefaults:prefs,savesColumnLayout:false) }
                closing.model.chooser.options.target=commitPicker ? .commit : .branch; closing.model.chooser.commitRevision=prior; closing.model.chooser.browse(commitPicker ? .commit : .branch)
                if let child=closing.referencePicker { try await wait([child.window!]) { !child.model.busy }; closing.close(); child.model.finish("refs/tags/release") }
                else if let child=closing.commitPicker { try await wait([child.window!]) { !child.model.busy }; closing.close(); child.model.accept() }
                else { throw Failure(description:"Forced worktree child missing") }
                closing.model.chooser.browse(commitPicker ? .commit : .branch)
                try require(closing.referencePicker==nil && closing.commitPicker==nil && closing.model.chooser.pickerTarget==nil && closing.model.chooser.referenceFocusRequest==0,"Forced worktree owner leaked/reopened child")
                continue
            }
            let closing=BranchTagWindowController(repository:repo,access:nil,isTag:false,preferences:prefs); defer { closing.close() }
            closing.model.load(revision:nil); try await wait([closing.window!]) { !closing.model.busy && !closing.model.chooser.busy }; closing.model.useHead=false
            closing.presentPicker={parent,_ in parent.makeFirstResponder(nil);return true}; closing.makeCommitPicker={repo,access,choose,prefs in LogWindowController(repository:repo,access:access,onChoose:choose,labelDefaults:prefs,savesColumnLayout:false) }
            closing.model.chooser.options.target=commitPicker ? .commit : .branch; closing.model.chooser.commitRevision=prior; closing.model.chooser.browse(commitPicker ? .commit : .branch)
            if let child=closing.referencePicker { try await wait([child.window!]) { !child.model.busy }; closing.close(); child.model.finish("refs/tags/release") }
            else if let child=closing.commitPicker { try await wait([child.window!]) { !child.model.busy }; closing.close(); child.model.accept() }
            else { throw Failure(description:"Forced child missing") }
            try require(closing.referencePicker==nil && closing.commitPicker==nil && closing.model.chooser.pickerTarget==nil,"Forced owner close leaked child")
        }
        print("PASS: actual Branch/Tag/Worktree full reference and typed Log pickers, graph/native single selection, canonical namespace handoff and strict base focus, context icons/callbacks, retained drafts/options and worktree suggestions, HEAD/duplicate/create/directory/close/Quit/cancel/stale/reject/forced/closed-parent guards; read-only picker invariants followed by real private branch/tag/worktree creation at selected base. Private preferences/repos, no ordered windows or actual sheets; physical/signed/full parity unverified.")
    }
}
