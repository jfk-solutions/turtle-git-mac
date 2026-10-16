// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct GeneralSourceVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {for _ in 0..<2500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=850,"General page escaped production viewport bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let selected=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:selected),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG missing")}
            try png.write(to:directory.appendingPathComponent("general-settings-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS General source family: real Git validation/private Apply, draft-scoped version results, cancellation/drain and real process cleanup, captured executable Browse/update questions, native completion/reactivation and owned Settings/Quit")}catch {fputs("General source failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.GeneralSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let model=GeneralGitSettingsModel(preferences:prefs);defer {model.suspend()};model.activate();model.draft.choice = .custom;model.draft.path=git.path
        let applied=await model.apply();try require(applied && !model.modified && model.version.hasPrefix("git version ") && GitEnginePreferences.load(from:prefs).path==git.path,"Real engine validation/private persistence failed")
        let accepted=GitEnginePreferences.load(from:prefs)
        var read:CheckedContinuation<String,Error>?,readToken:OperationCancellation?
        model.inspectEngine={_,token in readToken=token;return try await withCheckedThrowingContinuation {read=$0}}
        model.check();model.check();try await wait {read != nil}
        try require(model.busy && model.checking && !model.canEditEngine && GeneralGitSettingsModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Check duplicate/drain ownership missing")
        model.cancelCheck();model.cancelCheck();try require(model.cancellingCheck && readToken?.isCancelled == true && model.busy,"Cancel released work before drain")
        read?.resume(returning:"git version cancelled");read=nil;try await wait {!model.busy}
        try require(model.version.isEmpty && model.error==nil && GeneralGitSettingsModel.activeOperations==0,"Cancelled check published")
        model.check();try await wait {read != nil};model.draft.extraPath="/tmp";read?.resume(returning:"git version wrong-draft");read=nil;try await wait {!model.busy}
        try require(model.version.isEmpty,"Version described a changed engine")
        model.check();try await wait {read != nil};model.suspend();model.activate()
        try require(GeneralGitSettingsModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired read lost Quit lifetime")
        read?.resume(throwing:Failure.assertion("retired engine error"));read=nil;try await wait {GeneralGitSettingsModel.activeOperations==0}
        try require(model.error==nil && model.version.isEmpty,"Retired read published after reopening")
        // Apply remains valid for cached/hidden pages, but may not persist a changed draft.
        let pending=Task {await model.apply()};try await wait {read != nil};model.draft.extraPath="/usr/local/bin";read?.resume(returning:"git version old-apply");read=nil
        let staleApplied=await pending.value
        try require(!staleApplied && model.modified && model.error != nil && GitEnginePreferences.load(from:prefs)==accepted && model.draft.extraPath=="/usr/local/bin","Stale Apply persisted/replaced a newer engine draft")
        model.suspend();model.inspectEngine=nil;model.draft=accepted
        let hiddenApplied=await model.apply(validateUnchanged:true);try require(hiddenApplied && !model.modified,"Hidden cached General Apply rejected")
        model.activate()
        // Production subprocess cancellation, including an actual shell child.
        let helper=root.appendingPathComponent("git-check"),ready=URL(fileURLWithPath:helper.path+".ready")
        try Data(#"""
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        echo "$$ $task_child" > "$0.ready"
        wait "$task_child"
        echo git version fixture
        """#.utf8).write(to:helper);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        model.draft.path=helper.path;model.draft.bookmark=nil;model.check();try await wait {fm.fileExists(atPath:ready.path)}
        let pids=try String(contentsOf:ready).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
        try require(pids.count==2,"Version process identities missing");model.cancelCheck();try await wait {!model.busy && GeneralGitSettingsModel.activeOperations==0}
        try require(pids.allSatisfy {kill($0,0) != 0 && errno==ESRCH},"Owned Git version process/child remains")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.alphaValue=0;window.title="General – Settings – TurtleGit";model.window=window
        defer {model.suspend();window.contentView=nil;window.close()}
        model.draft=accepted
        var replies:[(NSApplication.ModalResponse)->Void]=[],selected=git,bookmarks=0
        model.presentPanel={_,_,reply in replies.append(reply)};model.selectedURL={_ in selected};model.bookmark={_ in bookmarks += 1;return Data("private Git grant".utf8)}
        model.browse();model.browse()
        try require(replies.count==1 && model.selecting && GeneralGitSettingsModel.activeDialogs==1 && model.validationError != nil && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Browse duplicate/modal ownership missing")
        model.draft.extraPath="/tmp";replies[0](.OK);try require(bookmarks==0 && model.draft.extraPath=="/tmp","Browse overwrote changed engine context")
        selected=root;model.browse();replies[1](.OK);try require(bookmarks==0 && model.error != nil,"Directory bookmarked as Git executable")
        selected=git;model.browse();replies[2](.OK);replies[2](.OK);try require(bookmarks==1 && model.draft.path==git.path && model.draft.extraPath=="/tmp" && !model.selecting && model.error==nil,"Browse adoption repeated or lost Extra PATH")
        model.browse();model.suspend();model.activate();replies[3](.OK);try require(bookmarks==1 && GeneralGitSettingsModel.activeDialogs==0,"Retired Browse accepted late bookmark")
        var questions:[NSAlert]=[],answers:[(NSApplication.ModalResponse)->Void]=[],disabled=0
        model.presentUpdateQuestion={alert,_,reply in questions.append(alert);answers.append(reply)}
        model.confirmDisableUpdates {disabled += 1};model.confirmDisableUpdates {disabled += 1}
        try require(answers.count==1 && GeneralGitSettingsModel.activeDialogs==1 && questions[0].buttons[1].keyEquivalent=="\r" && questions[0].buttons[0].keyEquivalent.isEmpty,"Update question duplicated or changed Abort default")
        answers[0](.alertSecondButtonReturn);try require(disabled==0 && !model.confirmingUpdates,"Abort disabled updates")
        model.confirmDisableUpdates {disabled += 1};answers[1](.alertFirstButtonReturn);answers[1](.alertFirstButtonReturn);try require(disabled==1,"Update confirmation repeated")
        model.confirmDisableUpdates {disabled += 1};model.suspend();model.activate();answers[2](.alertFirstButtonReturn);try require(disabled==1 && GeneralGitSettingsModel.activeDialogs==0,"Retired update reply changed reopened page")
        // Actual window close retires the owner even with an injected unattached panel.
        model.browse();window.close();replies[4](.OK);try require(bookmarks==1 && GeneralGitSettingsModel.activeDialogs==0 && !model.canEditPage,"Closed owner accepted executable")
        let pageWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);pageWindow.isReleasedWhenClosed=false;pageWindow.alphaValue=0;pageWindow.title="General – Settings – TurtleGit"
        let transaction=SettingsTransaction(),appearance=SettingsAppearanceDraft(appearance:AppAppearance(preferences:prefs))
        model.draft=accepted;model.error=nil
        let host=NSHostingView(rootView:GeneralSettings(appearance:appearance,model:model,preferences:prefs).environment(\.settingsTransaction,transaction).defaultAppStorage(prefs))
        let viewport=SettingsPageViewport(frame:pageWindow.contentLayoutRect);viewport.autoresizingMask=[.width,.height];pageWindow.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        defer {transaction.invalidate();model.suspend();pageWindow.contentView=nil;pageWindow.close()}
        viewport.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded();try await wait {views(host).contains {($0 as? PathEntryField.Field)?.accessibilityLabel()=="Git executable"}}
        let field=views(host).compactMap {$0 as? PathEntryField.Field}.first!;try await wait {field.isEnabled}
        try require(field.isEditable && field.frame.height>=20,"Native Git completion field clipped")
        let updateBox=views(host).compactMap {$0 as? NSButton}.first {$0.title=="Automatically check for newer versions every week"}
        try require(updateBox != nil && updateBox!.frame.height<=30,"Update checkbox stretched the source application group")
        model.suspend();try await wait {!field.isEnabled};model.activate();try await wait {field.isEnabled}
        model.draft.bookmark=Data("old grant".utf8);field.coordinator?.changed(git.path);try require(model.draft.bookmark==nil,"Typing Git path retained old bookmark")
        model.draft.extraPath="/usr/local/bin";model.check();try await wait {!model.busy}
        try require(model.version.hasPrefix("git version "),"Final real version check failed")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_GENERAL_CAPTURE"] {try await capture(pageWindow,to:URL(fileURLWithPath:output))}
        try require(GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0,"General ownership count leaked")
    }
}
