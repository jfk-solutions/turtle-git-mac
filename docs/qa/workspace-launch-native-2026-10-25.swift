// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ObjectiveC
import TurtleGitCore

private final class WorkspaceLaunchBookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
private extension NSWindow {
    @objc func workspaceLaunchOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));workspaceLaunchOrder(mode,relativeTo:number)
    }
}
@MainActor
@main enum WorkspaceLaunchVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:"Workspace launch: "+message)}}
    static func wait(_ message:String,_ predicate:()->Bool)async throws {
        for _ in 0..<3000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Workspace launch timeout: "+message)
    }
    @MainActor final class Context {
        let folder:URL,git:URL,suite:String,preferences:UserDefaults,store:RepositoryAccessStore
        let delegate=TurtleGitApplicationDelegate()
        let scene:WorkspaceSceneOwner
        var models=[RepositoryModel](),controllers=[WorkspaceWindowController](),settings=[SettingsPresentationService](),appearances=[AppAppearance]()
        var presentations=0,configurations=0
        init()throws {
            folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true);git=URL(fileURLWithPath:CommandLine.arguments[2])
            suite="TurtleGit.WorkspaceLaunch."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"EnableGravatar")
            store=try RepositoryAccessStore(storageURL:folder.appendingPathComponent("private-access.json"),provider:WorkspaceLaunchBookmarks())
            let executable=git
            let router=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:executable,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store)
            router.requiresRepositoryScope=true;router.repositoryBookmarkProvider=WorkspaceLaunchBookmarks();router.fileComparisonPreferences=preferences
            scene=WorkspaceSceneOwner(commandModel:router);models.append(router)
            DialogGeometry.install(preferences:preferences)
            scene.makeModel={ [unowned self] in self.makeModel() }
            scene.makeController={ [unowned self] model,appearance,delegate in
                let owner=WorkspaceWindowController(model:model,appearance:appearance,applicationDelegate:delegate)
                owner.presentWindow={ [weak self] window in self?.presentations += 1;window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.makeKeyAndOrderFront(nil) }
                self.controllers.append(owner);return owner
            }
            delegate.makeStandaloneWorkspace={ [unowned self] in self.makeModel() }
            delegate.configureStandaloneServices={ [unowned self] model,_ in
                let appearance=AppAppearance(preferences:self.preferences),service=SettingsPresentationService()
                self.appearances.append(appearance);self.settings.append(service);service.install(workspace:model,appearance:appearance)
            }
            delegate.activateStandaloneApplication={}
            delegate.startupDirectory=folder.path
            delegate.configureGeneralApplication={ [unowned self] delegate in self.configurations += 1;self.scene.configure(applicationDelegate:delegate) }
        }
        func makeModel()->RepositoryModel {
            let git=self.git
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store)
            value.requiresRepositoryScope=true;value.repositoryBookmarkProvider=WorkspaceLaunchBookmarks();value.fileComparisonPreferences=preferences
            models.append(value);return value
        }
        func cleanup()async throws {
            delegate.retireFinderServices();delegate.retireMenuImageVisibility();delegate.workspaceOpenHandoff.retire();delegate.actionErrorController?.close()
            for service in settings {service.controller?.close()}
            for model in models {model.stopMonitoringForTermination()}
            // Every window in this receiver belongs to its private case. The
            // runtime order interceptor kept even implicit alert children hidden.
            for window in NSApp.windows {
                if let child=window.attachedSheet {window.endSheet(child,returnCode:.cancel);child.close()}
                if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)}
                window.close();window.orderOut(nil)
            }
            try await WorkspaceLaunchVerification.wait("owned readers retired") {
                self.models.allSatisfy{!$0.busy && !$0.hasPendingRepositoryWork} && TurtleGitAboutController.activeReads==0 && PatchDocumentSession.activeOperations==0
            }
            preferences.removePersistentDomain(forName:suite)
        }
    }
    static func cold(_ c:Context)async throws {
        let patch=c.folder.appendingPathComponent("changes 雪.patch"),bytes=Data("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-before\n+after\n".utf8)
        try bytes.write(to:patch)
        // Finder/Launch Services supplies no reliable special argv. Deliver the
        // file event before startup using ordinary empty launch metadata.
        c.delegate.startupArguments=[]
        c.delegate.application(NSApp,open:[patch]);c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:false]))
        try await wait("cold file document") {NSApp.windows.compactMap{$0.delegate as? PatchWindowController}.contains{!$0.model.busy && $0.documentSession.fileURL?.lastPathComponent==patch.lastPathComponent}}
        guard let document=NSApp.windows.compactMap({$0.delegate as? PatchWindowController}).first(where:{$0.documentSession.fileURL?.lastPathComponent==patch.lastPathComponent}) else {throw Failure(description:"Cold patch owner missing")}
        try require(document.model.document.bytes==bytes && document.model.canEditText && document.model.error==nil,"Cold file document lost exact editable patch bytes")
        try require(c.scene.storedModel==nil && c.scene.storedController==nil && c.controllers.isEmpty && c.presentations==0,"Cold ordinary file event materialized workspace")
        try require(c.delegate.actionRepositoryModel != nil && c.models.allSatisfy{$0.workspaceWindow==nil},"Cold patch borrowed a workspace window")
        try require(c.configurations==1,"General startup configuration did not install exactly once")
        let baseline=Set(NSApp.windows.map(ObjectIdentifier.init))
        let about=FinderRequest(action:.about,paths:[c.folder]).url!
        c.delegate.application(NSApp,open:[about])
        try await wait("warm About without workspace") {NSApp.windows.contains{!baseline.contains(ObjectIdentifier($0)) && $0.windowController is TurtleGitAboutController}}
        try require(c.controllers.isEmpty && c.presentations==0,"Warm About materialized workspace after cold patch")
        try require((try Data(contentsOf:patch))==bytes,"Read-only patch launch changed input bytes")
    }
    static func late(_ c:Context)async throws {
        c.delegate.startupArguments=[]
        c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        try require(c.scene.storedModel==nil && c.scene.storedController==nil && c.controllers.isEmpty,"Missing default-launch metadata inferred a workspace")
        let about=FinderRequest(action:.about,paths:[c.folder]).url!
        c.delegate.application(NSApp,open:[about])
        try await wait("post-launch unmarked URL") {NSApp.windows.contains{$0.windowController is TurtleGitAboutController}}
        try require(c.scene.storedModel==nil && c.controllers.isEmpty && c.presentations==0 && c.configurations==1,"Late unmarked URL constructed workspace")
        try require(c.delegate.applicationOpenUntitledFile(NSApp),"Explicit AppKit Open intent refused")
        try await wait("explicit late workspace") {c.scene.storedController?.window?.isVisible==true}
        try require(c.controllers.count==1 && c.delegate.repositoryModel === c.scene.storedModel,"Explicit intent after cold URL did not promote one workspace")
    }
    static func workspace(_ c:Context)async throws {
        c.delegate.startupArguments=[];c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:true]))
        try require(!c.delegate.applicationShouldOpenUntitledFile(NSApp),"Universal scene permitted automatic untitled creation")
        try await wait("normal workspace") {c.scene.storedController?.window != nil && c.controllers.count==1}
        guard let owner=c.scene.storedController,let window=owner.window,let model=c.scene.storedModel else {throw Failure(description:"Retained workspace identity absent")}
        try require(c.delegate.repositoryModel === model && window.contentViewController != nil && window.contentMinSize.width>=920 && window.contentMinSize.height>=650,"Manual host lost repository/content minimum ownership")
        let items=window.toolbar?.items ?? []
        try require(items.map(\.itemIdentifier)==WorkspaceWindowController.toolbarIdentifiers && items.allSatisfy{$0.target === owner && $0.action != nil && $0.image != nil},"Manual workspace lost Open/Refresh/Commit/Log toolbar actions/icons")
        window.contentView?.layoutSubtreeIfNeeded();window.contentView?.displayIfNeeded()
        await Task.yield()
        try await wait("empty toolbar validation") {items.first?.isEnabled==true && items.dropFirst().allSatisfy{!$0.isEnabled}}
        model.confirmingQuit=true
        try await wait("toolbar Quit ownership") {items.allSatisfy{!$0.isEnabled}}
        model.confirmingQuit=false
        try await wait("toolbar restored") {items.first?.isEnabled==true && items.dropFirst().allSatisfy{!$0.isEnabled}}
        try require(window.styleMask.contains(.resizable) && window.styleMask.contains(.closable) && window.identifier?.rawValue=="workspace","Manual workspace lost stable identity/native controls")
        let oldModels=c.models.count,oldControllers=c.controllers.count
        window.performClose(nil)
        try await wait("workspace close attachment") {model.workspaceWindow==nil && !window.isVisible}
        try require(!model.isRetired,"Ordinary workspace close retired repository owner")
        _=c.delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        try await wait("Dock reopen exact host") {model.workspaceWindow === window && window.isVisible}
        try require(c.scene.storedController === owner && c.models.count==oldModels && c.controllers.count==oldControllers,"Dock reopen duplicated workspace model/controller")
        c.delegate.requestWorkspace()
        try require(c.scene.storedController === owner && model.workspaceWindow === window && c.controllers.count==1,"Explicit Open lost singleton host")
        let root=model.root,baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),hostCount=c.controllers.count
        c.delegate.application(NSApp,open:[FinderRequest(action:.about,paths:[c.folder]).url!])
        try await wait("warm action isolation") {NSApp.windows.contains{!baseline.contains(ObjectIdentifier($0)) && $0.windowController is TurtleGitAboutController}}
        try require(c.delegate.repositoryModel === model && model.root==root && c.controllers.count==hostCount && c.delegate.actionRepositoryModel !== model,"Warm action replaced/adopted workspace owner")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.workspaceLaunchOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        var context:Context?
        do {let value=try Context();context=value;switch CommandLine.arguments[3] {case "cold":try await cold(value);case "workspace":try await workspace(value);case "late":try await late(value);default:throw Failure(description:"Unknown case")};try await value.cleanup();print("PASS: workspace launch \(CommandLine.arguments[3])")}
        catch {let failure=error;do {try await context?.cleanup()}catch{fputs("Cleanup: \(error)\n",stderr)};fputs("\(failure)\n",stderr);exit(1)}
    }
}
