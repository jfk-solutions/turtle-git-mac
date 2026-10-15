// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@main struct FirstStartVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [FirstStartWizardController] = []
    @MainActor static var helpers: [URL] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func wait(line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "First Start operation did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            owners.forEach { $0.close() }
            for helper in helpers { try? Data().write(to: URL(fileURLWithPath: helper.path + ".release")) }
            for _ in 0..<1200 {
                if FirstStartWizardModel.activeWrites == 0 && GeneralGitSettingsModel.activeOperations == 0 && CredentialSettingsModel.activeReads == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fputs("First Start failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func capture(_ owner: FirstStartWizardController, page: String) async throws {
        guard let destination = ProcessInfo.processInfo.environment["TURTLEGIT_FIRST_START_CAPTURE"], let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture API unavailable") }
        window.alphaValue = 1; window.makeKeyAndOrderFront(nil)
        defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own wizard missing from compositor") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            fputs("Capture \(page)-\(suffix): frame=\(window.frame), compositor=\(own.frame), pixels=\(options.width)x\(options.height)\n", stderr)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("first-start-" + page + "-" + suffix + ".png"))
        }
    }
    @MainActor static func verify() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let standardBefore = UserDefaults.standard.object(forKey: "TurtleGit.FirstStartComplete") as? Bool
        var suites: [String] = []
        defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }; owners.forEach { $0.close() }; owners = [] }
        func fixture(_ label: String) throws -> (URL,URL,URL,UserDefaults) {
            let directory = root.appendingPathComponent(label), global = directory.appendingPathComponent("global.gitconfig"), helper = directory.appendingPathComponent("git-setup")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let credential = directory.appendingPathComponent("helpers/git-credential-store")
            try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: credential); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: credential.path)
            try Data("[user]\nname = Initial Turtle\nemail = initial@example.invalid\n[credential]\nhelper =\n[fixture]\nkeep = preserved\n".utf8).write(to: global)
            let script = """
            #!/bin/sh
            export GIT_CONFIG_GLOBAL=\(quote(global.path))
            export GIT_CONFIG_NOSYSTEM=1
            export GIT_CONFIG_COUNT=0
            unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
            task_version=0; task_read=0; task_write=0; task_email=0
            for task_arg in "$@"; do
              case "$task_arg" in
                --exec-path) printf '%s\\n' \(quote(credential.deletingLastPathComponent().path)); exit 0;;
                --version) task_version=1;;
                --get-regexp|--list) task_read=1;;
                --replace-all) task_write=1;;
                user.email) task_email=1;;
              esac
            done
            task_mode=$(/bin/cat "$0.mode" 2>/dev/null)
            if [ "$task_mode" = fail-email ] && [ "$task_write" = 1 ] && [ "$task_email" = 1 ]; then printf '%s\\n' 'private email write failure' >&2; exit 23; fi
            if { [ "$task_mode" = version ] && [ "$task_version" = 1 ]; } || { [ "$task_mode" = read ] && [ "$task_read" = 1 ]; } || { [ "$task_mode" = write ] && [ "$task_write" = 1 ] && [ "$task_email" = 1 ]; }; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" >> "$0.ready"
              task_attempts=0
              while [ ! -f "$0.release" ] && [ "$task_attempts" -lt 600 ]; do /bin/sleep 0.05; task_attempts=$((task_attempts + 1)); done
              kill "$task_child" 2>/dev/null
              wait "$task_child" 2>/dev/null
            fi
            exec \(quote(engine.path)) "$@"
            """
            try script.write(to: helper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path); helpers.append(helper)
            let suite = "TurtleGit.FirstStart.QA." + UUID().uuidString; suites.append(suite)
            return (directory,helper,global,UserDefaults(suiteName: suite)!)
        }
        func owner(_ directory: URL, _ helper: URL, _ prefs: UserDefaults) -> FirstStartWizardController {
            let owner = FirstStartWizardController(preferences: prefs, makeRepository: { selected, token in
                try token.check(); try require(selected.path == helper.path, "Wizard used another preference store's Git engine")
                return GitRepository(root: directory, executable: selected)
            })
            owners.append(owner); owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
            owner.model.git.draft.choice = .custom; owner.model.git.draft.path = helper.path
            owner.model.next(); owner.model.next()
            return owner
        }
        func mode(_ helper: URL, _ value: String) throws { try value.write(to: URL(fileURLWithPath: helper.path + ".mode"), atomically: true, encoding: .utf8) }
        func pids(_ helper: URL) -> [Int32] { (try? String(contentsOfFile: helper.path + ".ready", encoding: .utf8))?.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) } ?? [] }
        func ready(_ helper: URL) -> Bool { FileManager.default.fileExists(atPath: helper.path + ".ready") }
        let (directory,helper,global,prefs) = try fixture("flow"), main = owner(directory,helper,prefs), model = main.model
        try require(model.page == .git, "Five-stage ordering")
        model.next(); model.next(); try await wait { !model.busy && model.page == .user }
        try require(model.name == "Initial Turtle" && model.helpers.contains("store"), "Private configuration/helper discovery")
        main.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { views(main.window!.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Initial Turtle" } }
        model.name = "Ada Turtle"; model.email = "turtle@example.invalid"
        try await capture(main, page: "user")
        model.next(); model.name = "late mutation"; model.email = "late@example.invalid"
        try await wait { !model.busy && model.page == .authentication }
        let repository = GitRepository(root: directory, executable: helper)
        let savedName = try await repository.run(["config","--global","--get","user.name"]).text.trimmingCharacters(in: .newlines)
        let savedEmail = try await repository.run(["config","--global","--get","user.email"]).text.trimmingCharacters(in: .newlines)
        try require(savedName == "Ada Turtle" && savedEmail == "turtle@example.invalid", "Next read fields after submission")
        model.back(); model.skipUser = true; model.name = "Must not save"; model.next()
        try await wait { !model.busy && model.page == .authentication }
        let afterSkip = try await repository.run(["config","--global","--get","user.name"]).text.trimmingCharacters(in: .newlines)
        try require(afterSkip == savedName, "Don't store identity wrote config")
        model.skipHelper = false; model.generateSSHKey()
        try require(model.hasCredentialSheet && !model.canNavigate && !main.windowShouldClose(main.window!), "SSH child ownership")
        model.keyGenerationController?.close(); try await wait { !model.hasCredentialSheet && main.window?.attachedSheet == nil }
        model.configureCredentials()
        try require(model.skipHelper && model.hasCredentialSheet, "Advanced did not select source Don't store")
        try await wait { model.credentialController?.model.busy == false && model.credentialController?.model.snapshot != nil }
        model.credentialController?.close()
        try await wait { !model.hasCredentialSheet && !model.busy && CredentialSettingsModel.activeReads == 0 }
        try require(model.skipHelper && model.name == "Must not save" && model.email == "late@example.invalid", "Advanced reload lost skip choice or replaced identity draft")
        try await capture(main, page: "authentication")
        model.skipHelper = false; model.helper = ""; model.next(); model.helper = "store"; try await wait { !model.busy && FirstStartWizardModel.activeWrites == 0 }
        let helperAfter = try await repository.run(["config","--global","--get-all","credential.helper"],successfulExitCodes:0...1)
        try require(prefs.bool(forKey: "TurtleGit.FirstStartComplete") && helperAfter.exitCode == 1 && model.window?.isVisible != true, "Finish did not save helper/completion")
        try require(try String(contentsOf: global, encoding: .utf8).contains("preserved"), "Unrelated global setting lost")
        let cached = GeneralGitSettingsModel(preferences: prefs); cached.activate(); cached.draft.extraPath = "/private/setup-path"; cached.suspend()
        try require(await cached.apply(validateUnchanged: true), "Cached inactive General page could not Apply")
        try require(GitEnginePreferences.load(from: prefs).extraPath == "/private/setup-path", "General draft not persisted")
        for reading in ["version","read"] {
            let (folder,tool,_,settings) = try fixture(reading), child = owner(folder,tool,settings), value = child.model
            try mode(tool,reading); value.next(); try await wait { ready(tool) }
            try require(child.windowShouldClose(child.window!), "Cancellable read prevented normal Close")
            child.window?.performClose(nil)
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Retired setup read lost Quit accounting")
            try await wait { FirstStartWizardModel.activeWrites == 0 && GeneralGitSettingsModel.activeOperations == 0 }
            try require(GitEnginePreferences.load(from: settings).choice == (reading == "version" ? .automatic : .custom), "Read cancellation lost the accepted engine save point")
            try require(!pids(tool).isEmpty && pids(tool).allSatisfy { kill($0,0) != 0 } && value.page == .git && !settings.bool(forKey:"TurtleGit.FirstStartComplete"), "Read cancellation leaked child or advanced setup")
        }
        let (writeFolder,writeTool,_,writePrefs) = try fixture("write"), writer = owner(writeFolder,writeTool,writePrefs), writeModel = writer.model
        writeModel.next(); try await wait { !writeModel.busy && writeModel.page == .user }
        writeModel.name = "Captured Author"; writeModel.email = "captured@example.invalid"; try mode(writeTool,"write")
        writeModel.next(); try await wait { ready(writeTool) }
        try require(writeModel.writing && !writer.windowShouldClose(writer.window!) && !writeModel.canCancel, "Accepted write was cancellable")
        writer.close(); try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Closed writer lost Quit ownership")
        try Data().write(to: URL(fileURLWithPath: writeTool.path + ".release")); try await wait { FirstStartWizardModel.activeWrites == 0 }
        let writeRepo = GitRepository(root: writeFolder, executable: writeTool)
        let writeName = try await writeRepo.run(["config","--global","--get","user.name"]).text.trimmingCharacters(in:.newlines), writeEmail = try await writeRepo.run(["config","--global","--get","user.email"]).text.trimmingCharacters(in:.newlines)
        try require(writeName == "Captured Author" && writeEmail == "captured@example.invalid" && writeModel.page == .user && !writePrefs.bool(forKey:"TurtleGit.FirstStartComplete") && pids(writeTool).allSatisfy { kill($0,0) != 0 }, "Retired write lost accepted fields or finished wizard")
        let (failFolder,failTool,_,failPrefs) = try fixture("failure"), failed = owner(failFolder,failTool,failPrefs)
        failed.model.next(); try await wait { !failed.model.busy && failed.model.page == .user }
        try mode(failTool,"fail-email"); failed.model.name = "Earlier saved"; failed.model.email = "fails@example.invalid"; failed.model.next()
        try await wait { !failed.model.busy }
        let failRepo = GitRepository(root: failFolder, executable: failTool), partial = try await failRepo.run(["config","--global","--get","user.name"]).text.trimmingCharacters(in:.newlines)
        try require(partial == "Earlier saved" && failed.model.page == .user && failed.model.error?.contains("user.email") == true && failed.model.canCancel, "Partial-write failure hidden or advanced page")
        failed.close()
        let (credentialFolder,credentialTool,_,_) = try fixture("credential-read")
        try mode(credentialTool,"read")
        let credential = CredentialSettingsController(repository: GitRepository(root: credentialFolder, executable: credentialTool), access:nil, localAvailable:false)
        credential.model.activate(); try await wait { ready(credentialTool) }
        credential.close(); try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Closed credential reader lost Quit accounting")
        try await wait { CredentialSettingsModel.activeReads == 0 }
        try require(pids(credentialTool).allSatisfy { kill($0,0) != 0 }, "Credential read leaked helper")
        try require(UserDefaults.standard.object(forKey:"TurtleGit.FirstStartComplete") as? Bool == standardBefore, "Wizard wrote shared completion preferences")
        try require(FirstStartWizardModel.activeWrites == 0 && GeneralGitSettingsModel.activeOperations == 0 && CredentialSettingsModel.activeReads == 0, "Setup operation counts did not settle")
        print("PASS: First Start source forms/order, captured engine/identity, Don't store/Advanced/SSH sheets, private Finish, cached General Apply, cancellable reads and accepted-write/partial-failure lifetime")
    }
}
