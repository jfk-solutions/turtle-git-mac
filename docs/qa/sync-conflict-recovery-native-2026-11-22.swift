// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SyncConflictRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        if !value {throw Failure(description:"Sync conflict recovery \(line): "+message)}
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {
        guard let value else{throw Failure(description:message)};return value
    }
    static func wait(_ message:String,diagnostics:()->String = {""},_ ready:()->Bool)async throws {
        for _ in 0..<4000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Sync conflict recovery timeout: "+message+" "+diagnostics())
    }
    @MainActor final class Context {
        let base:URL,git:URL
        let suite="TurtleGit.SyncConflictRecovery."+UUID().uuidString
        let replacementSuite="TurtleGit.SyncConflictReplacement."+UUID().uuidString
        let preferences:UserDefaults,replacement:UserDefaults,clipboard=NSPasteboard.withUniqueName()
        let paths=["conflict 🐢.txt","other.swift"]
        var repo:GitRepository!,nested:GitRepository!,head="",nestedHead="",indexInput=Data()
        var workspace:RepositoryModel?,host:NSWindow?,owner:SynchronizationWindowController?
        var children:[ResolveWindowController]=[]
        var question:(NSWindow,NSAlert,(NSApplication.ModalResponse)->Void)?
        var notifications:[String]=[],closed=false
        var held=false,released=false
        init(base:URL,git:URL) {
            self.base=base.standardizedFileURL;self.git=git
            preferences=UserDefaults(suiteName:suite)!
            replacement=UserDefaults(suiteName:replacementSuite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"RefreshFileListAfterResolvingConflict")
            preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(0,forKey:"AutoCloseGitProgress")
            replacement.set(false,forKey:"RefreshFileListAfterResolvingConflict")
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            func repository(_ name:String)async throws->GitRepository {
                let root=base.appendingPathComponent(name)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let value=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
                _=try await value.run(["init","--template=","-b","main"])
                for (key,text) in [("user.name","Conflict Recovery QA"),("user.email","recovery@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await value.run(["config",key,text])}
                return value
            }
            repo=try await repository("repository")
            for path in paths {try Data("base\n".utf8).write(to:repo.root.appendingPathComponent(path))}
            try await repo.stage(paths);_=try await repo.commit(message:"Conflict recovery baseline")
            head=try await repo.rebaseCommit("HEAD").hash
            func blob(_ text:String)async throws->String {String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
            let baseHash=try await blob("base\n"),mine=try await blob("mine\n"),theirs=try await blob("theirs\n")
            indexInput=Data(paths.map {"0 "+String(repeating:"0",count:40)+"\t"+$0+"\n100644 "+baseHash+" 1\t"+$0+"\n100644 "+mine+" 2\t"+$0+"\n100644 "+theirs+" 3\t"+$0+"\n"}.joined().utf8)
            try await restoreConflicts()
            nested=try await repository("nested")
            _=try await nested.run(["commit","--allow-empty","-m","Nested baseline"])
            nestedHead=try await nested.rebaseCommit("HEAD").hash
            let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("private-access.json"))
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git] in GitRepository(root:$0,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:preferences,publishCachePersistence:{_ in})
            workspace=model;model.fileComparisonPreferences=preferences
            let window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:300,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0;window.orderFront(nil);host=window;model.workspaceWindow=window
            model.synchronizationWindowPresentation={ [weak self] child in
                guard let self else{return};self.owner=child
                child.window?.alphaValue=0;child.window?.setFrameOrigin(.init(x:-24000,y:-24000));child.showWindow(nil)
                child.model.tab=6
            }
            model.open(repo.root)
            try await SyncConflictRecoveryVerification.wait("private workspace load") {!model.busy && model.root?.path==self.repo.root.path}
            model.showSynchronization()
            try await SyncConflictRecoveryVerification.wait("production Sync conflict rows") {self.owner?.model.busy==false && self.owner?.model.conflictFileActions.busy==false && self.owner?.model.conflictFileActions.files.count==2}
            let owner=try SyncConflictRecoveryVerification.unwrap(owner,"Production Sync missing")
            let onClosed=owner.onClosed
            owner.onClosed={ [weak self] in onClosed();self?.closed=true }
            let configured=owner.configureConflictResolution
            owner.configureConflictResolution={ [weak self] child in
                configured(child)
                guard let self else{return};self.children.append(child)
                let publish=child.onChanged
                child.onChanged={ [weak self] text in self?.notifications.append(text);publish(text) }
                child.presentQuestion={ [weak self] parent,alert,reply in
                    guard let self,self.question==nil,parent.attachedSheet==nil else{return false}
                    alert.window.alphaValue=0;parent.beginSheet(alert.window)
                    self.question=(parent,alert,reply);return true
                }
            }
            // Changing the workspace defaults cannot retarget an existing Sync.
            model.fileComparisonPreferences=replacement
            owner.model.conflictFileActions.clipboard=clipboard
        }
        func restoreConflicts()async throws {
            _=try await repo.run(["update-index","--index-info"],input:indexInput)
            for path in paths {try Data("working\n".utf8).write(to:repo.root.appendingPathComponent(path))}
        }
        func refreshRows()async throws {
            owner?.model.refreshConflictFiles()
            try await SyncConflictRecoveryVerification.wait("explicit conflict refresh") {self.owner?.model.conflictFileActions.busy==false && self.owner?.model.conflictFileActions.files.count==2}
        }
        func begin(_ action:RepositoryAction)async throws->ResolveWindowController {
            let owner=try SyncConflictRecoveryVerification.unwrap(owner,"Missing Sync owner")
            let previous=children.count,actions=owner.model.conflictFileActions
            actions.selection=GitPathSet(paths)
            let menu=owner.model.conflictMenu(paths,mark:paths[1])
            owner.model.performConflict(action,menu:menu)
            try await SyncConflictRecoveryVerification.wait("owned Resolve confirmation") {self.children.count==previous+1 && self.question != nil && self.children.last?.model.hasQuestion==true}
            return children.last!
        }
        func answer(_ value:NSApplication.ModalResponse)async throws {
            let pending=try SyncConflictRecoveryVerification.unwrap(question,"Missing real Resolve question")
            question=nil;pending.2(value)
            try await SyncConflictRecoveryVerification.wait("actual question detachment") {pending.1.window.sheetParent==nil && pending.0.attachedSheet !== pending.1.window}
        }
        func cleanup()async throws {
            released=true;question=nil
            owner?.close();children.forEach{$0.model.executeResolution=nil;$0.close()};workspace?.stopMonitoringForTermination();host?.close()
            try await SyncConflictRecoveryVerification.wait("owned recovery and workspace drains") {
                ResolveWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 &&
                    SynchronizationWindowController.activeInlineReleases==0 && StatusWindowModel.activeOperations==0 &&
                    self.owner?.model.conflictResolutionActive != true && self.owner?.model.conflictFileActions.busy != true &&
                    self.workspace?.busy != true && self.workspace?.hasPendingFinderPublication != true &&
                    self.workspace?.hasPendingRepositoryWork != true
            }
            clipboard.releaseGlobally();preferences.removePersistentDomain(forName:suite);replacement.removePersistentDomain(forName:replacementSuite)
        }
    }
    static func verify(base:URL,git:URL)async throws {
        let context=Context(base:base,git:git)
        do {
            try await context.prepare()
            let owner=try unwrap(context.owner,"Owned Sync missing"),model=owner.model,actions=model.conflictFileActions
            let window=try unwrap(owner.window,"Sync native window missing")
            // Source clipboard action remains on the original captured rows.
            actions.selection=GitPathSet(context.paths)
            let menu=model.conflictMenu(context.paths,mark:context.paths[1])
            model.copyConflictFiles(.column(.fileExtension),menu:menu)
            let extensions=actions.sortedRows.filter {context.paths.contains($0.path)}.map(\.fileExtension).joined(separator:"\n")+"\n"
            try require(context.clipboard.string(forType:.string)==extensions,"Conflict Copy Extensions lost displayed order/values")
            let first=try await context.begin(.resolveTheirs)
            let firstWindow=try unwrap(first.window,"Resolve native window missing")
            let parentRepository=model.repository
            try require(model.preferences === context.preferences && first.model.preferences === model.preferences,
                "Owned Resolve lost captured preference object: original=\(ObjectIdentifier(context.preferences)), parent=\(ObjectIdentifier(model.preferences)), child=\(ObjectIdentifier(first.model.preferences))")
            // Root discovery deliberately returns an isDirectory URL. The
            // manually constructed fixture URL has no directory hint; its URL
            // equality is not the originating Sync repository identity.
            try require(first.model.repository.root==parentRepository.root,
                "Owned Resolve lost exact parent root URL: parent=\(parentRepository.root.absoluteString), child=\(first.model.repository.root.absoluteString)")
            try require(parentRepository.root.path.utf8.elementsEqual(context.repo.root.path.utf8),
                "Production parent changed fixture filesystem identity: fixture=\(context.repo.root.path), parent=\(parentRepository.root.path)")
            try require(first.model.repository.executable==parentRepository.executable && parentRepository.executable==context.git,
                "Owned Resolve changed selected executable: requested=\(context.git.absoluteString), parent=\(parentRepository.executable.absoluteString), child=\(first.model.repository.executable.absoluteString)")
            let expectedBackend=parentRepository.capturingDiffBackend(preferences:context.preferences).libgit2Configuration
            try require(first.model.repository.libgit2Configuration?.enabled==false && NativeDiffBackendIdentity(first.model.repository.libgit2Configuration)==NativeDiffBackendIdentity(expectedBackend),
                "Owned Resolve changed captured CLI backend: expected=\(NativeDiffBackendIdentity(expectedBackend)), child=\(NativeDiffBackendIdentity(first.model.repository.libgit2Configuration))")
            try require(firstWindow.sheetParent===window && model.conflictResolutionActive && model.hasBlockingChild && model.hasPendingInlineWork && !model.canUseConflictFiles && !model.canEditForm && !owner.windowShouldClose(window),"Sync was interactive during its real Resolve question")
            let count=context.children.count
            model.performConflict(.resolveMine,menu:menu)
            try require(context.children.count==count,"Blocking Resolve admitted a second child")
            actions.selection=[context.paths[1]]
            try require(Set(first.model.paths)==Set(context.paths),"Parent selection edit replaced captured resolution paths")
            model.confirmingQuit=true
            try require(first.model.confirmingQuit && !first.externalAvailability(),"Parent Quit did not suspend owned Resolve")
            model.confirmingQuit=false
            try require(!first.model.confirmingQuit && first.externalAvailability(),"Declined Quit did not restore owned Resolve")
            let confirmationGeneration=first.model.generation
            first.model.loadInitial()
            try require(first.model.generation==confirmationGeneration && first.model.hasQuestion,"Repeated initial attachment replaced its owned confirmation")
            try await context.answer(.alertFirstButtonReturn)
            let state:()->String = {"busy=\(first.model.busy), active=\(first.model.active), question=\(first.model.hasQuestion), child=\(first.model.hasChild), progress=\(first.model.showingProgress), success=\(first.model.success), cancelled=\(first.model.cancelled), available=\(first.externalAvailability()), error=\(String(describing:first.model.error)), output=\(first.model.output), generation=\(first.model.generation), parentClosed=\(model.closed)"}
            try await wait("real Theirs mutation",diagnostics:state) {!first.model.busy && (first.model.showingProgress || first.model.error != nil)}
            try require(first.model.success,"Accepted Theirs did not mutate: "+state())
            for path in context.paths {try require(try Data(contentsOf:context.repo.root.appendingPathComponent(path))==Data("theirs\n".utf8),"Theirs did not update captured working file")}
            try require(try await context.repo.conflicts(paths:context.paths).isEmpty,"Theirs did not resolve actual Git stages")
            try require(actions.files.count==2 && context.notifications.isEmpty && model.conflictResolutionActive,"Parent refreshed/notified before Resolve completion release")
            first.model.closeProgress()
            try await wait("Resolve drain then parent refresh") {owner.conflictResolutionController==nil && !model.conflictResolutionActive && !actions.busy && actions.files.isEmpty}
            try require(context.notifications.count==1 && firstWindow.sheetParent==nil,"Resolve notification did not follow actual detachment exactly once")
            model.performConflict(.resolveCurrent,menu:menu)
            try require(owner.conflictResolutionController==nil,"Completed child revived retained old conflict menu")
            // Rejected confirmation keeps both working files and staged entries.
            try await context.restoreConflicts();try await context.refreshRows()
            let unmerged=try await context.repo.run(["ls-files","--unmerged"]).stdout
            let rejected=try await context.begin(.resolveCurrent)
            try await context.answer(.alertSecondButtonReturn)
            try await wait("rejected Resolve release",diagnostics:{"retired=\(rejected.retired), busy=\(rejected.model.busy), question=\(rejected.model.hasQuestion), attached=\(String(describing:rejected.window?.attachedSheet)), sheetParent=\(String(describing:rejected.window?.sheetParent)), parentAttached=\(String(describing:window.attachedSheet)), active=\(model.conflictResolutionActive)"}) {owner.conflictResolutionController==nil && !model.conflictResolutionActive}
            let afterNo=try await context.repo.run(["ls-files","--unmerged"]).stdout
            try require(rejected.retired && context.notifications.count==1 && afterNo==unmerged,"Rejected question changed Git state or notified")
            // A foreign lock exercises actual resolution failure, not an injected
            // callback. Disabling refresh retains the source conflict display.
            context.preferences.set(0,forKey:"RefreshFileListAfterResolvingConflict")
            let lock=context.repo.root.appendingPathComponent(".git/index.lock")
            try Data("foreign lock".utf8).write(to:lock)
            let failed=try await context.begin(.resolveCurrent)
            try await context.answer(.alertFirstButtonReturn)
            try await wait("real index-lock failure") {!failed.model.busy && failed.model.showingProgress && !failed.model.output.isEmpty}
            try require(!failed.model.success && !failed.model.cancelled && model.conflictResolutionActive,"Failed Resolve did not retain owned result")
            try require(try await context.repo.run(["ls-files","--unmerged"]).stdout==unmerged,"Failed resolution changed unmerged index")
            // Exercise the production submodule Reset presentation seam with a
            // real separate repository/controller. This is ownership coverage,
            // not a claim that the fixture created a gitlink conflict.
            failed.model.hasChild=true
            var resetsCompleted=0
            failed.model.onSubmoduleReset(context.nested,context.nestedHead){resetsCompleted+=1}
            try await wait("owned nested Reset") {owner.conflictResetController != nil}
            let reset=try unwrap(owner.conflictResetController,"Nested Reset missing")
            try require(reset.window?.sheetParent===failed.window && reset.model.presentationPreferences === context.preferences,"Nested Reset lost captured owner/preferences")
            model.confirmingQuit=true
            try require(reset.model.confirmingQuit && failed.model.confirmingQuit,"Quit did not suspend nested recovery")
            model.confirmingQuit=false
            reset.model.close()
            try await wait("nested Reset actual release") {owner.conflictResetController==nil}
            try require(resetsCompleted==0,"Cancelled nested Reset resumed successful resolution")
            failed.close();context.question=nil
            try await wait("failed Resolve release") {owner.conflictResolutionController==nil && !model.conflictResolutionActive}
            try require(context.notifications.count==2 && actions.files.count==2,"Failure notification/disabled refresh policy changed")
            try FileManager.default.removeItem(at:lock)
            // A held owned worker deliberately ignores cancellation until it
            // releases. Closing Sync must remain pending rather than fabricating
            // child completion or allowing that late result to revive its UI.
            let configure=owner.configureConflictResolution
            owner.configureConflictResolution={child in
                configure(child)
                child.model.executeResolution={_,_,token,_,_ in
                    await MainActor.run {context.held=true}
                    while await MainActor.run(body:{!context.released}) {try? await Task.sleep(nanoseconds:10_000_000)}
                    try token.check();return "Unexpected late resolution"
                }
            }
            let held=try await context.begin(.resolveCurrent)
            try await context.answer(.alertFirstButtonReturn)
            try await wait("held actual Resolve worker") {context.held && held.model.busy}
            let notices=context.notifications.count
            owner.close()
            try require(model.closed && held.retired && model.conflictResolutionActive && !context.closed,"Closed Sync released before actual owned worker")
            context.released=true
            try await wait("forced parent/worker release") {context.closed && !model.conflictResolutionActive && owner.conflictResolutionController==nil && ResolveWindowModel.activeOperations==0}
            try require(context.notifications.count==notices && context.question==nil,"Late closed-parent callback notified or reopened question")
            let finalIndex=try await context.repo.run(["ls-files","--unmerged"]).stdout,finalHead=try await context.repo.rebaseCommit("HEAD").hash
            try require(finalIndex==unmerged && finalHead==context.head,"Recovery changed unintended index/HEAD state")
            try require(try await context.nested.rebaseCommit("HEAD").hash==context.nestedHead,"Cancelled nested Reset moved its repository")
            try await context.cleanup()
            print("PASS: production Sync owned Resolve captured roots/preferences/selection, real Theirs/No/locked-index recovery, parent Quit/readiness, nested Reset cancellation, post-drain refresh/notification and forced worker release")
        } catch {
            let original=error
            do {try await context.cleanup()} catch {throw Failure(description:"\(original); cleanup: \(error)")}
            throw original
        }
    }
}
