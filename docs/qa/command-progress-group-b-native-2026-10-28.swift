// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Called by the grouped command-progress receiver. No window is presented;
/// injected owned workers still execute the shipping progress model lifecycle.
@MainActor enum CommandProgressPolicyGroupB {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: "Command progress GroupB: " + message) }
    }
    static func verify(container: URL, git: URL) async throws {
        let initialScope=CommandProgressContext.current?.id
        let folder=container.appendingPathComponent("group-b-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:folder)}
        let repository=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _ = try await repository.run(["init","--template=","-b","main"])
        try Data("private owned source\n".utf8).write(to:folder.appendingPathComponent("scope-owned.txt"))
        let originalHead=try Data(contentsOf:folder.appendingPathComponent(".git/HEAD"))
        let originalSource=try Data(contentsOf:folder.appendingPathComponent("scope-owned.txt"))
        let suite="TurtleGit.CommandProgress.GroupB."+UUID().uuidString
        guard let preferences=UserDefaults(suiteName:suite) else {throw Failure(description:"Private preferences unavailable")}
        defer {preferences.removePersistentDomain(forName:suite)}
        preferences.set(0,forKey:"AutoCloseGitProgress")
        preferences.set(false,forKey:"PlaySound")
        let automatic=CommandProgressScope(policy:.noErrors),manual=CommandProgressScope(policy:.manual)
        let clean=CommandProgressContext.perform(automatic) {CleanWindowModel(repository:repository,defaults:preferences)}
        var acceptedScope:UUID?,cleanProgress:CleanProgressWindowModel?
        clean.onAccepted={request in
            acceptedScope=CommandProgressContext.current?.id
            cleanProgress=CleanProgressWindowModel(repository:repository,access:nil,request:request,preferences:preferences)
        }
        defer {cleanProgress?.invalidate();clean.retire()}
        CommandProgressContext.perform(manual) {clean.accept()}
        try require(acceptedScope==automatic.id && cleanProgress?.commandProgressScope?.id==automatic.id,"Deferred Clean acceptance/child lost originating scope")
        try require(preferences.integer(forKey:"AutoCloseGitProgress")==0,"Clean acceptance rewrote saved close policy")

        let add=CommandProgressContext.perform(automatic) {AddProgressWindowModel(repository:repository,access:nil,paths:["scope-owned.txt"],preferences:preferences)}
        defer {add.retire()}
        var workerScopes:[UUID?]=[],closeScopes:[UUID?]=[],finishScopes:[UUID?]=[]
        var release:CheckedContinuation<String,Never>?
        add.execute={_ in
            workerScopes.append(CommandProgressContext.current?.id)
            return await withCheckedContinuation {release=$0}
        }
        add.executeMode={_,_ in workerScopes.append(CommandProgressContext.current?.id)}
        add.close={closeScopes.append(CommandProgressContext.current?.id)}
        add.onFinished={_,_ in finishScopes.append(CommandProgressContext.current?.id)}
        let pending=Task {await CommandProgressContext.perform(manual) {await add.run()}}
        do {
            let deadline=Date().addingTimeInterval(10)
            while release==nil,Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
            try require(release != nil && add.busy && closeScopes.isEmpty && AddProgressWindowModel.activeOperations==1,"Automatic policy closed or lost a live owned Add worker")
            let finish=release;release=nil;finish?.resume(returning:"Owned injected add completed")
            await pending.value
        } catch {
            let finish=release;release=nil;finish?.resume(returning:"Retired injected worker drained")
            add.retire();await pending.value;throw error
        }
        try require(add.success && !add.busy && closeScopes==[automatic.id],"Add did not retain command automatic policy after options event")
        try require(workerScopes==[automatic.id] && finishScopes==[automatic.id],"Add worker/completion context changed")
        try require(preferences.integer(forKey:"AutoCloseGitProgress")==0,"Automatic invocation changed saved manual preference")

        // A different command's active TaskLocal must not override this owner's
        // explicit manual policy or its delayed post-command after actual drain.
        preferences.set(2,forKey:"AutoCloseGitProgress")
        let held=CommandProgressContext.perform(manual) {AddProgressWindowModel(repository:repository,access:nil,paths:["scope-owned.txt"],preferences:preferences)}
        var manualCloses=0,handoffs=0,handoffScope:UUID?,reply:((Bool)->Void)?
        defer {reply?(false);held.retire()}
        held.execute={_ in "Owned injected manual add completed"}
        held.executeMode={_,_ in workerScopes.append(CommandProgressContext.current?.id)}
        held.close={manualCloses+=1}
        held.onCommit={handoffs+=1;handoffScope=CommandProgressContext.current?.id}
        held.finishAndPerform={value in reply=value}
        await CommandProgressContext.perform(automatic) {await held.run()}
        try require(held.success && manualCloses==0,"Explicit manual policy leaked automatic preference or sibling command")
        await CommandProgressContext.perform(automatic) {await held.changeMode(.executable)}
        try require(held.success && manualCloses==0 && workerScopes.count==2 && workerScopes[1]==manual.id,"Add mode retry lost original manual policy")
        CommandProgressContext.perform(automatic) {held.commit()}
        try require(held.handoffPending && AddProgressWindowModel.activeOperations==1 && handoffs==0,"Pending handoff lost worker ownership")
        guard let finish=reply else {throw Failure(description:"Deferred Add handoff callback missing")}
        CommandProgressContext.perform(automatic) {finish(true);finish(true)}
        try require(handoffs==1 && handoffScope==manual.id && !held.handoffPending && AddProgressWindowModel.activeOperations==0,"Delayed post-command did not restore immutable scope exactly once")
        try require(preferences.integer(forKey:"AutoCloseGitProgress")==2,"Manual invocation changed saved automatic preference")
        let noOptions=CommandProgressScope(policy:.noOptions)
        let noMoreOptions=CommandProgressContext.perform(noOptions) {AddProgressWindowModel(repository:repository,access:nil,paths:["scope-owned.txt"],mode:.executable,preferences:preferences)}
        defer {noMoreOptions.retire()}
        noMoreOptions.allowsCommit=false
        var noOptionsCloses=0
        noMoreOptions.execute={_ in "Owned no-options add completed"};noMoreOptions.close={noOptionsCloses+=1}
        await CommandProgressContext.perform(manual) {await noMoreOptions.run()}
        try require(noMoreOptions.success && noOptionsCloses==1,"No-options policy did not close a drained result without post-actions")
        let withOptions=CommandProgressContext.perform(noOptions) {AddProgressWindowModel(repository:repository,access:nil,paths:["scope-owned.txt"],preferences:preferences)}
        defer {withOptions.retire()}
        withOptions.execute={_ in "Owned options-bearing add completed"};withOptions.close={noOptionsCloses+=1}
        await CommandProgressContext.perform(automatic) {await withOptions.run()}
        try require(withOptions.success && noOptionsCloses==1,"No-options policy hid available post-actions or leaked sibling policy")
        try require(CommandProgressContext.current?.id==initialScope,"Command scope escaped receiver operation")
        try require(try Data(contentsOf:folder.appendingPathComponent(".git/HEAD"))==originalHead,"Injected operation changed private HEAD")
        try require(try Data(contentsOf:folder.appendingPathComponent("scope-owned.txt"))==originalSource,"Injected operation changed private source")
        try require(!FileManager.default.fileExists(atPath:folder.appendingPathComponent(".git/index").path),"Injected operation wrote a private index")
        print("PASS: Command progress GroupB options, retry, saved preferences and deferred handoff")
    }
}
