// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

// This legacy workflow receiver injects its instrumented action owner through
// makeStandaloneWorkspace. Distinct scene/action ownership is verified by the
// current dialog-launch receiver, rather than inferred from this private host.

@MainActor private func verifyPublicOpenService(_ entries:[[String:Any]])throws {
    guard entries.count==1,let entry=entries.first,
          entry["NSMessage"] as? String=="openInTurtleGit",entry["NSUserData"] as? String=="open",
          entry["NSPortName"] as? String=="TurtleGit",entry["NSSendFileTypes"] as? [String]==["public.item"],
          entry["NSRestricted"] as? Bool==true,(entry["NSRequiredContext"] as? [String:Any])?.isEmpty==true,
          (entry["NSMenuItem"] as? [String:String])?["default"]=="Open in TurtleGit" else {
        throw NSError(domain:"TurtleGit.NativeServicesInventory",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected one restricted Open in TurtleGit item Service"])
    }
}

private struct DeliveryRepositoryScopes:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ bytes:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}

enum FinderDeliveryRepositoryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static let names=["diffLater","clearComparisonMark","export","formatPatch","importPatch","reviewPatch","sendMail","requestPull"]
    static let repositoryNames=["export","formatPatch","importPatch","requestPull"]
    static let folderNames:Set<String>=["export","formatPatch","requestPull"]
    static let originalNames=["pull","fetch","push","synchronize","commit","diff","log","status","rebase","stash","stashApply","stashPop","stashList","switchBranch","merge","branch","tag","clone","initialize","add","revert","resolve","resolveCurrent","resolveMine","resolveTheirs","blame","previousDiff","editConflict","ignore","ignoreMask","ignoreDelete","ignoreDeleteMask","rename","remove","removeKeep","clean","worktreeList","worktreeCreate","submoduleAdd","submoduleUpdate","submoduleSync","logSubmodule","reflog","referenceBrowser","repositoryBrowser","revisionGraph","daemon"]
    static let literal="literal [a]; 雪\n.txt"
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value{throw Failure(description:"\(line): \(message)")}}
    @MainActor static func wait(_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<2400 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:message)
    }
    @MainActor static func board(_ paths:[URL])->NSPasteboard {
        let board=NSPasteboard.withUniqueName()
        board.writeObjects(paths.map {url->NSPasteboardItem in let item=NSPasteboardItem();item.setString(url.absoluteString,forType:.fileURL);return item})
        return board
    }
    @MainActor static func invoke(_ provider:TurtleGitFinderServicesProvider,_ board:NSPasteboard,_ name:String)->NSString? {
        var error:NSString?;provider.performFinderAction(board,userData:name,error:&error);return error
    }
    @MainActor static func pending(_ controller:NSWindowController)->Bool {
        switch controller {
        case let child as ExportWindowController:return child.hasPendingWork
        case let child as FormatPatchWindowController:return child.hasPendingWork
        case let child as ImportPatchWindowController:return child.hasPendingWork
        case let child as RequestPullWindowController:return child.hasPendingWork
        default:return true
        }
    }
    @MainActor static func reusable(_ controller:NSWindowController)->Bool {
        switch controller {
        case let child as ExportWindowController:return child.canReuse
        case let child as FormatPatchWindowController:return child.canReuse
        case let child as ImportPatchWindowController:return child.canReuse
        case let child as RequestPullWindowController:return child.canReuse
        default:return false
        }
    }
    @MainActor static func closedReceipt(_ controller:NSWindowController)->()->Void {
        switch controller {
        case let child as ExportWindowController:return child.onClosed
        case let child as FormatPatchWindowController:return child.onClosed
        case let child as ImportPatchWindowController:return child.onClosed
        case let child as RequestPullWindowController:return child.onClosed
        default:return {}
        }
    }
    @MainActor static func preferences(_ controller:NSWindowController)->UserDefaults? {
        switch controller {
        case let child as ExportWindowController:return child.model.presentationPreferences
        case let child as FormatPatchWindowController:return child.model.preferences
        case let child as ImportPatchWindowController:return child.model.previewDocument.appearancePreferences
        case let child as RequestPullWindowController:return child.model.presentationPreferences
        default:return nil
        }
    }
    @MainActor static func loaded(_ controller:NSWindowController)->Bool {
        switch controller {
        case let child as ExportWindowController:return child.model.canEditForm && child.model.error==nil
        case let child as FormatPatchWindowController:return child.model.optionsAvailable && child.model.error==nil
        case let child as ImportPatchWindowController:return child.model.editable && child.model.error==nil
        case let child as RequestPullWindowController:return child.model.optionsAvailable && child.model.error==nil
        default:return false
        }
    }

    @MainActor static func provider(root:URL,git:URL,plist:URL)async throws {
        let directory=root.appendingPathComponent("provider folder 雪",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("literal [a]; 雪\n.patch"),other=directory.appendingPathComponent("other.diff")
        for url in [file,other] {try Data("private provider capture".utf8).write(to:url)}
        let old=NSApp.servicesProvider;defer{NSApp.servicesProvider=old}
        let marker=NSObject();NSApp.servicesProvider=marker
        let providerSuite="TurtleGit.Delivery.Provider.QA."+UUID().uuidString
        let providerPreferences=UserDefaults(suiteName:providerSuite)!
        defer{providerPreferences.removePersistentDomain(forName:providerSuite)}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("provider-marks.json")),cachePersistenceDefaults:providerPreferences)
        workspace.fileComparisonPreferences=providerPreferences
        defer{workspace.stopMonitoringForTermination()}
        for name in names {
            let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in}
            var received:[FinderRequest]=[]
            delegate.workspaceServiceHandler={_,request in received.append(request);return true}
            delegate.installFinderServices()
            defer{delegate.retireFinderServices()}
            try require((NSApp.servicesProvider as AnyObject?) === delegate.finderServicesProvider,"delivery provider not installed")
            let selected=folderNames.contains(name) ? directory:file
            let board=Self.board([selected]),multiple=Self.board([file,other]);defer{board.releaseGlobally();multiple.releaseGlobally()}
            let generation=board.changeCount
            try require(invoke(delegate.finderServicesProvider,board,name)==nil && delegate.pendingFinderServiceRequest?.action.rawValue==name,"cold delivery did not retain typed action")
            try require(invoke(delegate.finderServicesProvider,board,name) != nil && received.isEmpty,"cold duplicate accepted")
            delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching()
            try await wait("cold delivery did not drain"){received.count==1}
            try require(received[0].action.rawValue==name && received[0].paths.map{Data($0.path.utf8)}==[Data(selected.path.utf8)] && delegate.pendingFinderServiceRequest==nil && board.changeCount==generation,"cold action/path/pasteboard capture changed")
            try require(received[0].sources.isEmpty && received[0].clipboardPatch==nil && received[0].requestPullEnd==nil && received[0].requestPullURL==nil,"provider invented an execution preset")
            try require((received[0].alternateTool != nil)==(name=="diffLater"),"alternate-tool capture policy changed")
            try require(invoke(delegate.finderServicesProvider,board,name)==nil && received.count==2,"active delivery missing")
            if name=="importPatch" || name=="sendMail" {
                try require(invoke(delegate.finderServicesProvider,multiple,name)==nil && received.count==3 && received.last?.paths.map(\.path)==[file.path,other.path],"multi-file delivery lost literal order")
            } else {try require(invoke(delegate.finderServicesProvider,multiple,name) != nil && received.count==2,"singleton delivery accepted two paths")}
            let count=received.count
            delegate.retireFinderServices()
            try require((NSApp.servicesProvider as AnyObject?) === marker,"provider retirement failed to restore predecessor")
            try require(invoke(delegate.finderServicesProvider,board,name) != nil && received.count==count,"retired provider delivered")
        }
        let document=try requirePlist(plist),entries=try XCTEntries(document)
        try verifyPublicOpenService(entries)
        print("PASS: eight cold/active/retired typed delivery Services,one public declaration and legacy handlers and captured private pasteboards")
    }
    private static func requirePlist(_ url:URL)throws->[String:Any] {
        guard let value=try PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as? [String:Any] else{throw Failure(description:"invalid app plist")};return value
    }
    private static func XCTEntries(_ document:[String:Any])throws->[[String:Any]] {
        guard let entries=document["NSServices"] as? [[String:Any]] else{throw Failure(description:"missing Services declarations")};return entries
    }

    @MainActor private final class Context {
        let root:URL,git:URL,suite:String,defaults:UserDefaults,otherSuite:String,other:UserDefaults
        let store:RepositoryAccessStore,workspace:RepositoryModel,host:NSWindow
        let delegate=TurtleGitApplicationDelegate()
        var windows:[(RepositoryAction,NSWindowController,GitRepository,RepositoryAccessLease?)]=[]
        var panels:[NSOpenPanel]=[]
        var heldReply:((NSApplication.ModalResponse)->Void)?
        var holdNextGrant=false,grantURL:URL?
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;suite="TurtleGit.Delivery.Repository.QA."+UUID().uuidString;otherSuite=suite+".other"
            defaults=UserDefaults(suiteName:suite)!;other=UserDefaults(suiteName:otherSuite)!
            for preferences in [defaults,other] {preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(false,forKey:"RequestPullSendMail");preferences.set(false,forKey:"FormatPatchSendMail")}
            defaults.set("Menlo",forKey:"LogFontName");other.set("Helvetica",forKey:"LogFontName")
            store=try RepositoryAccessStore(storageURL:root.appendingPathComponent("delivery-access.json"),provider:DeliveryRepositoryScopes())
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("delivery-marks.json")),cachePersistenceDefaults:defaults)
            workspace.repositoryBookmarkProvider=DeliveryRepositoryScopes();workspace.requiresRepositoryScope=true;workspace.fileComparisonPreferences=defaults
            host=NSWindow(contentRect:.init(x:-20000,y:-20000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            host.alphaValue=0;host.isReleasedWhenClosed=false;host.orderFront(nil);workspace.workspaceWindow=host
            workspace.finderServiceWorkflowPresentation={ [weak self] action,controller,repository,access in
                controller.window?.alphaValue=0;controller.window?.setFrameOrigin(NSPoint(x:-20000,y:-20000));self?.windows.append((action,controller,repository,access))
            }
            workspace.presentFinderServiceFolderPanel={ [weak self] panel,parent,reply in
                guard let self else{reply(.cancel);return};panel.alphaValue=0;panel.setFrameOrigin(NSPoint(x:-20000,y:-20000));self.panels.append(panel)
                parent?.beginSheet(panel,completionHandler:nil)
                if self.holdNextGrant {self.holdNextGrant=false;self.heldReply=reply}
                else {Task{@MainActor in await Task.yield();reply(.OK)}}
            }
            workspace.selectedFinderServiceFolderURL={ [weak self] _ in self?.grantURL}
            workspace.finderServiceFilePermission={url,token in
                try token.check()
                return RepositoryAccessLease(url:url,provider:DeliveryRepositoryScopes())
            }
            workspace.presentCommandImportFolderPanel={ [weak self] panel,parent,reply in
                panel.alphaValue=0;panel.setFrameOrigin(NSPoint(x:-20000,y:-20000));self?.panels.append(panel)
                parent?.beginSheet(panel,completionHandler:nil);Task{@MainActor in await Task.yield();reply(.OK)}
            }
            workspace.selectedCommandImportFolderURL={ [weak self] _ in self?.grantURL}
            delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in};delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching()
        }
        func make(_ name:String)async throws->GitRepository {
            let directory=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repository=GitRepository(root:directory,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Delivery Services QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            try Data("committed\n".utf8).write(to:directory.appendingPathComponent(FinderDeliveryRepositoryVerification.literal));try await repository.stage([FinderDeliveryRepositoryVerification.literal]);_=try await repository.commit(message:"baseline")
            try Data("added\n".utf8).write(to:directory.appendingPathComponent("added.txt"));try await repository.stage(["added.txt"])
            try Data("untracked\n".utf8).write(to:directory.appendingPathComponent("untracked.txt"))
            return repository
        }
        func open(_ repository:GitRepository)async throws {
            try await FinderDeliveryRepositoryVerification.wait("workspace did not drain before Open"){!self.workspace.busy && !self.workspace.hasPendingRepositoryWork}
            var accepted=false;workspace.open(repository.root,onOpened:{accepted=true})
            try await FinderDeliveryRepositoryVerification.wait("workspace Open did not settle"){accepted && !self.workspace.busy && self.workspace.root?.path==repository.root.path}
        }
        func launch(_ name:String,_ paths:[URL],accepted:Bool=true,delayed:Bool=false)async throws->NSWindowController? {
            try await FinderDeliveryRepositoryVerification.wait("delivery workspace busy before \(name)"){!self.workspace.busy && !self.workspace.hasPendingRepositoryWork}
            workspace.error=nil;let count=windows.count,board=FinderDeliveryRepositoryVerification.board(paths);defer{board.releaseGlobally()}
            let error=FinderDeliveryRepositoryVerification.invoke(delegate.finderServicesProvider,board,name)
            if error != nil {try FinderDeliveryRepositoryVerification.require(!accepted && windows.count==count,"unexpected delivery refusal \(name): \(String(describing:error))");return nil}
            if delayed {
                try await FinderDeliveryRepositoryVerification.wait("delivery grant was not held"){self.heldReply != nil}
                try FinderDeliveryRepositoryVerification.require(windows.count==count && workspace.hasPendingFinderServiceWork,"grant created native form early or lost accounting")
                workspace.fileComparisonPreferences=other
                let reply=heldReply;heldReply=nil;reply?(.OK)
            }
            try await FinderDeliveryRepositoryVerification.wait("delivery dispatch did not settle: \(name)"){!self.workspace.busy && !self.workspace.hasPendingFinderServiceWork && (self.windows.count>count || self.workspace.error != nil)}
            if !accepted {try FinderDeliveryRepositoryVerification.require(windows.count==count && workspace.error != nil,"ineligible delivery presented \(name)");return nil}
            try FinderDeliveryRepositoryVerification.require(windows.count==count+1,"actual \(name) controller missing: \(workspace.error ?? "nil")")
            let found=windows[count]
            try FinderDeliveryRepositoryVerification.require(found.0.rawValue==name && found.1.window?.alphaValue==0 && found.3?.hasSecurityScope==true && found.3?.contains(found.2.root)==true,"actual delivery action/window/primary lease lost")
            try await FinderDeliveryRepositoryVerification.wait("actual \(name) metadata did not settle"){FinderDeliveryRepositoryVerification.loaded(found.1)}
            return found.1
        }
        func finish()async throws {
            let reply=heldReply;heldReply=nil;reply?(.cancel)
            delegate.retireFinderServices();workspace.stopMonitoringForTermination()
            windows.forEach{$0.1.close()}
            for panel in panels {panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close()};host.close()
            try await FinderDeliveryRepositoryVerification.wait("delivery forms/readers/sheets did not retire"){!self.workspace.hasPendingFinderServiceWork && self.windows.allSatisfy{!FinderDeliveryRepositoryVerification.pending($0.1)}}
            defaults.removePersistentDomain(forName:suite);other.removePersistentDomain(forName:otherSuite)
        }
    }
    private static func preserved(_ repository:GitRepository)async throws->[Data] {
        let root=repository.root
        return [try Data(contentsOf:root.appendingPathComponent(".git/index")),try Data(contentsOf:root.appendingPathComponent(".git/config")),try Data(contentsOf:root.appendingPathComponent(literal)),try await repository.run(["rev-parse","HEAD"]).stdout]
    }
    @MainActor static func routes(root:URL,git:URL)async throws {
        let context=try Context(root:root,git:git)
        do {
            let a=try await context.make("deliveryA"),b=try await context.make("workspaceB")
            try context.store.remember(b.root);try await context.open(b)
            let originalA=try await preserved(a),originalB=try await preserved(b)
            for(index,name)in repositoryNames.enumerated() {
                context.workspace.fileComparisonPreferences=context.defaults;context.grantURL=a.root;context.holdNextGrant=index==0
                let child=try await context.launch(name,[a.root],delayed:index==0)!
                if let importer=child as? ImportPatchWindowController {try require(importer.model.items.isEmpty,"selected repository folder was imported as a patch file")}
                try require(context.windows.last?.2.root.path==a.root.path && preferences(child) === context.defaults && context.windows.last?.3?.contains(b.root)==false,"\(name) used workspaceB or post-grant preferences")
                try await context.open(b);context.workspace.fileComparisonPreferences=context.other
                try require(preferences(child) === context.defaults,"workspace preference replacement retargeted original delivery form")
                let second=try await context.launch(name,[a.root])!
                try require(second !== child && preferences(second) === context.other && reusable(child),"\(name) crossed live preference-domain cache ownership")
                let oldClosed=closedReceipt(child)
                child.close();try await wait("retired delivery form did not drain"){!pending(child)}
                try await context.open(b);context.workspace.fileComparisonPreferences=context.defaults
                let replacement=try await context.launch(name,[a.root])!
                try require(replacement !== child && replacement !== second && reusable(second) && preferences(replacement) === context.defaults,"\(name) reopened a retired owner or removed independent cache entry")
                oldClosed()
                if name != "requestPull" {
                    let reused=try await context.launch(name,[a.root])!
                    try require(reused === replacement,"late old \(name) closure removed its replacement cache entry")
                }
                second.close();replacement.close()
                try await wait("delivery cache forms did not close"){!pending(second) && !pending(replacement)}
                try await context.open(b)
                for leaf in ["added.txt","untracked.txt"] {_=try await context.launch(name,[a.root.appendingPathComponent(leaf)],accepted:false)}
                try await context.open(b)
            }
            try await context.open(b);context.grantURL=a.root;context.workspace.fileComparisonPreferences=context.defaults
            let mailPatch=root.appendingPathComponent("external [one]; 雪\n.patch")
            let patchBytes=try await a.run(["format-patch","--stdout","-1","HEAD"]).stdout
            try patchBytes.write(to:mailPatch)
            let mixed=try await context.launch("importPatch",[mailPatch,a.root])!
            guard let importer=mixed as? ImportPatchWindowController else{throw Failure(description:"mixed source did not create actual Import form")}
            try require(importer.model.items.count==1 && importer.model.items[0].file.path==mailPatch.path && importer.model.repository.root.path==a.root.path,"mixed source failed to retain patch order/skip directory/use separately authorized destination")
            try require(try Data(contentsOf:mailPatch)==patchBytes,"Import options changed source patch bytes")
            mixed.close();try await wait("mixed Import did not drain"){!pending(mixed)}
            let bareURL=root.appendingPathComponent("bare-delivery.git",isDirectory:true)
            _=try await a.run(["clone","--bare",a.root.path,bareURL.path])
            let bare=GitRepository(root:bareURL,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))
            let bareHead=try await bare.run(["rev-parse","HEAD"]).stdout
            for name in repositoryNames {
                try await context.open(b);context.grantURL=bareURL;context.workspace.fileComparisonPreferences=context.defaults
                let accepted=name=="export" || name=="requestPull"
                if let child=try await context.launch(name,[bareURL],accepted:accepted) {try require(context.windows.last?.2.root.path==bareURL.path,"bare delivery used another root");child.close();try await wait("bare delivery did not close"){!pending(child)}}
            }
            let afterA=try await preserved(a),afterB=try await preserved(b)
            try require(afterA==originalA && afterB==originalB,"opening delivery forms changed actual HEAD/index/config/working bytes")
            let afterBareHead=try await bare.run(["rev-parse","HEAD"]).stdout
            try require(afterBareHead==bareHead,"bare delivery changed HEAD")
            try await context.finish()
        } catch {try? await context.finish();throw error}
        print("PASS: four actual repository delivery forms, captured roots/preferences, delayed grant, independent live cache and retired replacement, source selection gates and unchanged Git state")
    }
}
