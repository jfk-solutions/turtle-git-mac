import AppKit
import TurtleGitCore

struct HookRuntimeFamilyVerification {
    struct ScopeProvider:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{true}
        func stopAccessing(_ url:URL){}
    }
    @MainActor static func verify()async throws {
        func require(_ value:Bool,_ text:String)throws{if !value{throw NSError(domain:text,code:1)}}
        func wait(_ text:String,_ value:()->Bool)async throws{for _ in 0..<2000{if value(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:text,code:2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),folder=root.appendingPathComponent("runtime-family")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
        let suite="TurtleGit.HookRuntime.Family."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite);ClientHookProcessPool.shared.cancelAll()}
        let owner=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.appearance=NSAppearance(named:.darkAqua)
        defer{owner.orderOut(nil);owner.close()}
        let script=folder.appendingPathComponent("approved.sh"),marker=folder.appendingPathComponent("launched")
        try Data("printf launched >> '\(marker.path)'\n".utf8).write(to:script)
        let hook=ClientHook(type:.preCommit,path:folder.path,command:"/bin/sh '\(script.path)'",show:false,local:true)
        try await repo.saveProjectClientHooks([hook])
        let session=ClientHookSession(preferences:prefs);session.windowProvider={owner};defer{session.retire()}
        var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?
        session.presentQuestion={parent,alert,answer in question=alert;reply=answer;alert.beginSheetModal(for:parent,completionHandler:answer);return true}
        var defaultFinished=false
        let defaultResponse=Task{defer{defaultFinished=true};return try await session.run(.preCommit,repository:repo,access:nil,message:"original")}
        try await wait("Approval did not attach"){question?.window.sheetParent===owner}
        try require(question?.buttons.count==3 && question?.showsSuppressionButton==true,"Approval lost Yes/No/Cancel or remember option")
        try require(question?.window.alphaValue==0 && question?.window.appearance?.name==owner.appearance?.name,"Approval lost captured invisibility/appearance")
        let defaultDetails=question.map{alert in
            "buttons="+alert.buttons.enumerated().map{index,button in "\(index):title=\(button.title.debugDescription),key=\(button.keyEquivalent.unicodeScalars.map{$0.value}),state=\(button.state.rawValue),enabled=\(button.isEnabled)"}.joined(separator:"; ")+",defaultCellIndex="+String(describing:alert.buttons.firstIndex{($0.cell as? NSButtonCell) === alert.window.defaultButtonCell})+",defaultCell="+String(describing:alert.window.defaultButtonCell)
        } ?? "question=nil"
        let defaultAlert=question!
        try require(defaultAlert.window.defaultButtonCell === (defaultAlert.buttons[1].cell as? NSButtonCell) && defaultAlert.buttons[0].keyEquivalent != "\r","Repository approval lost safe default No: \(defaultDetails)")
        // Hidden receiver windows do not accept physical Return dispatch.
        // Exercise the actual control identified by AppKit's default cell.
        let defaultButton=defaultAlert.buttons.first{($0.cell as? NSButtonCell) === defaultAlert.window.defaultButtonCell}!
        defaultButton.performClick(nil)
        try await wait("Default approval No control did not dispatch: \(defaultDetails)"){defaultFinished}
        try require(try await defaultResponse.value==nil,"Default approval No control executed its hook")
        try require(owner.attachedSheet==nil && !FileManager.default.fileExists(atPath:marker.path) && ClientHookPreferences.decision(hook,preferences:prefs)==nil,"Default No retained sheet, launched script or stored an unrequested decision")
        question=nil;var finished=false
        let accepted=Task{defer{finished=true};return try await session.run(.preCommit,repository:repo,access:nil,message:"original")}
        try await wait("Approval after default No did not attach"){question?.window.sheetParent===owner}
        question?.suppressionButton?.state = .on;reply?(.alertFirstButtonReturn);reply?(.alertThirdButtonReturn)
        let result=try await accepted.value
        try require(finished && result?.exitCode==0 && owner.attachedSheet==nil && question?.window.sheetParent==nil,"Approval continued before actual question detach")
        try require(FileManager.default.fileExists(atPath:marker.path) && ClientHookPreferences.decision(hook,preferences:prefs)==true,"Approved remembered hook did not launch exactly scoped script")
        question=nil;_ = try await session.run(.preCommit,repository:repo,access:nil)
        try require(question==nil && (try String(contentsOf:marker,encoding:.utf8))=="launchedlaunched","Remembered exact approval prompted or duplicate answer launched twice")
        try ClientHookPreferences.remember(hook,approved:nil,preferences:prefs)
        question=nil;let denied=Task{try await session.run(.preCommit,repository:repo,access:nil)}
        try await wait("No choice did not attach"){question?.window.sheetParent===owner};question?.suppressionButton?.state = .on;reply?(.alertSecondButtonReturn)
        try require(try await denied.value==nil,"Declined hook executed")
        try require(owner.attachedSheet==nil && ClientHookPreferences.decision(hook,preferences:prefs)==false,"Decline did not detach/store rejection")
        try ClientHookPreferences.remember(hook,approved:nil,preferences:prefs)
        question=nil;let cancelled=Task{try await session.run(.preCommit,repository:repo,access:nil)}
        try await wait("Cancel choice did not attach"){question?.window.sheetParent===owner};reply?(.alertThirdButtonReturn)
        do{_ = try await cancelled.value;throw NSError(domain:"Approval Cancel accepted",code:1)}catch OperationCancellationFailure.cancelled{}
        try require(owner.attachedSheet==nil && ClientHookPreferences.decision(hook,preferences:prefs)==nil,"Cancel stored approval or retained sheet")
        // A failure decision uses the same actual sheet release boundary, and
        // preserves the user's draft after explicit Continue.
        var failureHook=hook;failureHook.local=false;failureHook.command="/bin/sh -c 'exit 7' hook"
        prefs.set(try ClientHookConfiguration.serialize([failureHook]),forKey:"hooks")
        question=nil;let continued=Task{try await session.run(.preCommit,repository:repo,access:nil,message:"kept",allowContinue:true)}
        try await wait("Failure choice did not attach"){question?.window.sheetParent===owner}
        try require(question?.buttons.count==2,"Failure lost Abort/Continue choices");reply?(.alertSecondButtonReturn)
        let failed=try await continued.value
        try require(failed?.exitCode==7 && failed?.message=="kept" && owner.attachedSheet==nil,"Continue lost exit/draft or preceded actual detach")
        question=nil;let aborted=Task{try await session.run(.preCommit,repository:repo,access:nil,allowContinue:true)}
        try await wait("Abort choice missing"){question?.window.sheetParent===owner};reply?(.alertFirstButtonReturn)
        do{_ = try await aborted.value;throw NSError(domain:"Abort accepted",code:1)}catch let error as ClientHookOperationFailure{try require(error.code==7,"Abort lost command exit")}
        prefs.removeObject(forKey:"hooks");question=nil
        let retired=Task{try await session.run(.preCommit,repository:repo,access:nil)}
        try await wait("Retired approval missing"){question?.window.sheetParent===owner};session.retire();reply?(.alertFirstButtonReturn)
        do{_ = try await retired.value;throw NSError(domain:"Retired question launched",code:1)}catch OperationCancellationFailure.cancelled{}
        try await wait("Question/operation ownership not drained"){ClientHookSession.activeOperations==0 && ClientHookSession.activeQuestionReleases==0 && owner.attachedSheet==nil}
        try require(ClientHookPreferences.decision(hook,preferences:prefs)==nil,"Retired late answer stored approval")
        let tokenSession=ClientHookSession(preferences:prefs);tokenSession.windowProvider={owner};defer{tokenSession.retire()}
        tokenSession.presentQuestion={parent,alert,answer in question=alert;reply=answer;alert.beginSheetModal(for:parent,completionHandler:answer);return true}
        question=nil;let approvalToken=OperationCancellation()
        let tokenApproval=Task{try await tokenSession.run(.preCommit,repository:repo,access:nil,cancellation:approvalToken)}
        try await wait("Token-cancelled approval did not attach"){question?.window.sheetParent===owner}
        let lateApprovalReply=reply;approvalToken.cancel()
        do{_ = try await tokenApproval.value;throw NSError(domain:"Cancelled approval returned",code:1)}catch OperationCancellationFailure.cancelled{}
        try await wait("Token cancellation retained approval sheet"){owner.attachedSheet==nil && question?.window.sheetParent==nil && ClientHookSession.activeQuestionReleases==0}
        lateApprovalReply?(.alertFirstButtonReturn)
        try require(ClientHookPreferences.decision(hook,preferences:prefs)==nil && (try String(contentsOf:marker,encoding:.utf8))=="launchedlaunched","Late token-cancelled approval stored or launched")
        prefs.set(try ClientHookConfiguration.serialize([failureHook]),forKey:"hooks")
        question=nil;let failureToken=OperationCancellation()
        let tokenFailure=Task{try await tokenSession.run(.preCommit,repository:repo,access:nil,cancellation:failureToken,allowContinue:true)}
        try await wait("Token-cancelled failure choice did not attach"){question?.window.sheetParent===owner}
        let lateFailureReply=reply;failureToken.cancel()
        do{_ = try await tokenFailure.value;throw NSError(domain:"Cancelled failure choice continued",code:1)}catch OperationCancellationFailure.cancelled{}
        try await wait("Token cancellation retained failure choice"){owner.attachedSheet==nil && ClientHookSession.activeQuestionReleases==0 && ClientHookSession.activeOperations==0}
        lateFailureReply?(.alertSecondButtonReturn);prefs.removeObject(forKey:"hooks")
        let held=ClientHookSession(preferences:prefs)
        var readReply:CheckedContinuation<[ClientHook],Error>?
        held.readProjectHooks={_,_ in try await withCheckedThrowingContinuation{readReply=$0}}
        let reading=Task{try await held.run(.preCommit,repository:repo,access:nil)}
        try await wait("Held project read missing"){readReply != nil};held.retire()
        try require(ClientHookSession.activeOperations==1,"Retirement dropped an undrained project read")
        readReply?.resume(returning:[hook]);readReply=nil
        do{_ = try await reading.value;throw NSError(domain:"Retired read published",code:1)}catch OperationCancellationFailure.cancelled{}
        try require(ClientHookSession.activeOperations==0,"Completed retired read leaked operation ownership")
        let heldApproval=ClientHookSession(preferences:prefs)
        var approvalReply:CheckedContinuation<ClientHookSession.Approval,Never>?
        heldApproval.approval={_ in await withCheckedContinuation{approvalReply=$0}}
        let approving=Task{try await heldApproval.run(.preCommit,repository:repo,access:nil)}
        try await wait("Held approval missing"){approvalReply != nil};heldApproval.retire()
        try require(ClientHookSession.activeOperations==1,"Retirement dropped undrained approval callback")
        approvalReply?.resume(returning:.init(approved:true,remember:true,cancelled:false));approvalReply=nil
        do{_ = try await approving.value;throw NSError(domain:"Retired held approval published",code:1)}catch OperationCancellationFailure.cancelled{}
        try require(ClientHookPreferences.decision(hook,preferences:prefs)==nil,"Retired held approval persisted")
        let running=ClientHookSession(preferences:prefs);defer{running.retire()}
        var worker=hook;worker.local=false;worker.command="/bin/sh -c 'printf ready > "+folder.appendingPathComponent("worker-ready").path+"; sleep 30 & wait' hook"
        prefs.set(try ClientHookConfiguration.serialize([worker]),forKey:"hooks")
        let working=Task{try await running.run(.preCommit,repository:repo,access:nil)}
        try await wait("Wait hook did not start"){ClientHookProcessPool.shared.activeScripts==1 && FileManager.default.fileExists(atPath:folder.appendingPathComponent("worker-ready").path)}
        running.retire();try require(ClientHookSession.activeOperations==1,"Retirement dropped actual wait worker ownership")
        do{_ = try await working.value;throw NSError(domain:"Retired worker published",code:1)}catch OperationCancellationFailure.cancelled{}
        try await wait("Retired hook worker did not drain"){ClientHookProcessPool.shared.activeScripts==0 && ClientHookSession.activeOperations==0}
        let taskCancelledSession=ClientHookSession(preferences:prefs);defer{taskCancelledSession.retire()}
        let taskMarker=folder.appendingPathComponent("task-worker-ready")
        worker.command="/bin/sh -c 'printf ready > "+taskMarker.path+"; sleep 30 & wait' hook"
        prefs.set(try ClientHookConfiguration.serialize([worker]),forKey:"hooks")
        let taskWorker=Task{try await taskCancelledSession.run(.preCommit,repository:repo,access:nil)}
        try await wait("Task cancellation worker did not start"){ClientHookProcessPool.shared.activeScripts==1 && FileManager.default.fileExists(atPath:taskMarker.path)}
        taskWorker.cancel()
        do{_ = try await taskWorker.value;throw NSError(domain:"Cancelled task published worker result",code:1)}catch is CancellationError{}catch OperationCancellationFailure.cancelled{}
        try await wait("Task cancellation did not cancel/drain actual hook worker"){ClientHookProcessPool.shared.activeScripts==0 && ClientHookSession.activeOperations==0}
        // Persist exact spellings independently of filesystem normalization.
        func literalURL(_ path:String)throws->URL{
            let encoded=path.utf8.map{$0==47 ? "/":String(format:"%%%02X",$0)}.joined()
            guard let url=URL(string:"file://"+encoded) else{throw NSError(domain:"Invalid literal fixture URL",code:1)}
            try require(Array(url.path.utf8)==Array(path.utf8),"Literal fixture URL changed input path bytes")
            return url
        }
        let composed=try literalURL(root.path+"/caf\u{00e9}.sh"),decomposed=try literalURL(root.path+"/cafe\u{0301}.sh")
        try require(Array(composed.path.utf8) != Array(decomposed.path.utf8),"Bookmark fixture did not supply distinct Unicode path bytes")
        try ClientHookScriptAccess.storeBookmark(Data([1]),for:composed,preferences:prefs)
        try ClientHookScriptAccess.storeBookmark(Data([2]),for:decomposed,preferences:prefs)
        try require(ClientHookScriptAccess.bookmark(for:composed,preferences:prefs)==Data([1]) && ClientHookScriptAccess.bookmark(for:decomposed,preferences:prefs)==Data([2]),"Bookmark store collapsed exact Unicode paths")
        var exactA=hook,exactB=hook;exactA.command="/bin/echo caf\u{00e9}";exactB.command="/bin/echo cafe\u{0301}"
        try ClientHookPreferences.remember(exactA,approved:true,preferences:prefs)
        try ClientHookPreferences.remember(exactB,approved:false,preferences:prefs)
        try require(ClientHookPreferences.decision(exactA,preferences:prefs)==true && ClientHookPreferences.decision(exactB,preferences:prefs)==false,"Native approval store collapsed exact command identities")
        try ClientHookPreferences.remember(exactA,approved:nil,preferences:prefs)
        try require(ClientHookPreferences.decision(exactB,preferences:prefs)==false,"Clearing one exact approval erased its Unicode alias")
        let external=root.appendingPathComponent("external.sh");try Data().write(to:external)
        prefs.set([external.path:Data([3])],forKey:"ClientHooks.ScriptBookmarks")
        // An already-created v2 store must remain authoritative; legacy data is
        // migrated only before v2 exists, in a separate private preference suite.
        let legacySuite=suite+".legacy",legacy=UserDefaults(suiteName:legacySuite)!
        defer{legacy.removePersistentDomain(forName:legacySuite)}
        legacy.set([external.path:Data([3])],forKey:"ClientHooks.ScriptBookmarks")
        let access=RepositoryAccessLease(url:folder,provider:ScopeProvider());var starts=0,stops=0
        let io=ClientHookScriptAccess.ScopeIO(resolve:{_ in (external,true)},bookmark:{_ in Data([4])},start:{_ in starts+=1;return true},stop:{_ in stops+=1})
        let scopes=try ClientHookScriptAccess.acquire("/bin/sh '\(external.path)' '\(external.path)'",root:folder,access:access,preferences:legacy,appStore:true,io:io)
        try require(scopes.count==1 && starts==1 && stops==0 && ClientHookScriptAccess.bookmark(for:external,preferences:legacy)==Data([4]),"Stale legacy grant was not renewed/deduplicated and retained")
        scopes.forEach{$0.release();$0.release()};try require(stops==1,"Scope release was unbalanced")
        let aliasIO=ClientHookScriptAccess.ScopeIO(resolve:{_ in (composed,false)},bookmark:{_ in Data()},start:{_ in starts+=1;return true},stop:{_ in stops+=1})
        do{_ = try ClientHookScriptAccess.acquire("/bin/sh '\(external.path)'",root:folder,access:access,preferences:legacy,appStore:true,io:aliasIO);throw NSError(domain:"Wrong bookmark alias accepted",code:1)}catch RepositoryAccessFailure.securityScopeUnavailable{}
        try require(starts==1 && stops==1,"Wrong alias started a security scope")
        let missing=root.appendingPathComponent("second-external.sh");try Data().write(to:missing)
        do{_ = try ClientHookScriptAccess.acquire("/bin/sh '\(external.path)' '\(missing.path)'",root:folder,access:access,preferences:legacy,appStore:true,io:io);throw NSError(domain:"Partial acquisition accepted missing grant",code:1)}catch RepositoryAccessFailure.securityScopeUnavailable{}
        try require(starts==2 && stops==2,"Partial acquisition failure did not balance earlier scope")
        print("Hook actual Yes/No/Cancel, Abort/Continue, detach/retire, exact bookmark migration and scoped release passed.")
    }
}
