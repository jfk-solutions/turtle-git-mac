import AppKit
import SwiftUI
import TurtleGitCore

@main struct MergePickerVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String? = nil) -> T? {
        if let result = view as? T, label == nil || result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    static func phase(_ message: String) { print("PHASE: " + message); fflush(stdout) }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.MergePickers.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Merge Picker QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        func commit(_ message: String) async throws -> String { _ = try await repo.run(["commit","--allow-empty","-m",message]); return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines) }
        let base = try await commit("base"), prior = try await commit("prior"), head = try await commit("latest")
        _ = try await repo.run(["checkout","-b","sibling",base]); let sibling = try await commit("sibling"); _ = try await repo.run(["checkout","main"])
        for ref in ["refs/heads/nested/topic","refs/remotes/origin/team/topic","refs/notes/custom"] { _ = try await repo.run(["update-ref",ref,prior]) }
        _ = try await repo.run(["tag","release",prior]); _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/team/topic"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config")), tree = try await repo.run(["write-tree"]).text
        let owner = MergeWindowController(repository: repo,access: nil,preferences: prefs); defer { owner.close() }
        owner.model.load(); try await wait([owner.window!]) { !owner.model.busy && !owner.model.references.isEmpty }
        var presentations = 0, callbacks: [(LogEntry?) -> Void] = []
        owner.presentPicker = { parent, child in presentations += 1; parent.makeFirstResponder(nil); return !parent.isVisible && !child.isVisible }
        owner.makeCommitPicker = { repo, access, choose, prefs in callbacks.append(choose); return LogWindowController(repository: repo,access: access,onChoose: choose,labelDefaults: prefs,savesColumnLayout: false) }
        var configuredNames: [String] = []
        owner.configureReferencePicker = { model in model.onLog = { configuredNames.append($0) }; model.onBrowse = { configuredNames.append($0) }; model.onCompare = { configuredNames.append($0) } }
        owner.model.options.noCommit = true; owner.model.options.squash = true; owner.model.message = "Preserved merge message"; owner.model.commitRevision = "saved commit draft"
        phase("All-reference handoff preserving Merge options")
        for (name,target,label) in [("refs/heads/nested/topic",CheckoutTarget.branch,"Merge branch revision"),("refs/tags/release",.tag,"Merge tag revision"),("refs/remotes/origin/HEAD",.branch,"Merge branch revision"),("refs/notes/custom",.commit,"Merge commit revision")] {
            owner.model.target = .branch; owner.model.browse(.branch)
            guard let child = owner.referencePicker else { throw Failure(description:"Reference browser missing") }
            try await wait([child.window!]) { !child.model.busy && child.model.snapshot != nil }
            if name == "refs/heads/nested/topic" {
                guard let native=find(NSTableView.self,child.window!.contentView!,label:"References"), let menu=native.menu else { throw Failure(description:"Context table missing") }
                try await wait([child.window!]) { native.selectedRow >= 0 && native.numberOfRows > 0 }
                menu.delegate?.menuNeedsUpdate?(menu)
                for title in ["Show log","Browse repository","Compare with working tree"] { let index=menu.indexOfItem(withTitle:title); try require(index >= 0 && menu.items[index].isEnabled && menu.items[index].image != nil,"Configured icon command missing"); menu.performActionForItem(at:index) }
                try require(configuredNames == Array(repeating:owner.model.branchRevision,count:3),"Context configuration lost canonical reference")
            }
            try require(child.model.snapshot!.folders.contains("refs/notes") && child.model.snapshot!.folders.contains("refs/tags"),"Browser restricted namespaces")
            try require(owner.model.pickerTarget == .branch && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Parent close/Quit escaped")
            let count=presentations; owner.model.browse(.branch); owner.model.browse(.commit); owner.model.merge(); owner.model.load(revision: base)
            try require(presentations==count && !owner.model.busy && owner.model.progress == nil && owner.commitPicker == nil,"Duplicate/cross-target/merge/reload escaped")
            let choice=child.model.snapshot!.initialSelection(name); child.model.setFolder(choice.folder); child.model.selected=choice.reference; child.model.accept()
            try await wait([owner.window!]) { owner.model.pickerTarget == nil && !owner.model.busy && owner.model.target == target }
            guard let control=find(NSControl.self,owner.window!.contentView!,label:label) else { throw Failure(description:"Revision control missing") }
            try await wait([owner.window!]) { if owner.window!.firstResponder === control { return true }; if let editor=(control as? NSTextField)?.currentEditor() { return owner.window!.firstResponder === editor }; return false }
            try require(owner.referencePicker == nil && GitReferenceName.equal(owner.model.revision, name),"Handoff/defaults differ")
            try require(owner.model.options.noCommit && owner.model.options.squash && owner.model.message == "Preserved merge message","Selection erased Merge options/message")
            if target != .commit { try require(owner.model.commitRevision == "saved commit draft","Unused commit draft overwritten") }
        }
        owner.model.target = .branch; owner.model.branchRevision="refs/heads/nested/topic"; owner.model.browse(.branch)
        guard let canceled=owner.referencePicker else { throw Failure(description:"Cancel browser missing") }; try await wait([canceled.window!]) { !canceled.model.busy }
        canceled.model.cancel(); try await wait([owner.window!]) { owner.model.pickerTarget == nil && !owner.model.busy }
        try require(owner.model.revision == "refs/heads/nested/topic","Cancel changed selected branch")
        owner.model.browse(.branch); guard let next=owner.referencePicker else { throw Failure(description:"Next browser missing") }; try await wait([next.window!]) { !next.model.busy }
        canceled.model.finish("refs/tags/release"); try require(owner.referencePicker === next && owner.model.pickerTarget == .branch,"Stale browser changed new child")
        next.model.cancel(); try await wait([owner.window!]) { owner.model.pickerTarget == nil && !owner.model.busy }
        phase("F5 and fresh return catalog")
        owner.model.target = .branch; owner.model.browse(.branch)
        guard let refresh=owner.referencePicker else { throw Failure(description:"Refresh browser missing") }; try await wait([refresh.window!]) { !refresh.model.busy && refresh.model.snapshot != nil }
        try require(!owner.model.references.contains(where:{$0.name=="refs/tags/late"}),"Late reference already in parent catalog")
        _ = try await repo.run(["update-ref","refs/tags/late",prior])
        guard let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:refresh.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:96) else { throw Failure(description:"F5 event unavailable") }
        try require(refresh.window!.performKeyEquivalent(with:event),"F5 not handled")
        try await wait([refresh.window!]) { !refresh.model.busy && refresh.model.snapshot?.references.contains(where:{$0.name=="refs/tags/late"}) == true }
        let lateChoice=refresh.model.snapshot!.initialSelection("refs/tags/late"); refresh.model.setFolder(lateChoice.folder); refresh.model.selected=lateChoice.reference; refresh.model.accept()
        try await wait([owner.window!]) { !owner.model.busy && owner.model.pickerTarget == nil && owner.model.target == .tag }
        try require(owner.model.revision=="refs/tags/late" && owner.model.tags.contains(where:{$0.name=="refs/tags/late"}),"Returned selection used stale parent catalog")
        phase("Full native Log at typed revision")
        owner.model.target = .commit; owner.model.commitRevision=prior; owner.model.browse(.commit)
        guard let log=owner.commitPicker else { throw Failure(description:"Log picker missing") }; try await wait([log.window!]) { !log.model.busy && log.model.entries.count==2 }
        try require(log.model.selecting && !log.model.selectingMultiple && !log.model.canShowWorkingTree && !log.model.showWorkingTree && log.model.endRevision==prior && Set(log.model.entries.map(\.hash)) == [base,prior] && !log.model.entries.contains(where:{$0.hash==head || $0.hash==sibling}),"Log ancestry or selection mode differs")
        guard let table=find(HistoryTableView.self,log.window!.contentView!) else { throw Failure(description:"Native Log table missing") }
        try require(table.numberOfRows==2 && !table.allowsMultipleSelection && log.model.graph.count==2,"Log graph/table differs")
        let entry=log.model.entries.first(where:{$0.hash==base})!; log.model.select([base]); log.model.accept()
        try await wait([owner.window!]) { owner.model.pickerTarget == nil && owner.model.commitRevision==base }
        guard let field=find(NSTextField.self,owner.window!.contentView!,label:"Merge commit revision") else { throw Failure(description:"Commit field missing") }
        try await wait([owner.window!]) { if let editor=field.currentEditor() { return owner.window!.firstResponder === editor }; return false }
        owner.model.commitRevision=prior; owner.model.browse(.commit); guard let second=owner.commitPicker else { throw Failure(description:"Second Log missing") }; try await wait([second.window!]) { !second.model.busy }
        callbacks[0](entry); try require(owner.model.commitRevision==prior && owner.commitPicker === second && owner.model.pickerTarget == .commit,"Stale Log result changed newer child")
        second.model.close(); try require(owner.commitPicker == nil && owner.model.pickerTarget == nil && owner.model.commitRevision==prior,"Log cancel changed draft/ownership")
        phase("Reject and forced-parent cleanup")
        owner.presentPicker={_,_ in false}; owner.model.browse(.commit); try require(owner.commitPicker == nil && owner.model.pickerTarget == nil,"Rejected Log retained child")
        owner.model.target = .branch; owner.model.browse(.branch); try require(owner.referencePicker == nil && owner.model.pickerTarget == nil && !owner.model.busy,"Rejected browser retained child/query")
        owner.presentPicker={parent,_ in parent.makeFirstResponder(nil); return true}; owner.model.browse(.branch); guard let final=owner.referencePicker else { throw Failure(description:"Final browser missing") }; try await wait([final.window!]) { !final.model.busy }
        owner.close(); final.model.finish("refs/tags/release"); owner.model.browse(.branch); owner.model.merge()
        try require(owner.referencePicker == nil && owner.model.pickerTarget == nil && final.model.closed && owner.model.referenceFocusRequest == 0 && owner.model.progress == nil,"Closed parent/late callback escaped")
        let closing=MergeWindowController(repository:repo,access:nil,preferences:prefs); defer { closing.close() }
        closing.model.load(revision: prior); try await wait([closing.window!]) { !closing.model.busy }
        var lateCallback: ((LogEntry?) -> Void)?
        closing.makeCommitPicker={repo,access,choose,prefs in lateCallback=choose; return LogWindowController(repository:repo,access:access,onChoose:choose,labelDefaults:prefs,savesColumnLayout:false) }
        closing.presentPicker={parent,_ in parent.makeFirstResponder(nil); return true}; closing.model.browse(.commit)
        guard let closingLog=closing.commitPicker else { throw Failure(description:"Forced Log missing") }; try await wait([closingLog.window!]) { !closingLog.model.busy }
        closing.close(); lateCallback?(entry); closing.model.browse(.commit)
        try require(closing.commitPicker == nil && closing.model.pickerTarget == nil && closing.model.commitRevision==prior && closing.model.referenceFocusRequest==0,"Forced Log close or late result escaped")
        phase("Forced closure during return-catalog read")
        let helper=root.appendingPathComponent("slow-return"), pause=URL(fileURLWithPath:helper.path+".pause"), marker=URL(fileURLWithPath:helper.path+".started")
        let git=URL(fileURLWithPath:CommandLine.arguments[2]), quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        if [ "${4-}" = for-each-ref ] && [ -f "$0.pause" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let pending=MergeWindowController(repository:GitRepository(root:root,executable:helper),access:nil,preferences:prefs)
        var ownedPids:[Int32]=[]
        defer { pending.close(); for pid in ownedPids where kill(pid,0)==0 { _ = kill(pid,SIGTERM) } }
        pending.model.load(revision:"refs/heads/nested/topic"); try await wait([pending.window!]) { !pending.model.busy && !pending.model.references.isEmpty }
        pending.presentPicker={parent,_ in parent.makeFirstResponder(nil); return true}; pending.model.browse(.branch)
        guard let returning=pending.referencePicker else { throw Failure(description:"Return browser missing") }; try await wait([returning.window!]) { !returning.model.busy && returning.model.snapshot != nil }
        try Data().write(to:pause)
        let returnChoice=returning.model.snapshot!.initialSelection("refs/tags/release"); returning.model.setFolder(returnChoice.folder); returning.model.selected=returnChoice.reference; returning.model.accept()
        try await wait([pending.window!]) { pending.model.busy && FileManager.default.fileExists(atPath:marker.path) }
        ownedPids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap { Int32($0) }
        try require(ownedPids.count==2 && ownedPids.allSatisfy { kill($0,0)==0 },"Return read process not live")
        let frozen=pending.model.revision; pending.close()
        try await wait([]) { ownedPids.allSatisfy { kill($0,0) != 0 } }
        try await Task.sleep(nanoseconds:100_000_000)
        try require(pending.model.closed && !pending.model.busy && pending.model.pickerTarget == nil && pending.model.revision==frozen && pending.model.error==nil && pending.model.referenceFocusRequest==0,"Late return catalog changed closed owner")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines), afterTree=try await repo.run(["write-tree"]).text
        try require(head==afterHead && tree==afterTree && config==Data(contentsOf:root.appendingPathComponent(".git/config")),"Picker mutated repository")
        print("PASS: Merge all-ref browser branch/tag/symbolic-remote/notes canonical handoff, F5 late-ref refresh and fresh return catalog, retained Merge options/message/draft, actual revision first responder; full Log typed ancestry/graph/native single selection and accepted hash focus; cancel/stale/reject/duplicate/cross-target/merge/reload/close/Quit/forced-parent guards. Private preferences/repos, unchanged HEAD/staged tree/config, no ordered windows or sheets. Physical/signed/full chooser parity unverified.")
    }
}
