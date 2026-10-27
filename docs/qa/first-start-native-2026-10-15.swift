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
        window.alphaValue = 1; window.orderFront(nil)
        defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own wizard missing from compositor") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * window.backingScaleFactor); options.height = Int(window.frame.height * window.backingScaleFactor)
            fputs("Capture \(page)-\(suffix): frame=\(window.frame), compositor=\(own.frame), pixels=\(options.width)x\(options.height)\n", stderr)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true; options.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("first-start-" + page + "-" + suffix + ".png"))
        }
    }
    @MainActor static func verify() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
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
        model.back(); model.back()
        try await capture(main,page:"language")
        let languageContext=model.formContext,languageGeneration=model.pageGeneration
        model.next(context:languageContext)
        try await capture(main,page:"welcome")
        model.next(context:languageContext);model.back(context:languageContext)
        try require(model.page == .welcome,"Retained Language actions changed Welcome")
        model.back(context:model.formContext)
        try require(!model.focusAllowed(page:.language,generation:languageGeneration),"Revisited page accepted an old focus request")
        model.next(context:model.formContext);model.next(context:model.formContext)
        try require(model.page == .git, "Five-stage ordering")
        let gitContext=model.formContext,oldGitPath=model.gitText(true,context:gitContext),oldExtraPath=model.gitText(false,context:gitContext)
        let originalPath=model.git.draft.path
        var pickerReply:((NSApplication.ModalResponse)->Void)?
        model.git.presentPanel={_,_,reply in pickerReply=reply}
        model.git.selectedURL={_ in helper};model.git.bookmark={_ in Data([1,2,3])}
        model.browseGit(context:gitContext)
        try require(model.git.selecting && !model.canNavigate && !model.canCancel,"Git picker did not own wizard navigation/Close")
        oldGitPath.wrappedValue="/stale/git";oldExtraPath.wrappedValue="/stale/path";model.next(context:gitContext)
        try require(model.page == .git && model.git.draft.path==originalPath && model.git.draft.extraPath.isEmpty,"Pending picker accepted old fields or Next")
        pickerReply?(.cancel);pickerReply?(.OK)
        try await wait {!model.git.selecting && GeneralGitSettingsModel.activeDialogs==0}
        try require(model.canNavigate && GeneralGitSettingsModel.activeDialogs==0 && model.git.draft.bookmark==nil,"Repeated picker reply changed the cancelled draft")
        oldExtraPath.wrappedValue="/after/cancel"
        try require(model.git.draft.extraPath.isEmpty,"Cancelled picker revived an old form binding")
        var inspected=false
        model.git.inspectEngine={_,token in
            inspected=true
            while !token.isCancelled {try await Task.sleep(nanoseconds:10_000_000)}
            try token.check();return "git version stale"
        }
        let checkContext=model.formContext
        model.checkGit(context:checkContext);try await wait {inspected}
        try require(model.git.checking && !model.canNavigate && model.canCancel,"Check/Cancel navigation gates")
        model.back(context:checkContext);model.next(context:checkContext)
        try require(model.page == .git,"Pending Git check changed pages")
        model.cancelGitCheck();try await wait {!model.git.busy && GeneralGitSettingsModel.activeOperations==0}
        try require(model.git.version.isEmpty && model.git.error==nil,"Cancelled check published a stale result")
        model.git.inspectEngine=nil
        model.next(context:checkContext)
        try require(!model.busy && model.page == .git,"Settled check revived its old Next action")
        try await capture(main,page:"git")
        model.next(); model.next(); try await wait { !model.busy && model.page == .user }
        try require(model.name == "Initial Turtle" && model.helpers.contains("store"), "Private configuration/helper discovery")
        main.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { views(main.window!.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Initial Turtle" } }
        let userContext=model.formContext,oldName=model.field(\.name,context:userContext),oldEmail=model.field(\.email,context:userContext)
        oldName.wrappedValue="Ada Turtle";oldEmail.wrappedValue="turtle@example.invalid"
        let skip=model.field(\.skipUser,context:userContext);skip.wrappedValue=true
        oldName.wrappedValue="Disabled stale name";oldEmail.wrappedValue="disabled@example.invalid"
        try require(model.name=="Ada Turtle" && model.email=="turtle@example.invalid","Disabled fields accepted retained values")
        model.field(\.skipUser,context:model.formContext).wrappedValue=false
        oldName.wrappedValue="Reenabled stale name"
        try require(model.name=="Ada Turtle","Reenabled form revived a retained binding")
        try await capture(main, page: "user")
        model.next(); model.name = "late mutation"; model.email = "late@example.invalid"
        try await wait { !model.busy && model.page == .authentication }
        oldName.wrappedValue="Wrong page";oldEmail.wrappedValue="wrong-page@example.invalid"
        try require(model.name=="late mutation" && model.email=="late@example.invalid","User bindings survived page navigation")
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
        let (finishFolder,finishTool,_,finishPrefs)=try fixture("finish-once"),finisher=owner(finishFolder,finishTool,finishPrefs),finishModel=finisher.model
        finishModel.next();try await wait {!finishModel.busy && finishModel.page == .user}
        finishModel.skipUser=true;finishModel.next();try await wait {!finishModel.busy && finishModel.page == .authentication}
        var finishCount=0;finishModel.finish={finishCount += 1};finishModel.skipHelper=true
        let finishContext=finishModel.formContext,oldHelper=finishModel.field(\.helper,context:finishContext)
        finishModel.next(context:finishContext);try await wait {!finishModel.busy}
        oldHelper.wrappedValue="store";finishModel.next(context:finishContext);finishModel.next();finishModel.back()
        try require(finishCount==1 && finishPrefs.bool(forKey:"TurtleGit.FirstStartComplete") && !finishModel.canNavigate && !finishModel.canCancel && finishModel.page == .authentication,"Finish completion was replayed or re-enabled navigation")
        finisher.close()
        let (pickerFolder,pickerTool,_,pickerPrefs)=try fixture("retired-picker"),pickerOwner=owner(pickerFolder,pickerTool,pickerPrefs)
        var retiredReply:((NSApplication.ModalResponse)->Void)?
        pickerOwner.model.git.presentPanel={_,_,reply in retiredReply=reply}
        pickerOwner.model.git.selectedURL={_ in engine};pickerOwner.model.git.bookmark={_ in Data([9])}
        pickerOwner.model.browseGit(context:pickerOwner.model.formContext)
        try require(GeneralGitSettingsModel.activeDialogs==1,"Picker not accounted")
        pickerOwner.close();retiredReply?(.OK)
        try await wait {GeneralGitSettingsModel.activeDialogs==0}
        try require(GeneralGitSettingsModel.activeDialogs==0 && pickerOwner.model.git.draft.path==pickerTool.path,"Closed wizard accepted picker reply or leaked ownership")
        // Automatic onboarding belongs to an attached workspace. Closing that
        // actual native owner before the deferred callback must not spawn it;
        // a later explicit workspace presentation can still onboard once.
        let (_,_,_,deferredPrefs)=try fixture("deferred-workspace")
        let service=FirstStartWizardService()
        let workspace=NSWindow(contentRect:.init(x:-24000,y:-24000,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        workspace.isReleasedWhenClosed=false;workspace.alphaValue=0;workspace.orderFront(nil)
        var availabilityChecks=0,created=0,presented=0
        service.create={_,page in
            created += 1
            let value=FirstStartWizardController(preferences:deferredPrefs,initialPage:page)
            value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-24000,y:-24000));owners.append(value)
            return value
        }
        service.present={value in presented += 1;value.window?.alphaValue=0;value.showWindow(nil)}
        let available:()->Bool={ [weak workspace] in availabilityChecks += 1;return workspace?.isVisible==true}
        service.install(isAvailable:available);workspace.close()
        try await wait {availabilityChecks>0}
        try require(created==0 && presented==0 && service.controller==nil,"Closed workspace spawned deferred onboarding")
        workspace.orderFront(nil);service.install(isAvailable:available)
        try await wait {presented==1 && service.controller != nil}
        try require(created==1 && service.controller?.window?.alphaValue==0,"Later explicit workspace could not onboard privately")
        service.install(isAvailable:available)
        try require(created==1 && presented==1,"Repeated workspace installation duplicated onboarding")
        service.controller?.close();workspace.close()
        try await wait {service.controller==nil}
        try require(UserDefaults.standard.object(forKey:"TurtleGit.FirstStartComplete") as? Bool == standardBefore, "Wizard wrote shared completion preferences")
        try require(FirstStartWizardModel.activeWrites == 0 && GeneralGitSettingsModel.activeOperations == 0 && CredentialSettingsModel.activeReads == 0, "Setup operation counts did not settle")
        print("PASS: First Start source forms/order, captured form/picker/check/focus generations, once-only Finish, captured engine/identity, Don't store/Advanced/SSH sheets, private Finish, cached General Apply, cancellable reads and accepted-write/partial-failure lifetime")
    }
}
