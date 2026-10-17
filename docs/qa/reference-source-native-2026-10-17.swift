import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct ReferenceSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Reference source wait at \(line)")
    }
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String)async throws {
        guard let output=ProcessInfo.processInfo.environment["TURTLEGIT_REFERENCE_SOURCE_CAPTURE"] else{return}
        if #available(macOS 14.4,*) {
            let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:250_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned reference capture missing")}
                let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
                let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
                guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"No reference PNG")}
                try png.write(to:directory.appendingPathComponent(name+"-"+theme+".png"))
            };window.alphaValue=0
        } else {throw Failure(description:"Capture requires macOS 14.4")}
    }
    @MainActor static func main()async {do {try await verify();await cleanup()}catch {await cleanup();fputs("FAIL reference source: \(error)\n",stderr);exit(1)}}
    @MainActor static func cleanup()async {
        for window in NSApp.windows {
            if let owner=window.delegate as? ReferenceBrowserWindowController {owner.close()}
            if let owner=window.delegate as? RemoteTagWindowController {owner.close()}
        }
        for _ in 0..<3000 {
            if ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && RemoteTagWindowModel.activeOperations==0 {return}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
    }
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Reference Source"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Reference source fixture")
        for name in ["topic-a","topic-b"] {_ = try await repo.run(["branch",name])}
        let suite="TurtleGit.ReferenceSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/topic-a",preferences:prefs,picking:false) {_ in}
        defer {owner.close()};let model=owner.model
        owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.load()
        try await wait {!model.busy && model.snapshot != nil}
        let context=model.formContext,query=model.queryBinding(context:context)
        query.wrappedValue="topic"
        try require(model.rows.count==2 && model.filterCue=="Filter by Refname, Subject, Authors, SHA-1","Synchronous query/initial field cue")
        let refname=model.searchField(.referenceNames,context:context);refname.wrappedValue=false
        try require(model.rows.isEmpty && model.filterCue=="Filter by Subject, Authors, SHA-1","Refname field mask/cue")
        refname.wrappedValue=true
        try await wait {views(owner.window?.contentView).compactMap {$0 as? NSSearchField}.first?.placeholderString==model.filterCue}
        let search=views(owner.window?.contentView).compactMap {$0 as? ReferenceBrowserOwnedSearchField}.first!
        let savedQuery=model.query,oldNested=model.nestedBinding(context:context),oldMerge=model.mergeFilterBinding(context:context)
        model.hasChild=true;query.wrappedValue="main";model.hasChild=false
        query.wrappedValue="main";oldNested.wrappedValue = !model.nested;oldMerge.wrappedValue = .unmerged
        try require(model.query==savedQuery && model.nested && model.mergeFilter == .all && !model.busy,"Child lifetime revived retained filter/scope controls")
        model.nestedBinding(context:model.formContext).wrappedValue=false
        try require(model.busy && !prefs.bool(forKey:"RefBrowserIncludeNestedRefs"),"Nested option did not synchronously persist/read")
        try await wait {!model.busy};oldMerge.wrappedValue = .unmerged
        try require(model.mergeFilter == .all,"Old merge filter revived after read")
        model.mergeFilterBinding(context:model.formContext).wrappedValue = .merged
        try require(model.busy && model.mergeFilter == .merged,"Merge-filter selection did not own read immediately")
        try await wait {!model.busy};model.queryBinding(context:model.formContext).wrappedValue=""
        model.setFolder("refs/heads");model.select(["refs/heads/topic-a"],last:"refs/heads/topic-a")
        try await capture(owner.window!,name:"reference-browser-source")
        // Range menus own their displayed pair despite later native selection changes.
        var chosen:[String?]=[]
        let picker=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/topic-a",preferences:prefs,picking:true,pickMultiple:true,allowsRangeSelection:true) {chosen.append($0)}
        defer {picker.close()};picker.model.load();try await wait {!picker.model.busy && picker.model.snapshot != nil}
        picker.model.select(["refs/heads/topic-a","refs/heads/topic-b"],last:"refs/heads/topic-b")
        guard let rangeContext=picker.model.menuContext(),let expected=picker.model.pickRangeChoices.first?.expression else {throw Failure(description:"No range menu")}
        picker.model.select(["refs/heads/main","refs/heads/topic-b"],last:"refs/heads/main")
        picker.model.acceptRange(0,context:rangeContext);picker.model.acceptRange(0,context:rangeContext)
        try require(chosen.count==1 && chosen[0]==expected,"Range accepted current instead of captured pair or accepted twice")
        // Real remote catalog with a name wider than the source-sized native dialog.
        let long="release/"+String(repeating:"long-",count:35)+"雪"
        for name in ["v2","v10",long] {_ = try await repo.run(["tag",name])}
        let tags=RemoteTagWindowController(repository:repo,access:nil,remote:root.path,preferences:prefs)
        defer {tags.close()};tags.presentProgress={_,_ in true};tags.window!.alphaValue=0;tags.window!.orderFront(nil);tags.model.load()
        try await wait {!tags.model.busy && tags.model.tags.count==3}
        try await wait {views(tags.window?.contentView).compactMap {$0 as? RemoteTagOwnedTable}.first?.numberOfRows==3}
        let table=views(tags.window?.contentView).compactMap {$0 as? RemoteTagOwnedTable}.first!
        let all=views(tags.window?.contentView).compactMap {$0 as? RemoteTagOwnedCheckbox}.first!
        let scroll=table.enclosingScrollView!;scroll.tile()
        let measured=(long as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:NSFont.systemFontSize)]).width
        try require(table.tableColumns[0].width>=measured && table.frame.width>scroll.contentSize.width && scroll.hasHorizontalScroller,"Full long tag cannot scroll horizontally")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try require(tags.model.selection.count==1 && tags.model.canDelete,"Actual tag table did not select")
        let before=table.visibleRect.origin
        try await wait {all.state == .mixed}
        try require(table.visibleRect.origin==before,"Selection update moved reading position")
        let retired=tags.model.formContext;tags.model.load();try await wait {!tags.model.busy}
        var confirmations=0;tags.model.confirm={_ in confirmations+=1;return false}
        tags.model.selectAll(.on,context:retired);tags.model.delete(context:retired)
        try require(tags.model.selection.isEmpty && confirmations==0,"Retired tag form selected/deleted new catalog")
        tags.model.select([GitReferenceName(long)],context:tags.model.formContext)
        try await wait {all.state == .mixed}
        try await capture(tags.window!,name:"remote-tags-source")
        owner.close();let queryBefore=model.query
        search.stringValue="closed";if let action=search.action {_ = NSApp.sendAction(action,to:search.target,from:search)}
        try require(search.lifetime.retired && model.query==queryBefore,"Closed search revived")
        tags.close();try require(table.lifetime.retired && all.lifetime.retired,"Closed tag controls not retired")
        print("PASS reference source: synchronous filter masks/cues/scope reads, captured range acceptance, full-width tag scrolling, selection reading position and retired controls")
    }
}
