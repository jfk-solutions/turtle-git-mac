import AppKit
import SwiftUI
import ScreenCaptureKit
import Darwin
import TurtleGitCore

private actor NetworkSourcePasswords:ProxyPasswordStoring {
    var loads=0
    func load()async throws->String {loads += 1;return "private draft secret"}
    func save(_ value:String)async throws {}
    func count()->Int {loads}
}
@main struct NetworkSourceFamilyVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height <= 800,"Capture host escaped production viewport bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let selected=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:selected),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("Capture PNG missing")}
            try png.write(to:directory.appendingPathComponent("network-settings-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Network source family: labelled proxy layout, native SSH completion, exact picker context/retirement, real SSH child cancellation, ignored readers and Quit/drain ownership")}catch {fputs("Network source failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,askpass:nil),fm=FileManager.default
        _=try await repo.run(["init","-b","main"])
        let suite="TurtleGit.NetworkSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,passwords=NetworkSourcePasswords()
        defer {prefs.removePersistentDomain(forName:suite)}
        // A detached read ignoring cancellation must retain Quit and skip cache/UI.
        let late=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:passwords);defer {late.deactivate()}
        var read:CheckedContinuation<GitProxySettings,Error>?
        late.readProxy={_ in try await withCheckedThrowingContinuation {read=$0}}
        late.activate();try await wait {read != nil}
        try require(NetworkSettingsModel.activeReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Initial read lacks Quit ownership")
        late.deactivate();try require(NetworkSettingsModel.activeReads == 1,"Retired read lost drain count")
        read?.resume(returning:GitProxySettings());read=nil;try await wait {NetworkSettingsModel.activeReads == 0}
        let passwordReads=await passwords.count()
        try require(!late.loaded && !late.busy && passwordReads == 0,"Retired read published or accessed password cache")
        let model=NetworkSettingsModel(repository:repo,access:nil,localAvailable:true,preferences:prefs,passwords:passwords);defer {model.deactivate()}
        model.activate();try await wait {model.loaded && !model.busy && NetworkSettingsModel.activeReads == 0}
        var version:CheckedContinuation<String,Error>?,checkToken:OperationCancellation?
        model.ssh.path="/usr/bin/ssh"
        model.sshVersion={_,token in checkToken=token;return try await withCheckedThrowingContinuation {version=$0}}
        model.checkSSH();try await wait {version != nil};try require(model.checkingSSH && model.busy && NetworkSettingsModel.activeReads == 1,"SSH read lacks owned state")
        model.cancelSSHCheck();model.cancelSSHCheck();try require(model.cancellingCheck && checkToken?.isCancelled == true,"Cancel check missed token")
        version?.resume(returning:"OpenSSH_cancelled");version=nil;try await wait {!model.busy && NetworkSettingsModel.activeReads == 0}
        try require(model.version.isEmpty && model.error == nil && !model.checkingSSH,"Cancelled check published")
        model.checkSSH();try await wait {version != nil};model.ssh.path="/changed-client";version?.resume(returning:"OpenSSH_wrong_client");version=nil
        try await wait {!model.busy};try require(model.version.isEmpty,"Old version described changed client")
        model.ssh.path="/usr/bin/ssh";model.checkSSH();try await wait {version != nil};model.deactivate()
        try require(NetworkSettingsModel.activeReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed check lost Quit")
        version?.resume(throwing:Failure.assertion("retired error"));version=nil;try await wait {NetworkSettingsModel.activeReads == 0}
        try require(model.error == nil && model.version.isEmpty,"Retired check published error")
        model.activate();model.sshVersion=nil
        // Production version execution with an actual owned shell/sleep tree.
        let helper=root.appendingPathComponent(".git/ssh-check"),ready=URL(fileURLWithPath:helper.path+".ready")
        try Data(#"""
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        echo "$$ $task_child" > "$0.ready"
        wait "$task_child"
        echo OpenSSH_fixture
        """#.utf8).write(to:helper);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        model.ssh.path=helper.path;model.ssh.bookmark=nil;model.checkSSH();try await wait {fm.fileExists(atPath:ready.path)}
        let pids=try String(contentsOf:ready).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
        try require(pids.count == 2,"SSH process identity missing");model.cancelSSHCheck();try await wait {!model.busy && NetworkSettingsModel.activeReads == 0}
        try require(pids.allSatisfy {kill($0,0) != 0 && errno == ESRCH},"Owned SSH processes remain")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.alphaValue=0;window.title="Network – Settings – TurtleGit";model.window=window
        defer {model.deactivate();window.contentView=nil;window.close()}
        var replies:[(NSApplication.ModalResponse)->Void]=[],bookmarks=0
        model.presentSSHPanel={_,_,reply in replies.append(reply)};model.selectedSSHURL={_ in URL(fileURLWithPath:"/usr/bin/ssh")};model.bookmarkSSH={_ in bookmarks += 1;return Data("private bookmark".utf8)}
        model.ssh.path="/old-client";model.browseSSH();model.browseSSH()
        try require(replies.count == 1 && model.selectingSSH && NetworkSettingsModel.activeSSHChoosers == 1 && model.validate() == "Finish selecting the SSH client first." && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"SSH picker lost ownership/duplicate gate")
        replies[0](.OK);replies[0](.OK);try await wait {NetworkSettingsModel.activeSSHChoosers == 0 && !model.selectingSSH}
        try require(model.ssh.path == "/usr/bin/ssh" && bookmarks == 1 && !model.selectingSSH,"Picker adoption repeated/failed")
        model.browseSSH();model.ssh.path="/typed-new-client";replies[1](.OK);try await wait {NetworkSettingsModel.activeSSHChoosers == 0 && !model.selectingSSH}
        try require(model.ssh.path == "/typed-new-client" && bookmarks == 1,"Picker overwrote changed SSH context")
        model.browseSSH();replies[2](.cancel);try await wait {NetworkSettingsModel.activeSSHChoosers == 0 && !model.selectingSSH};try require(!model.selectingSSH,"Picker Cancel retained state")
        model.selectedSSHURL={_ in root};model.browseSSH();replies[3](.OK);try await wait {NetworkSettingsModel.activeSSHChoosers == 0 && !model.selectingSSH}
        try require(bookmarks == 1 && model.ssh.path == "/typed-new-client" && model.error != nil,"Directory selection accepted as SSH executable")
        model.error=nil;model.browseSSH();let panel=model.panel;model.deactivate();replies[4](.OK);try await wait {NetworkSettingsModel.activeSSHChoosers == 0 && !model.selectingSSH}
        try require(NetworkSettingsModel.activeSSHChoosers == 0 && model.panel == nil && panel?.isVisible != true && bookmarks == 1,"Closed picker retained/adopted late grant")
        model.activate();model.ssh=SSHClientPreferences();model.proxy.enabled=true;model.proxy.server="proxy.example.invalid";model.proxy.port="8080";model.proxy.username="source-user";model.proxy.password="private sample secret"
        let transaction=SettingsTransaction(),host=NSHostingView(rootView:NetworkSettingsPage(model:model).environment(\.settingsTransaction,transaction).defaultAppStorage(prefs))
        // Use the production bounded Settings viewport. A bare NSHostingView
        // contentView can resize its window to the root Spacer's ideal height.
        let viewport=SettingsPageViewport(frame:window.contentLayoutRect);viewport.autoresizingMask=[.width,.height]
        window.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        viewport.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded()
        try await wait {views(host).contains {($0 as? PathEntryField.Field)?.accessibilityLabel() == "SSH client"}}
        let field=views(host).compactMap {$0 as? PathEntryField.Field}.first!
        try require(field.isEnabled && field.isEditable && field.frame.height >= 20,"SSH path-completion field disabled or clipped")
        model.deactivate();try await wait {!field.isEnabled}
        model.activate();try await wait {field.isEnabled}

        try require(window.frame.height <= 800 && host.frame.height <= 800,"Network proxy layout expanded beyond its source proportions")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_NETWORK_CAPTURE"] {try await capture(window,to:URL(fileURLWithPath:output))}
        model.deactivate();transaction.invalidate()
        try require(NetworkSettingsModel.activeReads == 0 && NetworkSettingsModel.activeSaves == 0 && NetworkSettingsModel.activeSSHChoosers == 0,"Network operation count leaked")
    }
}
