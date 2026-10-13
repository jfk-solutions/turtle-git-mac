import AppKit
import TurtleGitCore

@main struct LogMetadataVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Metadata timeout")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Log metadata failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        setenv("TURTLEGIT_QA_METADATA_GIT",git.path,1)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Metadata QA"),("user.email","metadata@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for index in 0..<12 {
            let path="file-\(index)\n雪"
            try Data("metadata \(index)\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"row \(index)")
        }
        let entries=try await repo.history(),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let wrapper=root.appendingPathComponent("count-git")
        try """
        #!/bin/sh
        if [ "$4" = diff-tree ]; then printf '%s\\n' diff-tree >> "$0.calls"; fi
        exec "${TURTLEGIT_QA_METADATA_GIT:?}" "$@"

        """.write(to:wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let suite="TurtleGit.LogMetadata.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let model=LogWindowModel(repository:GitRepository(root:root,executable:wrapper),access:nil,labelDefaults:prefs)
        model.entries=entries
        for entry in entries { model.requestActions(entry);model.requestActions(entry) }
        try await wait { !model.loadingActions && LogWindowModel.activeActionReads==0 }
        try require(model.actionFailures.isEmpty && model.revisionActions.count==entries.count,"Actions failed or omitted rows")
        try require(model.revisionActions.values.allSatisfy { $0.contains(.added) },"Wrong action role")
        let calls=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".calls")).split(separator:"\n")
        try require(calls.count==1,"Visible actions did not coalesce")
        let slow=root.appendingPathComponent("slow-git")
        try """
        #!/bin/sh
        if [ "$4" = diff-tree ]; then : > "$0.started"; /bin/sleep 30; fi
        exec "${TURTLEGIT_QA_METADATA_GIT:?}" "$@"

        """.write(to:slow,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:slow.path)
        let retired=LogWindowModel(repository:GitRepository(root:root,executable:slow),access:nil,labelDefaults:prefs);retired.entries=entries
        for entry in entries { retired.requestActions(entry) }
        try await wait { FileManager.default.fileExists(atPath:slow.path+".started") }
        retired.invalidate()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit did not await retired actions")
        try await wait { LogWindowModel.activeActionReads==0 }
        try require(retired.revisionActions.isEmpty && retired.actionFailures.isEmpty,"Retired batch published results")
        retired.requestActions(entries[0]);try require(!retired.loadingActions,"Retired model restarted")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==afterHead && index==afterIndex,"Metadata mutated Git")
        model.invalidate();print("Log metadata: 12 visible action rows coalesced into one owned diff-tree process; duplicate suppression, roles, retired cancellation/Quit and unchanged HEAD/index passed.")
    }
}
