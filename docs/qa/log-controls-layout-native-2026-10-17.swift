// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct LogControlsLayoutVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view]+view.subviews.flatMap { views($0) } }
    @MainActor static func wait(_ owner: NSWindow?, line: Int = #line, _ ready: () -> Bool) async throws {
        var count = 0
        for _ in 0..<2500 {
            try await Task.sleep(nanoseconds:10_000_000); owner?.contentView?.layoutSubtreeIfNeeded()
            count = ready() ? count+1:0; if count == 2 { return }
        }
        throw Failure(description:"Log controls timeout at \(line)")
    }
    @MainActor static func choose(_ menu: NSMenu, _ title: String) throws {
        guard let item = menu.items.first(where: { $0.title == title }) else { throw Failure(description:"Missing menu item: \(title)") }
        try require(item.isEnabled,"Disabled menu item: \(title)")
        menu.performActionForItem(at:menu.index(of:item))
    }
    @MainActor static func capture(_ window: NSWindow) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_LOG_CONTROLS_CAPTURE"] else { return }
        guard #available(macOS 14.4,*) else { throw Failure(description:"Owned capture unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:theme); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description:"Owned Log window unavailable") }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width*2); config.height = Int(window.frame.height*2); config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes = NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else { throw Failure(description:"Capture encoding") }
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("log-controls-"+name+".png"))
        }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); print("PASS Log controls/layout: native source menus, checked and disabled states/icons, one-use and stale command ownership, remembered scopes, retained ranges, real picker, divider restore/clamping/retirement, unchanged HEAD/index/refs") }
        catch { fputs("Log controls/layout failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Log Controls QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("shared.txt")); try await repo.stage(["shared.txt"]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["switch","-c","feature"]); try Data("feature\n".utf8).write(to:root.appendingPathComponent("shared.txt")); try await repo.stage(["shared.txt"]); _ = try await repo.commit(message:"feature change")
        _ = try await repo.run(["switch","main"]); try Data("main\n".utf8).write(to:root.appendingPathComponent("shared.txt")); try await repo.stage(["shared.txt"]); _ = try await repo.commit(message:"main change")
        let tree = try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let tag = try await repo.run(["commit-tree",tree,"-p",base],input:Data("tag-only change\n".utf8)).text.trimmingCharacters(in:.newlines)
        let custom = try await repo.run(["commit-tree",tree,"-p",base],input:Data("custom-ref change\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/tags/release",tag]); _ = try await repo.run(["update-ref","refs/custom/qa",custom])
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.LogControls."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"] { prefs.set(false,forKey:key) }
        let owner = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), model = owner.model
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.window!.orderFront(nil)
        try await wait(owner.window) { !model.busy && model.entries.count == 2 }
        guard let bridge = views(owner.window?.contentView).compactMap({ $0 as? LogPaneLayoutBridge.Probe }).first else { throw Failure(description:"Missing pane bridge") }
        try await wait(owner.window) { bridge.restored && bridge.split?.arrangedSubviews.count == 3 }
        let buttons = views(owner.window?.contentView).compactMap { $0 as? LogControlButton }
        try require(Set(buttons.compactMap { $0.identifier?.rawValue }) == ["Log.Control.reference","Log.Control.limit","Log.Control.walk","Log.Control.view"],"Native control buttons missing")
        let reference = LogControlMenus.make(model:model,kind:.reference)
        try require(reference.items.map(\.title) == ["Browse references…","HEAD → \"main\"","FETCH_HEAD","All","All basic refs","All local branches"],"Reference source order differs")
        try require(reference.items[2].isEnabled == false && reference.items[0].image != nil,"FETCH_HEAD or original command artwork wrong")
        model.chooseStartReference("refs/heads/feature",remember:true); try await wait(owner.window) { !model.busy && model.entries.count == 2 }
        try choose(LogControlMenus.make(model:model,kind:.reference),"All"); try await wait(owner.window) { !model.busy && model.entries.count == 5 }
        try require(model.referenceExpression == "refs/heads/feature","All scope destroyed retained range")
        model.chooseReferenceScope(.current); try await wait(owner.window) { !model.busy && model.entries.count == 2 }
        try require(model.endRevision == "refs/heads/feature","Returning from All did not restore explicit branch")
        for (scope,count) in [(HistoryReferenceScope.local,3),(.basic,4),(.all,5)] {
            try choose(LogControlMenus.make(model:model,kind:.reference),scope == .all ? "All":scope.title); try await wait(owner.window) { !model.busy && model.entries.count == count }
        }
        let checkbox = views(owner.window?.contentView).compactMap { $0 as? LogScopeCheckboxButton }.first!
        model.chooseReferenceScope(.basic); try await wait(owner.window) { !model.busy && checkbox.state == .mixed && checkbox.isEnabled }
        checkbox.performClick(nil); try await wait(owner.window) { !model.busy && model.effectiveReferenceScope == .current && model.entries.count == 2 }
        try require(HistoryReferenceScopePreference.load(root:root,defaults:prefs) == .current,"Checkbox did not immediately persist source scope")
        let walk = LogControlMenus.make(model:model,kind:.walk)
        try require(walk.items.map(\.title) == ["First Parent","No merges","Follow renames","Full history","","Compressed Graph","Show labeled commits only"],"Walk source order differs")
        try require(!walk.items[2].isEnabled,"Root Log enabled Follow renames")
        try choose(walk,"First Parent"); try await wait(owner.window) { !model.busy && model.historyWalk.firstParent }
        walk.performActionForItem(at:1); try require(!model.historyWalk.noMerges,"Consumed Walk receipt accepted second action")
        let next = LogControlMenus.make(model:model,kind:.walk); try require(next.items[0].state == .on,"Walk checked state missing")
        try choose(next,"First Parent"); try await wait(owner.window) { !model.busy && !model.historyWalk.firstParent }
        let view = LogControlMenus.make(model:model,kind:.view)
        try require(view.items.map(\.title) == ["Hide Unrelated Changed Paths","Gray Unrelated Changed Paths","","Show Unversioned Files","","Labels","","Gravatar","View Patch","","Show Working Tree Changes"],"View source hierarchy differs")
        let labels = view.items[5].submenu!
        try require(labels.items.map(\.title) == ["Tags","Local branches","Remote branches","Other refs"] && labels.items.allSatisfy { $0.state == .on && $0.image != nil },"Source label order/checks/artwork wrong")
        try choose(labels,"Tags"); try require(!model.referenceVisibility.contains(.tags),"Nested Labels command failed")
        try choose(LogControlMenus.make(model:model,kind:.view).items[5].submenu!,"Tags")
        let stale = LogControlMenus.make(model:model,kind:.view), unversioned = model.showUnversionedFiles
        model.busy = true; model.busy = false; stale.performActionForItem(at:3)
        try require(model.showUnversionedFiles == unversioned,"Menu survived busy transition")
        let blocked = LogControlMenus.make(model:model,kind:.walk)
        model.referencePickerBlocked = true; model.referencePickerBlocked = false; blocked.performActionForItem(at:0)
        try require(!model.historyWalk.firstParent,"Menu survived child-block transition")
        prefs.set(false,forKey:"ShowAppContextMenuIcons")
        try require(LogControlMenus.make(model:model,kind:.view).items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil },"Native context-icon preference ignored")
        prefs.set(true,forKey:"ShowAppContextMenuIcons")
        // The top reference control still opens the real shared browser on left click.
        buttons.first { $0.identifier?.rawValue == "Log.Control.reference" }!.performClick(nil)
        try await wait(owner.window) { owner.startReferencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let picker = owner.startReferencePicker!
        try require(model.referencePickerBlocked && !owner.windowShouldClose(owner.window!),"Native reference button lost picker ownership")
        picker.model.select(["refs/heads/main","refs/heads/feature"],last:"refs/heads/main"); picker.model.acceptRange(1)
        try await wait(owner.window) { !model.busy && !model.referencePickerBlocked && model.revisionRange != nil }
        let expression = model.referenceExpression
        model.chooseReferenceScope(.all); try await wait(owner.window) { !model.busy && model.entries.count == 5 }
        model.chooseReferenceScope(.current); try await wait(owner.window) { !model.busy }
        try require(model.referenceExpression == expression && model.entries.count == 1,"Range did not survive reference-set round trip")
        // Source close persistence and AppKit divider positions, without global defaults.
        model.chooseReferenceScope(.local); try await wait(owner.window) { !model.busy && model.entries.count == 3 }
        let referenceButton = buttons.first { $0.identifier?.rawValue == "Log.Control.reference" }!
        try await wait(owner.window) { referenceButton.title == "All local branches" }
        try require(referenceButton.bounds.width >= referenceButton.fittingSize.width-1,"Reference header truncates a standard scope label")
        for button in buttons where button.identifier?.rawValue != "Log.Control.reference" {
            try require(button.bounds.width >= button.fittingSize.width+8,"Native menu caption lacks arrow spacing")
        }
        let split = bridge.split!
        owner.window!.setContentSize(NSSize(width:1120,height:900)); try await wait(owner.window) { split.bounds.height > 650 }
        let available = split.bounds.height - split.dividerThickness*2
        split.setPosition(available*0.5,ofDividerAt:0); split.setPosition(available*0.5 + split.dividerThickness + available*0.25,ofDividerAt:1)
        try await wait(owner.window) { split.arrangedSubviews.allSatisfy { $0.frame.height > 100 } }
        let before = split.arrangedSubviews.map { Double($0.frame.height) }
        let retainedMenu = LogControlMenus.make(model:model,kind:.view)
        try await capture(owner.window!)
        owner.close()
        let saved = try HistoryPaneLayout.load(defaults:prefs).unwrap("Divider proportions not saved")
        let expected = HistoryPaneLayout(heights:before)!
        try require(zip(saved.fractions,expected.fractions).allSatisfy { abs($0-$1) < 0.01 },"Close saved wrong divider proportions")
        try require(HistoryReferenceScopePreference.load(root:root,defaults:prefs) == .local,"Close did not save selected reference scope")
        retainedMenu.performActionForItem(at:3); try require(model.showUnversionedFiles == unversioned,"Retired View menu changed model")
        let reopened = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), r = reopened.model
        defer { reopened.close() }; reopened.window!.alphaValue = 0; reopened.window!.orderFront(nil)
        try await wait(reopened.window) { !r.busy && r.effectiveReferenceScope == .local && r.entries.count == 3 }
        let restored = views(reopened.window?.contentView).compactMap { $0 as? LogPaneLayoutBridge.Probe }.first!
        try await wait(reopened.window) { restored.restored && restored.split != nil }
        let restoredSplit = restored.split!, heights = restoredSplit.arrangedSubviews.map { Double($0.frame.height) }
        let planned = saved.heights(available:heights.reduce(0,+))
        try require(zip(heights,planned).allSatisfy { abs($0-$1) <= 3 },"Native divider restore did not match saved layout: \(heights), \(planned)")
        reopened.window!.setContentSize(NSSize(width:1080,height:700)); try await wait(reopened.window) { restoredSplit.arrangedSubviews.allSatisfy { $0.frame.height > 0 } }
        for (view,minimum) in zip(restoredSplit.arrangedSubviews,HistoryPaneLayout.minimumHeights) { try require(Double(view.frame.height) >= minimum-1,"Native minimum pane clipped") }
        reopened.close(); let savedAfterClose = HistoryPaneLayout.load(defaults:prefs); restored.save()
        try require(HistoryPaneLayout.load(defaults:prefs) == savedAfterClose,"Retired bridge wrote preferences")
        // An explicit caller revision overrides the remembered all/local mask.
        let scoped = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,initialRevision:"refs/heads/feature")
        defer { scoped.close() }; scoped.window!.alphaValue = 0; scoped.window!.orderFront(nil)
        try await wait(scoped.window) { !scoped.model.busy && scoped.model.entries.count == 2 }
        try require(scoped.model.effectiveReferenceScope == .current,"Explicit revision inherited saved local mask")
        scoped.close()
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout, finalRefs = try await repo.run(["show-ref"]).stdout
        try require(finalHead == head && finalRefs == refs,"Presentation changed HEAD/refs")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Presentation changed index")
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value = self else { throw LogControlsLayoutVerification.Failure(description:message) }; return value }
}
