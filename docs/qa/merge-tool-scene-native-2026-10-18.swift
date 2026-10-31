// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum MergeToolSceneVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ stage:String="",line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1800 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Merge-tool scene timeout at \(line): \(stage)")
    }
    static func unwrap<T>(_ value:T?)throws->T {guard let value else{throw Failure(description:"Utility owner unavailable")};return value}
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "TurtleGit.MergeToolScene." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        for args in [[String](), ["/tmp/file"]] {
            try require(TurtleGitLaunchMode.resolve(arguments: args, currentDirectory: root.path) == .workspace, "Standalone scene consumed normal/repository launch")
        }
        for args in [["--command=log","--path",root.path],["--command=diff","--base","ignored"],["--turtlegit-action-only"]] {
            try require(TurtleGitLaunchMode.resolve(arguments:args,currentDirectory:root.path) == .actionOnly,"Primary action selected workspace or Merge tool scene")
        }
        for args in [["--merge-tool"], ["/base:a", "/mine:b"], ["--merge-tool", "--line", "0"], ["--merge-tool", "--unknown"]] {
            try require(TurtleGitLaunchMode.resolve(arguments: args, currentDirectory: root.path) == .mergeTool, "Recognized or malformed tool request selected workspace")
        }
        let lazyWorkspace = WorkspaceSceneOwner(); var ordinaryCreations = 0
        lazyWorkspace.makeModel = { ordinaryCreations += 1; return RepositoryModel(startMonitoring: false, initializePreferences: false) }
        try require(lazyWorkspace.storedModel == nil && ordinaryCreations == 0, "Installing App state created workspace eagerly")
        let ordinary = lazyWorkspace.model
        try require(lazyWorkspace.model === ordinary && ordinaryCreations == 1, "Workspace scene did not retain exactly one owner")
        defer { ordinary.stopMonitoringForTermination() }
        // Bare/Open/help and captured local two/three-way inputs are now
        // repository-independent. Verify real parser/bootstrap admission once,
        // without manufacturing an unrelated Git preparation continuation.
        let localInputs:[[String]]=[
            ["--merge-tool"],
            ["--merge-tool","--help"],
            ["--merge-tool","--base",root.appendingPathComponent("scene-base").path,"--mine",root.appendingPathComponent("scene-mine").path,"--readonly"],
            ["--merge-tool","--base",root.appendingPathComponent("scene-base").path,"--mine",root.appendingPathComponent("scene-mine").path,"--theirs",root.appendingPathComponent("scene-theirs").path,"--readonly"]]
        for arguments in localInputs {
            let standalone=TurtleGitApplicationDelegate();standalone.startupArguments=arguments;standalone.startupDirectory=root.path
            var creations=0,services=0,activations=0,deliveries=0,preparations=0,correctDelivery=false
            defer{standalone.repositoryModel?.stopMonitoringForTermination()}
            standalone.prepareGitConfigurationReads={preparations += 1}
            standalone.makeStandaloneWorkspace={creations += 1;let model=RepositoryModel(startMonitoring:false,initializePreferences:false);model.fileComparisonPreferences=prefs;return model}
            standalone.configureStandaloneServices={_,_ in services += 1}
            standalone.activateStandaloneApplication={activations += 1}
            standalone.startupCommandHandler={model,args,_ in deliveries += 1;correctDelivery=model === standalone.standaloneWorkspace && args==arguments}
            standalone.startupDidFinishLaunching();standalone.startupDidFinishLaunching()
            try require(standalone.startupDelivered && deliveries==1 && correctDelivery,"Local Merge startup did not admit its captured request immediately/exactly once: \(arguments)")
            // A queued preparation would begin on the next main turn; absence
            // is checked after that boundary as well as synchronously.
            await withCheckedContinuation{reply in DispatchQueue.main.async{reply.resume()}}
            standalone.startupDidFinishLaunching()
            try require(creations==1 && services==1 && activations==1 && deliveries==1 && preparations==0 && !standalone.gitConfigurationReadsReady,"Local Merge duplicated ownership or prepared unrelated Git configuration")
            try require(standalone.repositoryModel === standalone.standaloneWorkspace && standalone.repositoryModel?.finderWatches==nil && standalone.repositoryModel?.root==nil,"Local Merge restored repository/Finder workspace")
            try require(!standalone.applicationShouldOpenUntitledFile(NSApp) && !standalone.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false),"Local Merge startup/reopen requested an untitled workspace")
        }
        // Patch application/generation really depends on Git. Their accepted
        // command must remain behind one actual preparation owner, regardless
        // of repeat bootstrap notifications, and must deliver once after drain.
        let gitInputs:[[String]]=[
            ["--merge-tool","--diff",root.appendingPathComponent("scene-input.patch").path],
            ["--merge-tool","--createunifieddiff","--origfile",root.appendingPathComponent("scene-base").path,"--modifiedfile",root.appendingPathComponent("scene-mine").path,"--outfile",root.appendingPathComponent("scene-output.patch").path]]
        for arguments in gitInputs {
            let standalone=TurtleGitApplicationDelegate();standalone.startupArguments=arguments;standalone.startupDirectory=root.path
            var creations=0,services=0,activations=0,deliveries=0,preparations=0,correctDelivery=false
            var releasePreparation:CheckedContinuation<Void,Never>?
            defer{let pending=releasePreparation;releasePreparation=nil;pending?.resume();standalone.repositoryModel?.stopMonitoringForTermination()}
            standalone.prepareGitConfigurationReads={preparations += 1;await withCheckedContinuation{releasePreparation=$0}}
            standalone.makeStandaloneWorkspace={creations += 1;let model=RepositoryModel(startMonitoring:false,initializePreferences:false);model.fileComparisonPreferences=prefs;return model}
            standalone.configureStandaloneServices={_,_ in services += 1}
            standalone.activateStandaloneApplication={activations += 1}
            standalone.startupCommandHandler={model,args,_ in deliveries += 1;correctDelivery=model === standalone.standaloneWorkspace && args==arguments}
            standalone.startupDidFinishLaunching();standalone.startupDidFinishLaunching()
            try await wait("Git-backed patch preparation entered"){releasePreparation != nil}
            try require(creations==1 && services==1 && activations==1 && preparations==1 && deliveries==0 && !standalone.startupDelivered,"Git-backed Merge duplicated its owner or outran preparation")
            try require(standalone.repositoryModel === standalone.standaloneWorkspace && standalone.repositoryModel?.finderWatches==nil && standalone.repositoryModel?.root==nil,"Pending Git-backed Merge restored repository/Finder workspace")
            let pending=releasePreparation;releasePreparation=nil;pending?.resume()
            try await wait("Git-backed patch captured delivery"){standalone.startupDelivered && deliveries==1}
            standalone.startupDidFinishLaunching()
            try require(correctDelivery && creations==1 && services==1 && activations==1 && deliveries==1 && preparations==1 && standalone.gitConfigurationReadsReady,"Git-backed Merge lost/repeated accepted command or preparation")
            try require(!standalone.applicationShouldOpenUntitledFile(NSApp) && !standalone.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false),"Git-backed Merge reopened repository workspace")
        }
        print("PASS: scene local/Open/help admission without Git and Git-backed patch preparation/order, single owner and no workspace")
        let normal = TurtleGitApplicationDelegate(); normal.startupArguments = []; normal.startupDirectory = root.path
        var normalDeliveries = 0, normalPreparations = 0
        normal.prepareGitConfigurationReads = { normalPreparations += 1 }
        normal.configureStandaloneServices = { _, _ in fatalError("Ordinary startup configured standalone services") }
        normal.startupCommandHandler = { _, _, _ in normalDeliveries += 1 }
        normal.startupDidFinishLaunching()
        try require(normal.standaloneWorkspace == nil && !normal.startupDelivered && normalDeliveries == 0, "Ordinary startup constructed tool owner instead of waiting for workspace")
        normal.repositoryModel = ordinary
        try require(normalDeliveries == 1 && !normal.applicationShouldOpenUntitledFile(NSApp) && normal.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "Ordinary workspace startup/reopen changed")
        try require(normalPreparations == 0, "Empty workspace startup unnecessarily prepared Git configuration")
        let base = root.appendingPathComponent("scene-base"), mine = root.appendingPathComponent("scene-mine"), output = root.appendingPathComponent("scene-output")
        try Data("base\n".utf8).write(to: base); try Data("mine\n".utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs, deferInitialLoad: true)
        defer { owner.close() }
        let invocation = try MergeToolInvocation.parse(arguments: ["--merge-tool", "--base", base.path, "--mine", mine.path, "--merged", output.path, "--saverequired"], currentDirectory: root.path)!
        try owner.model.configureMergeTool(invocation)
        owner.window!.alphaValue = 0; owner.window!.orderFront(nil); owner.model.beginTransferredDocument()
        try await wait { !owner.model.mergeToolHasPendingWork && !owner.model.filtering && owner.model.document != nil }
        var focused: NSWindow? = owner.window
        let context = MergeToolMenuContext(keyWindow: { focused })
        context.refresh(); try require(context.canSaveAll, "Clean required result missing from Save All")
        let background = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false); background.isReleasedWhenClosed = false
        defer { background.close() }
        focused = background; context.refresh()
        try require(!context.canSaveAll && !context.saveAll() && !context.canClose && !context.close() && !FileManager.default.fileExists(atPath: output.path), "Application command used stale background editor")
        focused = owner.window; context.refresh()
        try require(context.saveAll(), "Save All did not dispatch to current editor")
        try await wait { !owner.model.mergeToolHasPendingWork && !owner.model.dirty }
        try require(owner.model.mergeToolSaved && (try Data(contentsOf: output)) == Data("mine\n".utf8), "Save All failed mandatory independent output")
        owner.model.confirmingQuit = true; context.refresh()
        try require(!context.canSaveAll && !context.saveAll() && !context.canClose && !context.close(), "Quit gate bypassed by application command")
        owner.model.confirmingQuit = false
        // Native focused menus remain the source of actual Open/Edit/View/Help.
        var main = NSMenu(title: "Private Merge menu")
        owner.editorCommandMenu?.applicationMenu = { main }; owner.editorCommandMenu?.keyWindow = { focused }
        owner.editorCommandMenu?.install(in: main)
        let names = main.items.map(\.title)
        try require(["File", "Edit", "Navigate", "View", "Help"].allSatisfy(names.contains) && !names.contains("TurtleGit"), "Tool lost focused native menus or added repository root")
        let file = main.items.first { $0.title == "File" }!.submenu!
        try require(file.items.contains { $0.title == "Open" } && file.items.contains { $0.title == "Save" } && file.items.contains { $0.title == "Save As…" }, "Tool native File commands missing")
        let replacedItem = file.items.first { $0.title == "Open" }!
        // A framework can replace its application menu after the editor became
        // key. Its existing lifecycle synchronizer must adopt the new menu even
        // without a second windowDidBecomeKey call.
        main = NSMenu(title: "Rebuilt localized SwiftUI menu")
        let priorWindowsMenu = NSApp.windowsMenu, priorHelpMenu = NSApp.helpMenu
        defer { NSApp.windowsMenu = priorWindowsMenu; NSApp.helpMenu = priorHelpMenu }
        func localizedRoot(_ title: String, action: String?, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: ""), submenu = NSMenu(title: title)
            root.submenu = submenu
            if let action {
                let anchor = NSMenuItem(title: "Framework-owned anchor", action: NSSelectorFromString(action), keyEquivalent: key)
                anchor.keyEquivalentModifierMask = modifiers; submenu.addItem(anchor)
            }
            main.addItem(root); return root
        }
        _ = localizedRoot("Application privée", action: "terminate:", key: "q", modifiers: .command)
        let newFileRoot = localizedRoot("Fichier", action: "saveAllDocuments:", key: "s", modifiers: [.command, .option])
        let editRoot = localizedRoot("Édition", action: "copy:", key: "c", modifiers: .command)
        let viewRoot = localizedRoot("Affichage", action: "toggleFullScreen:")
        let windowRoot = localizedRoot("Fenêtre", action: "performMiniaturize:", key: "m", modifiers: .command)
        let helpRoot = localizedRoot("Aide", action: "showHelp:")
        NSApp.windowsMenu = windowRoot.submenu; NSApp.helpMenu = helpRoot.submenu
        NotificationCenter.default.post(name: NSApplication.didUpdateNotification, object: NSApp)
        try await wait { newFileRoot.submenu?.items.contains { $0.title == "Open" } == true }
        try require(!replacedItem.isEnabled && file.items.isEmpty, "Replaced menu kept old editor epoch live")
        let replacementFile = newFileRoot.submenu!, retained = replacementFile.items.first { $0.title == "Open" }!
        try require(replacementFile.items.filter { $0.title == "Open" }.count == 1 && main.items.map(\.title) == ["Application privée", "Fichier", "Édition", "Navigate", "Affichage", "Fenêtre", "Aide"], "Rebuilt localized menu duplicated or reordered standard roots")
        try require(editRoot.submenu?.items.contains { $0.title == "Find" } == true && viewRoot.submenu?.items.contains { $0.title == "Locator bar" } == true && helpRoot.submenu?.items.contains { $0.title == "TurtleGitMerge Help" } == true, "Native commands did not merge into localized Edit/View/Help")
        focused = background; owner.editorCommandMenu?.remove()
        try require(!retained.isEnabled && replacementFile.items.count == 1 && main.items.map(\.title) == ["Application privée", "Fichier", "Édition", "Affichage", "Fenêtre", "Aide"], "Retirement removed framework roots/anchors or kept stale editor actions")
        focused = owner.window; context.refresh()
        try require(context.canClose && context.close(), "Close did not dispatch to current clean comparison")
        try await wait { owner.window?.isVisible == false }
        focused = nil
        try await wait { !owner.model.mergeToolHasPendingWork }
        context.refresh(); try require(!context.canSaveAll && !context.saveAll(), "Closed editor retained application Save All")
        let both = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs, deferInitialLoad: true)
        defer { both.close() }
        both.window!.alphaValue = 0; both.window!.orderFront(nil); both.model.beginTransferredDocument()
        try await wait { !both.model.mergeToolHasPendingWork && !both.model.filtering && both.model.document != nil }
        both.model.updateDraft("left edit\n", base: true)
        try require(both.model.dirty && !both.model.activeDirty, "Fixture did not keep edited left pane separate from clean active Mine")
        focused = both.window; context.refresh()
        try require(context.canSaveAll && context.saveAll(), "Save All ignored dirty inactive pane")
        try await wait { !both.model.mergeToolHasPendingWork && !both.model.dirty }
        try require((try Data(contentsOf: base)) == Data("left edit\n".utf8) && (try Data(contentsOf: mine)) == Data("mine\n".utf8), "Save All did not save inactive pane independently")
        try require(context.close(), "Close did not preserve current clean comparison ownership")
        try await wait { both.window?.isVisible == false && !both.model.mergeToolHasPendingWork }
        try require(!context.close(), "Close dispatched to already closed comparison")
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let opener = MergeOpenWindowController(preferences: prefs, pasteboard: pasteboard)
        defer { opener.close() }
        var openerClosed = 0; opener.onClosed = { openerClosed += 1 }
        opener.window!.alphaValue = 0; opener.showWindow(nil); opener.window!.orderFront(nil)
        focused = opener.window; context.refresh()
        try require(context.canClose && context.close(), "Close did not dispatch to owned Open chooser")
        try await wait { openerClosed == 1 && opener.window?.isVisible == false && opener.pendingChoices == 0 }
        try require(!context.close(), "Retired Open chooser retained Close action")
        // The utility command must target its own native controller, even
        // when it overlays an existing Merge document or scoped Settings owner.
        let about=TurtleGitAboutController(tool:.merge,information:.init(application:root,version:"1.0",build:"private"))
        defer{about.close()}
        var aboutClosed=0;about.onClosed={aboutClosed += 1}
        about.window!.alphaValue=0;about.window!.setFrameOrigin(.init(x:-20000,y:-20000));about.showWindow(nil);about.window!.orderFront(nil)
        focused=about.window;context.refresh()
        try require(context.canClose && !context.canSaveAll,"About did not own Close independently of the background editor")
        let utilitySheet=NSWindow(contentRect:.init(x:0,y:0,width:160,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        utilitySheet.isReleasedWhenClosed=false;utilitySheet.alphaValue=0;utilitySheet.setFrameOrigin(.init(x:-20000,y:-20000))
        about.window!.beginSheet(utilitySheet,completionHandler:nil);context.refresh()
        try require(!context.canClose && !context.close() && aboutClosed==0,"About Close bypassed its attached sheet")
        about.window!.endSheet(utilitySheet);utilitySheet.orderOut(nil);utilitySheet.close()
        try await wait{about.window?.attachedSheet==nil && utilitySheet.sheetParent==nil}
        context.refresh();try require(context.canClose && context.close(),"About custom Close was unavailable")
        try await wait{about.retired && aboutClosed==1 && about.window?.isVisible==false}
        try require(!context.close() && aboutClosed==1,"Closed About accepted a duplicate Close")
        let utilityWorkspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        utilityWorkspace.fileComparisonPreferences=prefs
        defer{utilityWorkspace.stopMonitoringForTermination()}
        let utilityAppearance=AppAppearance(preferences:prefs),scoped=SettingsPresentationService()
        scoped.install(workspace:utilityWorkspace,appearance:utilityAppearance)
        scoped.present={owner in owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.showWindow(nil);owner.window?.orderFront(nil)}
        scoped.show(globalOnly:true,initialPage:.advanced)
        defer{scoped.controller?.close()}
        try await wait{scoped.controller?.window?.isVisible==true && scoped.navigation?.canDismiss==true}
        let settings=try unwrap(scoped.controller?.window),navigation=try unwrap(scoped.navigation)
        try require(SettingsPresentationService.shared.controller?.window !== settings,"Fixture used shared rather than scoped Settings")
        focused=settings;context.refresh()
        try require(context.canClose && !context.canSaveAll,"Scoped Settings did not own custom Close")
        var save:CheckedContinuation<Bool,Never>?,dirty=true
        navigation.transaction.register("private-held-utility-save",participant:.init(page:.advanced,modified:{dirty},validate:{nil},apply:{await withCheckedContinuation{save=$0}},cancel:{dirty=false}))
        navigation.transaction.apply(closeAfter:false)
        defer{if let pending=save{save=nil;pending.resume(returning:false)}}
        try await wait{save != nil}
        context.refresh();try require(!context.canClose && !context.close() && scoped.controller?.window === settings,"Scoped Settings Close bypassed an active save")
        dirty=false;save?.resume(returning:true);save=nil
        try await wait{navigation.canDismiss && !navigation.transaction.busy}
        context.refresh();try require(context.canClose && context.close(),"Scoped Settings failed to close through its own delegate")
        try await wait{scoped.controller==nil && !settings.isVisible && SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0}
        try require(!context.close(),"Retired scoped Settings accepted duplicate Close")
        focused = nil
        print("PASS standalone scene classification/bootstrap, lazy workspace, focused native menus and Save All ownership, exact About/scoped Settings Close and sheet/save guards")
    }
}
