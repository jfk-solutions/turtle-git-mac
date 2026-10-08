import AppKit
import SwiftUI
import TurtleGitCore

@main struct BranchTagHandoffVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Branch/Tag timed out") }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), suite = "TurtleGit.BranchTagHandoff.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }; prefs.set(0,forKey:"AutoCloseGitProgress")
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Reference QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("next\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"next")
        let next = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        // Production-style callback hosts the real Switch model. Description is
        // written after result acknowledgement, not before checkout.
        let owner = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); owner.load(revision:"HEAD"); try await wait { !owner.busy && !owner.chooser.busy }; precondition(owner.useHead)
        owner.options.name = "topic"; owner.options.message = "  first\r\nsecond  "; owner.switchAfterCreation = true
        var result:SwitchProgressWindowModel?, acknowledge:(()->Void)?, events:[String] = []
        owner.onCreated = { _ in events.append("created") }; owner.close = { events.append("close") }
        owner.onSwitch = { ref,done in precondition(ref == "refs/heads/topic"); events.append("switch"); acknowledge = done; let model = SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs); result = model; model.close = done; model.start() }
        owner.create(); owner.load(revision:base); try await wait { result?.busy == false }
        precondition(owner.busy && result!.success && events == ["created","switch"] && owner.options.name == "topic")
        let beforeDescription = try await repo.run(["config","--get","branch.topic.description"],successfulExitCodes:0...1); precondition(beforeDescription.exitCode == 1)
        let branch = try await repo.branch(); precondition(branch == "topic")
        acknowledge?(); acknowledge?(); try await wait { !owner.busy }; let description = try await repo.run(["config","--get","branch.topic.description"]).text; precondition(description == "first\nsecond\n" && events == ["created","switch","close"]); owner.create(); precondition(events.count == 3)
        // Failed checkout exposes source Stash/Retry/merge recovery and still
        // writes the description after closing, while the created ref survives.
        _ = try await repo.run(["checkout","main"]); try Data("working\n".utf8).write(to:root.appendingPathComponent("file"))
        let failure = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); failure.load(revision:base); try await wait { !failure.busy && !failure.chooser.busy }; failure.options.name = "older"; failure.options.message = "older description"; failure.switchAfterCreation = true
        var failedResult:SwitchProgressWindowModel?, failedDone:(()->Void)?; failure.onSwitch = { ref,done in failedDone = done; let model = SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs); failedResult = model; model.start() }; failure.create(); try await wait { failedResult?.busy == false }
        precondition(!failedResult!.success && failedResult!.postActions == [.stash,.retry,.switchWithMerge] && failure.busy)
        let oldRef = try await repo.run(["rev-parse","refs/heads/older"]).text.trimmingCharacters(in:.newlines); precondition(oldRef == base)
        failedDone?(); try await wait { !failure.busy }; let retainedBranch = try await repo.branch(), retainedWorking = try String(contentsOf:root.appendingPathComponent("file")), failedDescription = try await repo.run(["config","--get","branch.older.description"]).text; precondition(retainedBranch == "main" && retainedWorking == "working\n" && failedDescription == "older description\n")
        _ = try await repo.run(["reset","--hard",next])
        // A foreign config lock after actual checkout keeps only description
        // retry. Retry neither recreates the ref nor switches again.
        let locked = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); locked.load(revision:nil); try await wait { !locked.busy && !locked.chooser.busy }; locked.options.name = "locked"; locked.options.message = "captured description"; locked.switchAfterCreation = true
        var lockedDone:(()->Void)?, lockedSwitch:SwitchProgressWindowModel?, switchCalls = 0, lockedCloses = 0
        locked.onSwitch = { ref,done in switchCalls += 1; lockedDone = done; let model = SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs); lockedSwitch = model; model.start() }; locked.close = { lockedCloses += 1 }; locked.create(); try await wait { lockedSwitch?.busy == false }
        let lock = root.appendingPathComponent(".git/config.lock"); try Data("foreign lock".utf8).write(to:lock); lockedDone?(); try await wait { !locked.busy }; precondition(locked.retryDescription && locked.error != nil && lockedCloses == 0)
        let lockedRef = try await repo.run(["rev-parse","refs/heads/locked"]).stdout, lockBytes = try Data(contentsOf:lock); precondition(lockBytes == Data("foreign lock".utf8)); try FileManager.default.removeItem(at:lock)
        locked.options.message = "wrong later edit"; locked.create(); try await wait { !locked.busy }; let sameRef = try await repo.run(["rev-parse","refs/heads/locked"]).stdout, lockedDescription = try await repo.run(["config","--get","branch.locked.description"]).text; precondition(sameRef == lockedRef && lockedDescription == "captured description\n" && switchCalls == 1 && lockedCloses == 1)
        // Tag Push and cross-name Continue use captured names/options/intent.
        var shared = ReferenceCreationOptions(); shared.name = "shared"; _ = try await repo.createReference(shared)
        let tag = BranchTagWindowModel(repository:repo,access:nil,isTag:true,preferences:prefs); tag.load(revision:nil); try await wait { !tag.busy && !tag.chooser.busy }; tag.onSwitch = { _,_ in preconditionFailure("Tag must not Switch") }; tag.options.name = "shared"; tag.options.message = "captured tag"; tag.pushAfterCreation = true
        var pushed:[String] = []; tag.onPushTag = { pushed.append($0) }; tag.create(); try await wait { !tag.busy }; precondition(tag.hasPendingNameConflict)
        tag.options.name = "wrong-name"; tag.options.message = "wrong message"; tag.pushAfterCreation = false; tag.create(); tag.create(allowNameConflict:true); try await wait { !tag.busy }
        let tagMessage = try await repo.run(["for-each-ref","--format=%(contents)","refs/tags/shared"]).text; precondition(pushed == ["refs/tags/shared"] && tagMessage.contains("captured tag")); let wrongTag = try? await repo.run(["show-ref","--verify","refs/tags/wrong-name"]); precondition(wrongTag == nil)
        let noPush = BranchTagWindowModel(repository:repo,access:nil,isTag:true,preferences:prefs); noPush.load(revision:nil); try await wait { !noPush.busy && !noPush.chooser.busy }; noPush.onSwitch = { _,_ in preconditionFailure("Tag must not Switch") }; noPush.options.name = "no-push"; noPush.pushAfterCreation = false; noPush.onPushTag = { _ in preconditionFailure("Later Push edit") }; noPush.create(); noPush.pushAfterCreation = true; try await wait { !noPush.busy }
        // A production presenter with unchecked Switch still saves description,
        // and force + whitespace removes old config without moving HEAD.
        let unchecked = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); unchecked.load(revision:nil); try await wait { !unchecked.busy && !unchecked.chooser.busy }
        unchecked.options.name = "unswitched"; unchecked.options.message = "old description"; unchecked.switchAfterCreation = false
        unchecked.onSwitch = { _,_ in preconditionFailure("Unchecked Switch") }; unchecked.create(); try await wait { !unchecked.busy }
        let unswitchedValue = try await repo.run(["config","--get","branch.unswitched.description"]).text; precondition(unswitchedValue == "old description\n")
        let whitespace = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); whitespace.load(revision:nil); try await wait { !whitespace.busy && !whitespace.chooser.busy }
        whitespace.options.name = "unswitched"; whitespace.options.force = true; whitespace.options.message = " \r\n\t "; whitespace.switchAfterCreation = false; whitespace.onSwitch = { _,_ in preconditionFailure("Unchecked Switch") }; whitespace.create(); try await wait { !whitespace.busy }
        let absent = try await repo.run(["config","--get","branch.unswitched.description"],successfulExitCodes:0...1), untouchedBranch = try await repo.branch(); precondition(absent.exitCode == 1 && untouchedBranch == "locked")
        // Actual hidden controller protects running/chooser/pending warning and
        // application Quit. Invalidating a pending warning prevents late create.
        let controller = BranchTagWindowController(repository:repo,access:nil,isTag:true,preferences:prefs); controller.model.load(revision:nil)
        precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await wait { !controller.model.busy && !controller.model.chooser.busy }; let host = NSHostingView(rootView:BranchTagDialog(model:controller.model,chooser:controller.model.chooser)); host.frame = NSRect(x:0,y:0,width:660,height:480); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        controller.window?.contentViewController = nil // Avoid displaying SwiftUI alerts in this headless guard test.
        controller.model.options.name = "topic"; controller.model.create(); try await wait { !controller.model.busy }; precondition(controller.model.hasPendingNameConflict && !controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        controller.close(); controller.model.create(allowNameConflict:true); let lateTag = try? await repo.run(["show-ref","--verify","refs/tags/topic"]); precondition(lateTag == nil)
        print("Branch/Tag: source-order real Switch/description acknowledgement, failed-checkout recovery actions/ref retention, foreign config lock and description-only retry, captured Tag Push/cross-name intent, duplicate/load/invalidation guards and native close/Quit. Hidden controller closed; no displayed UI/push/network or standard preference writes.")
    }
}
