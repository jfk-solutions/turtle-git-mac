import AppKit
import TurtleGitCore

struct ReferenceActionFamilyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, in root: NSView?, label: String) -> T? {
        guard let root else { return nil }; if let view = root as? T, view.accessibilityLabel() == label { return view }
        return root.subviews.compactMap { find(type, in: $0, label: label) }.first
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reference Actions"), ("user.email", "refs@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let input = root.appendingPathComponent("file"); try Data("base\n".utf8).write(to: input); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        for name in ["left", "right"] { _ = try await repo.run(["branch", name]) }
        _ = try await repo.run(["tag", "release"])
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        _ = try await repo.run(["config", "--add", "branch.left.description", "first\nline"])
        _ = try await repo.run(["config", "--add", "branch.left.description", "ignored"])
        _ = try await repo.run(["branch", "--set-upstream-to=origin/topic", "left"])
        try Data("second\n".utf8).write(to: input);try await repo.stage(["file"]);_ = try await repo.commit(message:"second")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: input)
        let suite = "TurtleGit.ReferenceActionFamily." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "UseMailmap"); prefs.set(317, forKey: "ReferenceActionFamily.Sentinel")
        let grant=RepositoryAccessLease(url:root)
        let owner = ReferenceBrowserWindowController(repository: repo, access: grant, initial: "refs/heads/left", preferences: prefs, picking: false) { _ in }, model = owner.model, window = owner.window!
        defer { owner.close() }
        owner.commandKeyWindow = { window }; window.alphaValue = 0; window.orderFront(nil)
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<2500 { window.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw Failure(description: "Reference action family timeout")
        }
        model.load(); try await wait { !model.busy && model.snapshot != nil }
        guard let table = find(ReferenceBrowserRenameTable.self, in: window.contentView, label: "References"),
              let tree = find(ReferenceBrowserNamespaceOutline.self, in: window.contentView, label: "Reference namespaces") else { throw Failure(description: "Native reference views missing") }
        try require(model.snapshot?.references.first { $0.name == "refs/heads/left" }?.description == "first\nline", "Catalog did not retain first local branch description")
        var menu: NSMenu?, calls: [String] = []
        table.selectionMenu.present = { popup, _, view in if view === table { menu = popup } }
        tree.selectionMenu.present = { popup, _, view in if view === tree { menu = popup } }
        model.onLog = { calls.append($0) }; model.copyReferences = { calls.append($0) }
        func choose(_ refs: Set<GitReferenceName>) async throws {
            model.select(refs, last: refs.first)
            try await wait { table.isEnabled && table.selectedRowIndexes.count == refs.count && table.selectedRowIndexes.allSatisfy { model.rows.indices.contains($0) && refs.contains(model.rows[$0].reference.name) } }
        }
        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action else { throw Failure(description: "Missing native action: " + item.title) }
            try require(NSApp.sendAction(action, to: item.target, from: item), "Native menu dispatch failed")
        }
        try await choose(["refs/heads/left"])
        try require(table.accessibilityPerformShowMenu(), "First accessible reference popup failed")
        guard let popup = menu, let copy = popup.item(withTitle: "Copy ref names"), let log = popup.item(withTitle: "Show log") else { throw Failure(description: "Source reference commands missing") }
        let titles = popup.items.map(\.title)
        guard let rename = titles.firstIndex(of: "Rename"), let unset = titles.firstIndex(of: "Unset tracked branch") else { throw Failure(description: "Source tracking section missing") }
        try require(unset == rename + 2 && popup.items[rename + 1].isSeparatorItem && copy.image != nil && log.image != nil, "Source tracking separator/icon order differs")
        try await choose(["refs/heads/right"]); try invoke(copy); try invoke(copy)
        try require(calls == ["left"] && model.selection == ["refs/heads/right"], "Captured one-shot copy retargeted, replayed or replaced visible selection")
        try invoke(log); try invoke(log)
        try require(calls == ["left", "refs/heads/left"], "Captured Log callback replayed or retargeted")
        // Native keyboard and accessibility entry share the selected-row route.
        menu = nil; window.makeFirstResponder(table)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109)!
        table.keyDown(with: key)
        try require(menu != nil && model.selection == ["refs/heads/right"], "Shift-F10 lost selected reference")
        let retired = menu!.item(withTitle: "Show log")!, count = calls.count
        model.hasChild = true; try require(!table.accessibilityPerformShowMenu(), "Child owner allowed accessible reference popup"); try invoke(retired); model.hasChild = false; try invoke(retired)
        try require(calls.count == count, "Child transition revived old native popup")
        // Folder menus have no leaf payload even while a list selection exists.
        model.setFolder("refs/heads"); try await choose(["refs/heads/right"])
        try await wait { tree.selectedRow >= 0 }
        menu = nil; try require(tree.accessibilityPerformShowMenu(), "Namespace accessibility popup failed")
        guard let folder = menu, let create = folder.item(withTitle: "Create Branch…") else { throw Failure(description: "Source namespace command missing") }
        var folderCalls = 0, leafCount = -1
        model.onCreateFolder = { tag in if !tag { folderCalls += 1; leafCount = model.selectedRows.count } }
        try invoke(create); try invoke(create)
        try require(folderCalls == 1 && leafCount == 0 && model.selection == ["refs/heads/right"], "Namespace popup inherited/replayed leaf selection")
        // Pair comparisons inherit the owner's actual preferences, not standard.
        try await choose(["refs/heads/left", "refs/heads/right"])
        model.onComparePair = { [weak owner] pair in owner?.showComparison(pair) }
        owner.presentComparison = { _, _ in true }
        model.comparePair(unified: false)
        guard let comparison = owner.comparisonDialog else { throw Failure(description: "Owned comparison did not open") }
        try require(comparison.model.preferences === prefs && comparison.model.preferences.integer(forKey: "ReferenceActionFamily.Sentinel") == 317 && model.hasChild, "Comparison lost owning preferences")
        try await wait { !comparison.model.busy }
        comparison.close(); try require(owner.comparisonDialog == nil && !model.hasChild, "Comparison ownership did not release")
        try await choose(["refs/heads/right"]); try require(table.accessibilityPerformShowMenu(), "Retirement popup missing")
        let closedCopy = menu!.item(withTitle: "Copy ref names")!, beforeClose = calls.count
        // Enter the actual nested Reflog from the browser's native popup. The
        // application configures this same child; do not replace its callbacks
        // with model-only recording closures.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false},cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
        defer{workspace.stopMonitoringForTermination()}
        workspace.configureReferenceBrowser(model,repository:repo,access:grant)
        var routed:[NSWindowController]=[]
        func capture(_ child:NSWindowController){child.window?.alphaValue=0;routed.append(child)}
        workspace.logWindowPresentation={capture($0)};workspace.browserWindowPresentation={capture($0)}
        workspace.revisionComparisonWindowPresentation={capture($0)};workspace.exportWindowPresentation={capture($0)}
        // Reset normally starts its initial read in the visible view's
        // onAppear. This private presentation intentionally never orders it in.
        workspace.resetWindowPresentation={capture($0);$0.model.load()}
        defer{routed.forEach{$0.close()}}
        owner.presentReflog={parent,child in child.alphaValue=0;return parent.attachedSheet==nil}
        try await choose(["refs/heads/left"])
        try require(table.accessibilityPerformShowMenu(),"Nested Reflog entry popup absent")
        guard let openReflog=menu?.item(withTitle:"Show Reflog") else{throw Failure(description:"Browser Reflog command absent")}
        try invoke(openReflog)
        guard let nested=owner.reflog,let nestedWindow=nested.window else{throw Failure(description:"Nested Reflog owner absent")}
        defer{nested.close()}
        try await wait{!nested.model.busy && !nested.model.entries.isEmpty}
        nestedWindow.contentView?.layoutSubtreeIfNeeded()
        guard let native=find(ReferenceLogTableView.self,in:nestedWindow.contentView,label:"Reference log entries"),let coordinator=native.owner else{throw Failure(description:"Nested native Reflog table absent")}
        let event=nested.model.entries[0],ids:Set<String>=[event.id]
        nested.model.selection=ids
        try await wait{native.selectedRowIndexes.count==1}
        try require(nested.model.repository === repo && nested.model.noteLog.repositoryAccess === grant && nested.model.preferences === prefs && model.hasChild,"Nested Reflog replaced its browser repository/preferences/lease")
        try require(nested.model.onLog != nil && nested.model.onLogRange != nil && nested.model.onCompare != nil && nested.model.onCheckout != nil && nested.model.onReset != nil && nested.model.onTransport != nil && nested.model.onBisect != nil && nested.model.onCombineRevisions != nil && nested.model.onFormatPatch != nil && nested.model.onMergeRevision != nil && nested.model.onRebaseRevision != nil && nested.model.onCherryPick != nil && nested.model.onRevertRevisions != nil,"Nested Reflog omitted the shared revision command family")
        for command in ReferenceLogRevisionCommand.allCases{try require(nested.model.canPerform(command,ids:ids),"Nested revision command unavailable: \(command)")}
        func invokeNested(_ title:String)throws{
            let popup=coordinator.menu()
            guard let item=popup.item(withTitle:title),item.isEnabled,item.image != nil else{throw Failure(description:"Missing enabled nested icon command: "+title)}
            try invoke(item)
        }
        try invokeNested("Show log")
        guard let logChild=routed.last as? LogWindowController else{throw Failure(description:"Nested Log did not route")}
        try require(logChild.model.repository.root==root && logChild.model.colorPreferences === prefs && logChild.model.repositoryAccess === grant && logChild.model.endRevision==event.hash,"Nested Log lost revision/repository/preferences/access")
        try invokeNested("Browse repository")
        guard let browserChild=routed.last as? RepositoryBrowserWindowController else{throw Failure(description:"Nested Browse did not route")}
        try await wait{!browserChild.model.busy && browserChild.model.snapshot != nil}
        try require(browserChild.model.snapshot?.objectID==event.hash && browserChild.model.preferences === prefs,"Nested Browse lost revision/preferences")
        try invokeNested("Compare with working tree")
        guard let diffChild=routed.last as? RevisionComparisonWindowController else{throw Failure(description:"Nested Compare did not route")}
        try await wait{!diffChild.model.busy}
        try require(diffChild.model.repository.root==root && diffChild.model.preferences === prefs && diffChild.model.access === grant,"Nested Compare lost requesting context")
        try invokeNested("Export this version…")
        guard let exportChild=routed.last as? ExportWindowController else{throw Failure(description:"Nested Export did not route")}
        try await wait{!exportChild.model.busy}
        try require(exportChild.model.revision==event.hash && exportChild.model.presentationPreferences === prefs && exportChild.model.access === grant,"Nested Export lost revision/preferences/access")
        try invokeNested(ReferenceLogHistoryCommand.reset.title(branch:nested.model.currentBranch))
        guard let resetChild=routed.last as? ResetWindowController else{throw Failure(description:"Nested Reset did not route")}
        try await wait{!resetChild.model.busy && !resetChild.model.chooser.busy && !resetChild.model.currentBranch.isEmpty}
        try require(resetChild.model.chooser.revision==event.hash && resetChild.model.presentationPreferences === prefs && resetChild.model.access === grant,"Nested Reset lost captured revision/preferences/access: revision=\(resetChild.model.chooser.revision), expected=\(event.hash), target=\(resetChild.model.chooser.options.target), prefs=\(resetChild.model.presentationPreferences === prefs), access=\(resetChild.model.access === grant), branch=\(resetChild.model.currentBranch), error=\(String(describing:resetChild.model.error)), chooserError=\(String(describing:resetChild.model.chooser.error))")
        var creationForms:[BranchTagWindowController]=[]
        defer{creationForms.forEach{$0.close()}}
        for (command,name) in [(ReferenceLogRevisionCommand.createBranch,"nested-created-branch"),(.createTag,"nested-created-tag")] {
            let windowsBefore=Set(NSApp.windows.map{ObjectIdentifier($0)})
            try invokeNested(command.title)
            guard let form=NSApp.windows.filter({!windowsBefore.contains(ObjectIdentifier($0))}).compactMap({$0.delegate as? BranchTagWindowController}).first else{throw Failure(description:"Nested creation did not open actual form")}
            creationForms.append(form)
            try await wait{!form.model.busy && !form.model.chooser.busy}
            try require(form.window?.alphaValue==0 && form.model.presentationPreferences === prefs && form.model.chooser.revision==event.hash && form.model.chooser.repository.root==root,"Nested creation lost revision/preferences/invisible owner")
            var didClose=false;let previous=form.onClosed;form.onClosed={previous();didClose=true}
            form.model.options.name=name;form.model.switchAfterCreation=false;form.model.pushAfterCreation=false;form.model.create()
            try await wait{didClose && !form.hasPendingWork}
            let ref=(command == .createTag ? "refs/tags/":"refs/heads/")+name
            try require((try await repo.run(["rev-parse",ref])).text.trimmingCharacters(in:.newlines)==event.hash && owner.reflog === nested && model.hasChild,"Nested creation changed revision or released its requesting Reflog")
        }
        // Standalone and nested controllers can coexist without overwriting
        // either one's revision/reference or lifecycle callback.
        let standalone=ReferenceLogWindowController(repository:repo,access:grant,reference:"HEAD",preferences:prefs)
        standalone.window?.alphaValue=0;defer{standalone.close()}
        workspace.configureReferenceLog(standalone,repository:repo,access:grant)
        try await wait{!standalone.model.busy && !standalone.model.entries.isEmpty}
        try require(standalone !== nested && standalone.model.reference=="HEAD" && nested.model.reference=="refs/heads/left" && owner.reflog === nested,"Shared wiring merged standalone/nested owners")
        nested.close()
        try await wait{owner.reflog==nil && !model.hasChild && !model.busy && model.snapshot?.references.contains(where:{$0.name=="refs/heads/nested-created-branch"})==true && model.snapshot?.references.contains(where:{$0.name=="refs/tags/nested-created-tag"})==true}
        try require(standalone.canReuse && !nested.canReuse,"Actual nested Close did not refresh/release independently")
        try await choose(["refs/heads/left"])
        try require(table.accessibilityPerformShowMenu(),"Reopened nested Reflog popup absent")
        guard let reopen=menu?.item(withTitle:"Show Reflog") else{throw Failure(description:"Reopened nested Reflog command absent")};try invoke(reopen)
        guard let retiredChild=owner.reflog,retiredChild !== nested else{throw Failure(description:"Browser reused retired Reflog")}
        defer{retiredChild.close()}
        try await wait{!retiredChild.model.busy && !retiredChild.model.entries.isEmpty}
        let retainedLog=retiredChild.model.onLog!,retainedCreate=retiredChild.model.onCreateReference!
        let originalRead=retiredChild.model.readOperationEntries
        var heldRead:CheckedContinuation<Void,Never>?,heldToken:OperationCancellation?,lateCherryPick=0
        defer{heldRead?.resume();heldRead=nil}
        let originalCherryPick=retiredChild.model.onCherryPick!
        retiredChild.model.onCherryPick={values in lateCherryPick += 1;originalCherryPick(values)}
        retiredChild.model.readOperationEntries={entries,selected,token in
            let metadata=try await originalRead(entries,selected,token)
            heldToken=token
            await withCheckedContinuation{heldRead=$0}
            return metadata
        }
        retiredChild.model.selection=[retiredChild.model.entries[0].id]
        try await wait{find(ReferenceLogTableView.self,in:retiredChild.window?.contentView,label:"Reference log entries")?.selectedRowIndexes.count==1}
        guard let heldCoordinator=find(ReferenceLogTableView.self,in:retiredChild.window?.contentView,label:"Reference log entries")?.owner,
              let cherry=heldCoordinator.menu().item(withTitle:"Cherry pick this commit…"),cherry.isEnabled else{throw Failure(description:"Nested Cherry Pick native command absent")}
        try invoke(cherry);try await wait{heldRead != nil && retiredChild.hasPendingWork}
        // Closing the browser retires its real child. Retained callbacks must
        // not open successors, even while the standalone controller is live.
        let beforeRetirement=routed.count,windowsBeforeRetirement=Set(NSApp.windows.map{ObjectIdentifier($0)})
        var parentClosed=0;let parentCompletion=owner.onClosed;owner.onClosed={parentClosed += 1;parentCompletion()}
        owner.close();retainedLog(event.hash);retainedCreate(false,event.hash)
        try require(heldToken?.isCancelled==true && retiredChild.hasPendingWork && owner.hasPendingWork && parentClosed==0,"Browser/child released a held cancelled revision read before actual drain")
        heldRead?.resume();heldRead=nil
        try await wait{!owner.hasPendingWork && !retiredChild.hasPendingWork}
        try require(!retiredChild.canReuse && owner.reflog==nil && routed.count==beforeRetirement && lateCherryPick==0 && parentClosed==1 && standalone.canReuse && Set(NSApp.windows.map{ObjectIdentifier($0)}).isSubset(of:windowsBeforeRetirement),"Parent retirement revived a child command, skipped drain or retired independent Reflog")
        standalone.close();routed.forEach{$0.close()}
        try await wait{!nested.hasPendingWork && !standalone.hasPendingWork && LogWindowModel.activeHistoryLoads==0}
        try invoke(closedCopy)
        try require(!table.accessibilityPerformShowMenu() && !tree.accessibilityPerformShowMenu() && calls.count == beforeClose, "Closed owner allowed stale native actions")
        try await wait { ReferenceBrowserWindowModel.activeReads == 0 && ReferenceBrowserWindowModel.activeMutations == 0 }
        try require(head == (try await repo.run(["rev-parse", "HEAD"])).stdout && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && bytes == Data(contentsOf: input), "Reference handoffs changed HEAD, index or working bytes")
        print("PASS: source reference sections, captured native popups, nested Reflog shared revision commands/actual Branch+Tag return/catalog refresh, standalone identity and parent retirement")
    }
}
