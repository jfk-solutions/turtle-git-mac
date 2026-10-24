// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
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
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        do {
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
        model.selectedSSHURL = { _ in client }; model.bookmarkSSH = { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        let stale = model.formContext, binding = model.sshPathBinding(context: stale)
        model.browseSSH(context: stale)
        try require(model.selectingSSH && !model.canNavigate && !model.canCancel, "SSH picker failed to own navigation/Close")
        binding.wrappedValue = "/stale"; model.chooseSSH(.automatic, context: stale); model.next(context: stale)
        try require(model.ssh.path == client.path && !prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Picker allowed stale edits/Finish")
        reply?(.OK); reply?(.cancel)
        try await wait { !model.selectingSSH && owner.window?.attachedSheet == nil && panel?.sheetParent == nil }
        try require(model.ssh.path == client.path && model.ssh.bookmark != nil, "Accepted client lost security bookmark")
        binding.wrappedValue = "/after"
        try require(model.ssh.path == client.path, "Consumed picker revived old binding")
        model.checkSSH(context: model.formContext); try await wait { !model.checkingSSH }
        try require(model.sshVersion == "OpenSSH_private_fixture", "Bookmarked SSH cannot be inspected")
        model.skipHelper = true; model.next(context: model.formContext); try await wait { !model.busy }
        try require(SSHClientPreferences.load(from: prefs) == model.ssh && prefs.bool(forKey: "TurtleGit.FirstStartComplete"), "Custom/bookmark not saved on Finish")
    }
    @MainActor static func lifetime(_ root: URL, _ git: URL) async throws {
        let (owner, prefs, client, _, _) = try await seed(root, git), model = owner.model
        var entered = false, release = false
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
