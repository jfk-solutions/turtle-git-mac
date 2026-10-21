// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ImageIO
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func graphSaveHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));graphSaveHiddenOrder(place,relativeTo:number)
    }
}
private actor RevisionGraphSaveWriteGate {
    private(set) var entered=false
    private(set) var enteredAfterDetach=false
    private var released=false
    func hold(afterDetach:Bool,cancellation:OperationCancellation)async throws {
        enteredAfterDetach=afterDetach;entered=true
        while !released {try cancellation.check();try await Task.sleep(nanoseconds:10_000_000)}
        try cancellation.check()
    }
    func waitUntilEntered()async throws {
        for _ in 0..<3000 {if entered{return};try await Task.sleep(nanoseconds:10_000_000)}
        throw NSError(domain:"Held graph writer did not start",code:1)
    }
    func release(){released=true}
}
@MainActor @main enum RevisionGraphSaveVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {if !condition{throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws {for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Graph save timeout at \(line)")}
    static func drained()->Bool {RevisionGraphWindowModel.activeOperations==0 && RevisionGraphWindowController.activeExportOperations==0 && RepositoryModel.activeCommandFileOperations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.GraphSave."+UUID().uuidString,prefs:UserDefaults
        var owners:[RevisionGraphWindowController]=[],workspaces:[RepositoryModel]=[],index=Data(),config=Data(),head=Data()
        var repo:GitRepository {GitRepository(root:base.appendingPathComponent("repo"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        var helper:URL {URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/graph-layout-runtime/GraphLayout/graph-layout")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set("Menlo",forKey:"LogFontName")}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Graph save QA"),("user.email","graph@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for n in 0..<2 {try Data("file \(n)\n".utf8).write(to:repo.root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"Graph \(n)")}
            _=try await repo.run(["tag","base","HEAD~1"]);_=try await repo.run(["branch","topic"])
            index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"));config=try Data(contentsOf:repo.root.appendingPathComponent(".git/config"));head=try await repo.run(["rev-parse","HEAD"]).stdout
        }
        func owner()async throws->RevisionGraphWindowController {
            let owner=RevisionGraphWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),preferences:prefs,layoutExecutable:helper)
            owners.append(owner);owner.window?.orderFront(nil)
            try await wait{!owner.model.busy && owner.model.geometry != nil}
            try require(owner.model.error==nil,"Graph load failed: "+(owner.model.error ?? "nil"));return owner
        }
        func preserved()async throws {
            try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Export changed index")
            try require(try Data(contentsOf:repo.root.appendingPathComponent(".git/config"))==config,"Export changed config")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"Export changed HEAD")
        }
        func clean()async {
            workspaces.forEach{$0.stopMonitoringForTermination()};owners.forEach{$0.close()}
            for window in NSApp.windows {if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func verifyBytes(_ data:Data,_ format:RevisionGraphFormat)throws {
        switch format {
        case .svg:try require(XMLParser(data:data).parse() && String(decoding:data,as:UTF8.self).contains("<svg"),"Invalid SVG")
        case .graphviz:try require(String(decoding:data,as:UTF8.self).contains("digraph"),"Invalid Graphviz")
        case .pdf:try require(data.starts(with:Data("%PDF".utf8)),"Invalid PDF")
        case .wmf,.emf:
            func word(_ offset:Int)->UInt32 {(0..<4).reduce(UInt32(0)){$0|UInt32(data[offset+$1])<<($1*8)}}
            try require(data.count>=88,"Truncated enhanced metafile "+format.rawValue)
            try require(word(0)==1 && word(4)==88 && word(40)==0x464d4520 && Int(word(48))==data.count,"Wrong enhanced-metafile header "+format.rawValue)
            try require(MetafileImageDecoder.convert(data) != nil,"Actual metafile decoder refused graph "+format.rawValue)
        default:
            guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw Failure(description:"Invalid graph image "+format.rawValue)}
            try require(CGImageSourceGetType(source) as String? == format.contentType.identifier && image.width>0 && image.height>0,"Wrong raster encoding "+format.rawValue)
        }
    }
    static func formats(_ c:Context)async throws {
        let owner=try await c.owner(),picker=RevisionGraphSavePanel()
        try require(picker.formats.numberOfItems==3 && picker.filter == .pictures,"Source filter choices/default missing")
        for(index,input,expected)in[(0,"new graph","new graph.svg"),(1,"new graph","new graph.gv"),(2,"new graph","new graph.jpg"),(0,"custom.PNG","custom.PNG"),(1,"custom.svg","custom.svg"),(2,"custom.unknown","custom.unknown.jpg")] {
            picker.panel.nameFieldStringValue=input;picker.formats.selectItem(at:index);picker.changeFormat()
            guard let final=picker.panel(picker.panel,userEnteredFilename:picker.panel.nameFieldStringValue,confirmed:true) else {throw Failure(description:"Native save panel rejected supported filename")}
            try require(final==expected,"Native filename/default changed: "+final)
            let destination=try picker.destination(for:c.base.appendingPathComponent(final))
            try verifyBytes(owner.graphExportData(format:destination.format),destination.format)
        }
        for format in RevisionGraphFormat.allCases {
            let target=c.base.appendingPathComponent("actual."+format.fileExtension)
            try owner.exportGraph(to:target,format:format);try verifyBytes(Data(contentsOf:target),format)
        }
        // A normalized sibling must never inherit the accepted URL's grant.
        do {_=try picker.destination(for:c.base.appendingPathComponent("not-authorized.unknown"));throw Failure(description:"Unnormalized accepted target was silently redirected")}
        catch is Failure {throw Failure(description:"Unnormalized accepted target was silently redirected")}
        catch {}
        try await c.preserved()
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.owner(),target=c.base.appendingPathComponent("accepted.PNG")
        let gate=RevisionGraphSaveWriteGate(),originalWriter=owner.writeGraph
        let panelDetached:@MainActor @Sendable ()->Bool={ [weak owner] in
            guard let owner,let panel=owner.graphSavePanel?.panel else{return false}
            return panel.sheetParent==nil
        }
        owner.writeGraph={data,url,token in
            let detached=await panelDetached()
            try await gate.hold(afterDetach:detached,cancellation:token)
            try await originalWriter(data,url,token)
        }
        defer {owner.close();Task{await gate.release()}}
        var reply:((NSApplication.ModalResponse)->Void)?,attachedSave:NSSavePanel?
        owner.selectedSaveURL={_ in target};owner.presentSavePanel={panel,parent,completion in
            attachedSave=panel;reply=completion;parent.beginSheet(panel,completionHandler:completion)
        }
        owner.saveGraph();try require(owner.hasExportSheet && !owner.windowShouldClose(owner.window!),"Save owner did not lock")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit accepted pending save")
        let zoom=owner.model.zoom;owner.perform("zoomIn");try require(owner.model.zoom==zoom,"Save allowed graph mutation")
        reply?(.OK);reply?(.OK)
        try await gate.waitUntilEntered()
        guard let save=attachedSave else {throw Failure(description:"Actual save sheet missing")}
        let enteredAfterDetach=await gate.enteredAfterDetach
        try require(enteredAfterDetach && save.sheetParent==nil && owner.hasPendingWork && RevisionGraphWindowController.activeExportOperations>0 && !FileManager.default.fileExists(atPath:target.path),"Writer started before native sheet detach or lost pending/no-publication ownership")
        await gate.release()
        try await wait{!owner.hasPendingWork && !owner.hasExportSheet}
        try require(save.sheetParent==nil,"Completed save left native sheet attached")
        try verifyBytes(Data(contentsOf:target),.png)
        owner.presentSavePanel={_,_,completion in reply=completion}
        try Data("sentinel".utf8).write(to:target);reply?(.OK)
        try await Task.sleep(nanoseconds:20_000_000)
        try require(try Data(contentsOf:target)==Data("sentinel".utf8),"Duplicate save reply overwrote destination")
        owner.model.confirmingQuit=true;owner.saveGraph();owner.perform("zoomIn")
        try require(!owner.hasExportSheet && owner.model.zoom==zoom,"Global Quit did not freeze graph")
        owner.model.confirmingQuit=false;owner.saveGraph();reply?(.cancel)
        try await wait{!owner.hasPendingWork && !owner.hasExportSheet}
        try require(try Data(contentsOf:target)==Data("sentinel".utf8),"Cancel overwrote target")
        let retired=try await c.owner();var stale:((NSApplication.ModalResponse)->Void)?
        let missing=c.base.appendingPathComponent("stale.svg")
        retired.selectedSaveURL={_ in missing};retired.presentSavePanel={_,_,completion in stale=completion}
        retired.saveGraph();retired.close();stale?(.OK)
        try await wait{!retired.hasPendingWork}
        try require(retired.model.closed && !FileManager.default.fileExists(atPath:missing.path),"Retired save wrote output")
        let invalidOwner=try await c.owner(),invalid=c.base.appendingPathComponent("not-approved.unknown"),sibling=c.base.appendingPathComponent("not-approved.unknown.jpg")
        var invalidReply:((NSApplication.ModalResponse)->Void)?,errorReply:((NSApplication.ModalResponse)->Void)?,errorSheet:NSWindow?,closed=false
        invalidOwner.selectedSaveURL={_ in invalid};invalidOwner.presentSavePanel={_,_,completion in invalidReply=completion}
        invalidOwner.presentExportError={parent,alert,completion in
            errorSheet=alert.window;errorReply=completion;parent.beginSheet(alert.window,completionHandler:completion)
        }
        invalidOwner.onClosed={closed=true};invalidOwner.saveGraph();invalidReply?(.OK)
        try await wait{errorSheet?.sheetParent === invalidOwner.window && invalidOwner.exportError != nil}
        try require(invalidOwner.hasPendingWork && invalidOwner.hasExportSheet && !invalidOwner.windowShouldClose(invalidOwner.window!),"Owned export error lost close/work gate")
        try require(!FileManager.default.fileExists(atPath:invalid.path) && !FileManager.default.fileExists(atPath:sibling.path),"Unnormalized accepted URL wrote an unauthorized destination")
        errorReply?(.OK);errorReply?(.OK)
        try await Task.sleep(nanoseconds:20_000_000)
        try require(invalidOwner.hasPendingWork && !closed && errorSheet?.sheetParent === invalidOwner.window,"Error reply released ownership before sheet detach")
        invalidOwner.close()
        try await wait{closed && !invalidOwner.hasPendingWork && errorSheet?.sheetParent==nil}
        try require(invalidOwner.model.closed && !FileManager.default.fileExists(atPath:sibling.path),"Error owner closure wrote fallback or left work pending")
        try await c.preserved()
    }
    static func command(_ c:Context)async throws {
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:c.base.appendingPathComponent("marks.json")),cachePersistenceDefaults:c.prefs)
        c.workspaces.append(workspace);workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=c.prefs
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:c.repo.root)}
        var grants:[URL]=[]
        workspace.commandLineOutputPermission={url in grants.append(url);c.prefs.set("Helvetica",forKey:"LogFontName");return RepositoryAccessLease(url:url.deletingLastPathComponent())}
        var capturedPreferences:[Bool]=[]
        workspace.revisionGraphWindowFactory={repository,access,preferences,load in
            capturedPreferences.append(preferences !== c.prefs && preferences.string(forKey:"LogFontName")=="Menlo")
            let owner=RevisionGraphWindowController(repository:repository,access:access,preferences:preferences,layoutExecutable:c.helper,automaticallyLoad:load);c.owners.append(owner);return owner
        }
        for(name,actual,format)in[("output","output.jpg",RevisionGraphFormat.jpeg),("custom.odd","custom.odd.jpg",.jpeg),("typed.PNG","typed.PNG",.png),("topology.gv","topology.gv",.graphviz),("native.pdf","native.pdf",.pdf),("legacy.wmf","legacy.wmf",.wmf)] {
            let expected=c.base.appendingPathComponent(actual),original=c.base.appendingPathComponent(name)
            c.prefs.set("Menlo",forKey:"LogFontName")
            workspace.error=nil;workspace.handleCommandLine(arguments:["--command=revisiongraph","--path",c.repo.root.path,"--output",original.path],currentDirectory:c.repo.root.path)
            try await wait{!workspace.busy && !workspace.hasPendingRepositoryWork && drained()}
            try require(workspace.error==nil,"Hidden graph failed: "+(workspace.error ?? "nil"))
            try require(grants.last?.path==expected.path,"Permission did not name final output")
            try require(capturedPreferences.last==true && c.owners.last?.model.font.familyName=="Menlo" && c.prefs.string(forKey:"LogFontName")=="Helvetica","Command graph retargeted preferences after accepted output permission")
            try verifyBytes(Data(contentsOf:expected),format)
            try require(c.owners.allSatisfy{$0.model.closed && $0.window?.isVisible != true},"Hidden graph controller survived")
            if name != actual {try require(!FileManager.default.fileExists(atPath:original.path),"Fallback wrote unnormalized path")}
        }
        let countBeforeDenial=c.owners.count,denied=c.base.appendingPathComponent("denied.jpg")
        workspace.error=nil;workspace.commandLineOutputPermission={_ in nil}
        workspace.handleCommandLine(arguments:["--command=revisiongraph","--path",c.repo.root.path,"--output",denied.path],currentDirectory:c.repo.root.path)
        try await wait{!workspace.busy && !workspace.hasPendingRepositoryWork && drained()}
        try require(!FileManager.default.fileExists(atPath:denied.path) && c.owners.count==countBeforeDenial,"Denied output created a graph or destination")

        // Hold the actual native layout helper, then retire its command owner.
        // Accepted worker cancellation must settle before the permissions and
        // global Quit accounting disappear; no output may arrive afterward.
        let wrapper=c.base.appendingPathComponent("held-graph-layout"),marker=c.base.appendingPathComponent("held-graph-layout.ready")
        let executable=c.helper.path.replacingOccurrences(of:"'",with:"'\\''")
        let script="""
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s' "$$" "$task_child" > "$0.ready.tmp"
        /bin/mv "$0.ready.tmp" "$0.ready"
        wait "$task_child"
        exec '\(executable)' "$@"
        """
        try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        workspace.commandLineOutputPermission={url in RepositoryAccessLease(url:url.deletingLastPathComponent())}
        workspace.revisionGraphWindowFactory={repository,access,preferences,load in
            let owner=RevisionGraphWindowController(repository:repository,access:access,preferences:preferences,layoutExecutable:wrapper,automaticallyLoad:load);c.owners.append(owner);return owner
        }
        let cancelled=c.base.appendingPathComponent("cancelled.svg")
        workspace.error=nil;workspace.handleCommandLine(arguments:["--command=revisiongraph","--path",c.repo.root.path,"--output",cancelled.path],currentDirectory:c.repo.root.path)
        defer{workspace.stopMonitoringForTermination()}
        try await wait{FileManager.default.fileExists(atPath:marker.path) && RevisionGraphWindowModel.activeOperations>0}
        let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && workspace.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations>0,"Held command lost worker ownership")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored held command export")
        workspace.stopMonitoringForTermination()
        try await wait{!workspace.hasPendingRepositoryWork && drained() && pids.allSatisfy{kill($0,0) != 0}}
        try require(!FileManager.default.fileExists(atPath:cancelled.path) && c.owners.allSatisfy{$0.model.closed},"Retired command published output or kept a hidden graph alive")
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.graphSaveHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.seed()
            let which=CommandLine.arguments[3]
            switch which {case "formats":try await formats(c);case "ownership":try await ownership(c);case "command":try await command(c);default:throw Failure(description:"Unknown case")}
            await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Receiver did not drain")
            print("PASS: Revision Graph save "+which)
        }catch{await c.clean();throw error}
    }
}
