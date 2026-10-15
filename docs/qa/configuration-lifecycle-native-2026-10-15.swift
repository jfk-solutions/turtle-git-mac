// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct ConfigurationLifecycleVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Configuration lifecycle wait at line \(line)")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root, executable: engine)
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Configuration QA"),("user.email","config@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repository.stage(["file.txt"]); _ = try await repository.commit(message: "base")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repository.run(["rev-parse","HEAD"]).stdout
        let files = try await repository.gitConfigurationFiles(hasRepository: true)
        let suite = "TurtleGit.ConfigLifecycle.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        preferences.set(true,forKey:"HintHierarchicalConfig")
        defer { preferences.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: .init(x:0,y:0,width:700,height:500), styleMask: [.titled,.closable], backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.orderFront(nil); defer { window.close() }
        func quitBlocked() -> Bool { TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel }
        // Superseded/closed read remains owned until an uncooperative provider settles.
        let projectRead = ProjectDialogSettingsModel(preferences: preferences)
        var projectRelease: CheckedContinuation<GitConfigurationFiles,Error>?, projectToken: OperationCancellation?
        projectRead.readConfigurationFiles = { _,_,token in projectToken=token; return try await withCheckedThrowingContinuation { projectRelease=$0 } }
        projectRead.activate(repository:repository,access:nil,localAvailable:true); try await wait { projectRelease != nil }
        try require(ProjectDialogSettingsModel.activeReads==1 && quitBlocked(),"Project read does not fence Quit")
        projectRead.invalidate(); try require(projectToken?.isCancelled==true && ProjectDialogSettingsModel.activeReads==1,"Project close lost pending read")
        projectRelease?.resume(returning:files); try await wait { ProjectDialogSettingsModel.activeReads==0 }
        try require(!projectRead.loaded && !projectRead.active && projectRead.error==nil,"Late Project read published/reactivated")
        let issueRead = IssueTrackerSettingsModel(preferences: preferences)
        var issueRelease: CheckedContinuation<GitConfigurationFiles,Error>?, issueToken: OperationCancellation?
        issueRead.readConfigurationFiles = { _,_,token in issueToken=token; return try await withCheckedThrowingContinuation { issueRelease=$0 } }
        issueRead.activate(repository:repository,access:nil,localAvailable:true); try await wait { issueRelease != nil }
        try require(IssueTrackerSettingsModel.activeReads==1 && quitBlocked(),"Issue read does not fence Quit")
        issueRead.invalidate(); try require(issueToken?.isCancelled==true,"Issue read not cancelled")
        issueRelease?.resume(returning:files); try await wait { IssueTrackerSettingsModel.activeReads==0 }
        try require(!issueRead.loaded && !issueRead.active && issueRead.error==nil,"Late Issue read published")
        let gitRead = GitConfigurationSettingsModel(preferences: preferences)
        var gitRelease: CheckedContinuation<GitConfigurationFiles,Error>?, gitToken: OperationCancellation?
        gitRead.readConfigurationFiles = { _,_,token in gitToken=token; return try await withCheckedThrowingContinuation { gitRelease=$0 } }
        gitRead.activate(repository:repository,access:nil,localAvailable:true); try await wait { gitRelease != nil }
        try require(GitConfigurationSettingsModel.activeReads==1 && quitBlocked(),"Git read does not fence Quit")
        gitRead.deactivate(); try require(gitToken?.isCancelled==true,"Git read not cancelled")
        gitRelease?.resume(returning:files); try await wait { GitConfigurationSettingsModel.activeReads==0 }
        try require(!gitRead.loaded && !gitRead.isActive && gitRead.error==nil,"Late Git read published")
        // Real local writes finish after invalidation, with captured value/destination.
        let project = ProjectDialogSettingsModel(preferences:preferences); project.authorizeFile={_ in true}; project.window=window
        defer { project.invalidate() }
        project.activate(repository:repository,access:nil,localAvailable:true); try await wait { project.loaded && !project.busy }
        project.load(.local); try await wait { project.loaded && !project.busy }
        project.draft.minimumMessageLength = .init(value:"17",inherit:false)
        project.suspend() // Cached inactive page still participates in property-sheet Apply.
        var projectWriteRelease: CheckedContinuation<Void,Never>?, projectDestination: ProjectDialogSettingsSource?
        project.writeSettings = { repo,value,destination,local in
            projectDestination=destination; await withCheckedContinuation { projectWriteRelease=$0 }
            try await repo.saveProjectDialogSettings(value,destination:destination,hasRepository:local)
        }
        let projectSave=Task { await project.apply(owner:window) }; try await wait { projectWriteRelease != nil }
        try require(ProjectDialogSettingsModel.activeSaves==1 && quitBlocked(),"Accepted Project save does not fence Quit")
        project.draft.minimumMessageLength.value="99"; project.destination = .project; project.invalidate()
        projectWriteRelease?.resume(); let projectResult=await projectSave.value
        let storedProject=try await repository.projectDialogSettings(source:.local)
        try require(!projectResult && !project.active && projectDestination == .local && storedProject.minimumLength==17 && ProjectDialogSettingsModel.activeSaves==0,"Captured Project save or retired UI differs")
        let issue=IssueTrackerSettingsModel(preferences:preferences); issue.authorizeFile={_ in true}; issue.window=window
        defer { issue.invalidate() }
        issue.activate(repository:repository,access:nil,localAvailable:true); try await wait { issue.loaded && !issue.busy }
        issue.load(.local); try await wait { issue.loaded && !issue.busy }
        issue.draft.fields[.label] = .init(value:"Captured ticket",inherit:false); issue.suspend()
        var issueWriteRelease: CheckedContinuation<Void,Never>?
        issue.writeSettings = { repo,value,destination,local in await withCheckedContinuation { issueWriteRelease=$0 }; try await repo.saveIssueTrackerSettings(value,destination:destination,hasRepository:local) }
        let issueSave=Task { await issue.apply(owner:window) }; try await wait { issueWriteRelease != nil }
        try require(IssueTrackerSettingsModel.activeSaves==1 && quitBlocked(),"Accepted Issue save does not fence Quit")
        issue.draft.fields[.label]?.value="late"; issue.destination = .project; issue.invalidate()
        issueWriteRelease?.resume(); let issueResult=await issueSave.value
        let storedIssue=try await repository.issueTrackerSettings(source:.local)
        try require(!issueResult && !issue.active && storedIssue.fields[.label]?.value=="Captured ticket" && IssueTrackerSettingsModel.activeSaves==0,"Captured Issue save/retirement differs")
        let git=GitConfigurationSettingsModel(preferences:preferences); git.authorizeFile={_ in true}; git.window=window
        defer { git.deactivate() }
        git.activate(repository:repository,access:nil,localAvailable:true); try await wait { git.loaded && !git.busy }
        git.load(.local); try await wait { git.loaded && !git.busy }
        git.draft.name = .init(value:"Captured name",inherit:false); git.deactivate()
        var gitWriteRelease: CheckedContinuation<Void,Never>?
        git.writeSettings = { repo,value,destination in await withCheckedContinuation { gitWriteRelease=$0 }; try await repo.saveGitConfiguration(value,destination:destination) }
        let gitSave=Task { await git.applyForSettings(owner:window) }; try await wait { gitWriteRelease != nil }
        try require(GitConfigurationSettingsModel.activeSaves==1 && quitBlocked(),"Accepted Git save does not fence Quit")
        git.draft.name.value="late"; git.destination = .global; git.deactivate()
        gitWriteRelease?.resume(); let gitResult=await gitSave.value
        let storedGit=try await repository.gitConfiguration(source:.local)
        try require(!gitResult && !git.isActive && storedGit.name.value=="Captured name" && GitConfigurationSettingsModel.activeSaves==0,"Captured Git save/retirement differs")
        // An unaccepted destination confirmation must never write after closure.
        let pending=ProjectDialogSettingsModel(preferences:preferences); pending.authorizeFile={_ in true}; pending.window=window
        defer { pending.invalidate() }
        pending.activate(repository:repository,access:nil,localAvailable:true); try await wait { pending.loaded && !pending.busy }
        pending.load(.local); try await wait { pending.loaded && !pending.busy }; pending.destination = .project
        var confirm: CheckedContinuation<Bool,Never>?
        pending.confirmSavingTo={_ in await withCheckedContinuation { confirm=$0 } }
        let unanswered=Task { await pending.apply(owner:window) }; try await wait { confirm != nil }
        pending.invalidate(); confirm?.resume(returning:true); let pendingResult=await unanswered.value
        try require(!pendingResult && !pending.active && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".tgitconfig").path),"Late confirmation wrote project configuration")
        // Native hierarchy hint suppression belongs to the Settings preference domain.
        let standardHint = UserDefaults.standard.object(forKey:"HintHierarchicalConfig") as? NSNumber
        func views(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(views) }
        func dismissHint() async throws {
            try await wait { window.attachedSheet != nil }
            let sheet=window.attachedSheet!
            guard let check=views(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where:{ $0.title=="Do not show this message again" }) else { throw Failure(description:"Missing hierarchy hint suppression") }
            check.state = .on; window.endSheet(sheet,returnCode:.alertFirstButtonReturn)
            try await wait { preferences.bool(forKey:"HintHierarchicalConfig") && window.attachedSheet==nil }
            sheet.orderOut(nil)
        }
        preferences.set(false,forKey:"HintHierarchicalConfig")
        let projectHint=ProjectDialogSettingsModel(preferences:preferences); projectHint.authorizeFile={_ in true}; projectHint.window=window
        defer { projectHint.invalidate() }
        projectHint.activate(repository:repository,access:nil,localAvailable:true); try await dismissHint()
        preferences.set(false,forKey:"HintHierarchicalConfig")
        let gitHint=GitConfigurationSettingsModel(preferences:preferences); gitHint.authorizeFile={_ in true}; gitHint.window=window
        defer { gitHint.deactivate() }
        gitHint.activate(repository:repository,access:nil,localAvailable:true); try await dismissHint()
        try require((UserDefaults.standard.object(forKey:"HintHierarchicalConfig") as? NSNumber)==standardHint,"Private hierarchy hint modified standard preferences")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Config lifecycle changed index")
        let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout; try require(finalHead==head,"Config lifecycle changed HEAD")
        print("PASS: Hierarchical settings cancelled reads, cached Apply, captured real writes, post-close Quit ownership and late-confirmation refusal")
    }
}
