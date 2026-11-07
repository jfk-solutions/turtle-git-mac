import AppKit
import Darwin
import TurtleGitCore
@testable import TurtleGitMac

struct SynchronizationHistoryVerification {
    @MainActor static var inspect:()->String={"no history owner"}
    @MainActor static func settle(_ condition: () -> Bool,line:Int = #line) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NSError(domain:"TurtleGit.SyncHistoryQA",code:2,userInfo:[NSLocalizedDescriptionKey:"Sync history did not settle at line \(line): "+inspect()])
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main", "--template="])
        for (key,value) in [("user.name","History QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        try Data("history fixture\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        _ = try await repo.run(["remote","add","origin",root.appendingPathComponent("no-server.git").path])
        let suite = "TurtleGit.Sync.History.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        DialogGeometry.install(preferences:prefs)
        defer {DialogGeometry.install(preferences:.standard)}
        // The actor owns the standardized filesystem root used by Sync's
        // persistence namespace (/private/var and /var may name the same tree).
        let key = "TurtleGit.Sync." + repo.root.path
        print("Sync history root receipt: supplied=\(root.path) captured=\(repo.root.path)")
        let urls = ["URL","url","e\u{301}","é"] + (0..<30).map { "url-\($0)" }
        prefs.set(urls,forKey:key+".urls"); prefs.set(["Topic","topic","other"],forKey:key+".branches")
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index")), config = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let owner = SynchronizationWindowController(repository:repo,access:nil,preferences:prefs)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model
        inspect={ [weak owner] in
            guard let m=owner?.model else{return "owner released"}
            return "busy=\(m.busy) pending=\(m.hasPendingInlineWork) waiting=\(m.waitingForInput) blocked=\(m.hasBlockingChild) closed=\(m.closed) outgoing=\(m.outgoing != nil) error=\(m.error ?? "none") remote=\(Array(m.remote.utf8)) branch=\(Array(m.remoteBranch.utf8)) urls=\(m.urlHistory.map{Array($0.utf8)}) operations=\(SynchronizationWindowModel.activeInlineOperations) sheet=\(owner?.window?.attachedSheet?.title ?? "none")"
        }
        try await settle { !model.busy && model.outgoing != nil }
        let expectedURLs=urls+["origin"]
        if model.urlHistory.map({Data($0.utf8)}) != expectedURLs.map({Data($0.utf8)}) {
            let actual=model.urlHistory.map{Array($0.utf8)}
            let saved=prefs.stringArray(forKey:key+".urls")?.map{Array($0.utf8)}
            throw NSError(domain:"TurtleGit.SyncHistoryQA",code:1,userInfo:[NSLocalizedDescriptionKey:"Initial URL history mismatch: actual=\(actual) expected=\(expectedURLs.map{Array($0.utf8)}) remotes=\(model.remotes) key=\(key) saved=\(String(describing:saved))"])
        }
        precondition(model.branchHistory.prefix(2) == ["Topic","other"])
        precondition(prefs.stringArray(forKey:key+".urls") == urls, "Loading must not save")
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        let controls = views(owner.window!.contentView!).compactMap { $0 as? EditableHistoryCombo }
        precondition(controls.count == 2)
        let urlCombo = controls.first { $0.numberOfItems == model.remoteChoices.count }!
        let removed = model.remoteChoices[2]
        urlCombo.selectItem(at:2)
        let coordinator=urlCombo.delegate as! FetchHistoryCombo.Coordinator
        coordinator.comboBoxSelectionDidChange(Notification(name:NSComboBox.selectionDidChangeNotification,object:urlCombo))
        precondition(model.remote.utf8.elementsEqual(removed.utf8),"Native combo selection did not reach its own text binding")
        // No SwiftUI repaint between this native selection and Shift+Delete:
        // the original field receipt must retain its own edit continuity.
        urlCombo.historyPopupOpen = true
        let deletion = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:117)!
        precondition(urlCombo.handleHistoryKey(deletion))
        try await settle { !model.busy && !model.hasPendingInlineWork && !model.waitingForInput }
        precondition(!model.urlHistory.contains(where: { $0.utf16.elementsEqual(removed.utf16) }) && model.remote == "é")
        precondition(prefs.stringArray(forKey:key+".urls") == model.urlHistory, "Deletion persists without Close")
        model.deleteBranchHistory(at:0); try await settle { !model.busy && !model.hasPendingInlineWork && !model.waitingForInput }
        precondition(model.remoteBranch == "other" && prefs.stringArray(forKey:key+".branches") == model.branchHistory)
        let before = prefs.stringArray(forKey:key+".urls")!
        model.remote = "  New\r\nURL  "; model.remoteBranch = " OTHER "
        model.choosingBranch = true
        precondition(!owner.windowShouldClose(owner.window!))
        precondition(prefs.stringArray(forKey:key+".urls") == before)
        model.choosingBranch = false
        owner.window!.performClose(nil)
        precondition(model.closed && !owner.window!.isVisible)
        precondition(prefs.stringArray(forKey:key+".urls")?.first == "New  URL")
        precondition(prefs.stringArray(forKey:key+".branches")?.first == "other")
        let reopened = SynchronizationWindowModel(repository:repo,access:nil,preferences:prefs)
        precondition(reopened.urlHistory.first == "New  URL" && reopened.urlHistory.count > 25)
        precondition(reopened.branchHistory.first == "other")
        let isolated = SynchronizationWindowModel(repository:GitRepository(root:root.appendingPathComponent("other-repository")),access:nil,preferences:prefs)
        precondition(isolated.urlHistory.isEmpty && isolated.branchHistory.isEmpty)
        reopened.remote = "unsaved"; reopened.invalidate(); reopened.saveHistory()
        precondition(prefs.stringArray(forKey:key+".urls")?.first == "New  URL")
        // The shared helper retains Pull/Fetch's 26-save / 25-load behavior.
        let large = (0..<25).map { "branch-\($0)" }
        let saved = FetchDialogHistory.save("new",entries:large,preferences:prefs,key:"default-limit",caseSensitive:false)
        precondition(saved.count == 26 && FetchDialogHistory.load(prefs,key:"default-limit",caseSensitive:false).count == 25)
        let finalRefs = try await repo.run(["show-ref"]).stdout, finalIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        precondition(refs == finalRefs && index == finalIndex && config == finalConfig)
        try await verifyDeletionReceipts(repo:repo)
        print("PASS: native Sync history Close/reopen, blocked and forced close, popup Shift+Delete, selection/order/case/Unicode/line folding, unlimited URLs, per-repository isolation and unchanged Git state")
    }
    @MainActor static func verifyDeletionReceipts(repo:GitRepository)async throws {
        let suite="TurtleGit.Sync.HistoryReceipts."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let key="TurtleGit.Sync."+repo.root.path
        let urls=["URL","url","e\u{301}","é","last"]
        var owners=[SynchronizationWindowController]()
        defer{owners.forEach{$0.model.invalidate();$0.window?.orderOut(nil);$0.close()};prefs.removePersistentDomain(forName:suite)}
        func settled(_ model:SynchronizationWindowModel)async throws {
            try await settle{!model.busy && !model.waitingForInput && !model.hasPendingInlineWork && !model.hasBlockingChild}
        }
        func open(_ actor:GitRepository?=nil)async throws->SynchronizationWindowController {
            prefs.set(urls,forKey:key+".urls");prefs.set(["Topic","other"],forKey:key+".branches");prefs.set(false,forKey:"UseLibgit2")
            let owner=SynchronizationWindowController(repository:actor ?? repo,access:nil,preferences:prefs);owners.append(owner)
            owner.window!.alphaValue=0;owner.window!.orderFront(nil)
            try await settle{owner.model.outgoing != nil && !owner.model.busy && !owner.model.hasPendingInlineWork && !owner.model.waitingForInput}
            try await settled(owner.model);return owner
        }
        let typed=try await open(),m=typed.model
        let receipt=m.formContext,entries=m.remoteChoices
        m.formString(\.remote,context:receipt).wrappedValue="typed URL"
        precondition(m.remote=="typed URL" && m.waitingForInput)
        m.deleteFormHistory(2,remoteURL:true,context:receipt,entries:entries)
        precondition(!m.urlHistory.contains{ $0.utf8.elementsEqual("e\u{301}".utf8) } && m.remote.utf8.elementsEqual("é".utf8),"Own-field typing invalidated its matching delete receipt")
        try await settled(m);typed.close();try await settle{!m.hasPendingInlineWork}

        let cross=try await open(),other=cross.model
        let old=other.formContext,before=other.remoteChoices
        other.formString(\.remoteBranch,context:old).wrappedValue="changed branch"
        other.deleteFormHistory(1,remoteURL:true,context:old,entries:before)
        precondition(other.remoteChoices.map{Data($0.utf8)}==before.map{Data($0.utf8)},"Cross-field edit revived a stale URL deletion")
        cross.close();try await settle{!other.hasPendingInlineWork}

        let changed=try await open(),catalog=changed.model
        let stale=catalog.formContext,original=catalog.remoteChoices
        catalog.deleteFormHistory(0,remoteURL:true,context:stale,entries:original)
        let accepted=catalog.remoteChoices
        catalog.deleteFormHistory(1,remoteURL:true,context:stale,entries:original)
        precondition(catalog.remoteChoices.map{Data($0.utf8)}==accepted.map{Data($0.utf8)},"Replaced catalog accepted retained deletion")
        try await settled(catalog)
        let closedReceipt=catalog.formContext,closedEntries=catalog.remoteChoices
        changed.close();catalog.deleteFormHistory(0,remoteURL:true,context:closedReceipt,entries:closedEntries)
        precondition(catalog.remoteChoices.map{Data($0.utf8)}==closedEntries.map{Data($0.utf8)},"Retired history owner accepted retained deletion")
        try await settle{!catalog.hasPendingInlineWork}

        // Hold the real catalog command, then deliver from the currently
        // rendered read generation. Deletion cancels that read while its owned
        // attempt stays fenced until the actual Git child drains.
        let wrapper=repo.root.appendingPathComponent("history-held-git"),hold=repo.root.appendingPathComponent("history-hold"),marker=repo.root.appendingPathComponent("history-pid")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let script="#!/bin/sh\n"+SynchronizationVerification.inspectGitArguments+"if [ \"$git_command\" = for-each-ref ] && [ -f "+quote(hold.path)+" ]; then\ntrap 'exit 130' INT\ntrap 'exit 143' TERM\nprintf '%s' \"$$\" > "+quote(marker.path+".pending")+"\nmv "+quote(marker.path+".pending")+" "+quote(marker.path)+"\nwhile [ -f "+quote(hold.path)+" ]; do sleep 0.05; done\nfi\nexec "+quote(repo.executable.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let heldRepo=GitRepository(root:repo.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        let held=try await open(heldRepo),read=held.model
        defer{try? FileManager.default.removeItem(at:hold)}
        inspect={
            "held busy=\(read.busy) editable=\(read.canEditText) pending=\(read.hasPendingInlineWork) waiting=\(read.waitingForInput) outgoing=\(read.outgoing != nil) closed=\(read.closed) marker=\(FileManager.default.fileExists(atPath:marker.path)) error=\(read.error ?? "none") operations=\(SynchronizationWindowModel.activeInlineOperations)"
        }
        try Data().write(to:hold);read.reload()
        try await settle{FileManager.default.fileExists(atPath:marker.path) && read.busy && read.canEditText}
        let pidText=try String(contentsOf:marker,encoding:.utf8)
        guard let pid=Int32(pidText) else{preconditionFailure("Held catalog process receipt malformed")}
        precondition(kill(pid,0)==0,"Catalog process was not live before deletion")
        let current=read.formContext,currentEntries=read.remoteChoices,beforeWorkers=SynchronizationWindowModel.activeInlineOperations
        read.deleteFormHistory(1,remoteURL:true,context:current,entries:currentEntries)
        precondition(read.remoteChoices.count==currentEntries.count-1 && read.hasPendingInlineWork && SynchronizationWindowModel.activeInlineOperations>=beforeWorkers,"Deletion released its replaced read before worker drain")
        try FileManager.default.removeItem(at:hold)
        try await settled(read)
        precondition(kill(pid,0) != 0 && errno==ESRCH,"Cancelled catalog process survived settled replacement")
        held.close();try await settle{!read.hasPendingInlineWork}
        print("PASS Sync history receipts: immediate native select/delete; own-field typing and current-read continuity; cross-field, replaced catalog and retired callbacks refused; actual held Git read cancelled/drained")
    }

}
@_cdecl("turtlegit_history_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        do { try await SynchronizationHistoryVerification.main(); exit(0) }
        catch { print(error); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
