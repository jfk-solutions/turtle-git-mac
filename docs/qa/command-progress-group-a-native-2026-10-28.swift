// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Invoked by the grouped invisible receiver. These are shipping models with
/// injected workers: no network, Finder registration, shared preferences or UI.
@MainActor enum CommandProgressPolicyGroupA {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private struct OwnedWorkerFailure: Error {}
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: "Command progress Group A: " + message) }
    }
    static func verify(container: URL, git: URL) async throws {
        let directory=container.appendingPathComponent("command-progress-group-a-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let suite="TurtleGit.CommandProgress.GroupA."+UUID().uuidString
        guard let preferences=UserDefaults(suiteName:suite) else {throw Failure(description:"Private preferences unavailable")}
        defer {preferences.removePersistentDomain(forName:suite)}
        preferences.set(false,forKey:"PlaySound")
        let manual=CommandProgressScope(policy:.manual),automatic=CommandProgressScope(policy:.noErrors),noOptions=CommandProgressScope(policy:.noOptions)
        let repository=GitRepository(root:directory,executable:git)

        // The explicit 0 must override the stored 2. Absence still uses the
        // stored policy; a sibling's current scope cannot alter an existing owner.
        for (owner,saved,expectedCloses) in [(manual as CommandProgressScope?,2,0),(automatic as CommandProgressScope?,0,1),(noOptions as CommandProgressScope?,2,0),(nil,2,1)] {
            preferences.set(saved,forKey:"AutoCloseGitProgress")
            let progress=CommandProgressContext.perform(owner) {PushProgressWindowModel(options:PushOptions(),superproject:nil,preferences:preferences)}
            defer {progress.invalidate()}
            var closes=0,closeScope:UUID?
            progress.close={closes+=1;closeScope=CommandProgressContext.current?.id}
            CommandProgressContext.perform(manual) {progress.complete(output:"Owned push succeeded",success:true,cancelled:false)}
            try require(progress.success && !progress.busy && closes==expectedCloses,"Push completion ignored invocation/absence policy")
            if expectedCloses>0 {try require(closeScope==owner?.id,"Push automatic close used sibling command context")}
            try require(progress.postActions==[.requestPull,.push,.switchBranch],"Auto-close policy removed Push follow-up actions")
            try require(preferences.integer(forKey:"AutoCloseGitProgress")==saved,"Push completion changed saved preferences")
        }

        // A retry opened from a retained result belongs to that command even
        // after its completion callback is held and delivered by a foreign event.
        preferences.set(2,forKey:"AutoCloseGitProgress")
        let result=CommandProgressContext.perform(manual) {PushProgressWindowModel(options:PushOptions(),superproject:nil,preferences:preferences)}
        defer {result.invalidate()}
        var delayed:(()->Void)?,retry:PushProgressWindowModel?,handoffs=0,actionScope:UUID?
        result.onPostAction={action in
            handoffs+=1;actionScope=CommandProgressContext.current?.id
            delayed=CommandProgressContext.capture {retry=PushProgressWindowModel(options:result.options,superproject:nil,preferences:preferences)}
        }
        result.complete(output:"Owned transport failed",success:false,cancelled:false)
        CommandProgressContext.perform(automatic) {result.perform(.push);result.perform(.push)}
        try require(handoffs==1 && actionScope==manual.id,"Push retry dispatch lost owner or dispatched twice")
        guard let delayed else {throw Failure(description:"Push retry callback missing")}
        CommandProgressContext.perform(automatic) {delayed()}
        guard let retry else {throw Failure(description:"Push retry result missing")}
        defer {retry.invalidate()}
        var retryCloses=0;retry.close={retryCloses+=1}
        CommandProgressContext.perform(automatic) {retry.complete(output:"Owned retry succeeded",success:true,cancelled:false)}
        try require(retry.success && retryCloses==0,"Retried Push result lost explicit manual policy")

        // Even noErrors retains errors and completion warnings for inspection.
        let warning=CommandProgressContext.perform(automatic) {PushProgressWindowModel(options:PushOptions(),superproject:nil,preferences:preferences)}
        defer {warning.invalidate()}
        var warningCloses=0;warning.close={warningCloses+=1}
        warning.complete(output:"Owned transport succeeded",success:true,cancelled:false,completionWarning:"Owned post-push warning")
        try require(warning.hasCompletionWarning && warningCloses==0,"Policy hid Push completion warning")

        // A later button event runs outside the originating TaskLocal. The
        // shipping Stash worker must restore it and retain errors after drain.
        preferences.set(0,forKey:"AutoCloseGitProgress")
        let stash=CommandProgressContext.perform(automatic) {StashSaveProgressWindowModel(repository:repository,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:preferences)}
        defer {stash.invalidate()}
        let originalOperations=StashSaveProgressWindowModel.activeOperations
        var workerScopes:[UUID?]=[],finishScopes:[UUID?]=[],stashCloses=0
        stash.saveOperation={_,_,_,_ in workerScopes.append(CommandProgressContext.current?.id);throw OwnedWorkerFailure()}
        stash.onFinished={_,_ in finishScopes.append(CommandProgressContext.current?.id)}
        stash.close={stashCloses+=1}
        await CommandProgressContext.perform(manual) {await stash.run()}
        await CommandProgressContext.perform(manual) {await stash.run()}
        try require(workerScopes==[automatic.id] && finishScopes==[automatic.id],"Deferred Stash start lost owner scope or executed twice")
        try require(!stash.success && !stash.busy && !stash.hasPendingWork && stashCloses==0,"Stash error auto-closed or failed to drain")
        try require(StashSaveProgressWindowModel.activeOperations==originalOperations,"Stash retained owned worker after failure")
        try require(preferences.integer(forKey:"AutoCloseGitProgress")==0,"Stash worker changed saved policy")
        try await verifyLFS(repository:repository,preferences:preferences)
        try require(CommandProgressContext.current==nil,"Command context escaped Group A verification")
        print("PASS: Command progress Group A saved preference isolation, explicit manual, deferred start, retry and error retention")
    }
    private static func verifyLFS(repository: GitRepository, preferences: UserDefaults) async throws {
        let automatic=CommandProgressScope(policy:.noErrors),manual=CommandProgressScope(policy:.manual),noOptions=CommandProgressScope(policy:.noOptions)
        let originalOperations=LFSLocksWindowModel.activeOperations
        let file=LFSFileResult(path:"scope-owned.txt",success:true,output:"Owned result")
        for (scope,saved,expectedVisible) in [(manual,2,true),(noOptions,0,false),(automatic,0,false)] {
            preferences.set(saved,forKey:"AutoCloseGitProgress")
            let model=CommandProgressContext.perform(scope) {LFSLocksWindowModel(repository:repository,access:nil,defaults:preferences)}
            defer {model.retire()}
            model.refreshLocksAfterOperation=false
            var observed:UUID?
            model.change={_,_,_,_ in observed=CommandProgressContext.current?.id;return LFSBatchResult(files:[file])}
            await CommandProgressContext.perform(automatic) {await model.perform(paths:[file.path],locked:false)}
            try require(observed==scope.id && model.showingProgress==expectedVisible,"Deferred LFS unlock lost originating command policy")
            try require(!model.busy && !model.actionLogFailed,"Injected LFS unlock did not drain successfully")
            try require(preferences.integer(forKey:"AutoCloseGitProgress")==saved,"LFS completion changed saved preferences")
        }
        preferences.set(0,forKey:"AutoCloseGitProgress")
        let retry=CommandProgressContext.perform(automatic) {LFSLocksWindowModel(repository:repository,access:nil,defaults:preferences)}
        defer {retry.retire()}
        retry.refreshLocksAfterOperation=false
        var attempts=0,forceValues:[Bool]=[],scopes:[UUID?]=[]
        retry.change={_,force,_,_ in
            attempts+=1;forceValues.append(force);scopes.append(CommandProgressContext.current?.id)
            return LFSBatchResult(files:[LFSFileResult(path:file.path,success:attempts>1,output:"Owned retry result")])
        }
        await CommandProgressContext.perform(manual) {await retry.perform(paths:[file.path],locked:false)}
        try require(retry.canForceRetry && retry.showingProgress,"LFS automatic policy hid failed unlock or force retry")
        await CommandProgressContext.perform(manual) {await retry.unlock(forceRetry:true)}
        try require(attempts==2 && forceValues==[false,true] && scopes==[automatic.id,automatic.id] && !retry.showingProgress,"LFS force retry lost command policy or captured options")

        let cancelled=CommandProgressContext.perform(automatic) {LFSLocksWindowModel(repository:repository,access:nil,defaults:preferences)}
        defer {cancelled.retire()}
        cancelled.refreshLocksAfterOperation=false
        cancelled.change={_,_,_,_ in LFSBatchResult(files:[file],cancelled:true)}
        await cancelled.perform(paths:[file.path],locked:false)
        try require(cancelled.actionLogCancelled && cancelled.showingProgress,"LFS automatic policy hid cancelled result")

        // The accepted lock callback runs with the owner's scope. A quit request
        // raised by that callback must prevent automatic result dismissal.
        let lock=CommandProgressContext.perform(automatic) {LFSLocksWindowModel(repository:repository,access:nil,defaults:preferences)}
        defer {lock.retire()}
        lock.refreshLocksAfterOperation=false;lock.lockChange={_,_,_ in LFSBatchResult(files:[file])}
        var pullScopes:[UUID?]=[]
        lock.onPullAfterLock={pullScopes.append(CommandProgressContext.current?.id);lock.confirmingQuit=true}
        await CommandProgressContext.perform(manual) {await lock.perform(paths:[file.path],locked:true)}
        try require(pullScopes==[automatic.id] && lock.showingProgress,"LFS Pull callback lost scope or bypassed quit ownership gate")
        try require(LFSLocksWindowModel.activeOperations==originalOperations,"LFS policy left active owned operations")
    }

}
