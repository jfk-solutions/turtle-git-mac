import AppKit
import SwiftUI
import TurtleGitCore

private actor SettingsAuthenticationFixture: SSHAuthenticationStore {
    func read(identity:String) async throws -> String? { nil }
    func save(identity:String,name:String,passphrase:String) async throws {}
    func entries() async throws -> [SSHAuthenticationEntry] { [.init(id:"private",name:"Fixture key")] }
    func remove(identity:String) async throws {}
}
private actor SettingsSMTPFixture: SMTPCredentialStore {
    func login() async throws -> String { "" }
    func store(login:String,password:String) async throws {}
    func clear() async throws {}
}
@main struct SettingsFamilyVerification {
    struct Failure: Error { let message:String }
    @MainActor static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    @MainActor static func wait(_ stage:String,_ ready:()->Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(message:stage)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Settings family failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), suite="TurtleGit.SettingsFamily.QA."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let keys=["SymbolizeRefNames","GravatarUrl","LogFontSize","LogFontName","MaxHistoryItems","NoSounds","TurtleGitBlame.TabSize","TurtleGitBlame.FontSize","TurtleGit.UnifiedDiffAppearance","TurtleGit.UnifiedDiffViewer.Application","TurtleGit.AlternativeEditor.Application","AutoCompleteMinChars","StyleCommitMessages","VersionCheck","TurtleGit.GitEngine","SendMail.Address","SendMail.Port","hooks"]
        let original=keys.map { UserDefaults.standard.object(forKey:$0).map { String(describing:$0) } }
        prefs.set(2,forKey:"SendMail.DeliveryType"); prefs.set(false,forKey:"VersionCheck"); prefs.set(true,forKey:"StyleCommitMessages"); prefs.set(false,forKey:"SymbolizeRefNames"); prefs.set(11,forKey:"LogFontSize")
        prefs.set(true,forKey:"TurtleGit.UnifiedDiffViewer.Enabled"); prefs.set("/Applications/Fixture.app",forKey:"TurtleGit.UnifiedDiffViewer.Application")
        prefs.set(true,forKey:"TurtleGit.AlternativeEditor.Custom"); prefs.set("/Applications/Fixture.app",forKey:"TurtleGit.AlternativeEditor.Application")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        let navigation=SettingsNavigationController(workspace:workspace,appearance:AppAppearance(preferences:prefs),globalOnly:true,preferences:prefs,smtpCredentials:SettingsSMTPFixture())
        let window=NSWindow(contentRect:.init(x:0,y:0,width:1100,height:820),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentViewController=navigation
        defer { window.close(); navigation.invalidate() }
        navigation.viewDidAppear()
        let outline=views(navigation.view).compactMap { $0 as? NSOutlineView }.first!
        outline.expandItem(nil,expandChildren:true)
        func choose(_ title:String) throws {
            for row in 0..<outline.numberOfRows {
                if let view=outline.view(atColumn:0,row:row,makeIfNecessary:true), views(view).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue==title }) {
                    outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); return
                }
            }
            throw Failure(message:"Missing Settings page: "+title)
        }
        try await wait("General update control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSButton }.contains { $0.title=="Automatically check for newer versions every week" } }
        views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title=="Automatically check for newer versions every week" }!.performClick(nil)
        try await wait("General draft") { navigation.transaction.modified }
        try choose("Message Editor")
        try await wait("Message editor control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSButton }.contains { $0.title=="Style commit messages" } }
        views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title=="Style commit messages" }!.performClick(nil)
        try await wait("Message editor draft") { navigation.transaction.modified }
        try choose("Dialogs 1"); navigation.transaction.apply(closeAfter:false)
        try await wait("Integration cached Apply") { !navigation.transaction.busy }
        try require(prefs.bool(forKey:"VersionCheck") && !prefs.bool(forKey:"StyleCommitMessages"),"General/Message Editor ignored owner domain")
        let engine=GeneralGitSettingsModel(preferences:prefs)
        engine.draft.choice = .custom; engine.draft.path = CommandLine.arguments[2]
        let engineApplied = await engine.apply()
        try require(engineApplied && GitEnginePreferences.load(from:prefs).path==CommandLine.arguments[2],"Validated Git-engine Apply ignored owner domain")
        try choose("Dialogs 1")
        try await wait("Dialogs controls") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSButton }.contains { $0.title=="Symbolize ref names" } }
        let checkbox=views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title=="Symbolize ref names" }!
        checkbox.performClick(nil)
        try await wait("Log draft registration") { navigation.transaction.modified }
        try require(!prefs.bool(forKey:"SymbolizeRefNames"),"Draft wrote before Apply")
        let combo=views(navigation.view).compactMap { $0 as? NSComboBox }.first { $0.objectValues.compactMap { $0 as? String }.contains("https://gravatar.com/avatar/%HASH%?d=retro") }!
        combo.stringValue="https://example.invalid/avatar/%HASH%"
        combo.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:combo))
        try choose("Colors 3"); try await wait("Colors page") { navigation.selected == .colors3 }
        navigation.transaction.apply(closeAfter:false)
        try await wait("Settings Apply") { !navigation.transaction.busy }
        try require(navigation.transaction.error==nil && prefs.bool(forKey:"SymbolizeRefNames") && prefs.string(forKey:"GravatarUrl")=="https://example.invalid/avatar/%HASH%","Cached Log draft did not apply to private domain")
        try choose("Dialogs 1"); checkbox.performClick(nil)
        try await wait("Cancel draft") { navigation.transaction.modified }
        navigation.transaction.cancel()
        try await wait("Cancel restored") { !navigation.transaction.modified }
        try require(prefs.bool(forKey:"SymbolizeRefNames"),"Cancel changed persisted Log choice")
        try choose("Dialogs 2")
        try await wait("Dialogs 2 controls") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSButton }.contains { $0.title=="Disable sounds" } }
        let sounds=views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title=="Disable sounds" }!
        sounds.performClick(nil); try await wait("Dialogs 2 draft") { navigation.transaction.modified }
        try choose("Colors 2"); navigation.transaction.apply(closeAfter:false)
        try await wait("Dialogs 2 Apply") { !navigation.transaction.busy }
        try require(prefs.bool(forKey:"NoSounds"),"Cached Dialogs 2 applied outside owner domain")
        func enter(_ placeholder:String,_ text:String) throws {
            guard let field=views(navigation.view).compactMap({ $0 as? NSTextField }).first(where:{ $0.placeholderString==placeholder }) else { throw Failure(message:"Missing field: "+placeholder) }
            field.stringValue=text
            field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
        }
        try choose("TurtleGitBlame")
        try await wait("Blame tab control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString=="Tab size" } }
        try enter("Tab size","6"); try await wait("Blame draft") { navigation.transaction.modified }
        try choose("Unified Diff"); navigation.transaction.apply(closeAfter:false)
        try await wait("Cached Blame Apply") { !navigation.transaction.busy }
        try require(GitBlamePresentation.load(from:prefs).tabSize==6,"Blame ignored owner domain")
        try await wait("Unified tab control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString=="Tab size" } }
        try enter("Tab size","7"); try await wait("Unified draft") { navigation.transaction.modified }
        try choose("Diff Viewer"); navigation.transaction.apply(closeAfter:false)
        try await wait("Cached Unified Apply") { !navigation.transaction.busy }
        try require(UnifiedDiffAppearance.load(from:prefs).tabSize==7,"Unified appearance ignored owner domain")
        try await wait("Nested viewer control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString=="Viewer application" } }
        try enter("Viewer application","/Applications/ChangedViewer.app")
        try await wait("Nested viewer draft") { navigation.transaction.modified }
        try choose("Alternative Editor"); navigation.transaction.apply(closeAfter:false)
        try await wait("Nested viewer Apply") { !navigation.transaction.busy }
        try require(UnifiedDiffViewerPreferences.load(from:prefs).applicationPath=="/Applications/ChangedViewer.app","Nested viewer ignored Diff owner domain")
        try await wait("Alternative editor control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString=="Editor application" } }
        try enter("Editor application","/Applications/ChangedEditor.app")
        try await wait("Alternative editor draft") { navigation.transaction.modified }
        try choose("Advanced"); navigation.transaction.apply(closeAfter:false)
        try await wait("Alternative editor Apply") { !navigation.transaction.busy }
        try require(AlternativeEditorPreferences.load(from:prefs).applicationPath=="/Applications/ChangedEditor.app","Alternative editor ignored owner domain")
 try await wait("Advanced table") { navigation.selected == .advanced }
        let advanced=AdvancedSettingsModel(defaults:prefs,publishFinderMenu:{ _ in })
        try require(advanced.edit("AutoCompleteMinChars",text:"5"),"Advanced numeric edit rejected")
        advanced.apply(); try require(prefs.integer(forKey:"AutoCompleteMinChars")==5,"Advanced ignored owner domain")
        advanced.edit("AutoCompleteMinChars",text:"6"); advanced.cancel(); try require(advanced.values["AutoCompleteMinChars"]=="5","Advanced Cancel lost saved value")
        try choose("Email")
        try await wait("Email port control") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString=="25" && $0.isEnabled } }
        try enter("25","2525"); try await wait("Email draft") { navigation.transaction.modified }
        try choose("Dialogs 1"); navigation.transaction.apply(closeAfter:false)
        try await wait("Cached Email Apply") { !navigation.transaction.busy }
        try require(prefs.integer(forKey:"SendMail.Port")==2525,"Email ignored owner domain: port=\(prefs.integer(forKey:"SendMail.Port")) error=\(navigation.transaction.error ?? "none") modified=\(navigation.transaction.modified)")
        let hooks=HookSettingsModel(preferences:prefs)
        hooks.activate(repository:nil,access:nil); try await wait("Private Hooks load") { hooks.loaded && !hooks.busy }
        hooks.hooks=[ClientHook(path:root.path,command:"/usr/bin/true")]
        let hooksApplied=await hooks.apply()
        try require(hooksApplied && ClientHookPreferences.globals(prefs).count==1,"Global Hooks ignored owner domain")
        hooks.hooks=[]; hooks.cancel(); try require(hooks.hooks.count==1,"Hooks Cancel lost saved snapshot"); hooks.invalidate()
        let replacement=SettingsTransaction()
        var held:CheckedContinuation<Bool,Never>?, staleWrites=0
        replacement.register("gate",participant:.init(page:.general,modified:{ true },validate:{ nil },apply:{ await withCheckedContinuation { held=$0 } },cancel:{}))
        replacement.register("target",participant:.init(page:.network,modified:{ true },validate:{ nil },apply:{ staleWrites += 1; return true },cancel:{}))
        replacement.apply(closeAfter:false); try await wait("Held Settings Apply") { held != nil }
        replacement.register("target",participant:.init(page:.network,modified:{ true },validate:{ nil },apply:{ staleWrites += 1; return true },cancel:{}))
        held!.resume(returning:true); try await wait("Replaced Settings refusal") { !replacement.busy }
        try require(replacement.error != nil && staleWrites==0,"New Settings context applied an obsolete snapshot")
        replacement.invalidate()
        let chooser=ToolApplicationChooser(); chooser.window=window
        var chooserReplies=0
        chooser.choose({ _,_ in chooserReplies += 1 },failure:{ _ in chooserReplies += 1 })
        try await wait("Owned app chooser") { window.attachedSheet != nil }
        chooser.window=nil; chooser.cancel()
        try await wait("Chooser departure cleanup") { window.attachedSheet == nil }
        try require(chooserReplies==0,"Canceled chooser applied a retained response")
        let font=MessageEditorFontSettings(defaults:prefs), fontTransaction=SettingsTransaction()
        let fontWindow=NSWindow(contentRect:.init(x:0,y:0,width:700,height:300),styleMask:[.titled],backing:.buffered,defer:false)
        fontWindow.isReleasedWhenClosed=false; fontWindow.contentView=NSHostingView(rootView:font.environment(\.settingsTransaction,fontTransaction).defaultAppStorage(prefs))
        defer { fontWindow.close(); fontTransaction.invalidate() }
        try await wait("Font controls") { fontWindow.contentView!.layoutSubtreeIfNeeded(); return views(fontWindow.contentView!).compactMap { $0 as? NSComboBox }.count >= 1 }
        let sizes=views(fontWindow.contentView!).compactMap { $0 as? NSComboBox }.first { $0.objectValues.compactMap { $0 as? String }.contains("10") }!
        sizes.stringValue="17"; sizes.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:sizes))
        try await wait("Font modified") { fontTransaction.modified }; fontTransaction.apply(closeAfter:false)
        try await wait("Font Apply") { !fontTransaction.busy }
        try require(prefs.integer(forKey:"LogFontSize")==17,"Font ignored private domain")
        let status=StatusColorSettingsModel(preferences:prefs), logColors=LogColorSettingsModel(preferences:prefs)
        status.set(.conflict,rgb:[13,27,51]); status.cancel(); try require(!status.changed,"Status Cancel retained draft")
        status.set(.conflict,rgb:[13,27,51]); status.apply()
        try require(StatusColorPreferences.load(prefs).rgb(.conflict)==[13,27,51],"Status colors ignored private domain")
        logColors.set(.branchLine1,rgb:[14,28,52]); logColors.setLineWidth(4); logColors.setNodeSize(12); logColors.apply()
        let loadedColors=LogColorPreferences.load(prefs)
        try require(loadedColors.rgb(.branchLine1)==[14,28,52] && loadedColors.lineWidth==4 && loadedColors.nodeSize==12,"Graph colors/dimensions ignored private domain")
        let cacheRoot=root.appendingPathComponent("cache"); try FileManager.default.createDirectory(at:cacheRoot,withIntermediateDirectories:true)
        let record=cacheRoot.appendingPathComponent(String(repeating:"a",count:64)+".json"); try Data("record".utf8).write(to:record)
        let temporary=TemporaryFileStore(root:root.appendingPathComponent("temporary"))
        let saved=SavedDataSettingsModel(store:ActionLogStore(storageURL:root.appendingPathComponent("log")),preferences:prefs,temporaryFiles:temporary,historyCache:HistoryFileCache(root:cacheRoot),showFile:{ _ in true })
        try require(saved.historyCacheRecords==1,"Saved Data missed cache record")
        saved.clearHistoryCache(); try require(saved.historyCacheRecords==0,"Saved Data did not clear own cache")
        var answer:((Bool)->Void)?; saved.confirmTemporaryClear={ answer=$0 }; saved.clearTemporaryFiles(); saved.retire(); answer?(true)
        try require(!saved.confirmingTemporaryClear && saved.retired,"Closed Saved Data accepted retained clear response")
        saved.activate(); saved.maximumLines="123"; saved.apply(); try require(prefs.integer(forKey:"MaxLinesInLogfile")==123,"Reactivated Saved Data draft failed")
        let authentication=SavedDataAuthenticationOwner(store:SettingsAuthenticationFixture())
        authentication.show(owner:window)
        try await wait("Authentication child") { authentication.controller?.model.busy==false }
        try require(authentication.controller?.model.entries.count==1,"Authentication child did not use owned store")
        authentication.close(); try await wait("Authentication cleanup") { SavedSSHAuthenticationModel.activeOperations==0 }
        try require(keys.map { UserDefaults.standard.object(forKey:$0).map { String(describing:$0) } }==original,"Settings changed global preferences")
        print("Settings family: actual navigation/cached Apply/Cancel, private Log/font drafts and Gravatar presets, owned cache clear, late cleanup refusal and authentication child cleanup passed. Owned windows closed.")
    }
}
