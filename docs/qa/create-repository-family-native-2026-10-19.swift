import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum CreateRepositoryFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws {for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:message)}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor final class Questions {
        var entries:[(CreateRepositoryQuestion,NSAlert,(NSApplication.ModalResponse)->Void)]=[]
        var last:(CreateRepositoryQuestion,NSAlert,(NSApplication.ModalResponse)->Void)? {entries.last}
        func install(_ owner:CreateRepositoryWindowController) {
            owner.presentQuestion={ [self] kind,alert,window,reply in
                entries.append((kind,alert,reply));alert.window.alphaValue=0
                alert.beginSheetModal(for:window,completionHandler:reply)
            }
        }
    }
    static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.CreateResult."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"FullRowSelect");prefs.set(true,forKey:"FullPathInTitle")
        var owned:[CreateRepositoryWindowController]=[]
        var releaseHeld:(()->Void)?
        defer {releaseHeld?();owned.forEach{$0.close()};prefs.removePersistentDomain(forName:suite)}
        func make(_ name:String)throws->CreateRepositoryWindowController {
            let folder=base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let owner=CreateRepositoryWindowController(folder:folder,access:RepositoryAccessLease(url:base),preferences:prefs)
            owner.model.executable=git;owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
            owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.showWindow(nil);owned.append(owner);return owner
        }
        // Source bare default, native Abort priority and actual answer/detach.
        do {
            let owner=try make("abort.git"),q=Questions();q.install(owner)
            try Data("keep\n".utf8).write(to:owner.model.folder.appendingPathComponent("keep"))
            var closes=0;owner.onClosed={closes += 1};owner.model.prepare()
            try require(owner.model.bare && owner.model.presentationPreferences === prefs,"Init lost bare default/captured preferences")
            owner.model.initialize();try await wait("Occupied bare warning not presented"){q.last != nil}
            let question=q.last!
            try require(question.0 == .warning(.nonemptyBare) && question.1.buttons.map{$0.title} == ["Abort","Proceed"],"Wrong source Init warning/order")
            try require(question.1.window.defaultButtonCell === (question.1.buttons[0].cell as? NSButtonCell),"Init Abort is not native default")
            try require(!owner.windowShouldClose(owner.window!) && owner.model.asking,"Warning released Init owner early")
            question.1.buttons[0].performClick(nil)
            try await wait("Init Abort did not drain question/owner"){closes==1 && owner.questionWindow==nil && owner.window?.attachedSheet==nil}
            question.2(.alertSecondButtonReturn)
            try require(closes==1 && !owner.model.completed && (try FileManager.default.contentsOfDirectory(atPath:owner.model.folder.path)) == ["keep"],"Late Proceed after Abort initialized a repository")
        }
        // Inject classification only to exercise the source special-folder alert privately.
        do {
            let owner=try make("special-warning"),q=Questions();q.install(owner)
            owner.model.warningsForFolder={_,_ in [.specialFolder]}
            var closes=0;owner.onClosed={closes += 1};owner.model.prepare()
            try await wait("Special-folder preparation warning missing"){q.last != nil}
            try require(q.last!.0 == .warning(.specialFolder) && !owner.model.ready,"Special-folder warning did not precede ready/init")
            owner.model.initialize();try require(!owner.model.hasPendingWork,"Init started before special-folder approval")
            q.last!.1.buttons[0].performClick(nil);try await wait("Special-folder Abort did not close"){closes==1}
            try require(try FileManager.default.contentsOfDirectory(atPath:owner.model.folder.path).isEmpty,"Special-folder Abort changed destination")
        }
        // Accepted bare snapshot is immutable; actual init determines repository kind.
        do {
            let owner=try make("proceed.git"),q=Questions();q.install(owner)
            try Data("preserved\n".utf8).write(to:owner.model.folder.appendingPathComponent("keep"))
            var closes=0,initialized=0,bareResult:Bool?
            owner.onClosed={closes += 1};owner.model.onInitialized={_,_,bare,_ in initialized += 1;bareResult=bare}
            owner.model.prepare();let context=owner.model.formContext,binding=owner.model.bareBinding(context)
            owner.model.initialize();try await wait("Proceed warning missing"){q.last != nil}
            binding.wrappedValue=false
            try require(owner.model.bare,"Stale bare binding changed accepted warning snapshot")
            let warning=q.last!;warning.1.buttons[1].performClick(nil)
            try await wait("Init success was not presented"){owner.model.completed && q.last?.0 == .success && !owner.model.hasPendingWork}
            try require(initialized==1 && bareResult==true && owner.model.confirmingSuccess && closes==0,"Actual bare completion/adoption acknowledgement lost")
            try require(try await GitRepository(root:owner.model.folder,executable:git).isBare(),"Init did not create bare repository")
            try require(try Data(contentsOf:owner.model.folder.appendingPathComponent("keep")) == Data("preserved\n".utf8),"Init replaced existing file")
            warning.2(.alertSecondButtonReturn)
            try require(initialized==1 && owner.questionWindow != nil,"Duplicate warning affected success question")
            q.last!.1.buttons[0].performClick(nil)
            try await wait("Success OK did not release actual Init owner"){closes==1 && owner.questionWindow==nil && owner.window?.attachedSheet==nil}
        }
        // Error acknowledgement leaves the options editable for a fresh retry.
        do {
            let owner=try make("retry"),q=Questions();q.install(owner)
            var attempts=0,closes=0
            owner.onClosed={closes += 1}
            owner.model.initializeOperation={repo,folder,bare,warnings,token in
                attempts += 1
                if attempts==1 {throw GitFailure(arguments:["init"],code:17,message:"controlled init failure")}
                return try await repo.initialize(at:folder,bare:bare,confirmedWarnings:warnings,cancellation:token)
            }
            owner.model.prepare();let stale=owner.model.bareBinding(owner.model.formContext)
            owner.model.initialize();try await wait("Init error question missing"){owner.model.confirmingError && owner.questionWindow != nil}
            guard case .error(let message)=q.last!.0 else{throw Failure(description:"Init failed without error question")}
            try require(message.contains("controlled init failure") && !owner.model.canClose && !owner.model.completed,"Init error ownership/details lost")
            q.last!.1.buttons[0].performClick(nil)
            try await wait("Init error did not release for retry"){owner.model.canEditForm && owner.questionWindow==nil}
            stale.wrappedValue=true;try require(!owner.model.bare,"Pre-error form callback became valid after error acknowledgement")
            owner.model.initialize();try await wait("Init retry did not complete"){owner.model.completed && q.last?.0 == .success}
            try require(attempts==2 && closes==0,"Init retry repeated or closed before acknowledgement")
            q.last!.1.buttons[0].performClick(nil);try await wait("Retried Init did not close"){closes==1}
            try require(!(try await GitRepository(root:owner.model.folder,executable:git).isBare()),"Init retry used stale bare setting")
        }
        // Forced native close retains queued actual work and Quit ownership until it drains.
        do {
            let owner=try make("held"),q=Questions();q.install(owner)
            var entered=false,reply:CheckedContinuation<Void,Never>?,closed=0,initialized=0
            owner.onClosed={closed += 1};owner.model.onInitialized={_,_,_,_ in initialized += 1}
            owner.model.initializeOperation={repo,folder,bare,warnings,token in
                entered=true;await withCheckedContinuation{reply=$0}
                return try await repo.initialize(at:folder,bare:bare,confirmedWarnings:warnings,cancellation:token)
            }
            releaseHeld={reply?.resume();reply=nil}
            owner.model.prepare();owner.model.initialize()
            try require(owner.model.hasPendingWork && owner.model.busy,"Init did not reserve queued worker synchronously")
            try await wait("Init held worker missing"){entered}
            owner.close()
            try require(owner.model.retired && owner.model.hasPendingWork && owner.model.busy && closed==0,"Forced Init close faked worker drain")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired Init work lost Quit ownership")
            reply?.resume();reply=nil;releaseHeld=nil
            try await wait("Forced Init did not release after actual worker drain"){closed==1 && !owner.model.hasPendingWork && CreateRepositoryWindowController.activeReleases==0}
            try require(initialized==0 && q.entries.isEmpty && !FileManager.default.fileExists(atPath:owner.model.folder.appendingPathComponent(".git").path),"Retired Init mutated/published after cancellation")
        }
        // A warning answered across a Quit round-trip cannot start captured work.
        do {
            let owner=try make("quit.git"),q=Questions();q.install(owner)
            try Data("keep".utf8).write(to:owner.model.folder.appendingPathComponent("keep"))
            var attempts=0;owner.model.initializeOperation={_,_,_,_,_ in attempts += 1;return "unexpected"}
            owner.model.prepare();let stale=owner.model.bareBinding(owner.model.formContext)
            owner.model.initialize();try await wait("Quit warning missing"){q.last != nil}
            owner.model.confirmingQuit=true;owner.model.confirmingQuit=false
            stale.wrappedValue=false;q.last!.1.buttons[1].performClick(nil)
            try await wait("Quit warning did not settle"){!owner.model.asking && owner.questionWindow==nil}
            try require(attempts==0 && owner.model.bare && !owner.model.completed && !owner.model.hasPendingWork,"Quit roundtrip accepted stale Init warning/form")
            owner.close();try await wait("Quit Init cleanup did not detach"){owner.questionWindow==nil}
        }
        // Unpresented model success settles once; no UI owner or grant is fabricated.
        do {
            let folder=base.appendingPathComponent("model-only")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let model=CreateRepositoryWindowModel(folder:folder,access:RepositoryAccessLease(url:base),preferences:prefs)
            model.executable=git;var closes=0,initialized=0;model.close={closes += 1};model.onInitialized={_,_,_,_ in initialized += 1}
            model.prepare();model.initialize();try await wait("Missing Init success presenter left model owned"){!model.hasPendingWork && model.completed && !model.confirmingSuccess}
            try require(closes==1 && initialized==1 && model.canClose,"Missing presenter duplicated or lost Init completion")
            model.acknowledgeSuccess();try require(closes==1,"Missing presenter callback closed twice");model.retire()
        }
        // Production Init completion uses a private real workspace handoff/store.
        do {
            let owner=try make("root-handoff"),q=Questions();q.install(owner)
            let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("init-private-access.json"))
            let root=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("init-private-marks.json")))
            root.fileComparisonPreferences=prefs;root.requiresRepositoryScope=false;root.notifyFinder={}
            let host=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            host.isReleasedWhenClosed=false;host.alphaValue=0;root.workspaceWindow=host
            defer{root.closeRepository();root.stopMonitoringForTermination();host.close()}
            root.configureCreateRepositoryInteractions(owner)
            owner.model.prepare();owner.model.initialize()
            try await wait("Actual Init workspace handoff did not open completed repository"){!root.busy && root.root?.resolvingSymlinksInPath().path==owner.model.folder.resolvingSymlinksInPath().path && owner.model.confirmingSuccess && q.last?.0 == .success}
            try require(root.error==nil && store.repositories.contains{$0.lastKnownPath==owner.model.folder.resolvingSymlinksInPath().path},"Init handoff lost private root/Recents")
            q.last!.1.buttons[0].performClick(nil);try await wait("Init handoff acknowledgement did not detach"){owner.questionWindow==nil && owner.window?.attachedSheet==nil}
            try require(root.root?.resolvingSymlinksInPath().path==owner.model.folder.resolvingSymlinksInPath().path,"Closing Init discarded completed workspace handoff")
        }
        owned.forEach{$0.close()}
        try await wait("Init owned native transitions survived cleanup"){CreateRepositoryWindowModel.activeOperations==0 && CreateRepositoryWindowController.activeReleases==0}
        print("Init native Abort/Proceed/default, captured bare/form/Quit, actual normal/bare creation/error retry, success acknowledgement, missing presenter and forced-close actual worker/owner drain passed.")
    }
}
