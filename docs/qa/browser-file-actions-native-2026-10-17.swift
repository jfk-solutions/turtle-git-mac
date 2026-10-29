// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct BrowserFileActionsVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {for _ in 0..<3000 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG missing")}
            try png.write(to:directory.appendingPathComponent("browser-file-actions-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Browser file actions: source relative readonly Path, exact atomic Save, captured/retired panels, launch scope/preview/Quit drain, late receipt fences, real sheet cleanup and unchanged Git state")}catch {fputs("Browser file actions failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let fixture=URL(fileURLWithPath:CommandLine.arguments[1]),root=fixture.appendingPathComponent("repository"),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        try fm.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git,askpass:nil)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Browser File Actions"),("user.email","browser@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let bytes=Data([0,1,2,13,10,0xff,0x41]),file=root.appendingPathComponent("folder/example.bin")
        try bytes.write(to:file);try Data("hello\n".utf8).write(to:root.appendingPathComponent("folder/readme.txt"));try await repo.stage(["folder"]);_=try await repo.commit(message:"Browser file sample")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),pinned=String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines)
        let suite="TurtleGit.BrowserFiles."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);HistoricalPreviewFiles.discardAll()}
        func owner()->RepositoryBrowserWindowController {let value=RepositoryBrowserWindowController(repository:repo,access:nil,revision:pinned,preferences:prefs);value.window?.alphaValue=0;return value}
        let host=owner(),model=host.model;defer {host.close()}
        try await wait {!model.busy && model.snapshot != nil};model.loadDirectory("folder",select:true);try await wait {model.snapshot?.directory=="folder"}
        host.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait {views(host.window?.contentView).contains {($0 as? NSTextField)?.accessibilityLabel()=="Repository path"}}
        let path=views(host.window?.contentView).compactMap {$0 as? NSTextField}.first {$0.accessibilityLabel()=="Repository path"}!
        try require(path.stringValue=="/folder" && !path.isEditable && path.isSelectable && path.toolTip?.contains(root.path+"/folder")==true && path.toolTip?.contains(pinned)==true,"Source readonly Path/absolute pinned tooltip mismatch")
        host.window?.makeFirstResponder(path)
        if let editor=path.currentEditor() as? NSTextView {editor.selectAll(nil);try require(editor.string=="/folder" && editor.selectedRange().length==7 && !editor.isEditable,"Path field lost native selection/read-only behavior")}
        host.window?.makeFirstResponder(nil)
        let entry=model.entries.first {$0.name=="example.bin"}!,content=try await repo.repositoryBrowserFile(model.snapshot!,entry:entry)
        var saves:[(NSApplication.ModalResponse)->Void]=[],savedPanels:[NSSavePanel]=[]
        let destination=fixture.appendingPathComponent("saved-example.bin")
        host.presentSavePanel={panel,_,reply in savedPanels.append(panel);saves.append(reply)};host.saveDestination={_ in destination}
        model.open(entry,action:.save);try await wait {saves.count==1}
        try require(model.handlingFile && !model.canUseMenu && RepositoryBrowserFileOperation.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel && savedPanels[0].nameFieldStringValue==entry.name,"Save modal lacks ownership/source filename")
        let generation=model.generation;model.refresh();model.loadDirectory("",select:true);model.open(entry,action:.save)
        try require(model.generation==generation && saves.count==1 && model.snapshot?.directory=="folder","Competing action replaced Save context")
        saves[0](.cancel);saves[0](.OK)
        try await wait {!model.handlingFile && !model.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(!fm.fileExists(atPath:destination.path),"Cancelled/repeated Save adopted")
        model.open(entry,action:.save);try await wait {saves.count==2};model.revision="changed-request";saves[1](.OK)
        try await wait {!model.handlingFile && !model.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(!fm.fileExists(atPath:destination.path),"Changed revision wrote a stale Save reply");model.revision=pinned
        model.open(entry,action:.save);try await wait {saves.count==3};saves[2](.OK);saves[2](.OK)
        try await wait {!model.handlingFile && RepositoryBrowserFileOperation.activeRequests==0};try require(try Data(contentsOf:destination)==content.bytes && content.bytes==bytes,"Atomic Save changed historical bytes")
        // Close during an authorized writer that ignores cancellation; Quit lasts until drain.
        let delayed=owner();defer {delayed.close()};try await wait {!delayed.model.busy && delayed.model.snapshot != nil}
        delayed.model.loadDirectory("folder",select:true);try await wait {delayed.model.snapshot?.directory=="folder"}
        var saveReply:((NSApplication.ModalResponse)->Void)?,writeReply:CheckedContinuation<Void,Error>?,writeToken:OperationCancellation?
        delayed.presentSavePanel={_,_,reply in saveReply=reply};delayed.saveDestination={_ in fixture.appendingPathComponent("ignored-save")}
        delayed.writeDocument={data,_,token in try require(data==bytes,"Delayed writer received wrong bytes");writeToken=token;try await withCheckedThrowingContinuation {writeReply=$0}}
        delayed.model.open(delayed.model.entries.first {$0.name=="example.bin"}!,action:.save);try await wait {saveReply != nil};saveReply?(.OK);try await wait {writeReply != nil}
        delayed.close();try require(writeToken?.isCancelled==true && RepositoryBrowserFileOperation.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed writer lost independent drain")
        writeReply?.resume(throwing:Failure.assertion("retired write failure"));writeReply=nil;try await wait {RepositoryBrowserFileOperation.activeRequests==0}
        try require(delayed.model.error==nil && !delayed.model.active,"Retired write published an error")
        // An Open With receipt retains the exact preview, including after window close.
        let opening=owner();defer {opening.close()};try await wait {!opening.model.busy && opening.model.snapshot != nil}
        opening.model.loadDirectory("folder",select:true);try await wait {opening.model.snapshot?.directory=="folder"}
        var apps:[(NSApplication.ModalResponse)->Void]=[],launchReply:CheckedContinuation<Void,Error>?,preview:URL?,launches=0
        let application=fixture.appendingPathComponent("Fixture.app");try fm.createDirectory(at:application,withIntermediateDirectories:true)
        opening.presentApplicationPanel={_,_,reply in apps.append(reply)};opening.selectedApplication={_ in application}
        opening.launchDocument={app,documents,configuration in
            try require(app.path==application.path && documents.count==1 && configuration.arguments.isEmpty && !configuration.createsNewApplicationInstance,"Open With changed native document-open semantics")
            preview=documents[0];try require(try Data(contentsOf:documents[0])==bytes,"Open With preview bytes changed");launches += 1
            try await withCheckedThrowingContinuation {launchReply=$0}
        }
        let openEntry=opening.model.entries.first {$0.name=="example.bin"}!
        opening.model.open(openEntry,action:.openWith);try await wait {apps.count==1};apps[0](.cancel);apps[0](.OK)
        try await wait {!opening.model.handlingFile && !opening.model.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(launches==0,"Cancelled Open With launched")
        opening.model.open(openEntry,action:.openWith);try await wait {apps.count==2};apps[1](.OK);apps[1](.OK);try await wait {launchReply != nil || opening.model.error != nil}
        try require(launchReply != nil && opening.model.error==nil,"Open With launch failed: \(opening.model.error ?? "no receipt")")
        opening.close();try require(launches==1 && RepositoryBrowserFileOperation.activeRequests==1 && ExternalDocumentApplication.activeRequests==1 && fm.fileExists(atPath:preview!.path) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pending launch lost preview/Quit ownership")
        launchReply?.resume(throwing:Failure.assertion("uncertain receipt after close"));launchReply=nil;try await wait {RepositoryBrowserFileOperation.activeRequests==0 && ExternalDocumentApplication.activeRequests==0}
        try require(opening.model.error==nil && fm.fileExists(atPath:preview!.path),"Closed launch published or deleted possibly accepted input")
        // Production native panels also retire through the actual controller close path.
        for action in [RepositoryBrowserWindowModel.FileAction.save,.openWith] {
            let native=owner();try await wait {!native.model.busy && native.model.snapshot != nil};native.model.loadDirectory("folder",select:true);try await wait {native.model.snapshot?.directory=="folder"}
            native.model.open(native.model.entries.first {$0.name=="example.bin"}!,action:action);try await wait {native.window?.attachedSheet != nil}
            native.close();try await wait {native.window?.attachedSheet==nil && RepositoryBrowserFileOperation.activeRequests==0 && RepositoryBrowserWindowModel.activeOperations==0}
            try require(!native.model.active && native.model.error==nil,"Production file panel survived Close")
        }
        var defaultLaunches=0
        host.defaultApplication={_ in application};host.launchDocument={app,documents,configuration in
            try require(app.path==application.path && documents.count==1 && configuration.arguments.isEmpty && (try Data(contentsOf:documents[0]))==bytes,"Default Open changed native documents or historical bytes");defaultLaunches += 1
        }
        model.open(entry);try await wait {defaultLaunches==1 && !model.handlingFile && RepositoryBrowserFileOperation.activeRequests==0}
        model.selection=[entry.id];host.window?.contentView?.layoutSubtreeIfNeeded()
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_BROWSER_FILES_CAPTURE"] {try await capture(host.window!,to:URL(fileURLWithPath:output))}
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==bytes,"File actions changed Git state or working file")
        try require(RepositoryBrowserFileOperation.activeRequests==0 && RepositoryBrowserWindowModel.activeOperations==0,"Browser file ownership count leaked")
    }
}
