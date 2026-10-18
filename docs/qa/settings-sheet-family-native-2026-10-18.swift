// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SettingsSheetFamilyVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    static func trace(_ message:String) { fputs("Settings sheet phase: \(message)\n",stderr);fflush(stderr) }
    static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1800 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Settings sheet family did not settle")
    }
    static func views(_ root:NSView)->[NSView] { [root]+root.subviews.flatMap(views) }
    static func footer(_ title:String,_ navigation:SettingsNavigationController) throws -> NSButton {
        guard let button=views(navigation.view).compactMap({$0 as? NSButton}).first(where:{$0.title==title && $0.target === navigation}),button.action != nil else {throw Failure(description:"No owned Settings footer "+title)};return button
    }
    static func click(_ button:NSButton) { _ = NSApp.sendAction(button.action!,to:button.target,from:button) }
    static func verify(properties:Bool) async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Sheet Family QA"),("user.email","sheet@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_ = try await repo.run(["config",key,value])}
        let input=root.appendingPathComponent("file.txt");try Data("base\n".utf8).write(to:input);try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:input)
        let domain="TurtleGit.SettingsSheetFamily.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:domain)!
        defer {prefs.removePersistentDomain(forName:domain)}
        let originalGlobal=UserDefaults.standard.data(forKey:"TurtleGit.UnifiedDiffAppearance")
        var appearance=UnifiedDiffAppearance();appearance.fontSize=27;appearance.save(to:prefs)
        trace(properties ? "Properties captured repository, preferences and draft":"Unified Diff captured document and Settings")
        if properties { try await propertiesFlow(repo,prefs) } else { try await patchFlow(repo,prefs) }
        try await wait {SettingsSheetController.activeSheets==0 && SettingsTransaction.activeApplications==0 && GitPropertiesWindowModel.activeOperations==0 && PatchDocumentSession.activeOperations==0}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Settings handoff changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:input)==bytes,"Settings handoff changed index/input")
        try require(UserDefaults.standard.data(forKey:"TurtleGit.UnifiedDiffAppearance")==originalGlobal,"Captured Settings changed standard preferences")
        print("PASS: Settings sheet family captured context/preferences, real footer Close/OK/Cancel, draft/replacement fences, actual release, Quit and forced retirement")
    }
    static func checkPrivateAppearance(_ navigation:SettingsNavigationController) async throws {
        try await wait {navigation.canDismiss}
        navigation.requestCommandPage(.unifiedDiff)
        try await wait {navigation.selected == .unifiedDiff && views(navigation.view).compactMap({$0 as? NSTextField}).contains(where:{$0.stringValue=="27"})}
    }
    static func propertiesFlow(_ repository:GitRepository,_ prefs:UserDefaults) async throws {
        let owner=GitPropertiesWindowController(contexts:[GitPropertiesContext(repository:repository,paths:["file.txt"],access:nil,submodule:false)],preferences:prefs)
        defer {owner.close()};let model=owner.model,window=owner.window!;window.alphaValue=0;window.orderFront(nil)
        try await wait {!model.busy && model.current != nil}
        model.set(\GitPropertyDraft.skipWorktree,.on);let draft=model.draft
        model.showSettings()
        try await wait {owner.settingsWindow?.sheetParent===window && owner.settingsNavigation != nil}
        let child=owner.settingsWindow!,navigation=owner.settingsNavigation!
        try require(child.alphaValue==0 && model.hasSettings && !owner.windowShouldClose(window) && SettingsSheetController.activeSheets==1,"Properties Settings ownership/private presentation missing")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored owned Settings")
        try await checkPrivateAppearance(navigation)
        let oldCancel=try footer("Cancel",navigation);click(oldCancel)
        try await wait {owner.settingsWindow==nil && window.attachedSheet==nil && SettingsSheetController.activeSheets==0}
        try require(!model.hasSettings && model.draft==draft && model.canApply,"Settings Cancel lost Properties draft or restored controls too early")
        trace("Properties explicit Close and held apply")
        model.showSettings();try await wait {owner.settingsWindow?.sheetParent===window && owner.settingsNavigation?.canDismiss==true}
        let close=owner.settingsWindow!;close.performClose(nil)
        try await wait {owner.settingsWindow==nil && window.attachedSheet==nil}
        model.showSettings();try await wait {owner.settingsWindow?.sheetParent===window && owner.settingsNavigation?.canDismiss==true}
        let heldNavigation=owner.settingsNavigation!
        var held:CheckedContinuation<Bool,Never>?
        defer {held?.resume(returning:false);held=nil}
        heldNavigation.transaction.register("qa-owned-save",participant:.init(page:.general,modified:{true},validate:{nil},apply:{await withCheckedContinuation{held=$0}},cancel:{}))
        click(try footer("OK",heldNavigation));try await wait {held != nil}
        owner.settingsWindow?.performClose(nil);click(try footer("Cancel",heldNavigation))
        try require(model.hasSettings && owner.settingsWindow != nil && SettingsTransaction.activeApplications>0,"Busy Properties Settings accepted closure")
        held?.resume(returning:true);held=nil
        try await wait {owner.settingsWindow==nil && window.attachedSheet==nil && SettingsTransaction.activeApplications==0}
        try require(model.draft==draft,"Applied child Settings discarded property flags")
        trace("Properties forced owner closure")
        model.showSettings();try await wait {owner.settingsWindow?.sheetParent===window && owner.settingsNavigation?.canDismiss==true}
        let retiredCancel=try footer("Cancel",owner.settingsNavigation!)
        owner.close();click(retiredCancel)
        try await wait {owner.settingsWindow==nil && window.attachedSheet==nil && SettingsSheetController.activeSheets==0}
        try require(model.retired && !model.hasSettings,"Late child Settings revived Properties owner")
    }
    static func patchFlow(_ repository:GitRepository,_ prefs:UserDefaults) async throws {
        let owner=PatchWindowController(repository:repository,access:nil,preferences:prefs),window=owner.window!,model=owner.model,session=owner.documentSession!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        let original=Data("diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-base\n+first\n".utf8)
        let replacement=Data(String(decoding:original,as:UTF8.self).replacingOccurrences(of:"+first",with:"+replacement").utf8)
        owner.presentDocument(original,title:"Original",comparison:"Original",information:"Private QA")
        model.editDocument(model.document.text.replacingOccurrences(of:"+first",with:"+dirty"))
        try require(model.documentDirty,"Patch edit did not become a draft")
        let dirty=model.document.text,identity=session.documentIdentity
        session.showSettings();try await wait {session.settingsWindow?.sheetParent===window && session.settingsNavigation != nil}
        let navigation=session.settingsNavigation!
        try require(navigation.globalOnly && navigation.selected == .unifiedDiff && session.settingsWindow?.alphaValue==0 && model.busy,"Unified Diff Settings did not retain captured scope/page/private presentation")
        try await checkPrivateAppearance(navigation)
        owner.presentDocument(replacement,title:"Rejected replacement",comparison:"Rejected",information:"Private QA")
        try require(session.documentIdentity==identity && model.document.text==dirty,"Settings allowed an early document replacement")
        var questions=0;session.askChanges={_,reply in questions += 1;reply(.cancel)}
        click(try footer("Cancel",navigation))
        try await wait {session.settingsWindow==nil && window.attachedSheet==nil && !model.busy && PatchDocumentSession.activeOperations==0 && questions==1}
        try require(model.document.text==dirty && model.documentDirty && window.title=="Original","Settings dismissal lost dirty patch after cancelled replacement")
        trace("Unified Diff OK and queued document replacement")
        session.showSettings();try await wait {session.settingsWindow?.sheetParent===window && session.settingsNavigation?.canDismiss==true}
        let okNavigation=session.settingsNavigation!
        owner.presentDocument(replacement,title:"Accepted replacement",comparison:"Accepted",information:"Private QA")
        session.askChanges={_,reply in questions += 1;reply(.discard)}
        click(try footer("OK",okNavigation))
        try await wait {session.settingsWindow==nil && window.attachedSheet==nil && !model.busy && PatchDocumentSession.activeOperations==0 && window.title=="Accepted replacement"}
        try require(session.documentIdentity != identity && !model.documentDirty && model.exportDocument.bytes==replacement && questions==2,"Queued replacement did not wait for actual Settings release")
        trace("Unified Diff owner retirement suppresses queued publication")
        session.showSettings();try await wait {session.settingsWindow?.sheetParent===window && session.settingsNavigation?.canDismiss==true}
        let retiredCancel=try footer("Cancel",session.settingsNavigation!)
        owner.presentDocument(original,title:"Late forbidden",comparison:"Late",information:"Private QA")
        owner.close();click(retiredCancel)
        try await wait {session.settingsWindow==nil && window.attachedSheet==nil && SettingsSheetController.activeSheets==0}
        try require(model.retired && window.title != "Late forbidden","Retired Settings reopened/replaced patch")
    }
}
