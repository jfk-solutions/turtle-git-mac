import AppKit
import TurtleGitCore
@testable import TurtleGitMac

struct SynchronizationHistoryVerification {
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Sync history did not settle")
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
        let key = "TurtleGit.Sync." + root.path
        let urls = ["URL","url","e\u{301}","é"] + (0..<30).map { "url-\($0)" }
        prefs.set(urls,forKey:key+".urls"); prefs.set(["Topic","topic","other"],forKey:key+".branches")
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index")), config = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let owner = SynchronizationWindowController(repository:repo,access:nil,preferences:prefs)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model
        try await settle { !model.busy && model.outgoing != nil }
        precondition(model.urlHistory == urls + ["origin"])
        precondition(model.branchHistory.prefix(2) == ["Topic","other"])
        precondition(prefs.stringArray(forKey:key+".urls") == urls, "Loading must not save")
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        let controls = views(owner.window!.contentView!).compactMap { $0 as? EditableHistoryCombo }
        precondition(controls.count == 2)
        let urlCombo = controls.first { $0.numberOfItems == model.remoteChoices.count }!
        let removed = model.remoteChoices[2]
        urlCombo.selectItem(at:2); urlCombo.historyPopupOpen = true
        let deletion = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:117)!
        precondition(urlCombo.handleHistoryKey(deletion))
        try await settle { !model.busy }
        precondition(!model.urlHistory.contains(where: { $0.utf16.elementsEqual(removed.utf16) }) && model.remote == "é")
        precondition(prefs.stringArray(forKey:key+".urls") == model.urlHistory, "Deletion persists without Close")
        model.deleteBranchHistory(at:0); try await settle { !model.busy }
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
        print("PASS: native Sync history Close/reopen, blocked and forced close, popup Shift+Delete, selection/order/case/Unicode/line folding, unlimited URLs, per-repository isolation and unchanged Git state")
    }
}
@_cdecl("turtlegit_history_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        do { try await SynchronizationHistoryVerification.main(); exit(0) }
        catch { print(error); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
