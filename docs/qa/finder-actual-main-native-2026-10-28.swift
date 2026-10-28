// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Carbon
import ObjectiveC
import Darwin
import TurtleGitCore

private final class ColdMainBookmarks:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data{Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool{true}
    func stopAccessing(_ url:URL){}
}
private extension NSWindow {
    @objc func coldMainHiddenOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));coldMainHiddenOrder(mode,relativeTo:number)
    }
}
private extension TurtleGitApplicationDelegate {
    @objc dynamic func coldMainPrivateConfiguration(_ notification:Notification) {
        // Keep the production outer main and real delegate lifecycle intact.
        // Its existing instance DI selects only private fixture authority.
        configureGeneralApplication={ [weak monitor=FinderActualMainVerification.monitor] in monitor?.configure($0) }
        coldMainPrivateConfiguration(notification)
    }
}
/// A synchronous entry intentionally calls the production outer App.main(). The
/// shared native receiver must not wrap this case in a second async NSApp.run.
@MainActor @main enum FinderActualMainVerification {
    @MainActor final class Monitor {
        let began=ProcessInfo.processInfo.systemUptime
        let repository:URL,preferences:UserDefaults,store:FinderActionHandoff,model:RepositoryModel
        let index:Data,working:Data,head:Data
        let scene=WorkspaceSceneOwner.shared
        var delegate:TurtleGitApplicationDelegate?,settings:SettingsPresentationService?
        var timer:Timer?,observer:NSObjectProtocol?
        var entryAt:Double?,configuredAt:Double?,shownAt:Double?,loadedAt:Double?,consumed=0,closing=false,finished=false,rawDelivered=false,repeatedDelivery=false
        var commitOwner:ObjectIdentifier?
        init()throws {
            let environment=ProcessInfo.processInfo.environment
            guard let path=environment["TURTLEGIT_QA_REPOSITORY"],let engine=environment["TURTLEGIT_QA_GIT"],let handoffs=environment["TURTLEGIT_QA_HANDOFFS"],let archive=environment["TURTLEGIT_QA_ARCHIVE"] else{throw POSIXError(.EINVAL)}
            repository=URL(fileURLWithPath:path);store=FinderActionHandoff(root:URL(fileURLWithPath:handoffs))
            preferences=UserDefaults(suiteName:"TurtleGit.ColdMain."+UUID().uuidString)!
            for (key,value) in [("UseLibgit2",false),("EnableGravatar",false),("Autocompletion",false),("HintStagingMode",true),("NoSounds",true)]{preferences.set(value,forKey:key)}
            preferences.set(1,forKey:"CommitMergeHint");preferences.set(7,forKey:"NothingToCommitShowUnversioned")
            let provider=ColdMainBookmarks(),access=try RepositoryAccessStore(storageURL:URL(fileURLWithPath:archive),provider:provider)
            _=try access.remember(repository)
            let git=URL(fileURLWithPath:engine)
            model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:access,comparisonMarks:WorkingComparisonMarkStore(storageURL:URL(fileURLWithPath:archive).deletingLastPathComponent().appendingPathComponent("private-mark.json")))
            model.requiresRepositoryScope=true;model.repositoryBookmarkProvider=provider;model.fileComparisonPreferences=preferences
            index=try Data(contentsOf:repository.appendingPathComponent(".git/index"))
            working=try Data(contentsOf:repository.appendingPathComponent("tracked.txt"))
            head=try Data(contentsOf:repository.appendingPathComponent(".git/refs/heads/main"))
        }
        func configure(_ delegate:TurtleGitApplicationDelegate) {
            configuredAt=ProcessInfo.processInfo.systemUptime;self.delegate=delegate
            scene.configure(applicationDelegate:delegate)
            delegate.makeStandaloneWorkspace={ [model] in model }
            delegate.makeStandaloneAppearance={ [preferences] in AppAppearance(preferences:preferences) }
            delegate.configureStandaloneServices={ [weak self] model,appearance in
                let service=SettingsPresentationService();self?.settings=service;service.install(workspace:model,appearance:appearance)
            }
            delegate.activateStandaloneApplication={}
            delegate.consumeFinderAction={ [weak self] delivery in
                guard let self else{throw POSIXError(.ECANCELED)}
                self.consumed+=1;return try self.store.consume(delivery)
            }
        }
        func dispatchDuplicate()throws {
            guard !rawDelivered,let delivery=FinderActionDelivery.parse(arguments:Array(CommandLine.arguments.dropFirst())) else{return}
            rawDelivered=true
            try dispatchURL(delivery.url)
        }
        func dispatchURL(_ url:URL)throws {
            let event=NSAppleEventDescriptor(eventClass:AEEventClass(kInternetEventClass),eventID:AEEventID(kAEGetURL),targetDescriptor:NSAppleEventDescriptor(processIdentifier:ProcessInfo.processInfo.processIdentifier),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string:url.absoluteString),forKeyword:AEKeyword(keyDirectObject))
            let reply=NSAppleEventDescriptor.null()
            guard let raw=event.aeDesc,let answer=reply.aeDesc else{throw POSIXError(.ENOMEM)}
            var context:UInt8=0
            withUnsafeMutablePointer(to:&context){_ = NSAppleEventManager.shared().dispatchRawAppleEvent(raw,withRawReply:UnsafeMutablePointer(mutating:answer),handlerRefCon:UnsafeMutableRawPointer($0))}
        }
        func fail(_ message:String)->Never {
            delegate?.retireInboundURLBridge();delegate?.retireFinderServices();model.stopMonitoringForTermination()
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.close()}
            fputs("Actual SwiftUI cold main failed: "+message+"\n",stderr);fflush(stderr);exit(1)
        }
        func poll() {
            guard !finished else{return}
            if ProcessInfo.processInfo.systemUptime-began>20 {fail("Timed out; configured=\(configuredAt != nil),consumed=\(consumed),windows=\(NSApp.windows.count)")}
            if closing {
                guard RepositoryModel.activeFinderAuthorityPreparations==0,CommitWindowModel.activeReloads==0,CommitWindowModel.activeMetadataOperations==0,CommitWindowModel.activePreferenceOperations==0,!model.hasPendingRepositoryWork,NSApp.windows.allSatisfy({!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil}) else{return}
                finish();return
            }
            guard let child=NSApp.windows.compactMap({$0.windowController as? CommitWindowController}).first,child.window?.isVisible==true else{return}
            if shownAt==nil{shownAt=ProcessInfo.processInfo.systemUptime}
            guard !child.model.busy,child.model.fileListAvailable,child.model.visibleEntries.contains(where:{GitReferenceName.equal($0.path,"tracked.txt")}) else{return}
            if loadedAt==nil{loadedAt=ProcessInfo.processInfo.systemUptime}
            if !repeatedDelivery {
                do {
                    try dispatchDuplicate()
                    guard consumed==1,rawDelivered else{fail("Original argv/GetURL receipt executed twice")}
                    commitOwner=ObjectIdentifier(child)
                    let again=try store.publish(FinderRequest(action:.commit,paths:[repository]))
                    repeatedDelivery=true;try dispatchURL(again.url)
                }catch{fail("Raw duplicate/independent event dispatch failed")}
                return
            }
            guard consumed==2,!model.hasPendingRepositoryWork else{return}
            guard commitOwner==ObjectIdentifier(child),NSApp.windows.compactMap({$0.windowController as? CommitWindowController}).count==1,scene.storedController==nil,model.workspaceWindow==nil,child.model.error==nil else{fail("Independent raw event lost current Commit owner, opened workspace, or failed")}
            closing=true;child.close();delegate?.retireInboundURLBridge();delegate?.retireFinderServices();delegate?.retireMenuImageVisibility();model.stopMonitoringForTermination();settings?.controller?.close()
            for window in NSApp.windows{window.close();window.orderOut(nil)}
        }
        func finish() {
            do {
                let afterIndex=try Data(contentsOf:repository.appendingPathComponent(".git/index")),afterWorking=try Data(contentsOf:repository.appendingPathComponent("tracked.txt")),afterHead=try Data(contentsOf:repository.appendingPathComponent(".git/refs/heads/main"))
                guard afterIndex==index,afterWorking==working,afterHead==head else{fail("Cold launch changed HEAD/index/working bytes")}
                finished=true;timer?.invalidate();if let observer{NotificationCenter.default.removeObserver(observer)}
                let phases:[String:Any]=["scope":"production TurtleGitApplication.main plus real SwiftUI App.main in private process; receipt argv, own raw GetURL duplicate and independent repeat", "configure_seconds":(configuredAt ?? began)-(entryAt ?? began),"window_seconds":(shownAt ?? began)-(entryAt ?? began),"changes_seconds":(loadedAt ?? began)-(entryAt ?? began),"consumptions":consumed,"workspace_windows":0,"repository_bytes_unchanged":true]
                let bytes=try JSONSerialization.data(withJSONObject:phases,options:[.sortedKeys]);print("COLD_MAIN_TIMING "+String(decoding:bytes,as:UTF8.self));print("PASS: actual SwiftUI cold Finder Commit main")
                fflush(stdout);exit(0)
            }catch{fail("Could not validate private repository bytes")}
        }
    }
    static var monitor:Monitor?
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if ProcessInfo.processInfo.environment["TURTLEGIT_QA_PUBLISH"] == "1" {
            do {
                let environment=ProcessInfo.processInfo.environment
                guard let root=environment["TURTLEGIT_QA_HANDOFFS"],let repository=environment["TURTLEGIT_QA_REPOSITORY"] else{throw POSIXError(.EINVAL)}
                let delivery=try FinderActionHandoff(root:URL(fileURLWithPath:root)).publish(FinderRequest(action:.commit,paths:[URL(fileURLWithPath:repository)]))
                print("COLD_CAPABILITY "+delivery.url.absoluteString);fflush(stdout);exit(0)
            }catch{fputs("Private capability publication failed: \(error)\n",stderr);exit(1)}
        }
        guard FinderActionDelivery.parse(arguments:Array(CommandLine.arguments.dropFirst())) != nil else{fputs("Actual main needs valid receipt argv\n",stderr);exit(1)}
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.coldMainHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        do {
            let value=try Monitor();monitor=value
            let willFinish=class_getInstanceMethod(TurtleGitApplicationDelegate.self,#selector(TurtleGitApplicationDelegate.applicationWillFinishLaunching(_:)))!,privateConfiguration=class_getInstanceMethod(TurtleGitApplicationDelegate.self,#selector(TurtleGitApplicationDelegate.coldMainPrivateConfiguration(_:)))!
            method_exchangeImplementations(willFinish,privateConfiguration)
            value.observer=NotificationCenter.default.addObserver(forName:NSApplication.didFinishLaunchingNotification,object:nil,queue:.main){ [weak value] _ in
                MainActor.assumeIsolated {DispatchQueue.main.async{try? value?.dispatchDuplicate()}}
            }
            value.timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true){ [weak value] _ in MainActor.assumeIsolated{value?.poll()} }
            value.entryAt=ProcessInfo.processInfo.systemUptime
            TurtleGitApplication.main()
            value.fail("Production App.main returned before owned result")
        }catch{fputs("Actual main fixture setup failed: \(error)\n",stderr);exit(1)}
    }
}
