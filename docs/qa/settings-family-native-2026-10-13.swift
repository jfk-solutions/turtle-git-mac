import AppKit
import SwiftUI
import TurtleGitCore

private actor SettingsAuthenticationFixture: SSHAuthenticationStore {
    func read(identity:String) async throws -> String? { nil }
    func save(identity:String,name:String,passphrase:String) async throws {}
    func entries() async throws -> [SSHAuthenticationEntry] { [.init(id:"private",name:"Fixture key")] }
    func remove(identity:String) async throws {}
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
        let keys=["SymbolizeRefNames","GravatarUrl","LogFontSize","LogFontName","MaxHistoryItems","NoSounds"]
        let original=keys.map { UserDefaults.standard.object(forKey:$0).map { String(describing:$0) } }
        prefs.set(false,forKey:"SymbolizeRefNames"); prefs.set(11,forKey:"LogFontSize")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        let navigation=SettingsNavigationController(workspace:workspace,appearance:AppAppearance(),globalOnly:true,preferences:prefs)
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
