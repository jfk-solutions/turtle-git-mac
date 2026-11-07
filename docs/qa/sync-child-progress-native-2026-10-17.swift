// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncChildProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Gate {
        var entered = false
        private var reply: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { reply = $0 } }
        func open() { let callback = reply; reply = nil; callback?.resume() }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<6000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Sync child progress wait at \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_CHILD_CAPTURE"] else { return }
        if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_RECOVERY_ONLY_CAPTURE"] == "1", !name.hasPrefix("sync-recovery") { return }
        if #available(macOS 14.4, *) {
            let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Missing owned progress window") }
                let config = SCStreamConfiguration(); config.width = Int(window.frame.width*2); config.height = Int(window.frame.height*2); config.showsCursor = false; config.includeChildWindows = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name+"-"+suffix+".png"))
            }
            window.alphaValue = 0
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.SyncChildQA."+UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); NSApp.windows.forEach { $0.close() } }
        preferences.set(0, forKey: "AutoCloseGitProgress"); preferences.set(true, forKey: "ShowAppContextMenuIcons")
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "--initial-branch=main", "--template="])
        for (key,value) in [("user.name","Sync QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let remote = root.appendingPathComponent("server.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path])
        _ = try await repo.run(["remote","add","origin",remote.path])
        let server = GitRepository(root: remote, executable: executable)
        _ = try await server.run(["config","core.hooksPath",remote.appendingPathComponent("hooks").path])
        let store = ActionLogStore(storageURL: root.appendingPathComponent("private-action-log.txt"))
        ProgressActionLog.install(store: store, preferences: preferences)
        _ = try await repo.run(["tag","qa-local"])
        let initial = try await repo.synchronizationTags(remote: "origin")
        let row = initial.rows.first { $0.name.rawValue == "qa-local" }!
        let progressParent=NSWindow(contentRect:.init(x:-24000,y:-24000,width:300,height:180),styleMask:[.titled],backing:.buffered,defer:false)
        progressParent.isReleasedWhenClosed=false;progressParent.alphaValue=0;progressParent.orderFront(nil)
        defer{progressParent.close()}
        var pushed = 0,pushWindow:NSWindow?
        let push = SynchronizationProgressController(repository: repo, operation: .tag(.push,row,initial,false), cancellation: OperationCancellation(), preferences: preferences) { result in
            precondition(pushWindow != nil && pushWindow?.sheetParent==nil && progressParent.attachedSheet==nil,"Tag completion preceded actual sheet detachment")
            if case .success(.tag) = result { pushed += 1 }
        }
        pushWindow=push.window;push.window!.alphaValue=0;progressParent.beginSheet(push.window!,completionHandler:nil);push.model.start()
        try await wait { !push.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(push.model.success && push.model.percentage == 100 && push.model.currentWork == "Success" && push.model.completionRange != nil && pushed == 0, "Manual Push result did not retain completion")
        let saved = try store.read(); push.model.saveActionLog(); try require(try store.read() == saved, "Duplicate Action log entry")
        try await wait { views(push.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text = views(push.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        let clipboard = NSPasteboard.withUniqueName(); text.clipboard = clipboard
        text.setSelectedRange(NSRange(location:0,length:min(4,(text.string as NSString).length)))
        let selection = text.selectedRange(), menu = text.outputMenu()
        try require(menu.items.first?.image != nil && menu.items.last?.image != nil, "Source Copy icons missing")
        text.copyAllInformation(nil)
        try require(clipboard.string(forType:.string) == text.string && text.selectedRange() == selection, "Copy all changed selection or lost output")
        clipboard.releaseGlobally(); push.close(); try await wait { pushed == 1 }; push.close(); try require(pushed == 1, "Progress completion repeated")

        // Source tag progress captures the preference; later Settings edits cannot change this attempt.
        _ = try await server.run(["tag","qa-remote"])
        let incoming = try await repo.synchronizationTags(remote:"origin"), incomingRow = incoming.rows.first { $0.name.rawValue == "qa-remote" }!
        preferences.set(2,forKey:"AutoCloseGitProgress"); var fetched = 0,fetchWindow:NSWindow?
        let fetch = SynchronizationProgressController(repository:repo,operation:.tag(.fetch,incomingRow,incoming,false),cancellation:OperationCancellation(),preferences:preferences) { result in
            precondition(fetchWindow != nil && fetchWindow?.sheetParent==nil && progressParent.attachedSheet==nil,"Automatic tag completion preceded actual sheet detachment")
            if case .success(.tag) = result { fetched += 1 }
        }
        fetchWindow=fetch.window;fetch.window!.alphaValue=0;progressParent.beginSheet(fetch.window!,completionHandler:nil);preferences.set(0,forKey:"AutoCloseGitProgress");fetch.model.start()
        try await wait { fetched == 1 && SynchronizationProgressModel.activeOperations == 0 }
        _ = try await repo.run(["rev-parse","--verify","refs/tags/qa-remote"])

        // Real transport rejection retains its raw diagnostics, terminal code, native footer and failure window.
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try FileManager.default.createDirectory(at:hook.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\necho 'fatal: QA remote rejected the tag' >&2\nexit 1\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await repo.run(["tag","qa-rejected"])
        let rejecting = try await repo.synchronizationTags(remote:"origin"), rejectedRow = rejecting.rows.first { $0.name.rawValue == "qa-rejected" }!
        var rejected = 0
        let failure = SynchronizationProgressController(repository:repo,operation:.tag(.push,rejectedRow,rejecting,false),cancellation:OperationCancellation(),preferences:preferences) { result in if case .failure = result { rejected += 1 } }
        failure.window!.alphaValue = 0; failure.window!.orderFront(nil); failure.model.start()
        try await wait { !failure.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(!failure.model.success && !failure.model.cancelled && failure.model.percentage == 100 && failure.model.currentWork.contains("exit code") && failure.model.output.contains("QA remote rejected") && failure.model.completionRange != nil && rejected == 0,"Real rejection lost Git result/footer")
        try await capture(failure.window!,name:"sync-child-progress-failure"); failure.close(); try await wait { rejected == 1 }

        let state = try await repo.synchronizationRebaseState(target:"HEAD")
        preferences.set(true,forKey:"ConfirmKillProcess")
        let gate = Gate(), token = OperationCancellation(); var closed = 0; var answer: ((Bool)->Void)?
        let live = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:token,preferences:preferences) { _ in closed += 1 }
        live.model.executeOperation = { onOutput in
            onOutput(GitOutputChunk(stream:.stderr,data:Data("Receiving objects:  42% (42/100)\r".utf8)))
            await gate.wait(); return .merge(try await repo.run(["status","--short"]))
        }
        live.model.confirmCancel = { answer = $0 }; live.window!.alphaValue = 0; live.window!.orderFront(nil); live.model.start()
        try await wait { gate.entered && live.model.percentage == 42 }
        try require(live.model.currentWork.contains("Receiving objects"), "Live parser current work lost")
        try await capture(live.window!,name:"sync-child-progress-live")
        live.model.cancel(); try require(live.model.confirmingCancellation && answer != nil,"Abort question was not owned")
        gate.open(); try await wait { !live.model.busy }
        try require(live.model.success && closed == 0 && !token.isCancelled,"Natural success closed behind Abort question")
        answer?(true); answer?(true); try await wait { closed == 1 }
        try require(!token.isCancelled,"Late Abort cancelled natural success")

        // Forced closure retires the presentation but keeps parent continuation and Quit fenced until actual drain.
        let drain = Gate(), forcedToken = OperationCancellation(); var delivered = 0, didClose = 0
        let forced = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:forcedToken,preferences:preferences) { result in if case .failure = result { delivered += 1 } }
        forced.onClosed = { didClose += 1 }
        forced.model.executeOperation = { onOutput in await drain.wait(); onOutput(GitOutputChunk(stream:.stderr,data:Data("late output\n".utf8))); return .merge(try await repo.run(["status","--short"])) }
        forced.window!.alphaValue = 0; forced.window!.orderFront(nil); forced.model.start(); try await wait { drain.entered }
        let before = forced.model.output; forced.abortPresentation()
        try require(SynchronizationProgressModel.activeOperations == 1 && delivered == 0 && didClose == 0 && forcedToken.isCancelled,"Forced close released worker ownership early")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored closed live worker")
        drain.open(); try await wait { SynchronizationProgressModel.activeOperations == 0 && delivered == 1 && didClose == 1 }
        try require(forced.model.output == before && forced.model.completionRange == nil && forced.model.result == nil,"Retired worker republished late output/result/footer")
        forced.abortPresentation(); try require(delivered == 1 && didClose == 1,"Forced-close callback repeated")

        preferences.set(false,forKey:"ConfirmKillProcess")
        let cancelGate = Gate(), cancelToken = OperationCancellation(); var cancelled = 0
        let abort = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:cancelToken,preferences:preferences) { _ in cancelled += 1 }
        abort.model.executeOperation = { _ in await cancelGate.wait(); try cancelToken.check(); return .merge(try await repo.run(["status","--short"])) }
        abort.window!.alphaValue = 0; abort.window!.orderFront(nil); abort.model.start(); try await wait { cancelGate.entered }
        abort.model.cancel(); abort.model.cancel(); try require(cancelToken.isCancelled && abort.model.cancelling,"Direct Abort did not cancel captured worker")
        cancelGate.open(); try await wait { !abort.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(abort.model.cancelled && abort.model.currentWork == "User cancelled" && abort.model.percentage == 100 && cancelled == 0,"Cancelled failure lost retained terminal state")
        abort.close(); try await wait { cancelled == 1 }
        var compact = 0; let compactToken = OperationCancellation()
        let tags = SynchronizationProgressController(repository:repo,operation:.tags("origin"),cancellation:compactToken,preferences:preferences) { result in if case .success(.tags) = result { compact += 1 } }
        tags.window!.alphaValue = 0; tags.window!.orderFront(nil); tags.model.start(); try await wait { compact == 1 && SynchronizationProgressModel.activeOperations == 0 }
        try require(!compactToken.isCancelled, "Successful compact close cancelled parent request")
        try await verifyPinnedMerge(root:root,git:executable,preferences:preferences)
        try await verifyRecovery(repo:repo,root:root,preferences:preferences)
        progressParent.close()
        try require(NSApp.windows.filter { $0.isVisible }.isEmpty,"Owned progress window remained visible")
        print("PASS Sync child progress: real tag Push/Fetch/rejection, captured auto-close, native Copy icons/private clipboard, one Action log, live parser, completion/timing/footer, question/natural-success race, direct Abort, compact results, forced close/late output/drain/Quit and once-only parent callbacks")
    }

    @MainActor static func verifyPinnedMerge(root:URL,git:URL,preferences:UserDefaults)async throws {
        let folder=root.appendingPathComponent("pinned-ff",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let accepted=GitLibGit2Configuration(enabled:false,mask:GitLibGit2Operation.mergeBase.mask|GitLibGit2Operation.checkConflicts.mask)
        let repo=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:accepted)
        _=try await repo.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Pinned merge QA"),("user.email","merge@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["switch","-c","advance"])
        try Data("tip\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"tip")
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["switch","main"])
        let state=try await repo.synchronizationRebaseState(target:tip)
        let priorEnabled=preferences.object(forKey:"UseLibgit2"),priorMask=preferences.object(forKey:"UseLibgit2_mask")
        defer {
            if let priorEnabled {preferences.set(priorEnabled,forKey:"UseLibgit2")}else{preferences.removeObject(forKey:"UseLibgit2")}
            if let priorMask {preferences.set(priorMask,forKey:"UseLibgit2_mask")}else{preferences.removeObject(forKey:"UseLibgit2_mask")}
        }
        preferences.set(true,forKey:"UseLibgit2");preferences.set(UInt32.max,forKey:"UseLibgit2_mask")
        func backend(_ actual:GitLibGit2Configuration)->Bool {
            actual.enabled==state.acceptedBackend.enabled && actual.mask==state.acceptedBackend.mask && actual.helperURL==state.acceptedBackend.helperURL
        }
        func progress(_ actor:GitRepository,_ receipt:SynchronizationRebaseState,_ token:OperationCancellation=OperationCancellation()) -> SynchronizationProgressController {
            let owner=SynchronizationProgressController(repository:actor,operation:.merge(receipt),cancellation:token,preferences:preferences,backend:.init(enabled:true,mask:UInt32.max)) {_ in}
            owner.window!.alphaValue=0;owner.window!.orderFront(nil);return owner
        }
        let successful=progress(repo,state)
        try require(successful.model.repository === repo && backend(successful.model.backend),"Native merge did not retain producer actor and accepted backend")
        successful.model.start();try await wait{!successful.model.busy && SynchronizationProgressModel.activeOperations==0}
        try require(successful.model.success && successful.model.currentWork=="Success","Actual native ff-only merge failed")
        try require(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)==tip,"Native merge did not advance to exact pinned target")
        successful.close()
        _=try await repo.run(["reset","--hard",base])
        func unchanged(_ operation:()async throws->Void)async throws {
            let head=try await repo.run(["rev-parse","HEAD"]).stdout
            let refs=try await repo.run(["show-ref"]).stdout
            let index=try Data(contentsOf:folder.appendingPathComponent(".git/index")),file=try Data(contentsOf:folder.appendingPathComponent("file"))
            try await operation()
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalRefs=try await repo.run(["show-ref"]).stdout
            try require(finalHead==head && finalRefs==refs,"Refused native merge changed references")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==index && Data(contentsOf:folder.appendingPathComponent("file"))==file,"Refused native merge changed index/worktree")
        }
        func refused(_ actor:GitRepository,_ receipt:SynchronizationRebaseState,_ token:OperationCancellation=OperationCancellation(),cancelled:Bool=false)async throws {
            let owner=progress(actor,receipt,token)
            try require(owner.model.repository === actor && backend(owner.model.backend),"Foreign receipt silently redirected its repository/backend")
            defer{owner.close()}
            owner.model.start();try await wait{!owner.model.busy && SynchronizationProgressModel.activeOperations==0}
            try require(!owner.model.success && owner.model.captureRecovery()==nil && owner.model.completionRange != nil,"Refused receipt offered Resolve or lost terminal result")
            guard case .failure(let error)=owner.model.result else{throw Failure(description:"Refused receipt reported success")}
            if cancelled {try require(error is OperationCancellationFailure,"Precancelled receipt became an executed Git failure")}
            else {
                guard let failure=error as? SynchronizationTransportFailure else{throw Failure(description:"Foreign/stale receipt lost typed refusal: \(error)")}
                guard case .repositoryChanged=failure else{throw Failure(description:"Foreign/stale receipt lost exact repositoryChanged refusal: \(failure)")}
            }
        }
        let metadataWrapper=folder.appendingPathComponent("metadata-git"),metadataFailure=folder.appendingPathComponent("metadata-fail"),metadataCalls=folder.appendingPathComponent("metadata-argv")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let wrapper="#!/bin/sh\nprintf '%s\\0' \"$@\" >> "+quote(metadataCalls.path)+"\nif [ -f "+quote(metadataFailure.path)+" ]; then printf 'QA prelaunch metadata refused\\n' >&2; exit 128; fi\nexec "+quote(git.path)+" \"$@\"\n"
        try Data(wrapper.utf8).write(to:metadataWrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:metadataWrapper.path)
        let metadataRepo=GitRepository(root:folder,executable:metadataWrapper,askpass:nil,libgit2Configuration:accepted)
        let metadataState=try await metadataRepo.synchronizationRebaseState(target:tip)
        try Data().write(to:metadataCalls);try Data().write(to:metadataFailure)
        defer{try? FileManager.default.removeItem(at:metadataFailure)}
        var inspections=0
        let metadata=progress(metadataRepo,metadataState)
        metadata.model.inspectConflicts={_ in inspections += 1;return true}
        try await unchanged{
            metadata.model.start();try await wait{!metadata.model.busy && SynchronizationProgressModel.activeOperations==0}
            try require(metadata.model.repository === metadataRepo && metadata.model.mergeCommand==nil && inspections==0 && metadata.model.captureRecovery()==nil,"Prelaunch metadata failure invented a merge or Resolve")
            guard case .failure(let error)=metadata.model.result,let failure=error as? GitFailure else{throw Failure(description:"Prelaunch metadata lost typed Git failure")}
            try require(failure.code==128 && metadata.model.output.contains("QA prelaunch metadata refused"),"Prelaunch metadata lost original code/diagnostic")
        }
        let calls=try Data(contentsOf:metadataCalls).split(separator:0)
        try require(!calls.contains{ $0.elementsEqual("merge".utf8) },"Refused metadata launched merge")
        metadata.close();try FileManager.default.removeItem(at:metadataFailure)
        let sameRoot=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:true))
        try await unchanged{try await refused(sameRoot,state)}
        let foreignRoot=root.appendingPathComponent("foreign-ff",isDirectory:true);try FileManager.default.createDirectory(at:foreignRoot,withIntermediateDirectories:true)
        let foreign=GitRepository(root:foreignRoot,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await foreign.run(["init","--template=","-b","main"])
        let foreignConfig=try Data(contentsOf:foreignRoot.appendingPathComponent(".git/config"))
        try await unchanged{try await refused(foreign,state)}
        try require(try Data(contentsOf:foreignRoot.appendingPathComponent(".git/config"))==foreignConfig && !FileManager.default.fileExists(atPath:foreignRoot.appendingPathComponent(".git/index").path),"Foreign-root refusal created an index or changed config")
        let token=OperationCancellation();token.cancel()
        try await unchanged{try await refused(repo,state,token,cancelled:true)}
        _=try await repo.run(["switch","--detach",base])
        try await unchanged{try await refused(repo,state)}
        _=try await repo.run(["switch","main"]);_=try await repo.run(["commit","--allow-empty","-m","stale HEAD"])
        try await unchanged{try await refused(repo,state)}
        print("PASS Sync pinned merge: actual ff-only, captured producer/backend across settings changes; same-root foreign actor, foreign-root, precancelled and stale attachment/HEAD refuse without mutation or Resolve")
    }

    @MainActor static func verifyRecovery(repo:GitRepository,root:URL,preferences:UserDefaults) async throws {
        let state=try await repo.synchronizationRebaseState(target:"HEAD")
        let beforeHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let beforeFile=try Data(contentsOf:root.appendingPathComponent("file.txt"))
        func blob(_ text:String) async throws -> String {
            String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        }
        let base=try await blob("base\n"), mine=try await blob("mine\n"), theirs=try await blob("theirs\n")
        let index="0 0000000000000000000000000000000000000000\tfile.txt\n100644 "+base+" 1\tfile.txt\n100644 "+mine+" 2\tfile.txt\n100644 "+theirs+" 3\tfile.txt\n"
        _=try await repo.run(["update-index","--index-info"],input:Data(index.utf8))
        let unresolved=try await repo.run(["ls-files","--unmerged"]).stdout
        try require(!unresolved.isEmpty,"Missing actual unmerged index fixture")
        var events=[String](), commit:CommitWindowController?
        let parent=SynchronizationWindowController(repository:repo,access:nil,preferences:preferences)
        parent.window!.alphaValue=0;parent.window!.orderFront(nil)
        defer {parent.close()}
        parent.model.onCommit={ [weak parent] in
            guard let parent else {return}
            events.append("recovery")
            precondition(SynchronizationProgressModel.activeOperations == 0 && parent.commandProgress == nil && parent.window!.attachedSheet == nil)
            let child=CommitWindowController(repository:repo,access:nil,defaults:preferences)
            child.window!.alphaValue=0;child.window!.orderFront(nil);child.model.reload();commit=child
        }
        let handoff=Task { await parent.model.performFastForward!(repo,state,OperationCancellation()) }
        try await wait {parent.commandProgress != nil}
        let failure=parent.commandProgress!, clear=parent.commandProgress!.onClosed
        failure.onClosed={clear();events.append("closed")}
        failure.window!.alphaValue=0;failure.window!.orderFront(nil);failure.model.start()
        try await wait{!failure.model.busy && SynchronizationProgressModel.activeOperations == 0}
        guard let recovery=failure.model.captureRecovery() else {throw Failure(description:"Failed ff-only with real unmerged index did not offer Resolve")}
        try require(!failure.model.success && failure.model.currentWork.contains("exit code") && failure.model.completionRange != nil,"Recovery inspection replaced original Git failure")
        try require(failure.model.repository === repo,"Recovery progress replaced its producing repository actor")
        if case .failure(let error)=failure.model.result,let original=error as? GitFailure {
            try require(original.code != 0 && failure.model.currentWork.contains(String(original.code)),"Recovery footer lost actual Git exit code")
            try require(failure.model.output.contains("unmerged") || failure.model.output.contains("unresolved"),"Recovery lost original Git conflict diagnostic")
        } else {throw Failure(description:"Recovery substituted a non-command error for real ff-only failure")}

        try await capture(failure.window!,name:"sync-recovery-conflict")
        let nested=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        nested.isReleasedWhenClosed=false;nested.alphaValue=0;failure.window!.beginSheet(nested,completionHandler:nil)
        failure.model.performRecovery(recovery)
        try require(events.isEmpty && !failure.model.recoveryConsumed,"Attached sheet consumed or dispatched recovery")
        failure.window!.endSheet(nested);nested.close()
        failure.model.performRecovery(recovery);failure.model.performRecovery(recovery)
        try await wait{commit != nil && !commit!.model.busy && CommitWindowModel.activeReloads == 0}
        try require(events == ["closed","recovery"] && !failure.window!.isVisible && commit!.model.entries.contains{$0.state == .conflicted},"Resolve did not close/drain then open whole-project Commit exactly once")
        try await capture(commit!.window!,name:"sync-recovery-commit")
        commit!.close();commit=nil;failure.model.performRecovery(recovery)
        try require(events.count == 2,"Retired recovery receipt launched another Commit")
        let originalOutcome=await handoff.value
        if case .failure(let error)=originalOutcome {try require(error is GitFailure,"Recovery lost original Git error")}
        else {throw Failure(description:"Recovery rewrote failed parent result")}
        parent.close()
        let afterUnmerged=try await repo.run(["ls-files","--unmerged"]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterUnmerged == unresolved && afterHead == beforeHead,"Recovery action changed index entries or HEAD")

        // Secondary inspection errors retain the actual failed Git result and footer.
        let probeFailure=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in}
        probeFailure.model.inspectConflicts={_ in throw NSError(domain:"TurtleGit.SyncRecoveryQA",code:1,userInfo:[NSLocalizedDescriptionKey:"QA conflict inspection failed"])}
        probeFailure.window!.alphaValue=0;probeFailure.window!.orderFront(nil);probeFailure.model.start()
        try await wait{!probeFailure.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(probeFailure.model.captureRecovery() == nil && probeFailure.model.output.contains("QA conflict inspection failed") && probeFailure.model.currentWork.contains("exit code"),"Inspection failure clobbered the original failure or offered unverified recovery")
        probeFailure.close()

        // An old Git Abort question cannot cancel the later read. A new read question can.
        preferences.set(true,forKey:"ConfirmKillProcess")
        let readGate=Gate(), originalToken=OperationCancellation()
        let heldMerge=root.appendingPathComponent("recovery-held-merge"),mergeHold=root.appendingPathComponent("recovery-merge-hold"),mergeEntered=root.appendingPathComponent("recovery-merge-entered")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let holdScript="#!/bin/sh\n"+SynchronizationVerification.inspectGitArguments+"if [ \"$git_command\" = merge ] && [ -f "+quote(mergeHold.path)+" ]; then trap 'exit 130' INT; trap 'exit 143' TERM; printf '%s' \"$$\" > "+quote(mergeEntered.path)+"; while [ -f "+quote(mergeHold.path)+" ]; do sleep 0.05; done; fi\nexec "+quote(repo.executable.path)+" \"$@\"\n"
        try Data(holdScript.utf8).write(to:heldMerge);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:heldMerge.path)
        let stagedRepo=GitRepository(root:root,executable:heldMerge,askpass:nil,libgit2Configuration:.init(enabled:false))
        let stagedState=try await stagedRepo.synchronizationRebaseState(target:"HEAD")
        try Data().write(to:mergeHold);defer{try? FileManager.default.removeItem(at:mergeHold)}
        var readToken:OperationCancellation?, answers=[(Bool)->Void]()
        let staged=SynchronizationProgressController(repository:stagedRepo,operation:.merge(stagedState),cancellation:originalToken,preferences:preferences) {_ in}
        staged.model.inspectConflicts={token in readToken=token;await readGate.wait();return true}
        staged.model.confirmCancel={answers.append($0)}
        staged.window!.alphaValue=0;staged.window!.orderFront(nil);staged.model.start();try await wait{FileManager.default.fileExists(atPath:mergeEntered.path)}
        try require(staged.model.mergeCommand != nil,"Actual merge did not announce its command before held execution")
        staged.model.cancel();try require(answers.count == 1,"Git cancellation question missing")
        try FileManager.default.removeItem(at:mergeHold);try await wait{readGate.entered}
        answers[0](true);answers[0](true)
        try require(!originalToken.isCancelled && readToken?.isCancelled == false && !staged.model.confirmingCancellation,"Late Git answer cancelled a replacement inspection")
        staged.model.cancel();try require(answers.count == 2,"Inspection cancellation question missing")
        answers[1](true);answers[1](true);try require(readToken?.isCancelled == true,"New inspection answer did not cancel its own read")
        readGate.open();try await wait{!staged.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(staged.model.captureRecovery() == nil && !staged.model.cancelled && staged.model.currentWork.contains("exit code"),"Cancelled secondary read invented recovery or rewrote Git outcome")
        staged.close()

        // Cancelling a real announced merge differs from a precancelled/read
        // refusal: retain its exact typed command result and inspect conflicts
        // with a fresh token before offering Resolve.
        preferences.set(false,forKey:"ConfirmKillProcess")
        try FileManager.default.removeItem(at:mergeEntered)
        try Data().write(to:mergeHold)
        let cancelledToken=OperationCancellation()
        let cancelledMerge=SynchronizationProgressController(repository:stagedRepo,operation:.merge(stagedState),cancellation:cancelledToken,preferences:preferences) {_ in}
        cancelledMerge.window!.alphaValue=0;cancelledMerge.window!.orderFront(nil);cancelledMerge.model.start()
        try await wait{FileManager.default.fileExists(atPath:mergeEntered.path) && cancelledMerge.model.mergeCommand != nil}
        cancelledMerge.model.cancel()
        try await wait{!cancelledMerge.model.busy && SynchronizationProgressModel.activeOperations==0}
        guard case .failure(let error)=cancelledMerge.model.result,let cancelledCommand=error as? GitCommandCancellationFailure else{throw Failure(description:"Actual merge cancellation lost typed command result")}
        try require(cancelledCommand.result.exitCode != 0 && cancelledMerge.model.cancelled && cancelledMerge.model.captureRecovery() != nil,"Cancelled announced merge lost original exit or independent conflict recovery")
        try FileManager.default.removeItem(at:mergeHold);cancelledMerge.close()

        let forcedGate=Gate();var forcedRead:OperationCancellation?, completed=0
        let forced=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in completed += 1}
        forced.model.inspectConflicts={token in forcedRead=token;await forcedGate.wait();return true}
        forced.window!.alphaValue=0;forced.window!.orderFront(nil);forced.model.start();try await wait{forcedGate.entered}
        forced.abortPresentation()
        try require(forcedRead?.isCancelled == true && completed == 0 && SynchronizationProgressModel.activeOperations == 1,"Forced close released recovery inspection before real drain")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed recovery inspection did not fence Quit")
        forcedGate.open();try await wait{completed == 1 && SynchronizationProgressModel.activeOperations == 0}
        try require(forced.model.captureRecovery() == nil && forced.model.completionRange == nil,"Retired probe published recovery/footer")
        _=try await repo.run(["reset","--hard","HEAD"])
        let noConflicts=SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:OperationCancellation(),preferences:preferences) {_ in}
        noConflicts.model.executeOperation={output in .merge(try await repo.run(["merge","--ff-only","--","refs/heads/qa-missing"],onOutput:output))}
        noConflicts.window!.alphaValue=0;noConflicts.window!.orderFront(nil);noConflicts.model.start()
        try await wait{!noConflicts.model.busy && SynchronizationProgressModel.activeOperations == 0}
        try require(!noConflicts.model.success && noConflicts.model.captureRecovery() == nil,"Non-conflict failure offered Resolve")
        noConflicts.close()
        try require(try Data(contentsOf:root.appendingPathComponent("file.txt")) == beforeFile,"Recovery inspection changed worktree bytes")
        print("PASS Sync recovery: real ff-only failure/unmerged index, source Resolve-to-Commit handoff after drain, unchanged index/HEAD/working bytes, nested sheet/duplicate/retired receipts, secondary read error, old/new cancellation stage ownership, forced read drain/Quit/late footer and non-conflict refusal")
    }
}
