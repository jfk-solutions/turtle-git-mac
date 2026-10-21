// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private struct DeliveryFileScopes:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
@MainActor enum FinderDeliveryFilesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws{if !value{throw Failure(description:"\(line): \(message)")}}
    static func wait(_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:message)
    }
    @MainActor final class Probe {var discoveries=0,mailContexts=0}
    @MainActor final class Context {
        let root:URL,defaults:UserDefaults,other:UserDefaults,suite:String
        let marks:WorkingComparisonMarkStore,workspace:RepositoryModel,host:NSWindow,probe:Probe
        let delegate=TurtleGitApplicationDelegate()
        var windows:[NSWindowController]=[],files:[(RepositoryAction,NSWindowController,[RepositoryAccessLease])]=[]
        var permissions:[URL]=[],unblock:[()->Void]=[]
        init(root:URL,git:URL)throws {
            self.root=root;suite="TurtleGit.DeliveryFiles.QA."+UUID().uuidString
            defaults=UserDefaults(suiteName:suite)!;other=UserDefaults(suiteName:suite+".replacement")!
            defaults.set(false,forKey:"UseLibgit2");defaults.set(false,forKey:"TurtleGitMerge.OnePane");defaults.set(0,forKey:"AutoCloseGitProgress")
            other.set(true,forKey:"TurtleGitMerge.OnePane")
            let provider=DeliveryFileScopes(),probe=Probe();self.probe=probe
            marks=WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("marks.json"),provider:provider)
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{location in
                // Send Mail needs Git's global identity/configuration, using an
                // exclusive application-owned directory, without a checkout.
                let temporary=try TurtleGitTemporaryStorage.root
                if location.lastPathComponent.hasPrefix("TurtleGit-mail-context-"),location.deletingLastPathComponent().standardizedFileURL==temporary.standardizedFileURL {
                    probe.mailContexts += 1;return GitRepository(root:location,executable:git)
                }
                probe.discoveries += 1;throw Failure(description:"Arbitrary-file Service attempted repository discovery")
            },snapshotWriter:{_ in false},comparisonMarks:marks)
            workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=provider
            workspace.fileComparisonPreferences=defaults;workspace.reviewPatchPreferences=defaults;workspace.comparisonMarkPublication={_ in false}
            delegate.repositoryModel=workspace
            host=NSWindow(contentRect:.init(x:-12000,y:-12000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            host.alphaValue=0;host.isReleasedWhenClosed=false;workspace.workspaceWindow=host;host.orderFront(nil)
            workspace.finderServiceFilePermission={ [weak self] file,token in
                try token.check();self?.permissions.append(file);return RepositoryAccessLease(url:file,provider:provider)
            }
            workspace.finderServiceFileWorkflowPresentation={ [weak self] action,controller,leases in
                self?.track(controller);self?.files.append((action,controller,leases))
            }
            workspace.fileComparisonWindowPresentation={ [weak self] controller in self?.track(controller);controller.showWindow(nil) }
            workspace.finderMailPresentation={ [weak self] controller in self?.track(controller);controller.showWindow(nil) }
        }
        func track(_ controller:NSWindowController){if !windows.contains(where:{$0 === controller}){windows.append(controller)};controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-12000,y:-12000))}
        func write(_ path:String,_ text:String)throws->URL {
            let file=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:file);return file
        }
        func start(_ action:RepositoryAction,_ paths:[URL],alternate:Bool?=nil)throws {
            workspace.error=nil
            try require(workspace.handleFinderService(.init(action:action,paths:paths,alternateTool:alternate)),"Service was not accepted: \(action)")
        }
        func settled()async throws{try await wait("File-first dispatch did not drain: \(workspace.error ?? "no error")"){!self.workspace.hasPendingFinderServiceWork && !self.workspace.busy}}
        var drained:Bool {!workspace.hasPendingRepositoryWork && FileListComparisonSession.activeOperations==0 && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 && SendPatchWindowModel.activeLoads==0 && SendPatchWindowController.activeReleases==0 && WorkingTreePatchWindowModel.activeOperations==0 && WorkingTreePatchWindowController.activeReleases==0}
        func cleanup()async {
            workspace.stopMonitoringForTermination();windows.forEach{$0.close()};host.close();unblock.forEach{$0()};unblock=[]
            for _ in 0..<3000 {
                if drained {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            windows.forEach{$0.window?.orderOut(nil)};defaults.removePersistentDomain(forName:suite);other.removePersistentDomain(forName:suite+".replacement")
        }
    }
    static func run(root:URL,git:URL)async throws {
        let c=try Context(root:root,git:git)
        do {
            let left=try c.write("first/literal [a]; 雪\n.txt","left\n"),right=try c.write("second/literal [b]; 雪.txt","right\n"),newer=try c.write("third/new.txt","newer\n")
            try c.start(.diffLater,[left],alternate:false);try await c.settled()
            try require(try c.marks.snapshot()?.path==left.path && c.files.isEmpty && c.probe.discoveries==0,"Mark required Git or presented a comparison")
            let originalMark=try c.marks.snapshot()?.id
            try require(!c.workspace.handleFinderService(.init(action:.clearComparisonMark,paths:[root])) && c.marks.snapshot()?.id==originalMark,"Clear on a folder bypassed nonfolder source admission")
            var alternate:Bool?,captured:FileComparisonDocument?
            c.workspace.finderServiceComparisonRead={comparison,token in
                let value=try comparison.read();captured=value;try token.check()
                try Data("changed after accepted read\n".utf8).write(to:comparison.base)
                return value
            }
            c.workspace.finderServiceFileWorkflowPresentation={action,controller,leases in
                c.track(controller);c.files.append((action,controller,leases))
                if let comparison=controller as? FileComparisonWindowController {
                    comparison.model.openExternalComparison={_,_,_,choice in alternate=choice;return false}
                }
            }
            c.workspace.finderServiceFilePermission={file,token in
                try token.check();c.permissions.append(file);c.workspace.fileComparisonPreferences=c.other
                return RepositoryAccessLease(url:file,provider:DeliveryFileScopes())
            }
            try c.start(.diffLater,[right],alternate:true);try await c.settled()
            let comparison=try unwrap(c.files.last?.1 as? FileComparisonWindowController,"No actual marked file comparison")
            try await wait("Actual comparison did not load"){!comparison.model.busy && comparison.model.document != nil}
            try require(comparison.model.comparisonDefaults === c.defaults && alternate==true,"Delayed authorization changed captured settings/tool")
            try require(comparison.model.document?.base.bytes==captured?.base.bytes && comparison.model.document?.base.bytes==Data("left\n".utf8),"Accepted read was discarded and files reread before presentation")
            try require(c.files.last?.2.count==2 && c.files.last?.2.allSatisfy(\.hasSecurityScope)==true && c.permissions.map(\.path)==[left.path,right.path],"Independent file grants were replaced by a common repository grant")
            try require(try c.marks.snapshot()==nil && c.probe.discoveries==0,"Accepted comparison failed to consume only its mark or discovered Git")
            comparison.model.load(discardingDraft:true)
            try await wait("Explicit Reload did not read current bytes"){!comparison.model.busy && comparison.model.document?.base.bytes==Data("changed after accepted read\n".utf8)}
            comparison.close();try await wait("Comparison close did not drain"){!comparison.model.mergeToolHasPendingWork}
            c.workspace.fileComparisonPreferences=c.defaults;c.workspace.finderServiceComparisonRead=nil
            c.workspace.finderServiceFilePermission={file,_ in RepositoryAccessLease(url:file,provider:DeliveryFileScopes())}
            try c.start(.diff,[left,right],alternate:false);try await c.settled()
            let pair=try unwrap(c.files.last?.1 as? FileComparisonWindowController,"Two-file Diff did not use the file-first route")
            try await wait("Two-file Diff did not load"){!pair.model.busy && pair.model.document != nil}
            try require(pair.model.document?.base.bytes==Data("changed after accepted read\n".utf8) && pair.model.document?.destination.bytes==Data("right\n".utf8) && c.marks.snapshot()==nil,"Two-file Diff changed file order/bytes or created a comparison mark")
            pair.close();try await wait("Two-file Diff close did not drain"){!pair.model.mergeToolHasPendingWork}

            // Replacing the durable mark while another authorization is held
            // must not silently compare or consume the replacement.
            _=try c.marks.remember(file:left,permission:RepositoryAccessLease(url:left,provider:DeliveryFileScopes()),requireSecurityScope:true)
            var reply:CheckedContinuation<RepositoryAccessLease?,Never>?,permissionToken:OperationCancellation?
            c.workspace.finderServiceFilePermission={_,token in permissionToken=token;return await withCheckedContinuation{reply=$0}}
            c.unblock.append{reply?.resume(returning:nil);reply=nil}
            let prior=c.files.count;try c.start(.diffLater,[right],alternate:false)
            try await wait("Comparison authorization was not held"){reply != nil}
            let replacement=try c.marks.remember(file:newer,permission:RepositoryAccessLease(url:newer,provider:DeliveryFileScopes()),requireSecurityScope:true)
            reply?.resume(returning:RepositoryAccessLease(url:right,provider:DeliveryFileScopes()));reply=nil;try await c.settled()
            try require(c.files.count==prior && c.workspace.error != nil && c.marks.snapshot()?.id==replacement.id && permissionToken?.isCancelled==false,"Delayed comparison retargeted or consumed a newer mark")
            let permissionCount=c.permissions.count;try c.start(.clearComparisonMark,[right]);try await c.settled()
            try require(try c.marks.snapshot()==nil && c.permissions.count==permissionCount,"Clear required file/repository permission")

            // A real read whose reply arrives after owner closure must remain
            // counted for Quit, preserve the mark and suppress presentation.
            _=try c.marks.remember(file:left,permission:RepositoryAccessLease(url:left,provider:DeliveryFileScopes()),requireSecurityScope:true)
            c.workspace.finderServiceFilePermission={file,_ in RepositoryAccessLease(url:file,provider:DeliveryFileScopes())}
            var readReply:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?
            c.workspace.finderServiceComparisonRead={comparison,token in let value=try comparison.read();readToken=token;await withCheckedContinuation{readReply=$0};return value}
            c.unblock.append{readReply?.resume();readReply=nil}
            try c.start(.diffLater,[right],alternate:false);try await wait("Actual comparison read receipt was not held"){readReply != nil}
            c.host.close()
            try require(readToken?.isCancelled==true && c.workspace.hasPendingFinderServiceWork && c.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Owner close released real file read before drainage")
            readReply?.resume();readReply=nil;try await c.settled()
            try require(c.files.count==prior && c.marks.snapshot() != nil,"Late comparison presented or consumed the mark")
            await c.cleanup();try require(c.drained,"Comparison cleanup left owned work")
        }catch{await c.cleanup();throw error}

        let deliveryRoot=root.appendingPathComponent("patch-and-mail");try FileManager.default.createDirectory(at:deliveryRoot,withIntermediateDirectories:true)
        let d=try Context(root:deliveryRoot,git:git)
        do {
            let patchText="--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"
            let patch=try d.write("outside/change.patch",patchText),other=try d.write("outside/second.patch",patchText)
            let target=try d.write("target/a.txt","old\n").deletingLastPathComponent()
            var reviews:[WorkingTreePatchWindowController]=[]
            d.workspace.reviewPatchPreparation={workflow in
                d.track(workflow);workflow.chooseTarget={target}
            }
            d.workspace.reviewPatchPresentation={controller in d.track(controller);reviews.append(controller);controller.showWindow(nil)}
            try d.start(.reviewPatch,[patch]);try await d.settled()
            try await wait("Arbitrary patch did not reach actual directory review"){reviews.first?.model.review != nil && reviews.first?.model.busy==false}
            let review=try unwrap(reviews.first,"Missing patch review")
            try require(review.model.openPreferences === d.defaults && review.model.directoryMode && review.model.repository.root.path==target.path && d.probe.discoveries==0,"Review borrowed workspace/repository context or lost captured preferences")
            try require(try Data(contentsOf:target.appendingPathComponent("a.txt"))==Data("old\n".utf8),"Opening patch review applied the patch")
            review.close()
            let missing=deliveryRoot.appendingPathComponent("outside/missing.patch")
            try d.start(.sendMail,[other,patch,missing]);try await d.settled()
            try require(d.workspace.error==nil,"Send Mail preparation failed: \(d.workspace.error ?? "none")")
            try await wait("Arbitrary mail files did not reach options"){d.files.contains{$0.0 == .sendMail && $0.1 is SendPatchWindowController}}
            let mail=try unwrap(d.files.last(where:{$0.0 == .sendMail})?.1 as? SendPatchWindowController,"Missing Send Mail options")
            try require(mail.model.rows.map(\.file.path)==[other.path,patch.path,missing.path] && mail.model.presentationPreferences === d.defaults,"Mail retargeted ordered files, removed unavailable checkbox rows, or changed preferences")
            try require(try Data(contentsOf:patch)==Data(patchText.utf8) && d.probe.discoveries==0 && d.probe.mailContexts==1,"Mail/review changed input, borrowed a checkout, or omitted the private global-identity context")
            mail.close();try await wait("Send options did not retire"){!mail.hasPendingWork}
            var presentedAfterRetirement=0,retiredMail:SendPatchWindowController?
            d.workspace.finderMailPresentation={_ in presentedAfterRetirement += 1}
            d.workspace.finderServiceFileWorkflowPresentation={action,controller,_ in
                d.track(controller)
                if action == .sendMail,let value=controller as? SendPatchWindowController {retiredMail=value;value.close()}
            }
            try d.start(.sendMail,[patch]);try await d.settled()
            try require(retiredMail?.canReuse==false && presentedAfterRetirement==0,"Prepared mail hook retired options but Services re-presented them")
            await d.cleanup();try require(d.drained,"Patch/mail cleanup left owned work")
        }catch{await d.cleanup();throw error}
        print("PASS: file-first comparison/mark/clear, captured read/settings, independent grants, newer mark/cancel, arbitrary patch/mail delivery")
    }
    private static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
}
