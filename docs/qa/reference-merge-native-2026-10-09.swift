import AppKit
import TurtleGitCore

@main struct ReferenceMergeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String) -> T? {
        if let result = view as? T, result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], line:UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out at line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceMerge.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite); defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Merge route QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "base"])
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature")); try await repo.stage(["feature"]); _ = try await repo.run(["commit", "-m", "feature"])
        let feature = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["remote", "add", "origin", root.path]); _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", feature]); _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/topic"])
        _ = try await repo.run(["tag", "release", base]); _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "annotated", "-m", "tag", base]); _ = try await repo.run(["update-ref", "refs/notes/custom", base])
        let blob = try await repo.run(["hash-object", "-w", "file"]).text.trimmingCharacters(in: .newlines); _ = try await repo.run(["update-ref", "refs/custom/blob", blob])
        let nfc = "refs/heads/Café", nfd = "refs/heads/Cafe\u{301}"
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let packed = root.appendingPathComponent(".git/packed-refs"); let text = try String(contentsOf: packed).replacingOccurrences(of: " sorted", with: "") + base + " " + nfc + "\n" + base + " " + nfd + "\n"; try Data(text.utf8).write(to: packed)
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/feature", preferences: prefs) { _ in }; defer { browser.close() }
        browser.presentMerge = { owner, _ in owner.makeFirstResponder(nil); return true }
        var configured = 0, changes = 0
        browser.model.configureMerge = { child in
            configured += 1; child.model.onChanged = { _ in changes += 1 }; child.model.onPostAction = { _, _ in }
            child.presentProgress = { owner, _ in owner.makeFirstResponder(nil) }
        }
        // The following assertions inspect actual native row views, not only
        // the model's menu contract. Mount this owned host without desktop ink.
        browser.window?.alphaValue=0;browser.window?.setFrameOrigin(NSPoint(x:-16000,y:-16000));browser.window?.orderFront(nil)
        browser.model.load(); try await wait([browser.window!]) { !browser.model.busy && browser.model.snapshot != nil }
        func nativeSelectionReady() -> Bool {
            let model=browser.model
            guard !model.busy,!model.hasChild,model.pendingReferenceReads==0,
                  let table=find(NSTableView.self,browser.window!.contentView!,label:"References"),table.isEnabled,
                  table.numberOfRows==model.rows.count else{return false}
            let column=table.column(withIdentifier:.init("name"));guard column>=0 else{return false}
            let indexes=IndexSet(model.rows.indices.filter{model.selection.contains(model.rows[$0].reference.name)})
            guard table.selectedRowIndexes==indexes else{return false}
            for row in model.rows.indices {
                guard let cell=table.view(atColumn:column,row:row,makeIfNecessary:true) as? NSTableCellView,
                      cell.textField?.stringValue.utf8.elementsEqual(model.text(model.rows[row],column:"name").utf8)==true else{return false}
            }
            return true
        }
        func selectionState(_ name:String) -> String {
            let model=browser.model,table=find(NSTableView.self,browser.window!.contentView!,label:"References")
            let column=table?.column(withIdentifier:.init("name")) ?? -1
            let actual:[String?]=(0..<(table?.numberOfRows ?? 0)).map {row in
                guard column>=0 else{return nil}
                return (table?.view(atColumn:column,row:row,makeIfNecessary:true) as? NSTableCellView)?.textField?.stringValue
            }
            return "requested=\(String(reflecting:name)),folder=\(model.folder.rawValue),chosen=\(String(reflecting:model.chosen?.name.rawValue)),selection=\(model.selection.map(\.rawValue)),busy=\(model.busy),pending=\(model.pendingReferenceReads),child=\(model.hasChild),nativeCount=\(String(describing:table?.numberOfRows)),modelCount=\(model.rows.count),enabled=\(String(describing:table?.isEnabled)),indexes=\(String(describing:table?.selectedRowIndexes)),nameColumn=\(column),nativeText=\(String(reflecting:actual)),expectedText=\(String(reflecting:model.rows.map{model.text($0,column:"name")})),frame=\(String(describing:table?.frame)),visible=\(browser.window?.isVisible == true),error=\(String(reflecting:model.error))"
        }
        func select(_ name: String) async throws {
            // Child release schedules a real catalog reload. Admit before the
            // single guarded folder/selection action; never retry a refused one.
            do {try await wait([browser.window!]) {browser.model.canEditPresentation && browser.model.pendingReferenceReads==0 && browser.window?.attachedSheet==nil}}
            catch {throw Failure(description:"Reference Merge selection admission blocked: \(selectionState(name)); \(error)")}
            let choice = browser.model.snapshot!.initialSelection(name);browser.model.setFolder(choice.folder);browser.model.select(Set(choice.reference.map{[$0]} ?? []),last:choice.reference)
            do {try await wait([browser.window!]) { browser.model.chosen?.name == GitReferenceName(name) && nativeSelectionReady() }}
            catch {throw Failure(description:"Reference Merge selection did not settle: \(selectionState(name)); \(error)")}
        }
        func mergeCaption() -> String {HistoryLabels.text("Merge to \"{branch}\"…",values:["branch":browser.model.currentBranchCaption])}
        func menu() async throws -> NSMenu {
            do {try await wait([browser.window!]) {nativeSelectionReady()}}
            catch {throw Failure(description:"Reference Merge menu projection did not settle: \(selectionState(browser.model.selected?.rawValue ?? "nil")); \(error)")}
            guard let table = find(NSTableView.self, browser.window!.contentView!, label: "References"), let menu = table.menu else { throw Failure(description: "Native menu missing") }
            menu.delegate?.menuNeedsUpdate?(menu); return menu
        }
        func open() async throws -> MergeWindowController {
            let menu = try await menu(); let title = mergeCaption()
            guard let command = menu.items.first(where: { $0.title == title }), command.isEnabled, command.image != nil else { throw Failure(description: "Original Merge menu/icon missing: expected=\(String(reflecting:title)),chosen=\(String(reflecting:browser.model.chosen?.name.rawValue)),type=\(String(reflecting:browser.model.chosen?.objectType)),canAccept=\(browser.model.canAccept),canMerge=\(browser.model.canMerge),busy=\(browser.model.busy),child=\(browser.model.hasChild),items=\(menu.items.map{[$0.title,String($0.isEnabled),String($0.image != nil)]}),error=\(String(reflecting:browser.model.error))") }
            let switchIndex=menu.indexOfItem(withTitle:HistoryLabels.caption("Switch/Checkout to this…"))
            try require(switchIndex>=0 && menu.indexOfItem(withTitle:title)<switchIndex,"Merge/Switch order differs")
            guard let action=command.action else{throw Failure(description:"Native Merge action missing")}
            try require(NSApplication.shared.sendAction(action,to:command.target,from:command),"Native menu dispatch")
            guard let child = browser.mergeDialog else { throw Failure(description: "Owned Merge missing") }; return child
        }
        for (ref, target) in [("refs/heads/feature", CheckoutTarget.branch), ("refs/remotes/origin/topic", .branch), ("refs/remotes/origin/HEAD", .branch), ("refs/tags/release", .tag), ("refs/notes/custom", .commit), (nfc, .branch), (nfd, .branch)] {
            try await select(ref); let child = try await open(); try await wait([child.window!]) { !child.model.busy && !child.model.references.isEmpty }
            try require(child.model.target == target && GitReferenceName.equal(child.model.revision, ref) && child.model.repository === repo && child.model.onPostAction != nil, "Canonical Merge preset/role/configuration differs")
            if target != .commit {
                let label = target == .tag ? "Merge tag revision" : "Merge branch revision"
                try await wait([child.window!]) {
                    guard let popup=find(NSPopUpButton.self,child.window!.contentView!,label:label) else{return false}
                    let refs=target == .tag ? child.model.tags:child.model.branches
                    return refs.indices.contains(popup.indexOfSelectedItem) && GitReferenceName.equal(refs[popup.indexOfSelectedItem].name,ref)
                }
                guard let popup = find(NSPopUpButton.self, child.window!.contentView!, label: label) else { throw Failure(description: "Native popup missing") }
                let refs = target == .tag ? child.model.tags : child.model.branches
                try require(refs.indices.contains(popup.indexOfSelectedItem) && GitReferenceName.equal(refs[popup.indexOfSelectedItem].name, ref), "Exact native selection lost")
            } else {
                try await wait([child.window!]) {find(NSTextField.self,child.window!.contentView!,label:"Merge commit revision")?.stringValue==ref}
                try require(find(NSTextField.self,child.window!.contentView!,label:"Merge commit revision")?.stringValue==ref,"Commit field differs")
            }
            try require(browser.model.hasChild && !browser.model.canAccept && !browser.windowShouldClose(browser.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Parent/close/Quit lock differs")
            let count = configured; browser.showMerge(); browser.showSwitch(); browser.selectTracking(); browser.model.load(); browser.model.currentBranch(); browser.model.accept()
            try require(configured == count && browser.mergeDialog === child && !browser.model.busy, "Competing route escaped")
            child.model.close()
            try await wait([browser.window!]) {browser.mergeDialog==nil && browser.model.canEditPresentation && browser.model.pendingReferenceReads==0 && child.model.pendingTransportReads==0 && child.window?.sheetParent==nil && browser.window?.attachedSheet==nil}
            try require(browser.mergeDialog == nil && !browser.model.hasChild, "Cancel did not release Merge")
        }
        for ref in ["refs/heads/main", "refs/tags/annotated", "refs/custom/blob"] {
            try await select(ref);let currentMenu=try await menu()
            try require(!browser.model.canMerge && currentMenu.indexOfItem(withTitle:mergeCaption()) == -1, "Current/type gate differs")
            browser.showMerge(); try require(browser.mergeDialog == nil, "Forbidden Merge opened")
        }
        try await select("refs/heads/feature")
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/feature"])
        try require(!browser.model.canMerge && browser.model.mergeTitle == "Merge to \"feature\"…", "Live HEAD gate/label did not update")
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try await repo.run(["checkout", "--detach", base]); try require(browser.model.canMerge && browser.model.mergeTitle == "Merge to \"(no branch)\"…", "Detached gate/label differs"); _ = try await repo.run(["checkout", "main"])
        let linkedRoot = root.appendingPathComponent("linked")
        _ = try await repo.run(["worktree", "add", "-b", "linked-current", linkedRoot.path, base])
        let linked = ReferenceBrowserWindowController(repository: GitRepository(root: linkedRoot, executable: repo.executable), access: nil, initial: "main", preferences: prefs) { _ in }; defer { linked.close() }
        linked.model.load(); try await wait([linked.window!]) { !linked.model.busy && linked.model.snapshot != nil }
        try require(linked.model.currentBranchName == "linked-current" && linked.model.canMerge && linked.model.mergeTitle == "Merge to \"linked-current\"…", "Linked worktree HEAD location differs")
        linked.close()
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "feature", preferences: prefs) { _ in }; defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && bare.model.snapshot != nil }; try require(!bare.model.canMerge, "Bare Merge exposed")
        browser.presentMerge = { _, _ in false }; browser.showMerge()
        try await wait([browser.window!]) {browser.mergeDialog==nil && browser.model.canEditPresentation && browser.model.pendingReferenceReads==0 && browser.window?.attachedSheet==nil}
        try require(browser.mergeDialog == nil && !browser.model.hasChild, "Rejected presentation leaked")
        try require(head == Data(contentsOf: root.appendingPathComponent(".git/HEAD")) && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Open/cancel changed repository")
        let beforeTree = try await repo.run(["write-tree"]).text
        browser.presentMerge = { owner, _ in owner.makeFirstResponder(nil); return true }; let child = try await open()
        try await wait([child.window!]) { !child.model.busy }; child.model.merge(); child.model.branchRevision = "refs/heads/main"
        try await wait([child.window!]) { child.progressController?.model.busy == false }
        guard let progress = child.progressController else { throw Failure(description: "Owned native progress missing") }
        try require(progress.model.success && progress.model.options.revision == "refs/heads/feature" && child.model.busy && browser.model.hasChild && changes == 1, "Owned merge transaction/lock/capture differs")
        let merged = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try require(merged == feature && FileManager.default.fileExists(atPath: root.appendingPathComponent("feature").path), "Real merge not applied")
        progress.model.close(); try await wait([browser.window!]) { browser.mergeDialog == nil }
        try require(!browser.model.hasChild && !child.model.busy && child.progressController == nil, "Acknowledgement did not release owned route")
        let afterTree = try await repo.run(["write-tree"]).text; try require(beforeTree != afterTree && index != Data(contentsOf: root.appendingPathComponent(".git/index")), "Merge did not update index")
        let closing = try await open(); browser.close()
        try await wait([browser.window!]) {browser.mergeDialog==nil && !closing.model.busy && closing.model.pendingTransportReads==0 && browser.model.pendingReferenceReads==0}
        try require(browser.model.closed && browser.mergeDialog == nil && !closing.model.busy && closing.model.references.isEmpty, "Forced close allowed initial metadata publication")
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "Displayed windows")
        print("PASS: original Merge menu/icon/order, canonical native local/remote/symbolic/tag/notes/NFC/NFD presets, live HEAD/current/type/bare gates, owned/cancel/reject/competing/Quit/forced-load cleanup and real captured merge/progress acknowledgement. Private preferences/repository, no ordered windows or physical sheets.")
    }
}
