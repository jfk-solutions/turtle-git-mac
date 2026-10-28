// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@main struct CommandProgressVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<3000 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: "Owned command progress did not settle")
    }
    @MainActor static func verifyRouting(container: URL, git: URL) async throws {
        let root=container.appendingPathComponent("routing", isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Progress QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {
            _ = try await repository.run(["config",key,value])
        }
        try Data("owned\n".utf8).write(to:root.appendingPathComponent("file"))
        try await repository.stage(["file"])
        _ = try await repository.commit(message:"base")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.CommandProgress.Routing."+UUID().uuidString
        let preferences=UserDefaults(suiteName:suite)!
        preferences.set(1,forKey:"AutoCloseGitProgress")
        defer { preferences.removePersistentDomain(forName:suite) }
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false
        workspace.fileComparisonPreferences=preferences
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container)}
        var controllers:[CommitWindowController]=[],scopes:[CommandProgressScope?]=[]
        workspace.commitWindowFactory={repo,access in
            scopes.append(CommandProgressContext.current)
            let controller=CommitWindowController(repository:repo,access:access,defaults:preferences)
            controllers.append(controller)
            return controller
        }
        defer {
            controllers.forEach {$0.close()}
            workspace.stopMonitoringForTermination()
        }
        for arguments in [["--command=commit","--closeonend=0"],["--command=commit","--closeonend=2"],["--command=commit"]] {
            let count=controllers.count
            workspace.handleCommandLine(arguments:arguments,currentDirectory:root.path)
            try await wait {!workspace.busy && controllers.count==count+1 && controllers.last?.model.busy == false}
        }
        try require(scopes.count==3 && scopes[0]?.policy == .manual && scopes[1]?.policy == .noErrors && scopes[2]==nil,"CLI scope was lost or another invocation's owner was reused")
        try require(scopes[0]?.id != scopes[1]?.id,"Independent commands share their window identity")
        controllers[0].close()
        try await wait {CommitWindowModel.activeReloads==0}
        workspace.handleCommandLine(arguments:["--command=commit"],currentDirectory:root.path)
        try await wait {!workspace.busy}
        try require(controllers.count==3 && workspace.error != nil,"Closing explicit command evicted ordinary owner's cache entry")
        try require(preferences.integer(forKey:"AutoCloseGitProgress")==1,"Command invocation changed saved policy")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Opening command forms mutated the index")
        controllers.forEach {$0.close()}
        try await wait {CommitWindowModel.activeReloads==0}
        var log:LogWindowController?,logScope:CommandProgressScope?
        workspace.logWindowFactory={repo,access in
            logScope=CommandProgressContext.current
            let controller=LogWindowController(repository:repo,access:access,labelDefaults:preferences,loadsImmediately:false)
            log=controller
            return controller
        }
        defer {log?.close()}
        workspace.handleCommandLine(arguments:["--command=log","--closeonend=1"],currentDirectory:root.path)
        try await wait {!workspace.busy && log != nil}
        let before=controllers.count
        CommandProgressContext.perform(CommandProgressScope(policy:.manual)) {
            log?.model.onWorkingFiles?(.commit, [])
        }
        try await wait {controllers.count==before+1 && controllers.last?.model.busy == false}
        try require(logScope?.policy == .noOptions && scopes.last! == logScope,"Delayed Log action inherited a foreign command's policy")
        controllers.last?.close();log?.close()
        try await wait {CommitWindowModel.activeReloads==0 && LogWindowModel.activeHistoryLoads==0}
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let ordered=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.commandProgressOrder(_:relativeTo:)))!
        method_exchangeImplementations(ordered,hidden)
        defer {
            for window in NSApp.windows {window.close()}
            method_exchangeImplementations(ordered,hidden)
        }
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        switch CommandLine.arguments[3] {
        case "routing": try await verifyRouting(container:container,git:git)
        case "a": try await CommandProgressPolicyGroupA.verify(container:container,git:git)
        case "b": try await CommandProgressPolicyGroupB.verify(container:container,git:git)
        default: throw Failure(message:"Unknown progress verification group")
        }
        print("PASS: command progress "+CommandLine.arguments[3]+"; owned workers drained and windows closed")
    }
}
private extension NSWindow {
    @objc func commandProgressOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0
        setFrameOrigin(NSPoint(x:-20000,y:-20000))
        commandProgressOrder(place,relativeTo:number)
    }
}
