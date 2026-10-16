import AppKit
import ScreenCaptureKit
import TurtleGitCore

private actor EmailEditorStore:SMTPCredentialStore {
    var username="source-login",password="",writes=0,clears=0
    var waiter:CheckedContinuation<Void,Never>?,holding=false
    func login()async throws->String {username}
    func store(login:String,password:String)async throws {if holding {await withCheckedContinuation {waiter=$0}};username=login;self.password=password;writes += 1}
    func clear()async throws {username="";password="";clears += 1}
    func hold() {holding=true}
    func release() {holding=false;waiter?.resume();waiter=nil}
    func state()->(String,String,Int,Int) {(username,password,writes,clears)}
}
@main struct EmailCredentialEditorVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {for _ in 0..<2500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Screen capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let target=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:target),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG failed")}
            try png.write(to:directory.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Email credential editor: native source fields/focus/limit/defaults, immediate exactly-once Store/Clear, captured/retired replies, owned Quit/Settings and mail-client availability")}catch {fputs("Email editor failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let suite="TurtleGit.EmailEditor."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,store=EmailEditorStore()
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(EmailDelivery.mailClient.rawValue,forKey:"SendMail.DeliveryType")
        let absent=EmailSettingsModel(preferences:prefs,credentials:store,mailClientAvailable:false)
        try require(absent.availableDeliveries == [.direct,.configured] && absent.delivery == .direct && absent.changed,"Missing client did not fall back without invalid menu index")
        try require(EmailConfiguration(preferences:prefs).delivery == .mailClient,"Client discovery rewrote options")
        absent.apply();try require(EmailConfiguration(preferences:prefs).delivery == .direct,"Fallback Apply did not persist direct delivery");absent.invalidate()
        prefs.set(EmailDelivery.configured.rawValue,forKey:"SendMail.DeliveryType");prefs.set(true,forKey:"SendMail.AuthenticationRequired")
        let model=EmailSettingsModel(preferences:prefs,credentials:store,mailClientAvailable:true),owner=SMTPCredentialOwner(model:model)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.alphaValue=0;owner.window=window;owner.present={_,_ in}
        defer {model.invalidate();owner.cancel();window.close()}
        model.refreshCredentials();try await wait {!model.busy};model.editCredentials()
        guard let first=owner.editor else {throw Failure.assertion("Credential owner absent")}
        try require(first.username.stringValue == "source-login" && first.password.stringValue.isEmpty && first.window?.initialFirstResponder === first.password,"Initial username/password focus mismatch")
        try require(model.editingCredentials && !model.canApply && !model.canClear && model.validationError == "Close the credential editor first." && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Idle credential editor lost gates/Quit")
        model.editCredentials();try require(owner.editor === first && EmailSettingsModel.activeCredentialEditors == 1,"Duplicate editor created")
        first.username.stringValue="";first.acceptButton.performClick(nil)
        try require(!first.retired && first.validation.stringValue == "Enter a username." && first.window?.firstResponder === first.username.currentEditor(),"Empty username lost validation focus")
        first.username.stringValue="captured 雪";first.password.stringValue=String(repeating:"a",count:254)+"🐢"+"tail"
        first.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:first.password))
        try require(first.password.stringValue == String(repeating:"a",count:254),"Password split a surrogate at 255 UTF-16 boundary")
        first.password.stringValue=String(repeating:"b",count:253)+"🐢"+"tail"
        await store.hold();first.acceptButton.performClick(nil);first.accept()
        try require(first.retired && first.password.stringValue.isEmpty && owner.editor == nil && !model.editingCredentials && model.busy && EmailSettingsModel.activeCredentialEditors == 0,"Accepted editor did not scrub/settle once")
        await store.release();try await wait {!model.busy && model.pendingOperations == 0}
        var state=await store.state();try require(state.0 == "captured 雪" && state.1 == String(repeating:"b",count:253)+"🐢" && state.2 == 1 && model.login == state.0,"Captured immediate store changed or repeated")
        model.editCredentials();guard let cancelled=owner.editor else {throw Failure.assertion("Cancel editor missing")};cancelled.password.stringValue="cancelled secret";cancelled.cancelButton.performClick(nil);cancelled.accept()
        state=await store.state();try require(state.2 == 1 && cancelled.password.stringValue.isEmpty && !model.editingCredentials,"Cancel/late OK wrote credentials")
        model.editCredentials();guard let changed=owner.editor else {throw Failure.assertion("Captured editor missing")};model.server="replaced.example.invalid";changed.username.stringValue="wrong context";changed.accept();state=await store.state();try require(state.2 == 1,"Changed Settings context accepted old reply")
        model.editCredentials();guard let detached=owner.editor else {throw Failure.assertion("Detached editor missing")};owner.cancel();detached.accept();try require(!model.editingCredentials && detached.retired,"Host detachment retained dialog")
        model.delivery = .direct;model.authenticate=false;try require(model.canClear && !model.credentialControls,"Clear followed configured/auth gate");model.clearCredentials();try await wait {!model.busy};state=await store.state();try require(state.3 == 1 && model.login.isEmpty,"Immediate Clear failed")
        // Request identity also fences an injected stale presenter callback.
        model.delivery = .configured;model.authenticate=true;var reply:(((String,String)?)->Void)?
        model.presentCredentialEditor={_,completion in reply=completion};model.cancelCredentialEditor={}
        model.editCredentials();let late=reply;model.invalidate();late?(("late","late secret"));late?(("twice","twice secret"));state=await store.state()
        try require(EmailSettingsModel.activeCredentialEditors == 0 && state.2 == 1 && !model.editingCredentials,"Retired reply adopted or leaked dialog lifetime")
        let empty=SMTPCredentialWindowController(login:""){_ in};defer {empty.cancel()}
        try require(empty.window?.initialFirstResponder === empty.username && empty.acceptButton.keyEquivalent == "\r" && empty.cancelButton.keyEquivalent == "\u{1b}" && empty.username.nextKeyView === empty.password,"Source default buttons/tab/initial focus missing")
        // Actual hosted Email page retains original layout; all credential values
        // are synthetic and only the injected actor above can be touched.
        try await store.store(login:"source-login",password:"")
        let host=EmailSettingsWindowController(preferences:prefs,credentials:store);defer {host.close()};host.window?.alphaValue=0
        host.window?.contentView?.layoutSubtreeIfNeeded();try await wait {!host.model.busy && host.model.login == "source-login"}
        host.model.delivery = .configured;host.model.authenticate=true;host.model.server="smtp.example.invalid";host.model.port="587";host.model.encryption = .startTLS
        try await wait {views(host.window?.contentView).compactMap {$0 as? NSTextField}.contains {$0.identifier?.rawValue == "SMTPLogin"}}
        if let folder=ProcessInfo.processInfo.environment["TURTLEGIT_EMAIL_CAPTURE"],let page=host.window,let credential=empty.window {
            let target=URL(fileURLWithPath:folder);try await capture(page,name:"email-settings",to:target)
            empty.username.stringValue="source-login";try await capture(credential,name:"smtp-credentials",to:target)
        }
        let beforeClose=await store.state()
        host.model.editCredentials();try await wait {host.window?.attachedSheet != nil}
        guard let realEditor=host.window?.attachedSheet?.windowController as? SMTPCredentialWindowController else {throw Failure.assertion("Actual hosted credential controller missing")}
        realEditor.password.stringValue="retired hosted secret";realEditor.username.stringValue="retired host"
        host.close();try await wait {EmailSettingsModel.activeCredentialEditors == 0}
        realEditor.accept();let afterClose=await store.state()
        try require(realEditor.retired && realEditor.password.stringValue.isEmpty && beforeClose.2 == afterClose.2,"Actual host closure retained secret/editor or accepted late Store")
        try require((prefs.persistentDomain(forName:suite) ?? [:]).keys.allSatisfy {!$0.lowercased().contains("password")},"Secret preference key appeared")
        try require(EmailSettingsModel.activeOperations == 0 && EmailSettingsModel.activeCredentialEditors == 0,"Email work remains")
    }
}
