// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func publicationQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));publicationQAOrder(mode,relativeTo:number)}
}
@MainActor @main enum SettingsPublicationRecoveryVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Settings publication \(line): "+message)}}
    static func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Settings transaction did not drain")}
    @MainActor final class Context {
        let suite="TurtleGit.SettingsPublication.QA."+UUID().uuidString,prefs:UserDefaults
        let folder:URL
        var windows:[NSWindow]=[],transactions:[SettingsTransaction]=[]
        var failing=Set<String>(),calls:[String:Int]=[:],afterWrite:((SettingsPublicationChannel)throws->Void)?
        var applied=0
        var intents:SettingsPublicationIntents{.init(defaults:prefs)}
        init(_ name:String)throws {
            prefs=UserDefaults(suiteName:suite)!
            folder=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        }
        func channelURL(_ channel:SettingsPublicationChannel)->URL{
            let name=channel == .cachePersistence ? "status.json":channel == .cacheTray ? "cache-tray-settings.json":"menu-settings.json"
            return folder.appendingPathComponent(name)
        }
        func publish(_ channel:SettingsPublicationChannel,_ write:()throws->Void)throws {
            calls[channel.rawValue,default:0] += 1
            if failing.contains(channel.rawValue){throw Failure(description:"Injected private "+channel.rawValue+" write refusal")}
            try write();try afterWrite?(channel)
        }
        func model()->AdvancedSettingsModel {
            let model=AdvancedSettingsModel(defaults:prefs,publishFinderMenu:{[self] value in try publish(.finderMenu){_=try value.write(to:channelURL(.finderMenu))}},publishCachePersistence:{[self] value in try publish(.cachePersistence){_=try value.write(to:channelURL(.cachePersistence))}},publishCacheTray:{[self] value in try publish(.cacheTray){_=try value.write(to:channelURL(.cacheTray))}})
            model.onApplied={[weak self] in self?.applied += 1};return model
        }
        func owner(_ model:AdvancedSettingsModel)->NSWindow {
            let window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0;windows.append(window);model.attach(to:window);return window
        }
        func transaction(_ model:AdvancedSettingsModel)->SettingsTransaction {
            let transaction=SettingsTransaction();transactions.append(transaction)
            transaction.register("advanced",participant:.init(page:.advanced,modified:{model.modified},validate:{nil},apply:{model.apply();return model.error==nil},cancel:model.cancel));return transaction
        }
        func pending()->Set<String>{Set(SettingsPublicationChannel.allCases.filter{intents.pending($0) != nil}.map(\.rawValue))}
        func clean()async throws {
            transactions.forEach{$0.invalidate()};windows.forEach{$0.close()}
            try await wait{SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0 && GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func recovery()async throws {
        let c=try Context("recovery")
        do {
            c.failing=Set(SettingsPublicationChannel.allCases.map(\.rawValue))
            let model=c.model();_=c.owner(model)
            for(key,value)in[("CacheSave","false"),("CacheTrayIcon","true"),("ShowContextMenuIcons","false")]{try require(model.edit(key,text:value),"Actual Advanced edit refused")}
            let transaction=c.transaction(model);transaction.apply(closeAfter:false)
            try await wait{!transaction.busy && SettingsTransaction.activeApplications==0}
            try require(model.error != nil && c.pending()==Set(SettingsPublicationChannel.allCases.map(\.rawValue)),"Initial failed channels lost durable intents")
            try require(model.modified && transaction.modified && !c.prefs.bool(forKey:"CacheSave") && c.prefs.bool(forKey:"CacheTrayIcon") && !c.prefs.bool(forKey:"ShowContextMenuIcons"),"Accepted local settings or host retry eligibility lost")
            let diagnostic=model.error ?? ""
            try require(SettingsPublicationChannel.allCases.allSatisfy{diagnostic.contains($0.rawValue) || diagnostic.lowercased().contains($0 == .cachePersistence ? "cache persistence":$0 == .cacheTray ? "cache menu":"finder menu")},"Multiple failed channels lost distinct diagnostics")
            let acceptedTokens=SettingsPublicationChannel.allCases.map{c.intents.pending($0)}
            model.error=nil;model.cancel()
            try require(model.modified && transaction.modified && SettingsPublicationChannel.allCases.map{c.intents.pending($0)}==acceptedTokens,"Dismiss/Cancel erased accepted publication debt")
            c.failing=[SettingsPublicationChannel.finderMenu.rawValue]
            let reopened=c.model(),retry=c.transaction(reopened);_=c.owner(reopened)
            try require(reopened.modified && retry.modified,"Reopened Settings host omitted pending-only retry")
            let beforeApplied=c.applied;retry.apply(closeAfter:false);try await wait{!retry.busy && SettingsTransaction.activeApplications==0}
            try require(c.pending()==[SettingsPublicationChannel.finderMenu.rawValue] && reopened.error != nil && reopened.modified,"Partial success cleared another failed channel")
            try require(c.applied==beforeApplied,"Pending-only retry replayed local onApplied effects")
            try require(try FinderCachePersistencePreferences.read(from:c.channelURL(.cachePersistence))==FinderCachePersistencePreferences.from(defaults:c.prefs),"Actual private persistence publication differs")
            try require(FinderCacheTrayPreferences.read(from:c.channelURL(.cacheTray))==FinderCacheTrayPreferences.from(defaults:c.prefs),"Actual private tray publication differs")
            let counts=c.calls;c.failing=[];reopened.error=nil;retry.apply(closeAfter:false);try await wait{!retry.busy && SettingsTransaction.activeApplications==0}
            try require(c.pending().isEmpty && !reopened.modified && !retry.modified && reopened.error==nil,"Successful pending-only host retry did not acknowledge")
            try require(c.calls["cacheTray"]==counts["cacheTray"] && c.calls["cachePersistence"]==counts["cachePersistence"] && c.calls["finderMenu"]==counts["finderMenu"]!+1,"Retry replayed already successful channels")
            try require(FinderMenuSettings.read(from:c.channelURL(.finderMenu))==FinderMenuSettings.from(defaults:c.prefs),"Actual private Finder menu publication differs")
            try await c.clean()
        }catch{try? await c.clean();throw error}
    }
    static func supersession()async throws {
        let c=try Context("supersession")
        do {
            c.failing=[SettingsPublicationChannel.finderMenu.rawValue]
            let model=c.model();_=c.owner(model);try require(model.edit("ShowContextMenuIcons",text:"false"),"Finder icon edit refused");model.apply()
            let old=try unwrap(c.intents.pending(.finderMenu),"Missing old Finder intent")
            c.failing=[];var newer:String?
            c.afterWrite={channel in
                guard channel == .finderMenu else{return};c.afterWrite=nil
                var peer=FinderMenuSettings.from(defaults:c.prefs);peer.hideForUnversioned=true
                try peer.save(to:c.prefs);try AppLanguageChoice.save("de",to:c.prefs)
                newer=c.intents.request(.finderMenu)
            }
            let retry=c.model();_=c.owner(retry)
            let host=c.transaction(retry);var closed=false
            host.completed={closeAfter in if closeAfter{closed=true}}
            host.apply(closeAfter:true);try await wait{!host.busy && SettingsTransaction.activeApplications==0}
            try require(!closed && host.error != nil && retry.error != nil,"Superseded publication falsely completed Close-after-Apply")
            try require(newer != nil && newer != old && c.intents.pending(.finderMenu)==newer && retry.modified,"Stale completion cleared newer accepted Finder payload")
            try require(AppLanguageChoice.selected(in:c.prefs)=="de" && FinderMenuSettings.from(defaults:c.prefs).hideForUnversioned,"Retry overwrote reentrant accepted language/menu settings")
            retry.error=nil;host.apply(closeAfter:true);try await wait{!host.busy && SettingsTransaction.activeApplications==0}
            try require(closed && host.error==nil,"Current accepted retry failed to finish host Apply")
            try require(c.intents.pending(.finderMenu)==nil && !retry.modified && FinderMenuSettings.read(from:c.channelURL(.finderMenu))==FinderMenuSettings.from(defaults:c.prefs),"Current full Finder payload did not publish/acknowledge")
            // A new accepted request with equal bytes is still a distinct owner.
            let first=c.intents.request(.cacheTray),second=c.intents.request(.cacheTray)
            try require(!c.intents.complete(.cacheTray,request:first) && c.intents.pending(.cacheTray)==second,"Equal-value stale request erased newer intent")
            retry.apply();try require(c.intents.pending(.cacheTray)==nil,"Already-open Advanced failed to detect peer pending channel")
            try await c.clean()
        }catch{try? await c.clean();throw error}
    }
    static func peerPages()async throws {
        let c=try Context("peer-pages")
        do {
            c.prefs.set(false,forKey:"ShowContextMenuIcons")
            var accepted=FinderMenuSettings.from(defaults:c.prefs);accepted.hideForUnversioned=true;try accepted.save(to:c.prefs)
            _=c.intents.request(.finderMenu)
            let general=GeneralGitSettingsModel(preferences:c.prefs);general.activate();await Task.yield()
            var notifications=0
            general.notifyFinderLanguage={notifications += 1}
            general.publishFinderLanguage={language in
                var settings=FinderMenuSettings.from(defaults:c.prefs);settings.language=language
                _=try settings.write(to:c.channelURL(.finderMenu));return true
            }
            general.chooseLanguage("de")
            try require(general.languageModified && general.applyLanguage(),"Actual General language Apply refused")
            try require(c.intents.pending(.finderMenu)==nil && AppLanguageChoice.selected(in:c.prefs)=="de" && notifications==1,"General complete publication failed to acknowledge accepted retry")
            let published=FinderMenuSettings.read(from:c.channelURL(.finderMenu))
            try require(!published.showIcons && published.hideForUnversioned && published.language=="de","Language publication lost current menu/icon settings")
            _=c.intents.request(.finderMenu)
            let menu=FinderContextMenuSettingsModel(defaults:c.prefs,publish:{settings in _=try settings.write(to:c.channelURL(.finderMenu));return true},notify:{notifications += 1})
            menu.binding(\.excludedPaths,context:menu.context(.primary)).wrappedValue=c.folder.path
            try require(menu.modified && menu.apply(),"Actual Context menu Apply refused")
            try require(c.intents.pending(.finderMenu)==nil && notifications==2 && FinderMenuSettings.read(from:c.channelURL(.finderMenu))==FinderMenuSettings.from(defaults:c.prefs),"Context complete payload failed to acknowledge or preserve language/icons")
            // Publish-beforelocal failures remain editable drafts, not accepted intents.
            let refused=FinderContextMenuSettingsModel(defaults:c.prefs,publish:{_ in throw Failure(description:"Private menu refusal")},notify:{notifications += 1})
            refused.binding(\.hideForUnversioned,context:refused.context(.primary)).wrappedValue=false
            let before=FinderMenuSettings.from(defaults:c.prefs)
            try require(!refused.apply() && refused.modified && FinderMenuSettings.from(defaults:c.prefs)==before && c.intents.pending(.finderMenu)==nil,"Unaccepted Context failure changed accepted settings")
            refused.cancel();try require(!refused.modified && FinderMenuSettings.from(defaults:c.prefs)==before,"Cancel restored an unaccepted draft into persisted menu")
            general.chooseLanguage("en");var raceLanguage=true
            general.publishFinderLanguage={language in
                var settings=FinderMenuSettings.from(defaults:c.prefs);settings.language=language
                _=try settings.write(to:c.channelURL(.finderMenu))
                if raceLanguage {raceLanguage=false;var peer=FinderMenuSettings.from(defaults:c.prefs);peer.clipboardTransfers=false;try peer.save(to:c.prefs)}
                return true
            }
            try require(!general.applyLanguage() && general.languageModified && AppLanguageChoice.selected(in:c.prefs)=="de" && !FinderMenuSettings.from(defaults:c.prefs).clipboardTransfers && c.intents.pending(.finderMenu) != nil,"Reentrant language publication overwrote peer accepted menu or accepted stale draft")
            try require(general.applyLanguage() && c.intents.pending(.finderMenu)==nil && AppLanguageChoice.selected(in:c.prefs)=="en" && !FinderMenuSettings.read(from:c.channelURL(.finderMenu)).clipboardTransfers,"Language retry lost newer accepted menu payload")
            var raceMenu=true
            let concurrent=FinderContextMenuSettingsModel(defaults:c.prefs,publish:{settings in
                _=try settings.write(to:c.channelURL(.finderMenu))
                if raceMenu {raceMenu=false;var peer=FinderMenuSettings.from(defaults:c.prefs);peer.hideForUnversioned=false;try peer.save(to:c.prefs)}
                return true
            },notify:{notifications += 1})
            concurrent.binding(\.excludedPaths,context:concurrent.context(.primary)).wrappedValue=c.folder.appendingPathComponent("new accepted exclusion").path
            try require(!concurrent.apply() && concurrent.modified && !FinderMenuSettings.from(defaults:c.prefs).hideForUnversioned && c.intents.pending(.finderMenu) != nil,"Reentrant Context publication overwrote peer accepted fields")
            try require(concurrent.apply() && !concurrent.modified && c.intents.pending(.finderMenu)==nil && FinderMenuSettings.read(from:c.channelURL(.finderMenu))==FinderMenuSettings.from(defaults:c.prefs),"Context retry lost newer accepted language/menu payload")
            general.suspend();try await c.clean()
        }catch{try? await c.clean();throw error}
    }
    static func retired()async throws {
        let c=try Context("retired")
        do {
            let model=c.model(),window=c.owner(model)
            for(key,value)in[("CacheSave","false"),("CacheTrayIcon","true"),("ShowContextMenuIcons","false")]{try require(model.edit(key,text:value),"Retirement edit refused")}
            c.afterWrite={_ in c.afterWrite=nil;window.close()}
            model.apply()
            try require(c.calls.values.reduce(0,+)==1 && !c.pending().isEmpty,"Retired publisher continued other channels or lost retry debt")
            let tokens=SettingsPublicationChannel.allCases.map{c.intents.pending($0)}
            model.apply();try require(c.calls.values.reduce(0,+)==1 && SettingsPublicationChannel.allCases.map{c.intents.pending($0)}==tokens,"Retired model revived publication")
            let appliedBefore=c.applied
            let fresh=c.model();_=c.owner(fresh);fresh.apply()
            try require(c.applied==appliedBefore,"Retired pending-only retry replayed local Apply effects")
            try require(c.pending().isEmpty && !fresh.modified,"Fresh owner could not settle retired accepted intents")
            try await c.clean()
        }catch{try? await c.clean();throw error}
    }
    static func retiredSupersessionAndLocalAcceptance()async throws {
        for throwsAfterWrite in [false,true] {
            let c=try Context(throwsAfterWrite ? "retired-late-throw":"retired-late-return")
            do {
                let model=c.model(),window=c.owner(model)
                for(key,value)in[("CacheSave","false"),("CacheTrayIcon","true"),("ShowContextMenuIcons","false")]{try require(model.edit(key,text:value),"Late retirement edit refused")}
                c.afterWrite={channel in
                    c.afterWrite=nil
                    try require(channel == .cachePersistence,"Unexpected first publication channel")
                    c.prefs.set(true,forKey:"CacheSave");let newer=c.intents.request(.cachePersistence)
                    _=try FinderCachePersistencePreferences(cacheSave:true).write(to:c.channelURL(.cachePersistence))
                    try require(c.intents.complete(.cachePersistence,request:newer),"Newer publication did not complete")
                    _=try FinderCachePersistencePreferences(cacheSave:false).write(to:c.channelURL(.cachePersistence))
                    window.close()
                    if throwsAfterWrite{throw Failure(description:"Old publication failed after its stale write")}
                }
                model.apply()
                try require(c.intents.pending(.cachePersistence) != nil && c.prefs.bool(forKey:"CacheSave") && c.calls.values.reduce(0,+)==1 && model.error==nil,"Retired Advanced lost latest intent, continued channels or published late UI error")
                let fresh=c.model();fresh.apply();try require(c.pending().isEmpty && !fresh.modified,"Advanced could not recover late retired write")
                let general=GeneralGitSettingsModel(preferences:c.prefs);general.activate();await Task.yield();general.chooseLanguage("de")
                var languageNotifies=0;general.notifyFinderLanguage={languageNotifies += 1}
                general.publishFinderLanguage={language in
                    var old=FinderMenuSettings.from(defaults:c.prefs);old.language=language
                    try AppLanguageChoice.save("en",to:c.prefs);let newer=c.intents.request(.finderMenu)
                    _=try FinderMenuSettings.from(defaults:c.prefs).write(to:c.channelURL(.finderMenu));try require(c.intents.complete(.finderMenu,request:newer),"Newer language publication did not complete")
                    _=try old.write(to:c.channelURL(.finderMenu));general.suspend()
                    if throwsAfterWrite{throw Failure(description:"Old language write failed late")};return true
                }
                try require(!general.applyLanguage() && AppLanguageChoice.selected(in:c.prefs)=="en" && c.intents.pending(.finderMenu) != nil && languageNotifies==0 && general.error==nil,"Retired General lost current intent or updated late UI")
                general.publishFinderLanguage=nil
                let languageRetry=c.model();languageRetry.apply();try require(c.pending().isEmpty && FinderMenuSettings.read(from:c.channelURL(.finderMenu)).language=="en","Retired language retry did not publish latest accepted payload")
                let menuWindow=NSWindow(contentRect:.init(x:-24000,y:-24000,width:400,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);menuWindow.isReleasedWhenClosed=false;menuWindow.alphaValue=0;c.windows.append(menuWindow)
                var menuNotifies=0
                let menu=FinderContextMenuSettingsModel(defaults:c.prefs,publish:{old in
                    var peer=FinderMenuSettings.from(defaults:c.prefs);peer.clipboardTransfers=false;try peer.save(to:c.prefs)
                    let newer=c.intents.request(.finderMenu);_=try peer.write(to:c.channelURL(.finderMenu));try require(c.intents.complete(.finderMenu,request:newer),"Newer context publication did not complete")
                    _=try old.write(to:c.channelURL(.finderMenu));menuWindow.close()
                    if throwsAfterWrite{throw Failure(description:"Old context write failed late")};return true
                },notify:{menuNotifies += 1})
                menu.attach(to:menuWindow,page:.primary)
                menu.binding(\.hideForUnversioned,context:menu.context(.primary)).wrappedValue=true
                try require(!menu.apply() && !FinderMenuSettings.from(defaults:c.prefs).clipboardTransfers && c.intents.pending(.finderMenu) != nil && menuNotifies==0 && menu.error==nil,"Retired Context lost accepted peer intent or updated late UI")
                let menuRetry=c.model();menuRetry.apply();try require(c.pending().isEmpty && !FinderMenuSettings.read(from:c.channelURL(.finderMenu)).clipboardTransfers,"Retired Context retry lost current accepted fields")
                try await c.clean()
            }catch{try? await c.clean();throw error}
        }
        let c=try Context("accepted-local-only")
        do {
            let general=GeneralGitSettingsModel(preferences:c.prefs);general.activate();await Task.yield();general.chooseLanguage("de");general.publishFinderLanguage={_ in false};general.notifyFinderLanguage={preconditionFailure("Unavailable shared publisher notified Finder")}
            try require(c.pending().isEmpty && general.applyLanguage() && !general.languageModified && AppLanguageChoice.selected(in:c.prefs)=="de" && c.intents.pending(.finderMenu) != nil,"Accepted local language did not retain Finder retry")
            let languageRetry=c.model();languageRetry.apply();try require(c.pending().isEmpty && FinderMenuSettings.read(from:c.channelURL(.finderMenu)).language=="de","Local-only language retry failed")
            let menu=FinderContextMenuSettingsModel(defaults:c.prefs,publish:{_ in false},notify:{preconditionFailure("Unavailable shared menu notified Finder")})
            menu.binding(\.hideForUnversioned,context:menu.context(.primary)).wrappedValue=true
            try require(c.pending().isEmpty && menu.apply() && !menu.modified && FinderMenuSettings.from(defaults:c.prefs).hideForUnversioned && c.intents.pending(.finderMenu) != nil,"Accepted local Context choice did not retain Finder retry")
            let menuRetry=c.model();menuRetry.apply();try require(c.pending().isEmpty && FinderMenuSettings.read(from:c.channelURL(.finderMenu))==FinderMenuSettings.from(defaults:c.prefs),"Local-only menu retry lost current accepted language/payload")
            general.suspend();try await c.clean()
        }catch{try? await c.clean();throw error}
    }
    final class StartupGate:@unchecked Sendable {
        private let lock=NSLock(),semaphore=DispatchSemaphore(value:0)
        private var stored:Bool?
        var captured:Bool?{lock.lock();defer{lock.unlock()};return stored}
        func hold(_ value:FinderCachePersistencePreferences){lock.lock();stored=value.cacheSave;lock.unlock();semaphore.wait()}
        func release(){semaphore.signal()}
    }
    static func startup()async throws {
        for alreadyCompleted in [false,true] {
            let c=try Context(alreadyCompleted ? "startup-completed-newer":"startup-pending-newer"),gate=StartupGate()
            let access=try RepositoryAccessStore(storageURL:c.folder.appendingPathComponent("private-grants.json"))
            let manager=FinderWatchManager(permissions:access,cache:nil,requireScope:false,notify:{})
            let status=c.channelURL(.cachePersistence);var gitRequests=0
            let model=RepositoryModel(startMonitoring:true,initializePreferences:true,repositoryFactory:{_ in gitRequests += 1;throw Failure(description:"Empty private startup attempted repository access")},snapshotStore:FinderSnapshotStore(url:status),finderWatches:manager,savedAccessStore:access,comparisonMarks:WorkingComparisonMarkStore(storageURL:c.folder.appendingPathComponent("private-comparison.json")),cachePersistenceDefaults:c.prefs,publishCachePersistence:{value in gate.hold(value);_=try value.write(to:status)},prepareGitConfigurationReads:{})
            do {
                // The worker must capture the choice at actual start, after init.
                c.prefs.set(false,forKey:"CacheSave");model.startWorkspaceServices()
                try await wait{gate.captured != nil}
                try require(gate.captured==false && model.workspaceServicesPending,"Startup used initializer preference snapshot or lost actual worker ownership")
                c.prefs.set(true,forKey:"CacheSave");let newer=c.intents.request(.cachePersistence)
                if alreadyCompleted {
                    let page=c.model();page.apply()
                    try require(c.intents.pending(.cachePersistence)==nil && !page.modified && page.error==nil,"Newer accepted page did not complete while old startup was held")
                    let current=try FinderCachePersistencePreferences.read(from:status)
                    try require(current.cacheSave,"Newer accepted publication bytes missing before old completion")
                }
                gate.release();await model.settleWorkspaceServices()
                try require(!model.workspaceServicesPending && c.prefs.bool(forKey:"CacheSave") && c.intents.pending(.cachePersistence) != nil,"Old startup erased latest accepted retry intent")
                if !alreadyCompleted{try require(c.intents.pending(.cachePersistence)==newer,"Old startup replaced newer pending identity")}
                let written=try FinderCachePersistencePreferences.read(from:status)
                try require(!written.cacheSave,"Held worker did not perform actual captured old private write")
                let page=c.model();try require(page.modified,"Reopened Advanced missed stale startup publication")
                page.apply()
                let repaired=try FinderCachePersistencePreferences.read(from:status)
                try require(repaired.cacheSave && c.pending().isEmpty && !page.modified && page.error==nil && c.applied==0 && gitRequests==0,"Pending-only current startup retry lost payload or replayed local/Git effects")
                model.stopMonitoringForTermination();await model.shutdownFinderPublication();await manager.shutdown();try await c.clean()
            }catch{gate.release();model.stopMonitoringForTermination();await model.settleWorkspaceServices();await model.shutdownFinderPublication();await manager.shutdown();try? await c.clean();throw error}
        }
        // An ordinary successful startup acknowledges all three exact channels.
        let c=try Context("startup-success"),access=try RepositoryAccessStore(storageURL:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("success-grants.json"))
        let manager=FinderWatchManager(permissions:access,cache:nil,requireScope:false,notify:{})
        let model=RepositoryModel(startMonitoring:true,initializePreferences:true,repositoryFactory:{_ in throw Failure(description:"Empty startup attempted Git")},snapshotStore:FinderSnapshotStore(url:c.channelURL(.cachePersistence)),finderWatches:manager,savedAccessStore:access,comparisonMarks:WorkingComparisonMarkStore(storageURL:c.folder.appendingPathComponent("private-comparison.json")),cachePersistenceDefaults:c.prefs,prepareGitConfigurationReads:{})
        do{model.startWorkspaceServices();await model.settleWorkspaceServices();try require(c.pending().isEmpty && !model.workspaceServicesPending,"Successful startup retained publication debt");model.stopMonitoringForTermination();await model.shutdownFinderPublication();await manager.shutdown();try await c.clean()}
        catch{model.stopMonitoringForTermination();await model.settleWorkspaceServices();await model.shutdownFinderPublication();await manager.shutdown();try? await c.clean();throw error}
    }
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let a=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let b=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.publicationQAOrder(_:relativeTo:))){method_exchangeImplementations(a,b)}
        do {
            try RetainedAdvancedSettingsVerification.run()
            try await recovery();try await supersession();try await peerPages();try await retired();try await retiredSupersessionAndLocalAcceptance();try await startup()
            try await wait{SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0}
            print("PASS Settings publication recovery: durable channel retry/partial success, actual SettingsTransaction eligibility, reopen/Cancel, current payload/peer acknowledgements, supersession and retirement; private files/preferences and owned lifecycle only")
        }catch{fputs("Settings publication recovery failed: \(error)\n",stderr);exit(1)}
    }
}
