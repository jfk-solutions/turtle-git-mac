// SPDX-License-Identifier: GPL-2.0-or-later
// Hidden native Commit timing on a caller-owned private large checkout.
// argv: private-clone git classic|staging [expected-changes=0]
// This is native-owner timing after safety preflight, not cold Finder startup.
import AppKit
import CryptoKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func scaleQuietOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0
        scaleQuietOrder(mode,relativeTo:number)
    }
    @objc func scaleQuietSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0
        scaleQuietSheet(sheet,completionHandler:completionHandler)
    }
}

@MainActor @main struct CommitStartupScaleVerification {
    struct Failure:Error {let reason:String}
    static var phase="arguments"
    static var ownerClosed=false
    static func require(_ value:Bool,_ reason:String)throws {if !value {throw Failure(reason:reason)}}
    static func now()->Double {ProcessInfo.processInfo.systemUptime}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func countersDrained()->Bool {
        CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 &&
        CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 &&
        CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 &&
        CommitWindowModel.activeIssueProviderOperations==0 && PatchWindowModel.activeOperations==0 &&
        ClientHookSession.activeOperations==0
    }
    static func idle(_ owner:CommitWindowController)->Bool {
        let m=owner.model
        return m.commitIdentityPrepared && m.changelistsLoaded && !m.guiFileListsLoading &&
        !m.busy && !m.inputsBlocked && !m.fileWorkPending && !m.loadingFileMetadata &&
        !m.loadingAuthorIdentity && !m.loadingAuthorDate && !m.loadingAmendMessage &&
        !m.loadingImportedMessage && !m.savingPreferences && !m.issueProviderBusy &&
        !m.issueProviderWorkPending && m.guiPatch?.busy != true && countersDrained()
    }
    static func nativeReady(_ owner:CommitWindowController,gui:Bool,expected:Int)->Bool {
        let keys=gui ? ["unstaged","staged"]:["checkbox"]
        let probes=views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}
        for key in keys {
            guard let table=owner.model.fileListTable(key:key),table.window === owner.window,
                  let header=table.headerView,header.window === owner.window,
                  table.enclosingScrollView?.window === owner.window,
                  probes.contains(where:{$0.nativeTable === table && $0.nativeColumnLayoutReady}) else {return false}
            let count=key=="staged" ? 0:expected
            guard table.numberOfRows==count else {return false}
        }
        return true
    }
    static func waitReady(_ owner:CommitWindowController,gui:Bool,expected:Int)async throws {
        let deadline=now()+120
        while now()<deadline {
            try Task.checkCancellation()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            try require(owner.model.error==nil && owner.model.fileListReadError==nil,"model-read-error")
            try require(owner.window?.attachedSheet==nil,"unexpected-owned-sheet")
            if idle(owner) && nativeReady(owner,gui:gui,expected:expected) {return}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw Failure(reason:"native-readiness-timeout")
    }
    static func cleanup(_ owner:CommitWindowController?)async->Bool {
        if let owner {owner.model.message="";owner.close()}
        let deadline=now()+30
        while now()<deadline {
            if (owner==nil || ownerClosed) && countersDrained() && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil}) {return true}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        return false
    }
    static func printJSON(_ object:[String:Any],failure:Bool=false) {
        guard let bytes=try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),let text=String(data:bytes,encoding:.utf8) else{return}
        if failure {fputs(text+"\n",stderr);fflush(stderr)} else {print(text);fflush(stdout)}
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite="TurtleGit.CommitStartupScale."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);board.releaseGlobally()}
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let quietOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.scaleQuietOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!
        let quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.scaleQuietSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quietOrder);method_exchangeImplementations(sheet,quietSheet)
        defer {method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quietOrder)}
        var owner:CommitWindowController?
        var result:[String:Any]=[:]
        do {
            let argv=CommandLine.arguments
            try require((4...5).contains(argv.count),"argument-count")
            let root=URL(fileURLWithPath:argv[1],isDirectory:true).standardizedFileURL
            let git=URL(fileURLWithPath:argv[2]),gui=argv[3]=="staging"
            try require(argv[3]=="classic" || gui,"mode")
            let expected=argv.count==5 ? Int(argv[4]):0
            try require(expected != nil && (0...1).contains(expected!),"expected-change-count")
            let count=expected!
            for (key,value) in GitRuntime.environment(executable:git) {setenv(key,value,1)}
            let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            phase="safety-preflight"
            let directoryResult=try await repository.run(["rev-parse","--absolute-git-dir"])
            var directoryBytes=directoryResult.stdout
            if directoryBytes.last==10 {directoryBytes.removeLast()}
            let directory=URL(fileURLWithPath:String(decoding:directoryBytes,as:UTF8.self),isDirectory:true).standardizedFileURL
            try require(directory.path.hasPrefix(root.path+"/"),"index-not-private-to-checkout")
            let index=directory.appendingPathComponent("index")
            let head=try await repository.run(["rev-parse","--verify","HEAD"]).stdout
            let indexHash=SHA256.hash(data:try Data(contentsOf:index))
            let tracked=try await repository.trackedPaths().count
            try require(tracked>=10000,"not-a-large-checkout")
            let hooks=try await repository.projectClientHooks()
            let provider=try await repository.nativeIssueAssociation(rows:[])
            let identity=try await repository.replayUserIdentity()
            try require(hooks.isEmpty && provider==nil && identity.complete,"configured-hook-provider-or-incomplete-identity")
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit"] {prefs.set(true,forKey:key)}
            for key in ["EnableGravatar","UseLibgit2","SelectFilesForCommit"] {prefs.set(false,forKey:key)}
            prefs.set("",forKey:"hooks");prefs.set(gui,forKey:"TurtleGit.Commit.GitGuiInterface")
            try NativeIssueAssociations.save([],to:prefs)
            StatusListColumnSettings().save(to:prefs)
            phase="initial-native-read"
            let begin=now()
            let controller=CommitWindowController(repository:repository,access:nil,defaults:prefs)
            owner=controller
            controller.onClosed={ownerClosed=true}
            let initialized=now()-begin
            controller.window?.alphaValue=0
            controller.window?.setFrame(NSRect(x:-22000,y:-22000,width:1100,height:900),display:false)
            controller.showWindow(nil)
            controller.model.reload(paths:["."])
            try await waitReady(controller,gui:gui,expected:count)
            let initial=now()-begin,m=controller.model
            try require(m.gitGuiInterface==gui && m.stagingEnabled==gui,"unexpected-interface-mode")
            try require(m.entries.count==count && m.visibleEntries.count==count && m.stagedEntries.isEmpty,"unexpected-change-count")
            try require(!NSApp.isActive && controller.window?.alphaValue==0,"receiver-activated-or-visible")
            phase="native-refresh-read"
            let refreshed=now()
            // Equivalent owned refresh action; no physical Finder/F5 claim.
            m.reload()
            try require(m.busy,"refresh-not-admitted")
            try await waitReady(controller,gui:gui,expected:count)
            let refresh=now()-refreshed
            try require(m.entries.count==count && m.visibleEntries.count==count && m.stagedEntries.isEmpty,"refresh-change-count")
            phase="retire-native-owner"
            try require(await cleanup(controller),"owner-drain-timeout")
            owner=nil
            phase="unchanged-checkout"
            let afterHead=try await repository.run(["rev-parse","--verify","HEAD"]).stdout
            let afterTracked=try await repository.trackedPaths().count
            try require(head==afterHead && indexHash==SHA256.hash(data:try Data(contentsOf:index)),"head-or-index-changed")
            try require(afterTracked==tracked && countersDrained() && !NSApp.isActive,"tracked-count-or-ownership-changed")
            result=["result":"passed","mode":gui ? "staging":"classic","tracked":tracked,"changes":count,
                    "init_seconds":initialized,"initial_native_ready_seconds":initial,"refresh_native_ready_seconds":refresh,
                    "head_unchanged":true,"index_unchanged":true,"owned_work_drained":true,
                    "scope":"hidden native Commit owner after safety preflight; model.reload refresh; no Finder or signed cold-launch claim"]
        } catch {
            let failedPhase=phase,reason=(error as? Failure)?.reason ?? "operation-failed"
            let drained=await cleanup(owner)
            printJSON(["result":"failed","phase":failedPhase,"reason":reason,"owned_work_drained":drained],failure:true)
            exit(1)
        }
        printJSON(result)
    }
}
