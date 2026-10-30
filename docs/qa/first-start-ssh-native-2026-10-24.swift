// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
import Security
import TurtleGitCore

@main struct FirstStartSSHVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [FirstStartWizardController] = []
    @MainActor static var suites: [String] = []
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "First Start SSH timeout at \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    struct HostIdentity {
        let bundleID:String?,codeID:String?,selfStatus:OSStatus,staticStatus:OSStatus,informationStatus:OSStatus,validityStatus:OSStatus
        let flags:String,entitlements:String
        var diagnostic:String {"bundleID=\(bundleID ?? "nil") codeID=\(codeID ?? "nil") selfStatus=\(selfStatus) staticStatus=\(staticStatus) informationStatus=\(informationStatus) validityStatus=\(validityStatus) flags=\(flags) entitlements=\(entitlements) executable=\(Bundle.main.executableURL?.path ?? "nil")"}
    }
    static func hostIdentity()->HostIdentity {
        var code:SecCode?,staticCode:SecStaticCode?,information:CFDictionary?
        let selfStatus=SecCodeCopySelf(SecCSFlags(rawValue:0),&code)
        let staticStatus=code.map{SecCodeCopyStaticCode($0,SecCSFlags(rawValue:0),&staticCode)} ?? errSecParam
        let informationStatus=staticCode.map{SecCodeCopySigningInformation($0,SecCSFlags(rawValue:kSecCSSigningInformation),&information)} ?? errSecParam
        let validityStatus=code.map{SecCodeCheckValidity($0,SecCSFlags(rawValue:0),nil)} ?? errSecParam
        let values=information as? [String:Any] ?? [:]
        return HostIdentity(bundleID:Bundle.main.bundleIdentifier,codeID:values[kSecCodeInfoIdentifier as String] as? String,selfStatus:selfStatus,staticStatus:staticStatus,informationStatus:informationStatus,validityStatus:validityStatus,
                            flags:String(describing:values[kSecCodeInfoFlags as String] ?? "none"),entitlements:String(describing:values[kSecCodeInfoEntitlementsDict as String] ?? "none"))
    }
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        do {
            let identity=hostIdentity()
            print("First Start SSH host identity: "+identity.diagnostic)
            try require(identity.bundleID?.hasPrefix("org.turtlegit.qa.firststartssh.")==true && identity.codeID==identity.bundleID && identity.selfStatus==errSecSuccess && identity.staticStatus==errSecSuccess && identity.informationStatus==errSecSuccess && identity.validityStatus==errSecSuccess,"Missing verified private application identity; "+identity.diagnostic)
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), mode = CommandLine.arguments[3]
            defer { suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) } }
            switch mode { case "choices": try await choices(root, git); case "picker": try await picker(root, git); default: try await lifetime(root, git) }
            owners.forEach { $0.close() }; owners = []
            try await wait { FirstStartWizardModel.activeWrites == 0 && GeneralGitSettingsModel.activeOperations == 0 && GeneralGitSettingsModel.activeDialogs == 0 }
            try require(NSApp.windows.allSatisfy { !$0.isVisible }, "Owned wizard/sheet remained visible")
            print("PASS: First Start SSH " + mode)
        } catch {
            owners.forEach { $0.close() }; owners = []
            for _ in 0..<1500 { if FirstStartWizardModel.activeWrites == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            fputs("First Start SSH failure: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func seed(_ root: URL, _ git: URL) async throws -> (FirstStartWizardController, UserDefaults, URL, URL, URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let global = root.appendingPathComponent("global"), wrapper = root.appendingPathComponent("git-private"), client = root.appendingPathComponent("custom SSH client")
        try Data("[user]\nname = Private Turtle\nemail = qa@example.invalid\n[credential]\nhelper = store\n[fixture]\nkeep = retained\n".utf8).write(to: global)
        let script = """
        #!/bin/sh
        export GIT_CONFIG_GLOBAL=\(quote(global.path))
        export GIT_CONFIG_NOSYSTEM=1
        export GIT_CONFIG_COUNT=0
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
        task_write=0
        for task_arg in "$@"; do
          if [ "$task_arg" = --replace-all ] || [ "$task_arg" = --unset-all ]; then task_write=1; fi
        done
        if [ "$task_write" = 1 ] && [ -f "$0.fail" ]; then printf '%s\\n' 'private helper failure' >&2; exit 23; fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try Data("#!/bin/sh\nprintf '%s\\n' 'OpenSSH_private_fixture' >&2\n".utf8).write(to: client)
        for file in [wrapper, client] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        let suite = "TurtleGit.FirstStartSSH.Native." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!; suites.append(suite)
        var ssh = SSHClientPreferences(); ssh.path = client.path; try ssh.save(to: prefs)
        let owner = FirstStartWizardController(preferences: prefs, initialPage: 4, makeRepository: { _, token in try token.check(); return GitRepository(root: root, executable: wrapper) })
        owners.append(owner); owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
        try await wait { !owner.model.busy }
        try require(owner.model.page == .authentication && owner.model.error == nil, "Authentication bootstrap failed: " + (owner.model.error ?? ""))
        return (owner, prefs, client, wrapper, global)
    }
    @MainActor static func capture(_ owner: FirstStartWizardController) async throws {
        guard let target = ProcessInfo.processInfo.environment["TURTLEGIT_FIRST_START_SSH_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        window.alphaValue = 1; window.orderFront(nil)
        defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own wizard capture unavailable") }
            let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true; configuration.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target).appendingPathComponent("first-start-ssh-" + suffix + ".png"))
        }
    }
    @MainActor static func choices(_ root: URL, _ git: URL) async throws {
        let (owner, prefs, client, wrapper, global) = try await seed(root, git), model = owner.model
        let bytes = try Data(contentsOf: global)
        try require(model.sshChoice == .custom && model.ssh.path == client.path, "Configured custom SSH was displayed as automatic")
        try await wait { owner.window?.contentView.map { descendants($0).contains { ($0 as? NSTextField)?.stringValue == client.path } } == true }
        try await capture(owner)
        model.checkSSH(context: model.formContext)
        try require(model.checkingSSH && !model.canNavigate && model.canCancel, "Check did not own navigation/read-only Close")
        try await wait { !model.checkingSSH }
        try require(model.sshVersion == "OpenSSH_private_fixture" && model.error == nil, "Actual private SSH version not shown")
        try require(try Data(contentsOf: global) == bytes && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Inspection mutated setup")
        let bad = root.appendingPathComponent("not-an-ssh-client")
        try Data("#!/bin/sh\nprintf '%s\\n' 'not OpenSSH'\n".utf8).write(to: bad)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bad.path)
        model.editSSHPath(bad.path, context: model.formContext)
        model.checkSSH(context: model.formContext); try await wait { !model.checkingSSH }
        try require(model.error != nil, "Non-OpenSSH executable passed Check")
        model.skipHelper = true; model.next(context: model.formContext); try await wait { !model.busy }
        try require(model.error != nil && SSHClientPreferences.load(from: prefs).path == client.path && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Invalid changed client was saved or completed setup")
        model.editSSHPath(client.path, context: model.formContext)
        let stale = model.formContext
        model.chooseSSH(.automatic, context: stale)
        model.editSSHPath("/stale", context: stale)
        try require(model.ssh.path.isEmpty, "Old custom-path action changed automatic choice")
        model.chooseSSH(.custom, context: model.formContext)
        try require(model.ssh.path == client.path, "Automatic/custom toggle discarded captured custom client")
        model.chooseSSH(.automatic, context: model.formContext)
        try Data().write(to: URL(fileURLWithPath: wrapper.path + ".fail"))
        model.helper = "store"; model.skipHelper = false; model.next(context: model.formContext)
        try await wait { !model.busy }
        try require(model.error != nil && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Credential failure completed wizard")
        try require(SSHClientPreferences.load(from: prefs).path.isEmpty, "Source-ordered accepted SSH save was rolled back")
        try require(try Data(contentsOf: global) == bytes, "Failed helper write changed unrelated configuration")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: wrapper.path + ".fail"))
        var finishes = 0; model.finish = { finishes += 1 }
        model.skipHelper = true; model.next(context: model.formContext)
        try await wait { !model.busy }
        model.next()
        try require(finishes == 1 && prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Finish not accepted exactly once")
        try require(try Data(contentsOf: global) == bytes, "Don't store changed global helper/identity")
    }
    @MainActor static func picker(_ root: URL, _ git: URL) async throws {
        let (owner, prefs, client, _, _) = try await seed(root, git), model = owner.model
        var reply: ((NSApplication.ModalResponse) -> Void)?; var panel: NSOpenPanel?
        model.presentSSHPanel = { chooser, window, callback in panel = chooser; reply = callback; window.beginSheet(chooser, completionHandler: callback) }
        var selectionCalls=0,bookmarkCalls=0,selectionAttached=false,bookmarkError:String?,reentered=false
        var createdBookmarks:[Data]=[],bookmarkRoundTrips=0
        model.selectedSSHURL={chooser in
            selectionCalls += 1;selectionAttached=chooser.sheetParent === owner.window
            if !reentered{reentered=true;reply?(.cancel)}
            return selectionAttached ? client:nil
        }
        model.bookmarkSSH={file in
            bookmarkCalls += 1
            do{
                let bytes=try file.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
                var stale=false
                let restored=try URL(resolvingBookmarkData:bytes,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
                try require(!bytes.isEmpty && !stale && restored.isFileURL && Data(restored.path.utf8)==Data(file.path.utf8),"Real scoped bookmark failed exact private-file round trip")
                createdBookmarks.append(bytes);bookmarkRoundTrips += 1
                return bytes
            }catch{
                let failure=error as NSError
                bookmarkError="\(failure.domain) code=\(failure.code): \(failure.localizedDescription); userInfo=\(failure.userInfo); canonical=\(String(reflecting:file.resolvingSymlinksInPath().path)); exists=\(FileManager.default.fileExists(atPath:file.path)); executable=\(FileManager.default.isExecutableFile(atPath:file.path))"
                throw error
            }
        }
        let stale = model.formContext, binding = model.sshPathBinding(context: stale)
        model.browseSSH(context:stale)
        try await wait{panel?.sheetParent === owner.window && owner.window?.attachedSheet === panel}
        try require(model.selectingSSH && !model.canNavigate && !model.canCancel, "SSH picker failed to own navigation/Close")
        binding.wrappedValue = "/stale"; model.chooseSSH(.automatic, context: stale); model.next(context: stale)
        try require(model.ssh.path == client.path && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Picker allowed stale edits/Finish")
        reply?(.OK); reply?(.cancel)
        try await wait { !model.selectingSSH && owner.window?.attachedSheet == nil && panel?.sheetParent == nil }
        let diagnostics="path=\(String(reflecting:model.ssh.path)) expected=\(String(reflecting:client.path)) bookmark=\(model.ssh.bookmark != nil) selectionCalls=\(selectionCalls) attachedAtSelection=\(selectionAttached) bookmarkCalls=\(bookmarkCalls) scopedRoundTrips=\(bookmarkRoundTrips) createdBookmarks=\(createdBookmarks.count) canonicalClient=\(String(reflecting:client.resolvingSymlinksInPath().path)) bookmarkError=\(bookmarkError ?? "none") hostIdentity={\(hostIdentity().diagnostic)} modelError=\(model.error ?? "none") selecting=\(model.selectingSSH) page=\(model.page) activeWrites=\(FirstStartWizardModel.activeWrites)"
        print("First Start SSH accepted-picker diagnostics: "+diagnostics)
        try require(model.ssh.path == client.path && model.ssh.bookmark != nil,"Accepted client lost security bookmark; "+diagnostics)
        try require(selectionCalls==1 && selectionAttached && bookmarkCalls==1 && bookmarkRoundTrips==1 && createdBookmarks.count==1 && model.ssh.bookmark==createdBookmarks.first && reentered && FirstStartWizardModel.activeWrites==0,"Picker selection/real scoped bookmark roundtrip/reentrant admission or work drain was not exactly once; "+diagnostics)
        binding.wrappedValue = "/after"
        try require(model.ssh.path == client.path, "Consumed picker revived old binding")
        var accepted=model.ssh
        model.sshPathBinding(context:model.formContext).wrappedValue=client.path
        try require(model.ssh==accepted,"Unchanged native path publication discarded accepted bookmark")
        model.checkSSH(context:model.formContext);try await wait{!model.checkingSSH}
        try require(model.sshVersion=="OpenSSH_private_fixture","Bookmarked SSH cannot be inspected")
        model.sshPathBinding(context:model.formContext).wrappedValue=client.path
        model.chooseSSH(.custom,context:model.formContext)
        try require(model.ssh==accepted && model.sshVersion=="OpenSSH_private_fixture","Unchanged path/client choice discarded inspected program identity")
        model.editSSHPath(client.path+".changed",context:model.formContext)
        try require(model.ssh.path==client.path+".changed" && model.ssh.bookmark==nil && model.sshVersion.isEmpty,"Real program edit retained the previous program’s bookmark/inspection")
        model.browseSSH(context:model.formContext)
        try await wait{panel?.sheetParent === owner.window && owner.window?.attachedSheet === panel}
        reply?(.OK)
        try await wait{!model.selectingSSH && owner.window?.attachedSheet==nil}
        try require(model.ssh.path==client.path && model.ssh.bookmark != nil && bookmarkCalls==2 && bookmarkRoundTrips==2 && createdBookmarks.count==2 && model.ssh.bookmark==createdBookmarks.last,"A fresh picker did not restore the original program grant with a real scoped roundtrip")
        accepted=model.ssh
        model.checkSSH(context:model.formContext);try await wait{!model.checkingSSH}
        try require(model.sshVersion=="OpenSSH_private_fixture","Freshly accepted original program did not inspect correctly")
        // A refused bookmark must leave the prior accepted authority repairable.
        let inspection=model.sshVersion
        model.selectedSSHURL={_ in client}
        model.bookmarkSSH={_ in throw NSError(domain:"TurtleGit.FirstStartSSH.Private",code:71,userInfo:[NSLocalizedDescriptionKey:"Private bookmark refusal"])}
        model.browseSSH(context:model.formContext)
        try await wait{panel?.sheetParent === owner.window && owner.window?.attachedSheet === panel}
        reply?(.OK)
        try await wait{!model.selectingSSH && owner.window?.attachedSheet==nil}
        try require(model.ssh==accepted && model.sshVersion==inspection && model.error?.contains("Private bookmark refusal")==true,"Bookmark failure replaced accepted authority or hid its error")
        model.checkSSH(context:model.formContext);try await wait{!model.checkingSSH}
        try require(model.error==nil && model.ssh==accepted,"Retained bookmark could not recover after picker failure")
        model.skipHelper = true; model.next(context: model.formContext); try await wait { !model.busy }
        try require(SSHClientPreferences.load(from: prefs) == model.ssh && prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Custom/bookmark not saved on Finish")
    }
    @MainActor static func lifetime(_ root: URL, _ git: URL) async throws {
        let (owner, prefs, client, _, _) = try await seed(root, git), model = owner.model
        var entered = false, release = false
        defer{release=true}
        model.readSSHVersion = { _, _ in entered = true; while !release { try? await Task.sleep(nanoseconds: 10_000_000) }; return "OpenSSH_late" }
        model.checkSSH(context: model.formContext); try await wait { entered }
        model.cancelSSHCheck()
        try require(model.checkingSSH && model.cancellingSSH && FirstStartWizardModel.activeWrites > 0, "Cancel released still-running check")
        release = true; try await wait { !model.checkingSSH }
        try require(model.sshVersion.isEmpty && model.error == nil && model.canNavigate, "Cancelled version published or never released navigation")
        entered = false; release = false
        model.checkSSH(context: model.formContext); try await wait { entered }
        owner.close()
        try require(FirstStartWizardModel.activeWrites > 0 && !model.canNavigate, "Retired check lost Quit accounting")
        release = true; try await wait { FirstStartWizardModel.activeWrites == 0 }
        try require(model.sshVersion.isEmpty && SSHClientPreferences.load(from: prefs).path == client.path && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Late closed check changed setup")
        let (pickerOwner, _, selected, _, _) = try await seed(root.appendingPathComponent("picker-close"), git)
        var answer: ((NSApplication.ModalResponse) -> Void)?
        pickerOwner.model.presentSSHPanel = { _, _, reply in answer = reply }
        pickerOwner.model.selectedSSHURL = { _ in selected }
        pickerOwner.model.browseSSH(context: pickerOwner.model.formContext)
        pickerOwner.close(); answer?(.OK)
        try await wait { FirstStartWizardModel.activeWrites == 0 }
        try require(pickerOwner.model.ssh.bookmark == nil && !pickerOwner.model.canNavigate, "Closed chooser applied late grant")
    }
}
