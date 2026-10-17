// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct SwitchSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description:message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Switch source timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
    @MainActor static func capture(_ window: NSWindow, folder: URL) async throws {
        guard #available(macOS 14.4,*) else { throw Failure(description:"Capture requires 14.4") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=750,"Switch window escaped content bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else { throw Failure(description:"Missing owned capture window") }
            let configuration=SCStreamConfiguration();configuration.includeChildWindows=false;configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:configuration)
            guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure(description:"PNG missing") }
            try data.write(to:folder.appendingPathComponent("switch-source-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Switch Source"),("user.email","qa@example.invalid"),("core.precomposeUnicode","true"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _=try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repo.run(["tag","release"]);_=try await repo.run(["remote","add","origin",root.path])
        for name in ["refs/remotes/origin/team/topic","refs/remotes/origin/Café"] { _=try await repo.run(["update-ref",name,hash]) }
        let suite="TurtleGit.SwitchSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let owner=SwitchWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model
        defer { owner.window?.close() };owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.load();try await wait {model.canEditForm}
        try require(!model.options.createBranch && model.options.branchName=="Branch_main","Local source defaults missing")
        let stale=model.option(\.merge,context:model.formContext)
        model.selectTarget(.commit,context:model.formContext);model.revisionBinding(.commit,context:model.formContext).wrappedValue=hash
        try require(model.options.createBranch && model.options.branchName=="Branch_"+hash.prefix(8),"Source short hash is eight characters")
        stale.wrappedValue=true;try require(!model.options.merge,"Replaced radio context mutated options")
        model.selectTarget(.branch,context:model.formContext);model.revisionBinding(.branch,context:model.formContext).wrappedValue="refs/remotes/origin/team/topic"
        try require(model.options.createBranch && model.options.branchName=="team/topic" && model.options.tracking == .automatic,"Immediate remote defaults missing")
        model.option(\.branchName,context:model.formContext).wrappedValue="topic"
        try require(model.options.tracking == .automatic,"Source remote suffix match disabled tracking")
        model.revisionBinding(.branch,context:model.formContext).wrappedValue="refs/remotes/origin/Café"
        model.option(\.branchName,context:model.formContext).wrappedValue="Cafe\u{301}"
        try require(model.options.tracking == .noTrack,"Exact Unicode name edit failed to disable tracking")
        model.option(\.tracking,context:model.formContext).wrappedValue = .track
        // There must be no delayed view onChange resetting a later explicit click.
        try await Task.sleep(nanoseconds:150_000_000);try require(model.options.tracking == .track,"Later Track click overwritten")
        model.option(\.overrideBranch,context:model.formContext).wrappedValue=true
        model.option(\.createBranch,context:model.formContext).wrappedValue=false
        let blockedName=model.option(\.branchName,context:model.formContext),blockedTrack=model.option(\.tracking,context:model.formContext)
        blockedName.wrappedValue="disabled";blockedTrack.wrappedValue = .track
        try require(!model.options.overrideBranch && model.options.tracking == .noTrack && model.options.branchName != "disabled","Disabled dependent options remained writable")
        model.option(\.createBranch,context:model.formContext).wrappedValue=true;model.option(\.tracking,context:model.formContext).wrappedValue = .automatic
        try await wait { views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.title=="Track" && $0.isEnabled && $0.state == .mixed} }
        let track=views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Track"}!
        try await wait { (track.target as? TrackingCheckbox.Coordinator)?.value == .automatic }
        for expected in [CheckoutTracking.noTrack,.track,.automatic] { track.performClick(nil);try require(model.options.tracking==expected,"Native source Track cycle differs") }
        let force=model.option(\.overwriteChanges,context:model.formContext),target=track.target as? TrackingCheckbox.Coordinator
        model.busy=true;try await wait {!track.isEnabled};force.wrappedValue=true;target?.clicked(track)
        try require(!model.options.overwriteChanges && model.options.tracking == .automatic,"Busy source form accepted stale callbacks")
        model.busy=false;try await wait {track.isEnabled}
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_SWITCH_SOURCE_CAPTURE"] { try await capture(owner.window!,folder:URL(fileURLWithPath:path)) }
        let retained=model.option(\.merge,context:model.formContext);owner.window?.close();retained.wrappedValue=true;target?.clicked(track)
        try require(!model.options.merge && (track as? ReferenceChoiceButton)?.retired==true && !track.isEnabled,"Retired source owner/native target remained writable")
        // Source remembers tag/commit choice only once validation has accepted it.
        prefs.set(false,forKey:"SwitchToTagNewBranch");prefs.set(0,forKey:"AutoCloseGitProgress")
        let transaction=SwitchWindowModel(repository:repo,access:nil,revision:"refs/tags/release",preferences:prefs)
        defer { transaction.invalidate() };transaction.load();try await wait { transaction.canEditForm }
        transaction.option(\.createBranch,context:transaction.formContext).wrappedValue=true
        transaction.option(\.branchName,context:transaction.formContext).wrappedValue="invalid..name"
        transaction.checkout();try await wait {!transaction.busy}
        try require(transaction.error != nil && !prefs.bool(forKey:"SwitchToTagNewBranch"),"Invalid submission changed remembered source choice")
        transaction.error=nil;transaction.option(\.branchName,context:transaction.formContext).wrappedValue="release"
        transaction.checkout();try await wait {!transaction.busy}
        try require(transaction.hasPendingTagConflict && !prefs.bool(forKey:"SwitchToTagNewBranch"),"Unaccepted warning changed remembered choice")
        let warningName=transaction.option(\.branchName,context:transaction.formContext);warningName.wrappedValue="wrong"
        transaction.abortTagConflict();transaction.option(\.branchName,context:transaction.formContext).wrappedValue="made-e\u{301}"
        let accepted=transaction.options.branchName,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        var result:SwitchProgressWindowModel?,changes=0,closes=0
        transaction.onProgress={result=$0};transaction.onChanged={_ in changes+=1};transaction.close={closes+=1}
        let oldName=transaction.option(\.branchName,context:transaction.formContext);transaction.checkout();oldName.wrappedValue="late"
        try await wait {result?.busy==false}
        try require(result?.success==true && result?.options.branchName.utf8.elementsEqual(accepted.utf8)==true && changes==1 && prefs.bool(forKey:"SwitchToTagNewBranch"),"Accepted captured transaction/default persistence failed")
        result?.close();result?.close();try require(closes==1 && !transaction.busy,"Progress acknowledgement repeated")
        let branch=try await repo.run(["symbolic-ref","--short","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(branch.utf8.elementsEqual(accepted.utf8) && index == (try Data(contentsOf:root.appendingPathComponent(".git/index"))),"Switch changed exact branch identity or index")
        try await wait {SwitchWindowModel.activeReads==0}
        print("PASS native Switch source: synchronous source defaults/suffix/exact tracking, eight-character names, native tri-state/disabled/retired controls, captured fields, rejected preference changes, real exact-name checkout/progress and once-only acknowledgement; private repository/preferences")
    }
}
