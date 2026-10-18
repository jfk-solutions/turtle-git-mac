import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct CredentialSourceFamilyVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    static func require(_ value:Bool,_ text:String)throws {if !value {throw Failure.assertion(text)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height <= 850,"Credential host escaped viewport")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let selected=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:selected),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("Capture PNG missing")}
            try png.write(to:directory.appendingPathComponent("credential-settings-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Credential source family: native editable helper/labels, chain preservation, removed-group and failed refresh, captured editor/selection retirement, simple-mode manager and owned Settings/Quit")}catch {fputs("Credential source failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,askpass:nil)
        _=try await repo.run(["init","-b","main"])
        let url="https://source.example.invalid",key="credential."+url+".helper",other="https://other.example.invalid"
        for helper in ["","source-one"] {_=try await repo.run(["config","--local","--add",key,helper])}
        _=try await repo.run(["config","--local","credential."+url+".username","source-user"])
        _=try await repo.run(["config","--local","credential."+other+".helper","source-two"])
        _=try await repo.run(["config","--global","credential.https://global.example.invalid.helper","source-global"])
        let model=CredentialSettingsModel(repository:repo,access:nil,localAvailable:true);model.authorizeFile={_ in true};model.confirmAction={_,_,_ in true};defer {model.deactivate()}
        model.activate();try await wait {model.snapshot != nil && !model.busy}
        guard let first=model.snapshot?.groups.first(where:{$0.url==url}),let second=model.snapshot?.groups.first(where:{$0.url==other}) else {throw Failure.assertion("Fixture groups absent")}
        model.select(first.id);try await wait {!model.busy && model.selected==first.id}
        try require(model.draft.helpers == ["","source-one"] && !model.modified,"Chain did not survive source selection")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.alphaValue=0;window.title="Credential – Settings – TurtleGit"
        let suite="TurtleGit.CredentialSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,transaction=SettingsTransaction()
        defer {prefs.removePersistentDomain(forName:suite);transaction.invalidate();model.deactivate();window.contentView=nil;window.close()}
        let host=NSHostingView(rootView:CredentialSettingsPage(model:model).environment(\.settingsTransaction,transaction).defaultAppStorage(prefs)),viewport=SettingsPageViewport(frame:window.contentLayoutRect)
        viewport.autoresizingMask=[.width,.height];window.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        viewport.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
        func helperCombo()->NSComboBox? {views(host).compactMap {$0 as? NSComboBox}.first {$0.accessibilityLabel()=="Credential helper"}}
        try await wait {helperCombo() != nil}
        let combo=helperCombo()!,oldIdentity=model.editorIdentity
        guard let delegate=combo.delegate as? CloneHistoryCombo.Coordinator else {throw Failure.assertion("Native helper delegate absent")}
        let oldReply=delegate.change
        try require(combo.isEnabled && combo.isEditable && combo.numberOfItems==model.helpers.count && combo.stringValue.isEmpty,"Native editable helper differs")
        model.deactivate();try await wait {helperCombo()?.isEnabled == false};model.activate();try await wait {helperCombo()?.isEnabled == true}
        oldReply("late after reactivation");try require(model.editorIdentity != oldIdentity && model.draft.helpers == ["","source-one"],"Retired field callback overwrote chain")
        guard let current=helperCombo(),let editing=current.delegate as? CloneHistoryCombo.Coordinator else {throw Failure.assertion("Reactivated helper absent")}
        current.stringValue="typed-helper --argument";editing.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:current))
        try require(model.draft.helpers == ["typed-helper --argument"] && model.modified,"Native helper edit did not intentionally replace chain")
        // F5/Refresh never discards an unsaved helper.
        let dirty=model.draft;var reads=0
        model.readCredentials={_ in reads += 1;return try await repo.credentialConfiguration()};model.refresh()
        try require(reads == 0 && model.draft==dirty,"Refresh discarded an unsaved helper")
        model.cancelDraft();try require(model.draft.helpers == ["","source-one"],"Cancel did not restore accepted chain")
        // All required reads complete before origins/list/mode/selection change.
        let accepted=model.snapshot,acceptedFiles=model.files,acceptedDraft=model.draft
        func acceptedOrigins()->Bool {
            [model.files?.local,model.files?.global,model.files?.xdg,model.files?.system] == [acceptedFiles?.local,acceptedFiles?.global,acceptedFiles?.xdg,acceptedFiles?.system]
        }
        guard let globalPointer=getenv("GIT_CONFIG_GLOBAL") else {throw Failure.assertion("Private global configuration absent")}
        let globalPath=String(cString:globalPointer),replacementGlobal=root.appendingPathComponent("replacement-global.config")
        try Data().write(to:replacementGlobal);setenv("GIT_CONFIG_GLOBAL",replacementGlobal.path,1)
        defer {setenv("GIT_CONFIG_GLOBAL",globalPath,1)}
        var reply:CheckedContinuation<GitCredentialSnapshot,Error>?
        model.readCredentials={_ in try await withCheckedThrowingContinuation {reply=$0}}
        model.refresh();try await wait {reply != nil}
        try require(model.snapshot==accepted && acceptedOrigins() && model.draft==acceptedDraft,"Pending refresh published partial credential fields")
        reply?.resume(throwing:Failure.assertion("late config read"));reply=nil;try await wait {!model.busy}
        try require(model.snapshot==accepted && model.selected==first.id && model.draft==acceptedDraft && model.error != nil,"Failed refresh changed accepted group")
        setenv("GIT_CONFIG_GLOBAL",globalPath,1);model.readCredentials=nil
        // An externally removed selected group cannot remain as a valid draft.
        _=try await repo.run(["config","--local","--remove-section","credential."+url]);model.refresh();try await wait {!model.busy}
        try require(model.selected==nil && model.draft.helpers.isEmpty && !model.draft.valid && !model.modified && model.snapshot?.groups.contains(where:{$0.id==first.id}) == false,"Refresh retained a removed credential group")
        oldReply("resurrect old group");try require(model.draft.helpers.isEmpty,"Old combo reply resurrected deleted credentials")
        model.select(second.id);try await wait {!model.busy && model.selected==second.id}
        model.select("missing-id");try require(!model.busy && model.selected==second.id,"Unknown list id cleared accepted selection")
        model.draft.username="unsaved selection draft";var selection:CheckedContinuation<Bool,Never>?,questions=0
        model.confirmAction={_,_,_ in questions += 1;return await withCheckedContinuation {selection=$0}}
        model.select(nil);model.select(nil);try await wait {selection != nil}
        try require(questions == 1 && CredentialSettingsModel.activeSelections == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Selection question lost serialization/Quit ownership")
        model.deactivate();try require(CredentialSettingsModel.activeSelections == 1,"Retired selection released accepted worker before its reply");model.activate();selection?.resume(returning:true);selection=nil
        try await wait {!model.busy && CredentialSettingsModel.activeSelections == 0};try require(model.selected==second.id && model.draft.username=="unsaved selection draft","Late selection replaced reactivated draft")
        model.confirmAction={_,_,_ in true};model.cancelDraft()
        var launches=0;model.openPasswordManager={launches += 1;return true};model.mode="none"
        try await wait {model.canManagePasswords && helperCombo()?.isEnabled == false}
        model.openKeychain();try require(launches == 1,"Simple mode disabled password-manager routing")
        model.mode="advanced";model.cancelDraft();try await wait {helperCombo()?.isEnabled == true}
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_CREDENTIAL_CAPTURE"] {try await capture(window,to:URL(fileURLWithPath:output))}
        let expected=try await repo.credentialConfiguration()
        try require(model.snapshot == expected && CredentialSettingsModel.activeReads == 0 && CredentialSettingsModel.activeSelections == 0 && CredentialSettingsModel.activeSaves == 0,"UI checks changed configuration or leaked ownership")
    }
}
