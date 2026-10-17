import AppKit
import TurtleGitCore

struct MergeSaveAccessVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    final class Provider:RepositoryBookmarkProvider {
        var started=[URL](),stopped=[URL]()
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {started.append(url);return true}
        func stopAccessing(_ url:URL) {stopped.append(url)}
    }
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        try await policy(root:root)
        try await comparison(root:root)
        try await merge(root:root)
        print("PASS: parent-folder grant containment/reuse, leaf and sibling refusal, actual owned panel Cancel, Compare Save/Save As/backups and unified patch, merged output/source export and related-scope reuse, Close/Quit ownership, held grant cancellation/retirement and no late writes; owned windows closed; injected scopes, not signed sandbox acceptance")
    }
    @MainActor static func policy(root:URL) async throws {
        let provider=Provider(),folder=root.appendingPathComponent("policy"),other=root.appendingPathComponent("other")
        for url in [folder,other] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let file=folder.appendingPathComponent("file"),access=MergeSaveFolderAccess(),token=OperationCancellation()
        access.requireScope=true;access.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
        let leaf=RepositoryAccessLease(url:file,provider:provider);var asks=0
        access.chooseFolder={_,parent in asks += 1;try! require(parent.path==folder.path,"Wrong required folder");return folder}
        let acquired=try await access.authorize(file:file,permissions:[leaf],window:nil,cancellation:token)
        try require(asks==1 && acquired?.count==1,"Leaf file was treated as folder access")
        let related=leaf.retainingRelatedScopes(acquired!)
        let reused=try await access.authorize(file:file,permissions:[related],window:nil,cancellation:token)
        try require(reused?.isEmpty==true && asks==1,"Related parent grant not reused")
        access.chooseFolder={_,_ in other}
        do {_=try await access.authorize(file:file,permissions:[leaf],window:nil,cancellation:token);throw Failure(description:"Sibling folder accepted")} catch RepositoryAccessFailure.securityScopeUnavailable {}
        let window=NSWindow(contentRect:.init(x:0,y:0,width:500,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        defer {window.close()};window.isReleasedWhenClosed=false;window.alphaValue=0;window.orderFront(nil)
        access.chooseFolder=nil;let cancelled=OperationCancellation();var completed=false,wasCancelled=false
        Task {do {_=try await access.authorize(file:file,permissions:[leaf],window:window,cancellation:cancelled)} catch OperationCancellationFailure.cancelled {wasCancelled=true} catch {};completed=true}
        try await SaveAsTargetsVerification.wait([window]) {access.panel != nil && window.attachedSheet != nil}
        try require(access.panel?.canChooseDirectories==true && access.panel?.canChooseFiles==false && access.panel?.prompt=="Allow Save","Folder panel options")
        cancelled.cancel();access.cancel();try await SaveAsTargetsVerification.wait([window]) {completed && window.attachedSheet==nil}
        try require(wasCancelled,"Owned folder panel did not cancel")
    }
    @MainActor static func comparison(root:URL) async throws {
        let provider=Provider(),folder=root.appendingPathComponent("compare"),output=root.appendingPathComponent("copy"),patchFolder=root.appendingPathComponent("patch"),lateFolder=root.appendingPathComponent("late")
        for url in [folder,output,patchFolder,lateFolder] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let left=folder.appendingPathComponent("left"),right=folder.appendingPathComponent("right"),copy=output.appendingPathComponent("chosen"),patch=patchFolder.appendingPathComponent("change.diff"),late=lateFolder.appendingPathComponent("late")
        try Data("left\n".utf8).write(to:left);try Data("right\n".utf8).write(to:right)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[RepositoryAccessLease(url:left,provider:provider),RepositoryAccessLease(url:right,provider:provider)])
        defer {owner.close()};let model=owner.model,window=owner.window!
        window.alphaValue=0;window.orderFront(nil);model.editorConfigEnabled=[true:false,false:false];model.load()
        let suite="TurtleGit.SaveAccess."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)};MergeFileSaveOptions.saveBackupPreference(true,to:defaults);model.comparisonDefaults=defaults
        try await SaveAsTargetsVerification.wait([window]) {!model.busy && !model.filtering && model.document != nil}
        var reply:CheckedContinuation<URL?,Never>?,asks=0,completed:Bool?
        model.saveFolderAccess.requireScope=true;model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
        model.saveFolderAccess.chooseFolder={_,parent in asks += 1;try! require(parent.path==folder.path,"Normal Save folder");return await withCheckedContinuation {reply=$0}}
        SaveAsTargetsVerification.type(SaveAsTargetsVerification.textView(window,label:"Destination file"),"edited\n")
        try await SaveAsTargetsVerification.wait([window]) {!model.filtering}
        model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {reply != nil}
        try require(model.busy && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel,"Folder choice lost Save ownership")
        model.save();model.load();try require(asks==1,"Duplicate grant request")
        reply?.resume(returning:nil);reply=nil;try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==false && model.dirty && Data(contentsOf:right)==Data("right\n".utf8),"Folder Cancel changed original")
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {reply != nil};reply?.resume(returning:folder);reply=nil
        try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.filtering}
        try require(completed==true && Data(contentsOf:URL(fileURLWithPath:right.path+".bak"))==Data("right\n".utf8),"Authorized Save/backup")
        model.chooseExportLocation={_,_,_ in copy};model.saveFolderAccess.chooseFolder={_,parent in asks += 1;try! require(parent.path==output.path,"Save As folder");return output}
        model.saveAs(base:false);try await SaveAsTargetsVerification.wait([window]) {!model.busy && !model.filtering}
        try require(model.savedPaneURL(base:false)==copy && asks==3,"Save As folder/target binding")
        SaveAsTargetsVerification.type(SaveAsTargetsVerification.textView(window,label:"Destination file"),"second\n");try await SaveAsTargetsVerification.wait([window]) {!model.filtering}
        completed=nil;model.save {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil && !model.filtering}
        try require(completed==true && asks==3 && Data(contentsOf:copy)==Data("second\n".utf8),"Retained parent grant not reused")
        model.patchExecutable=URL(fileURLWithPath:CommandLine.arguments[2]);model.choosePatchLocation={_,_,_ in patch};model.saveFolderAccess.chooseFolder={_,parent in asks += 1;try! require(parent.path==patchFolder.path,"Patch folder");return nil}
        model.createUnifiedPatch();try await SaveAsTargetsVerification.wait([window]) {!model.exporting}
        try require(!FileManager.default.fileExists(atPath:patch.path),"Cancelled patch grant wrote output")
        model.saveFolderAccess.chooseFolder={_,_ in patchFolder};model.createUnifiedPatch();try await SaveAsTargetsVerification.wait([window]) {!model.exporting}
        try require(try String(contentsOf:patch).contains("diff --git"),"Authorized unified diff missing")
        model.chooseExportLocation={_,_,_ in late};model.saveFolderAccess.chooseFolder={_,_ in await withCheckedContinuation {reply=$0}}
        model.saveAs(base:false);try await SaveAsTargetsVerification.wait([window]) {reply != nil}
        let active=FileComparisonWindowModel.activePaneExports,started=provider.started.count
        owner.close();try require(FileComparisonWindowModel.activePaneExports==active,"Held folder choice lost lifetime")
        reply?.resume(returning:lateFolder);reply=nil;try await SaveAsTargetsVerification.wait([]) {FileComparisonWindowModel.activePaneExports==active-1}
        try require(!FileManager.default.fileExists(atPath:late.path) && provider.started.count==started,"Late folder reply acquired scope or wrote file")
    }
    @MainActor static func merge(root:URL) async throws {
        let provider=Provider(),folder=root.appendingPathComponent("merge"),output=root.appendingPathComponent("merged-output"),sourceFolder=root.appendingPathComponent("source-output"),lateFolder=root.appendingPathComponent("source-late")
        for url in [folder,output,sourceFolder,lateFolder] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
        let base=folder.appendingPathComponent("base"),mine=folder.appendingPathComponent("mine"),theirs=folder.appendingPathComponent("theirs"),chosen=output.appendingPathComponent("merged"),source=sourceFolder.appendingPathComponent("left"),late=lateFolder.appendingPathComponent("late")
        for (url,text) in [(base,"base\n"),(mine,"mine\n"),(theirs,"theirs\n")] {try Data(text.utf8).write(to:url)}
        let owner=TextConflictWindowController(repository:GitRepository(root:folder),access:nil,path:"result",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),permissions:[base,mine,theirs].map {RepositoryAccessLease(url:$0,provider:provider)})
        defer {owner.close()};let model=owner.model,window=owner.window!
        window.alphaValue=0;window.orderFront(nil);model.load();try await SaveAsTargetsVerification.wait([window]) {!model.busy && model.document != nil}
        model.result="merged\n";model.chooseStandaloneOutput={_,_ in chosen};model.saveFolderAccess.requireScope=true;model.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
        var asks=0,completed:Bool?
        model.saveFolderAccess.chooseFolder={_,parent in asks += 1;try! require(parent.path==output.path,"Merge output folder");return nil}
        model.save(markResolved:false) {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==false && !FileManager.default.fileExists(atPath:chosen.path),"Merged folder Cancel wrote")
        model.saveFolderAccess.chooseFolder={_,_ in asks += 1;return output};completed=nil;model.save(markResolved:false) {completed=$0}
        try await SaveAsTargetsVerification.wait([window]) {completed != nil};try require(completed==true && asks==2,"Merged output grant/save")
        model.result="later\n";completed=nil;model.save(markResolved:false) {completed=$0};try await SaveAsTargetsVerification.wait([window]) {completed != nil}
        try require(completed==true && asks==2 && Data(contentsOf:chosen)==Data("later\n".utf8),"Merged grant not reused")
        let exporter=model.sourceExporter;exporter.saveFolderAccess.requireScope=true;exporter.saveFolderAccess.makeLease={RepositoryAccessLease(url:$0,provider:provider)}
        var answer:((NSApplication.ModalResponse)->Void)?
        exporter.present={_,_,completion in answer=completion};exporter.selectedURL={_ in source};exporter.saveFolderAccess.chooseFolder={_,_ in sourceFolder}
        model.exportSource(mine:false);answer?(.OK);try await SaveAsTargetsVerification.wait([window]) {!model.exportingSource}
        try require(model.sourceTargetURL(mine:false)==source,"Source Save As did not bind")
        model.result="related grant\n";model.chooseStandaloneOutput={_,_ in sourceFolder.appendingPathComponent("merged")};completed=nil
        try await SaveAsTargetsVerification.wait([window]) {model.sourceToolsAllowed}
        model.export();try await SaveAsTargetsVerification.wait([window]) {!model.busy}
        try require(asks==2 && model.workingMergeOutput?.deletingLastPathComponent().path==sourceFolder.path,"Related exported-source folder scope not reused: asks=\(asks), target=\(String(describing:model.workingMergeOutput)), error=\(String(describing:model.error)), ready=\(model.nativeEditorReady)")
        var reply:CheckedContinuation<URL?,Never>?
        exporter.selectedURL={_ in late};exporter.saveFolderAccess.chooseFolder={_,_ in await withCheckedContinuation {reply=$0}}
        model.exportSource(mine:true);answer?(.OK);try await SaveAsTargetsVerification.wait([window]) {reply != nil}
        let active=MergeSourceExport.activeExports,started=provider.started.count
        try require(model.exportingSource && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel,"Source folder request lost owner")
        owner.close();try require(MergeSourceExport.activeExports==active,"Retired source folder request lost lifetime")
        reply?.resume(returning:lateFolder);reply=nil;try await SaveAsTargetsVerification.wait([]) {MergeSourceExport.activeExports==active-1}
        try require(!FileManager.default.fileExists(atPath:late.path) && provider.started.count==started,"Late source-folder reply wrote/acquired scope")
    }
}
