// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func inaccessibleFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect {rect}
    @objc func inaccessibleOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));inaccessibleOrder(mode,relativeTo:number)}
}
@MainActor @main enum InaccessibleRepositoryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    struct Scope:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:FileTransferPaths.fileURL(String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {true}
        func stopAccessing(_ url:URL) {}
    }
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"Inaccessible \(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Inaccessible timeout at \(line)")
    }
    static var drained:Bool {InaccessibleRepositoryWindowModel.activeOperations==0 && RepositoryModel.activeInaccessiblePreparations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.Inaccessible."+UUID().uuidString,prefs:UserDefaults
        var bad:URL {base.appendingPathComponent("bad-e\u{301}",isDirectory:true)}
        var good:URL {base.appendingPathComponent("good",isDirectory:true)}
        let config=URL(fileURLWithPath:ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]!)
        var owners:[InaccessibleRepositoryWindowController]=[],workspaces:[RepositoryModel]=[]
        var release:[()->Void]=[]
        var baselineConfig=Data(),head=Data(),index=Data(),localConfig=Data()
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func repository(_ root:URL)->GitRepository {GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:good,withIntermediateDirectories:true)
            try Data("not a gitdir\n".utf8).write(to:bad.appendingPathComponent(".git"))
            let repo=repository(good);_=try await repo.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Inaccessible QA"),("user.email","inaccessible@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repo.run(["config",k,v])}
            try Data("base\n".utf8).write(to:good.appendingPathComponent("file"));try await repo.stage(["."]);_=try await repo.commit(message:"base")
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:good.appendingPathComponent(".git/index"));localConfig=try Data(contentsOf:good.appendingPathComponent(".git/config"));baselineConfig=try Data(contentsOf:config)
        }
        func own(_ owner:InaccessibleRepositoryWindowController)->InaccessibleRepositoryWindowController {
            owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);return owner
        }
        func window(_ root:URL?=nil)->InaccessibleRepositoryWindowController {let path=root ?? bad;return own(InaccessibleRepositoryWindowController(repository:repository(path),access:RepositoryAccessLease(url:path,provider:Scope())))}
        func workspace()->RepositoryModel {
            let ws=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[self] in repository($0)})
            ws.repositoryBookmarkProvider=Scope();ws.requiresRepositoryScope=false
            ws.inaccessibleFolderPermission={url,token in try token.check();return RepositoryAccessLease(url:url,provider:Scope())}
            ws.inaccessiblePresentation={[weak self] in _=self?.own($0)};workspaces.append(ws);return ws
        }
        func unchanged(global:Bool=true)async throws {
            let actual=try await repository(good).run(["rev-parse","HEAD"]).stdout
            try require(actual==head && (try Data(contentsOf:good.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:good.appendingPathComponent(".git/config")))==localConfig,"Diagnosis changed adopted HEAD/index/local config")
            if global {try require(try Data(contentsOf:config)==baselineConfig,"Read/cancel changed global config")}
        }
        func clean()async {
            for f in release{f()};release=[]
            for owner in owners{owner.model.cancel();owner.close()}
            for ws in workspaces{ws.stopMonitoringForTermination()}
            for _ in 0..<3000 {if InaccessibleRepositoryVerification.drained{break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func diagnosis(_ c:Context)async throws {
        let owner=c.window();owner.model.refresh();try await wait{!owner.model.busy && owner.model.diagnosis != nil}
        try require(owner.model.diagnosis?.reason == .inaccessible && owner.model.diagnosis?.gitFile==true && owner.model.canTrust,"Real malformed .git did not expose source gitfile diagnosis")
        let board=NSPasteboard(name:.init("TurtleGit.Inaccessible."+UUID().uuidString));defer{board.clearContents()}
        owner.model.copy(to:board)
        try require(board.string(forType:.string).map{Data($0.utf8)==Data(owner.model.copyText.utf8)}==true && Data(owner.model.copyText.utf8).starts(with:Data((owner.model.root.path+"\n").utf8)) && owner.model.root.lastPathComponent.utf8.elementsEqual(c.bad.lastPathComponent.utf8) && !owner.model.details.isEmpty,"Detailed diagnostic Copy omitted exact header/Unicode leaf/text")
        let healthy=c.window(c.good);healthy.model.refresh();try await wait{!healthy.model.busy && healthy.model.diagnosis != nil}
        try require(healthy.model.diagnosis?.reason == .accessible && !healthy.model.canTrust,"Healthy uncached Finder candidate offered trust")
        let empty=c.base.appendingPathComponent("not-repository",isDirectory:true);try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
        let missing=c.window(empty);missing.model.refresh();try await wait{!missing.model.busy && missing.model.diagnosis != nil}
        try require(missing.model.diagnosis?.reason == .notRepository && !missing.model.canTrust,"Not-repository error offered trust")
        for name in [NSAppearance.Name.aqua,.darkAqua] {owner.window?.appearance=NSAppearance(named:name);owner.window?.contentView?.layoutSubtreeIfNeeded();try require((owner.window?.contentView?.bounds.width ?? 0)>=580,"Detailed native surface lost minimum width")}
        try await c.unchanged()
    }
    static func routes(_ c:Context)async throws {
        let ws=c.workspace();ws.open(c.good);try await wait{!ws.busy && ws.root != nil}
        ws.inaccessibleFolderPermission={_,token in try token.check();return RepositoryAccessLease(url:c.base,provider:Scope())}
        let original=ws.root;ws.message="keep accepted commit draft"
        guard let url=FinderRequest(action:.inaccessible,paths:[c.bad]).url else{throw Failure(description:"Inaccessible Finder route missing")}
        ws.handle(url);try await wait{!ws.inaccessibleWindows.isEmpty && drained}
        try require(ws.root==original && ws.message=="keep accepted commit draft" && ws.error==nil,"Manual diagnostic adopted failed root or replaced workspace draft")
        let first=ws.inaccessibleWindows.values.first!
        ws.handleCommandLine(arguments:["/command:inaccessible","/path:"+c.bad.path],currentDirectory:c.base.path)
        try await wait{drained}
        try require(ws.inaccessibleWindows.count==1 && ws.inaccessibleWindows.values.first === first,"CLI/Finder duplicate lost exact owner identity")
        ws.open(c.bad);try await wait{!ws.busy && !ws.inaccessibleWindows.isEmpty && drained}
        try require(ws.root==original && ws.message=="keep accepted commit draft" && ws.error==nil,"Automatic failed adoption did not preserve accepted workspace/show typed diagnosis")
        let retry=ws.inaccessibleWindows.values.first!
        try FileManager.default.removeItem(at:c.bad.appendingPathComponent(".git"))
        _=try await c.repository(c.bad).run(["init","--template=","-b","main"])
        retry.model.retry()
        do {
            try await wait{!ws.busy}
            try require(ws.root?.path.utf8.elementsEqual(c.bad.standardizedFileURL.path.utf8)==true && ws.root?.lastPathComponent.utf8.elementsEqual(c.bad.lastPathComponent.utf8)==true && ws.root?.path.utf8.elementsEqual(c.base.standardizedFileURL.path.utf8)==false,"Retry did not adopt exact selected root/Unicode leaf instead of ancestor grant")
        }
        catch {
            print("Retry diagnostic: busy=\(ws.busy), root=\(String(describing:ws.root)), requested=\(c.bad), error=\(ws.error ?? "nil"), output=\(ws.output), retired=\(retry.model.retired), canRetry=\(retry.model.canRetry), modelBusy=\(retry.model.busy), modelError=\(retry.model.error ?? "nil"), reason=\(String(describing:retry.model.diagnosis?.reason)), registry=\(ws.inaccessibleWindows.keys.map{String(decoding:$0,as:UTF8.self)}), active=\(InaccessibleRepositoryWindowModel.activeOperations)/\(RepositoryModel.activeInaccessiblePreparations)")
            fflush(stdout);throw error
        }
        try require(retry.model.retired && ws.inaccessibleWindows.isEmpty,"Explicit Retry used ancestor grant instead of selected root or failed registry retirement")
        ws.open(c.good);try await wait{!ws.busy}
        try require(ws.root?.path.utf8.elementsEqual(c.good.standardizedFileURL.path.utf8)==true,"Good workspace was not restored after explicit Retry")
        let broken=c.base.appendingPathComponent("unsupported",isDirectory:true),admin=broken.appendingPathComponent(".git",isDirectory:true)
        try FileManager.default.createDirectory(at:admin.appendingPathComponent("objects"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:admin.appendingPathComponent("refs"),withIntermediateDirectories:true)
        try Data("ref: refs/heads/main\n".utf8).write(to:admin.appendingPathComponent("HEAD"))
        try Data("[core]\nrepositoryformatversion = 1\n[extensions]\nobjectformat = unsupported\n".utf8).write(to:admin.appendingPathComponent("config"))
        ws.open(broken);try await wait{!ws.busy && !ws.inaccessibleWindows.isEmpty && drained}
        let unsupported=ws.inaccessibleWindows.values.first!
        try require(unsupported.model.diagnosis?.reason == .inaccessible && unsupported.model.diagnosis?.gitFile==false && !unsupported.model.canTrust && ws.root?.path.utf8.elementsEqual(c.good.standardizedFileURL.path.utf8)==true,"Failed .git directory was hidden or incorrectly offered trust")
        let before=ws.inaccessibleWindows.count
        ws.handleCommandLine(arguments:["/command:inaccessible","/path:"+c.good.appendingPathComponent("file").path],currentDirectory:c.base.path)
        try await wait{drained};try require(ws.inaccessibleWindows.count==before && ws.error != nil,"Single nonfolder inaccessible selection was admitted")
        try await c.unchanged()
    }
    static func trust(_ c:Context)async throws {
        let owner=c.window();owner.model.refresh();try await wait{owner.model.canTrust}
        var confirms=0,permissions=0,remembered=0,authorized=false
        var sequence:[String]=[]
        var expectedConfirmation=""
        owner.configurationAuthorized={_ in authorized}
        let prepare=owner.model.prepareTrust
        owner.model.prepareTrust={diagnosis,token in
            sequence.append("prepare");let plan=try await prepare(diagnosis,token)
            expectedConfirmation=plan.root.path+"\n\n"+plan.configurationFile.path;return plan
        }
        owner.presentQuestion={alert,window,reply in
            sequence.append("confirm")
            confirms += 1
            if expectedConfirmation.isEmpty || Data(alert.informativeText.utf8).range(of:Data(expectedConfirmation.utf8))==nil {reply(.alertFirstButtonReturn);return}
            window.beginSheet(alert.window)
            reply(.alertSecondButtonReturn)
        }
        owner.presentFolder={panel,window,reply in permissions += 1;sequence.append("authorize");window.beginSheet(panel);reply(.OK)}
        owner.selectedFolder={_ in c.config.deletingLastPathComponent()}
        owner.rememberConfiguration={folder,file in
            try require(Data(file.path.utf8)==Data(c.config.path.utf8) && RepositoryAccessLease.pathIsContained(file,by:folder),"Wrong config directory authorization target")
            remembered += 1
            authorized=true
        }
        owner.model.trust();try await wait{!owner.model.busy && owner.model.trustReceipt != nil}
        let receipt=owner.model.trustReceipt!
        let values=try await c.repository(c.good).run(["config","--file",c.config.path,"--null","--get-all","safe.directory"]).stdout
        try require(confirms==1 && permissions==1 && remembered==1 && values==Data(receipt.value.utf8)+Data([0]),"Trust did not append exact approved private config value once")
        try require(sequence==["authorize","prepare","confirm"],"Config inspection occurred before directory authorization or trust confirmation preceded concrete plan")
        try require(receipt.value.utf8.elementsEqual(owner.model.diagnosis!.root.path.utf8) && receipt.root.path.utf8.elementsEqual(receipt.value.utf8) && receipt.configurationFile.path==c.config.path,"Trust widened/canonicalized wrong root or file")
        try require(owner.model.diagnosis?.reason == .inaccessible && owner.model.status.contains("recorded"),"Trust pretended malformed Git metadata was repaired")
        try await c.unchanged(global:false)
        // A second, explicitly cancelled confirmation must not append again.
        owner.presentQuestion={_,_,reply in reply(.alertFirstButtonReturn)}
        owner.model.trust();try await wait{!owner.model.busy}
        let after=try await c.repository(c.good).run(["config","--file",c.config.path,"--null","--get-all","safe.directory"]).stdout
        try require(after==values,"Cancelled trust changed config")
    }
    static func ownership(_ c:Context)async throws {
        let real=try await c.repository(c.bad).diagnoseRepositoryAccess()
        let owner=c.window();var held:CheckedContinuation<GitRepositoryDiagnosis,Error>?
        owner.model.readDiagnosis={_ in try await withCheckedThrowingContinuation{held=$0}}
        c.release.append{held?.resume(returning:real);held=nil}
        owner.model.refresh();try await wait{held != nil}
        owner.window?.performClose(nil)
        try require(owner.model.cancelling && !owner.model.retired && !drained && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Busy close/Quit released a live diagnostic")
        held?.resume(returning:real);held=nil;try await wait{drained && owner.model.retired}
        try require(owner.model.diagnosis==nil,"Cancelled late read published")
        let retired=c.window();var late:CheckedContinuation<GitRepositoryDiagnosis,Error>?
        retired.model.readDiagnosis={_ in try await withCheckedThrowingContinuation{late=$0}}
        c.release.append{late?.resume(returning:real);late=nil}
        retired.model.refresh();try await wait{late != nil};retired.close()
        try require(!drained && retired.model.retired && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired diagnostic worker lost Quit ownership")
        late?.resume(returning:real);late=nil;try await wait{drained}
        try require(retired.model.diagnosis==nil,"Retired diagnostic published/reopened")
        let question=c.window();question.model.refresh();try await wait{question.model.canTrust}
        var reply:((NSApplication.ModalResponse)->Void)?,writes=0
        question.presentQuestion={alert,window,answer in window.beginSheet(alert.window);reply=answer}
        let write=question.model.writeTrust;question.model.writeTrust={plan,token in writes += 1;return try await write(plan,token)}
        var phase="await trust question"
        @MainActor func questionDiagnostic(){
            print("Owned question diagnostic: phase=\(phase), reply=\(reply != nil), busy=\(question.model.busy), cancelling=\(question.model.cancelling), retired=\(question.model.retired), error=\(question.model.error ?? "nil"), attachedSheet=\(String(describing:question.window?.attachedSheet)), sheetParent=\(String(describing:question.window?.attachedSheet?.sheetParent)), active=\(InaccessibleRepositoryWindowModel.activeOperations)/\(RepositoryModel.activeInaccessiblePreparations), writes=\(writes)");fflush(stdout)
        }
        question.model.trust()
        do {
            try await wait{reply != nil};questionDiagnostic()
            phase="parent performClose"
            question.window?.performClose(nil);questionDiagnostic()
            // AppKit blocks a parent Close while its modal question is owned.
            // Exercise the separate programmatic cancellation contract, rather
            // than forcing the unavailable parent-window gesture to close it.
            try require(question.model.busy && !question.model.cancelling && !question.model.retired && question.window?.attachedSheet != nil,"Parent Close bypassed owned modal trust question")
            phase="programmatic owned close cancellation"
            try require(question.model.requestClose(),"Owned busy close did not request cancellation/drain")
            phase="await close and sheet drain"
            try await wait{drained && question.model.retired}
        } catch {questionDiagnostic();throw error}
        reply?(.alertSecondButtonReturn)
        try require(writes==0 && question.model.trustReceipt==nil && question.window?.attachedSheet==nil,"Late confirmation dispatched cancelled config write or sheet failed to drain")
        let nativeCancel=c.window();nativeCancel.model.refresh();try await wait{nativeCancel.model.canTrust}
        var alert:NSAlert?
        nativeCancel.presentQuestion={value,window,completion in alert=value;value.beginSheetModal(for:window,completionHandler:completion)}
        nativeCancel.model.trust();try await wait{alert?.window.sheetParent === nativeCancel.window}
        guard let button=alert?.buttons.first else{throw Failure(description:"Actual Cancel button absent")}
        button.performClick(nil)
        try await wait{drained && !nativeCancel.model.busy && nativeCancel.window?.attachedSheet==nil}
        try require(!nativeCancel.model.retired && nativeCancel.model.trustReceipt==nil,"Actual alert Cancel closed diagnostic or recorded trust")
        try await c.unchanged()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.inaccessibleFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.inaccessibleOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs)
        do {
            try await c.prepare()
            switch CommandLine.arguments[3] {case "diagnosis":try await diagnosis(c);case "routes":try await routes(c);case "trust":try await trust(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown inaccessible case")}
            await c.clean();DialogGeometry.install(preferences:.standard)
            try require(drained && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Diagnostic owners/workers not cleaned")
            print("PASS: inaccessible repository "+CommandLine.arguments[3]);fflush(stdout)
        } catch {await c.clean();DialogGeometry.install(preferences:.standard);fputs("Inaccessible repository failed: \(error)\n",stderr);exit(1)}
    }
}
