import AppKit
import ScreenCaptureKit
import Darwin
import TurtleGitCore

@main struct SubmoduleSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Submodule wait at \(line)")
    }
    @MainActor static func capture(_ window: NSWindow, directory: URL) async throws {
        if #available(macOS 14.4,*) {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned Update window absent")}
                let config=SCStreamConfiguration();config.width=Int(window.frame.width * 2);config.height=Int(window.frame.height * 2);config.showsCursor=false
                let filter=SCContentFilter(desktopIndependentWindow:owned);config.includeChildWindows=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
                guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"No Update PNG")}
                try png.write(to:directory.appendingPathComponent("submodule-update-source-"+name+".png"))
            };window.alphaValue=0
        } else {throw Failure(description:"Capture needs macOS 14.4")}
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do {try await verify();await cleanup();print("PASS Submodule source family")}
        catch {await cleanup();fputs("FAIL Submodule source family: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func cleanup() async {
        for window in NSApp.windows {
            if let owner=window.delegate as? SubmoduleUpdateWindowController {owner.close()}
            if let owner=window.delegate as? SubmoduleAddWindowController {owner.close()}
        }
        for _ in 0..<3000 {if SubmoduleUpdateWindowModel.activeReads==0 {return};try? await Task.sleep(nanoseconds:10_000_000)}
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
        let suite="TurtleGit.SubmoduleSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let modules=root.appendingPathComponent(".gitmodules"),first="folder/one",second="elsewhere/two"
        for (name,path) in [("first",first),("second",second)] {
            _ = try await repo.run(["config","--file",modules.path,"submodule."+name+".path",path])
            _ = try await repo.run(["config","--file",modules.path,"submodule."+name+".url","https://example.invalid/"+name])
        }
        let owner=SubmoduleUpdateWindowController(repository:repo,access:nil,scope:["folder"],preferences:prefs)
        defer {owner.close()};let model=owner.model
        owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load()
        try await wait {!model.busy && model.paths==[first]}
        try require(owner.window!.title.contains("folder"),"Scoped title missing")
        var received:[String]=[],accepted:SubmoduleUpdateOptions?
        model.onSubmit={received=$0;accepted=$1}
        let old=model.formContext,staleForce=model.option(\.force,context:old),scope=model.wholeProjectBinding(context:old)
        scope.wrappedValue=true
        try require(model.busy && model.wholeProject && prefs.bool(forKey:"SubmoduleUpdate."+root.path+".wholeProject"),"Scope did not synchronously own reload/persistence")
        staleForce.wrappedValue=true;model.setSelectedPaths([],context:old);model.apply(context:old)
        try await wait {!model.busy}
        try require(Set(model.paths)==[first,second] && model.selection==Set([first,second].map { GitReferenceName($0) }) && !model.options.force && received.isEmpty,"Stale scoped form changed reloaded selection/options or submitted")
        scope.wrappedValue=false;staleForce.wrappedValue=true
        try require(model.wholeProject && !model.options.force,"Retired bindings revived after load")
        let current=model.formContext
        for field in [\SubmoduleUpdateOptions.initialize,\.recursive,\.force,\.remote,\.noFetch,\.merge,\.rebase] {model.option(field,context:current).wrappedValue=true}
        model.setSelectedPaths([GitReferenceName(first)],context:current)
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_SUBMODULE_SOURCE_CAPTURE"] {try await capture(owner.window!,directory:URL(fileURLWithPath:output))}
        // Failed refresh keeps its diagnostic actionable, but cannot submit an old catalog.
        try Data("[broken\n".utf8).write(to:modules);model.load();try await wait {!model.busy}
        try require(model.error != nil && !model.canApply,"Metadata failure accepted old selection")
        try FileManager.default.removeItem(at:modules)
        _ = try await repo.run(["config","--file",modules.path,"submodule.first.path",first])
        model.load();try require(model.error==nil && model.busy,"Retry did not clear diagnostic/start read")
        try await wait {!model.busy};let acceptedContext=model.formContext
        let quitOption=model.option(\.force,context:acceptedContext),before=model.options.force
        model.confirmingQuit=true;quitOption.wrappedValue = !before;model.confirmingQuit=false;quitOption.wrappedValue = !before
        try require(model.options.force==before,"Quit lifetime revived old option")
        model.apply(context:model.formContext);model.apply(context:model.formContext)
        try require(received==[first] && accepted?.initialize==true && accepted?.recursive==true && accepted?.force==true && accepted?.remote==true && accepted?.noFetch==true && accepted?.merge==true && accepted?.rebase==true,"Single accepted path/options snapshot changed")
        let restored=SubmoduleUpdateWindowModel(repository:repo,access:nil,scope:[],selected:[],preferences:prefs);defer {restored.invalidate()}
        try require(restored.options.force && restored.options.merge && restored.options.rebase,"Saved independent options lost")
        // Real in-flight metadata process: Cancel returns immediately; the owned read drains.
        let wrapper=root.appendingPathComponent("paused-git"),marker=root.appendingPathComponent("started")
        let script="""
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = config ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > '\(marker.path)'
            wait "$task_child"
          fi
        done
        exec '\(git.path)' "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let pending=SubmoduleUpdateWindowController(repository:GitRepository(root:root,executable:wrapper),access:nil,scope:[],preferences:prefs)
        defer {pending.close()};pending.model.load()
        try await wait {(try? String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).count)==2}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
        try require(pending.model.busy && pending.windowShouldClose(pending.window!),"Loading dialog cannot close")
        let pendingContext=pending.model.formContext,pendingForce=pending.model.options.force;var closed=0;pending.onClosed={closed+=1};pending.model.cancel();pending.model.cancel()
        try require(closed==1 && !pending.model.canApply,"Cancel did not retire once")
        try await wait {SubmoduleUpdateWindowModel.activeReads==0}
        pending.model.option(\.force,context:pendingContext).wrappedValue = !pendingForce
        try require(pending.model.paths.isEmpty && pending.model.options.force==pendingForce && pending.model.error==nil,"Cancelled read published late state")
        try await wait {pids.allSatisfy {kill($0,0) != 0 && errno==ESRCH}}
        // Add dependencies, stale history indices, picker/Quit lifetimes and retired submission.
        let add=SubmoduleAddWindowModel(repository:repo,access:nil,path:"folder",preferences:prefs,clipboardText:"")
        defer {add.invalidate()};add.source="https://example.invalid/source.git";add.path="folder/source";add.useKey=false
        let initial=add.formContext;add.field(\.branch,context:initial).wrappedValue="blocked"
        try require(add.branch.isEmpty,"Hidden branch accepted edit")
        add.field(\.useBranch,context:initial).wrappedValue=true
        add.field(\.branch,context:initial).wrappedValue="stale"
        try require(add.branch.isEmpty,"Pre-branch form revived")
        let branch=add.field(\.branch,context:add.formContext);branch.wrappedValue="main"
        let retired=add.field(\.source,context:add.formContext);add.picking=true;retired.wrappedValue="wrong";add.picking=false;retired.wrappedValue="wrong"
        try require(add.source=="https://example.invalid/source.git" && add.branch=="main","Picker lifetime revived Add edit")
        let quit=add.field(\.path,context:add.formContext);add.confirmingQuit=true;add.confirmingQuit=false;quit.wrappedValue="wrong"
        try require(add.path=="folder/source","Quit lifetime revived Add edit")
        var additions=0;add.onSubmit={_ in additions+=1};let submit=add.formContext;add.apply(context:submit);add.apply(context:submit)
        try require(additions==1,"Add submitted more than once")
        branch.wrappedValue="wrong";try require(add.branch=="main","Submitted Add accepted retained edit")
    }
}
