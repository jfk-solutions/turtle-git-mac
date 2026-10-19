// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private final class ArchiveFinalizationGate:@unchecked Sendable {
    private let condition=NSCondition();private var entered=false,released=false
    var waiting:Bool{condition.lock();defer{condition.unlock()};return entered && !released}
    func hold(){condition.lock();entered=true;condition.broadcast();while !released{condition.wait()};condition.unlock()}
    func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
}
struct ExportProgressFamilyVerification {
    @MainActor static func verify()async throws {
        typealias F=StashExportProgressFixture
        let suite="TurtleGit.ExportFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let(repo,_,_)=try await F.repository("export space"),destination=repo.root.appendingPathComponent("preserved.zip"),original=Data("existing ZIP bytes".utf8)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        for forcedClose in [false,true] {
            try original.write(to:destination)
            let gate=ArchiveFinalizationGate();defer{gate.release()}
            let model=ExportProgressWindowModel(repository:repo,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:destination,preferences:prefs)
            model.outputClipboard=clipboard;model.beforeFinalization={gate.hold()}
            let parent=F.parent(),owner=ExportProgressWindowController(model:model)
            F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
            var closed=0,explored=0,abandoned=0
            owner.onClosed={closed+=1};model.onAbandonedCompletion={abandoned+=1}
            model.showInFinder={url in precondition(url.path==destination.path && parent.attachedSheet==nil && owner.window?.sheetParent==nil && closed==1 && !model.hasPendingWork);explored+=1}
            model.start();try F.require(model.hasPendingWork,"Export start did not synchronously reserve work")
            try await F.wait("Archive receipt did not precede held finalization"){gate.waiting && model.commandFinished}
            try F.require(model.commandSucceeded && model.busy && model.hasPendingWork && !model.success && (try Data(contentsOf:destination))==original,"Export finalized destination or workflow before actual finalization")
            try F.require(model.output.hasPrefix(repo.executable.path+" --literal-pathspecs -C '"+repo.root.path+"' archive --format=zip "),"Archive preamble omitted actual scoped command: \(model.output.debugDescription)")
            try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:true,preferences:prefs,clipboard:clipboard)
            try F.require(!(model.output as NSString).substring(with:model.completionRange!).contains(" ms @ "),"Export ignored private hidden timings")
            model.explore();try F.require(explored==0,"Explore escaped actual pending finalization")
            try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held archive finalization")
            if forcedClose {
                owner.close();try F.require(model.hasPendingWork && closed==0 && !model.active,"Export forced close released actual finalizer early")
            }
            gate.release()
            try await F.wait("Archive finalization did not drain"){!model.hasPendingWork && !model.busy}
            if forcedClose {
                try await F.wait("Retired Export did not detach actual sheet"){closed==1 && parent.attachedSheet==nil && ExportProgressWindowController.activeReleases==0}
                try F.require(abandoned==1 && explored==0 && !model.success && (try Data(contentsOf:destination))==original,"Retired archive replaced destination or dispatched late Explore")
                model.explore();try F.require(explored==0,"Retired Export accepted Explore")
            } else {
                try F.require(model.success && Array(try Data(contentsOf:destination).prefix(2))==[0x50,0x4b],"Successful finalizer did not publish actual ZIP")
                model.explore();model.explore()
                try await F.wait("Explore did not wait for actual close/detach once"){closed==1 && explored==1 && parent.attachedSheet==nil && ExportProgressWindowController.activeReleases==0}
                try F.require(abandoned==0,"Successful Export was reported abandoned")
            }
            try F.require(try !FileManager.default.contentsOfDirectory(atPath:repo.root.path).contains{$0.hasPrefix(".TurtleGitArchive-")},"Export left temporary archive after finalization")
        }
        try await verifyCancellation(repo:repo,preferences:prefs,clipboard:clipboard)
        try await verifyOptionsExplore(repo:repo,preferences:prefs,clipboard:clipboard)
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        try F.require(finalHead==head && finalIndex==index,"Export changed source HEAD/index")
        print("Export actual command receipt/styled Copy before held finalization, cancellation-preserved destination, Quit/forced-close drain, native No/Yes and actual options Explore handoff passed.")
    }
    @MainActor static func verifyCancellation(repo:GitRepository,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=StashExportProgressFixture
        let(slow,marker,_)=try F.wrapper(repo,command:"archive"),destination=repo.root.appendingPathComponent("cancel.zip"),original=Data("preserved on kill".utf8)
        try original.write(to:destination)
        let model=ExportProgressWindowModel(repository:slow,access:nil,outputAccess:nil,revision:"HEAD",directory:"",destination:destination,preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=ExportProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0
        owner.onClosed={closed+=1};owner.presentCancellation={question,window,reply in alert=question;answer=reply;question.beginSheetModal(for:window,completionHandler:reply)}
        model.start();try await F.wait("Held archive worker/progress missing"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Archive helper ownership missing")
        model.cancel();try await F.wait("Export kill question missing"){alert?.window.sheetParent===owner.window}
        try F.require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==parent.appearance?.name,"Export question lost captured appearance")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Export No did not actually detach"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(!model.cancelling && pids.allSatisfy{kill($0,0)==0},"Late duplicate Yes killed declined archive")
        model.cancel();try await F.wait("Export second question missing"){alert?.window.sheetParent===owner.window};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Cancelled archive did not drain actual process"){!model.hasPendingWork && !model.busy && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try F.require(!model.commandSucceeded && !model.success && owner.window?.attachedSheet==nil && (try Data(contentsOf:destination))==original,"Cancelled archive replaced destination or completed before question detach")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        model.close();model.close();try await F.wait("Export close did not drain exactly once"){closed==1 && parent.attachedSheet==nil}
    }
    @MainActor static func verifyOptionsExplore(repo:GitRepository,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=StashExportProgressFixture
        let owner=ExportWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),revision:"HEAD",preferences:preferences)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);defer{owner.close()}
        try await F.wait("Actual Export options did not load"){!owner.model.busy}
        owner.model.destination=repo.root.appendingPathComponent("options.zip").path
        var progress:ExportProgressWindowController?,explored=0,closed=0
        let original=owner.model.onProgress
        owner.model.onProgress={model in
            model.outputClipboard=clipboard;original?(model);progress=owner.progressController
            model.showInFinder={_ in precondition(owner.progressController==nil && owner.window?.attachedSheet==nil && progress?.window?.sheetParent==nil && closed==1);explored+=1}
        }
        owner.onClosed={closed+=1};owner.model.export()
        try await F.wait("Actual Export options progress did not finish"){progress?.model.success==true && progress?.model.hasPendingWork==false}
        try F.require(progress?.window?.appearance?.name==NSAppearance.Name.darkAqua && progress?.window?.alphaValue==0,"Export progress lost options appearance")
        progress?.model.explore();progress?.model.explore()
        try await F.wait("Actual Export Explore ran before options+progress detach"){explored==1 && closed==1 && owner.progressController==nil && owner.window?.attachedSheet==nil}
    }
}
