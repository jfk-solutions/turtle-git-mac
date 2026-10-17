import AppKit
import ScreenCaptureKit
import Darwin
import TurtleGitCore

@main struct SubmoduleAddInputsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Submodule input wait at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        if #available(macOS 14.4,*) {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned Submodule Add capture window absent")}
                let config=SCStreamConfiguration();config.width=Int(window.frame.width * 2);config.height=Int(window.frame.height * 2);config.showsCursor=false
                let filter=SCContentFilter(desktopIndependentWindow:owned);config.includeChildWindows=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"No Submodule Add PNG")}
                try png.write(to:directory.appendingPathComponent("submodule-add-inputs-"+name+".png"))
            }
            window.alphaValue=0
        } else {throw Failure(description:"Passive window capture requires macOS 14.4")}
    }
    @MainActor static func main()async {do {try await verify()}catch {fputs("Submodule inputs failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),parent=root.appendingPathComponent("parent"),child=root.appendingPathComponent("source")
        for directory in [parent,child] {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        let repo=GitRepository(root:parent,executable:git),source=GitRepository(root:child,executable:git)
        for candidate in [repo,source] {
            _ = try await candidate.run(["init","-b","main"])
            for (key,value) in [("user.name","Submodule Inputs"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await candidate.run(["config",key,value])}
            try Data("base\n".utf8).write(to:candidate.root.appendingPathComponent("file"));try await candidate.stage(["file"]);_ = try await candidate.commit(message:"base")
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:parent.appendingPathComponent(".git/index")),sourceHead=try await source.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.SubmoduleInputs."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,lease=RepositoryAccessLease(url:root),board=NSPasteboard(name:.init(suite))
        defer {prefs.removePersistentDomain(forName:suite);board.releaseGlobally()}
        prefs.set(["ssh://host/A","ssh://host/a","ssh://host/é","ssh://host/e\u{301}"]+(0..<30).map {"ssh://host/\($0)"},forKey:"SubmoduleAdd.URLHistory")
        prefs.set(["paths/One","paths/one"],forKey:"SubmoduleAdd.PathHistory");prefs.set(["/tmp/one","/tmp/two"],forKey:"Clone.KeyHistory")
        board.setString("git clone 'ssh://clipboard.invalid/group/module.git'",forType:.string)
        let owner=SubmoduleAddWindowController(repository:repo,access:lease,path:"modules",preferences:prefs,clipboardText:board.string(forType:.string));defer {owner.close()}
        let model=owner.model;owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.makeSSHCoordinator={SSHTransportCoordinator(repository:$0)};model.useKey=true
        try require(model.source=="ssh://clipboard.invalid/group/module.git" && model.path=="modules" && model.sources.count==25,"Clipboard default rewrote path/history or lost load bounds")
        let clone=CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:git,clipboardText:board.string(forType:.string));defer {clone.invalidate()};try require(clone.source==model.source,"Clone/Submodule clipboard defaults diverged")
        let fallback=SubmoduleAddWindowModel(repository:repo,access:lease,path:".",preferences:prefs,clipboardText:"unrecognized text");defer {fallback.invalidate()};try require(fallback.source==model.sources[0] && fallback.path.isEmpty,"Invalid clipboard did not retain first history/invocation")
        model.sourceEndedEditing();try require(model.path=="modules/module","Source end-edit did not derive invocation-relative path")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_INPUT_CAPTURE"] {
            model.onSubmit={_ in};model.useBranch=true;model.branch="main";try await capture(owner.window!,to:URL(fileURLWithPath:output));model.onSubmit=nil;model.useBranch=false;model.branch=""
        }
        model.source="git@host:Repo.GIT";model.sourceEndedEditing();try require(model.path=="modules/git@host:Repo.GIT","End-edit changed scp colon/case source rule")
        try await wait {views(owner.window?.contentView).compactMap {$0 as? EditableHistoryCombo}.count==3}
        let combos=views(owner.window?.contentView).compactMap {$0 as? EditableHistoryCombo}
        func combo(_ name:String)->EditableHistoryCombo {combos.first {$0.accessibilityLabel()==name}!}
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:51)!
        let url=combo("Submodule repository")
        try await wait {url.isEnabled && url.stringValue.utf8.elementsEqual(model.source.utf8)}
        url.selectItem(at:1);url.historyPopupOpen=true
        try require(url.handleHistoryKey(event) && !model.sources.contains("ssh://host/a") && model.sources.contains("ssh://host/A"),"Repository history deletion lost case identity")
        try await wait {url.numberOfItems==model.sources.count}
        let path=combo("Submodule path");path.selectItem(at:0);path.historyPopupOpen=true
        try require(path.handleHistoryKey(event) && model.paths==["paths/one"] && model.path=="paths/one","Path history deletion/nearest selection failed")
        try await wait {path.numberOfItems==model.paths.count}
        let key=combo("OpenSSH private key");try await wait {key.isEnabled};key.selectItem(at:0);key.historyPopupOpen=true
        try require(key.handleHistoryKey(event) && model.keys==["/tmp/two"] && prefs.stringArray(forKey:"Clone.KeyHistory")==["/tmp/two"],"Shared key history deletion failed")
        var callbacks:[(NSApplication.ModalResponse)->Void]=[],selected=child
        owner.presentOpenPanel={_,_,reply in callbacks.append(reply)};owner.selectedPanelURL={_ in selected}
        model.pick(.repository);try require(model.picking && !model.canApply && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Picker lost owner/Close/Quit gate")
        let oldSource=model.source;model.source="changed while picker pending";callbacks[0](.OK)
        try require(!model.picking && model.source=="changed while picker pending","Changed draft accepted obsolete folder")
        model.source=oldSource;model.pick(.path);callbacks[0](.OK);try require(model.picking,"Old callback settled replacement picker");callbacks[1](.cancel)
        try require(!model.picking,"Cancel retained picker")
        model.source="https://host/folder/repo.git";model.pick(.path);selected=parent;callbacks[2](.OK)
        try require(model.path=="repo","Path Browse did not append shared source component at repository root")
        let prior=model.path;model.pick(.path);selected=root;callbacks[3](.OK)
        try require(model.path==prior && model.error != nil,"Outside-tree Browse escaped path validation");model.error=nil
        model.pick(.key);let late=callbacks[4],saved=prefs.dictionaryRepresentation();owner.close();late(.OK);model.pick(.repository)
        try require(!model.picking && owner.panel==nil && callbacks.count==5 && prefs.dictionaryRepresentation() as NSDictionary == saved as NSDictionary,"Forced close/retired callback wrote history or reopened picker")
        try require(try Data(contentsOf:parent.appendingPathComponent(".git/index"))==index,"Input/picker operations changed index")
        // Real local mutation uses only this wrapper's local-file transport grant.
        let wrapper=root.appendingPathComponent("local-git")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        try ("#!/bin/sh\nexec "+quote(git.path)+" -c protocol.file.allow=always \"$@\"\n").write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let submission=SubmoduleAddWindowController(repository:GitRepository(root:parent,executable:wrapper),access:lease,path:"modules",preferences:prefs,clipboardText:"git clone '"+child.absoluteString+"'");defer {submission.close()}
        submission.model.useKey=false;submission.model.sourceEndedEditing();var progress:SubmoduleAddProgressWindowModel?
        submission.model.onSubmit={progress=$0};submission.model.apply()
        try require(progress != nil && !submission.model.canApply && prefs.stringArray(forKey:"SubmoduleAdd.URLHistory")?.first==child.absoluteString && prefs.stringArray(forKey:"SubmoduleAdd.PathHistory")?.first=="modules/source","Accepted submission did not capture/save histories once")
        progress!.start();try await wait {!progress!.busy};try require(progress!.success,"Captured Add failed: \(progress!.output)")
        let childHash=try await GitRepository(root:parent.appendingPathComponent("modules/source"),executable:git).run(["rev-parse","HEAD"]).stdout
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,sourceAfter=try await source.run(["rev-parse","HEAD"]).stdout
        let gitlink=try await repo.run(["ls-files","--stage","--","modules/source"]).text
        try require(after==head && sourceAfter==sourceHead && childHash==sourceHead && gitlink.hasPrefix("160000 "),"Add did not stage correct gitlink or changed source/parent HEAD")
        progress!.invalidate()
        // Actual native panel retirement, separate from injected selection probes.
        let closing=SubmoduleAddWindowController(repository:repo,access:lease,preferences:prefs);defer {closing.close()};closing.window!.alphaValue=0;closing.window!.orderFront(nil);closing.model.pick(.path)
        try await wait {closing.window?.attachedSheet != nil};closing.window!.close();try await wait {closing.window?.attachedSheet==nil}
        try require(!closing.model.picking && !closing.model.canEdit && closing.panel==nil,"Production panel did not retire with owner")
        print("PASS Submodule Add inputs: shared private clipboard defaults, source path derivation, three exact native history deletions, captured/replaced/retired picker replies, actual panel close/Quit gates, accepted-history handoff and real local staged gitlink with source/parent HEAD preserved")
    }
}
