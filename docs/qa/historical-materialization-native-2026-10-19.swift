// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum HistoricalMaterializationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Historical output timeout at \(line)")}
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func phase(_ label:String) {fputs("Historical output phase: "+label+"\n",stderr)}
    static func drained()->Bool {RepositoryBrowserWindowModel.activeOperations==0 && RepositoryBrowserFileOperation.activeRequests==0 && RepositoryBrowserExportFiles.activeLoads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeHistoryLoads==0 && LogDocumentOpenSession.activeRequests==0 && RevisionComparisonWindowModel.activeFileOperations==0 && RepositoryModel.activeCommandFileOperations==0 && AlternativeEditor.activeRequests==0 && ExternalDocumentApplication.activeRequests==0}
    static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3]),fm=FileManager.default
        let root=base.appendingPathComponent("repository"),repo=GitRepository(root:base.appendingPathComponent("repository"),executable:git,askpass:nil),path="nested/source 雪.txt"
        try fm.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Materialization QA"),("user.email","output@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("filter.qa.clean","cat"),("filter.qa.required","true")] {_ = try await repo.run(["config",key,value])}
        let filter=base.appendingPathComponent("smudge"),hold=base.appendingPathComponent("smudge.hold"),ready=base.appendingPathComponent("smudge.ready")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        if [ -f "$0.hold" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
          /bin/mv "$0.ready.tmp" "$0.ready"
          wait "$task_child"
        fi
        exec /usr/bin/sed 's/source/FILTERED/g'
        """
        try script.write(to:filter,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:filter.path)
        _ = try await repo.run(["config","filter.qa.smudge",quote(filter.path)])
        try Data("*.txt filter=qa\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
        try Data("source first\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([".gitattributes",path]);_ = try await repo.commit(message:"first")
        let first=try await repo.rebaseCommit("HEAD")
        let raw=Data("source second\n".utf8),filtered=Data("FILTERED second\n".utf8)
        try raw.write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"second")
        let head=try await repo.rebaseCommit("HEAD"),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.HistoricalOutput."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges")
        func selected(){prefs.set(true,forKey:"UseLibgit2");prefs.set(0x200,forKey:"UseLibgit2_mask")}
        func disabled(){prefs.set(false,forKey:"UseLibgit2")}
        func captured()->GitLibGit2Configuration {.load(from:prefs,helperURL:helper)}
        selected()
        let grant=RepositoryAccessLease(url:root),app=base.appendingPathComponent("Reader.app"),other=base.appendingPathComponent("Other.app")
        try fm.createDirectory(at:app,withIntermediateDirectories:true);try fm.createDirectory(at:other,withIntermediateDirectories:true)
        AlternativeEditorPreferences(custom:true,applicationPath:app.path).save(to:prefs)
        let browser=RepositoryBrowserWindowController(repository:repo,access:grant,revision:head.hash,preferences:prefs,initialFile:path)
        let log=LogWindowController(repository:repo,access:grant,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false)
        let compare=RevisionComparisonWindowModel(repository:repo,access:grant,from:.revision(first.hash),to:.revision(head.hash),preferences:prefs)
        var saveReply:((NSApplication.ModalResponse)->Void)?,savePanel:NSSavePanel?,applicationReply:((NSApplication.ModalResponse)->Void)?
        var chooser:CheckedContinuation<URL?,Never>?
        defer {chooser?.resume(returning:nil);browser.close();log.close();compare.invalidate();HistoricalPreviewFiles.discardAll();RepositoryBrowserExportFiles.discardAll();prefs.removePersistentDomain(forName:suite)}
        browser.model.captureMaterializationBackend=captured;log.model.captureMaterializationBackend=captured;compare.captureMaterializationBackend=captured
        browser.window?.orderFront(nil);log.window?.orderFront(nil)
        try await wait{!browser.model.busy && !log.model.busy && !log.model.entries.isEmpty}
        let entry=browser.model.entries.first{$0.path==path}!
        phase("Browser open/editor")
        // Real source menu outputs use filtered content and preserve the
        // accepted application/configuration through asynchronous materialization.
        var launched:[(URL,Data)]=[]
        browser.defaultApplication={_ in app};browser.selectedApplication={_ in app}
        browser.launchDocument={application,documents,_ in launched.append((application,try Data(contentsOf:documents[0])))}
        for action in [RepositoryBrowserWindowModel.FileAction.open,.alternativeEditor] {
            selected();AlternativeEditorPreferences(custom:true,applicationPath:app.path).save(to:prefs)
            let count=launched.count;browser.model.open(entry,action:action);disabled();AlternativeEditorPreferences(custom:true,applicationPath:other.path).save(to:prefs)
            try await wait{!browser.model.handlingFile && RepositoryBrowserWindowModel.activeOperations==0 && launched.count>count}
            let launchedPath=launched.last?.0.standardizedFileURL.path ?? "",expectedPath=app.standardizedFileURL.path
            try require(GitReferenceName.equal(launchedPath,expectedPath) && launched.last?.1==filtered,"Browser open/editor changed accepted bytes or application: action=\(action), actualURL=\(String(describing:launched.last?.0.absoluteString)), expectedURL=\(app.absoluteString), actualPath=\(launchedPath.debugDescription), expectedPath=\(expectedPath.debugDescription), bytes=\(launched.last?.1.base64EncodedString() ?? "nil"), expectedBytes=\(filtered.base64EncodedString())")
        }
        phase("Browser Open With")
        browser.presentApplicationPanel={panel,parent,reply in parent.beginSheet(panel);applicationReply=reply}
        selected();browser.model.open(entry,action:.openWith);try await wait{applicationReply != nil};disabled();applicationReply?(.OK);applicationReply?(.OK)
        try await wait{!browser.model.handlingFile && RepositoryBrowserFileOperation.activeRequests==0}
        try require(launched.last?.1==filtered && launched.count==3,"Open With did not retain exact filtered output or duplicated reply")
        phase("Browser Save As")
        let saved=base.appendingPathComponent("saved.txt");browser.saveDestination={_ in saved}
        browser.presentSavePanel={panel,parent,reply in savePanel=panel;parent.beginSheet(panel);saveReply=reply}
        browser.writeDocument={bytes,url,token in try require(savePanel?.sheetParent==nil,"Save began before actual sheet detach");try token.check();try bytes.write(to:url,options:.atomic)}
        selected();browser.model.open(entry,action:.save);try await wait{saveReply != nil};disabled();saveReply?(.cancel);saveReply?(.OK)
        try await wait{!browser.model.handlingFile};try require(!fm.fileExists(atPath:saved.path),"Cancelled Save wrote output")
        saveReply=nil;selected();browser.model.open(entry,action:.save);try await wait{saveReply != nil};disabled();saveReply?(.OK)
        try await wait{!browser.model.handlingFile && RepositoryBrowserFileOperation.activeRequests==0}
        try require(try Data(contentsOf:saved)==filtered,"Browser Save ignored accepted filtered bytes")
        phase("Browser provider")
        // Provider callbacks may begin later, after settings and owner changes.
        selected();var provider:NSItemProvider?=browser.model.dragProvider(entry);disabled()
        let promised:Data=try await withCheckedThrowingContinuation {reply in
            provider!.loadFileRepresentation(forTypeIdentifier:provider!.registeredTypeIdentifiers[0]){url,error in
                do {if let error{throw error};guard let url else {throw Failure(description:"Missing promised output")};reply.resume(returning:try Data(contentsOf:url))}catch{reply.resume(throwing:error)}
            }
        }
        try require(promised==filtered,"Historical drag failed to retain accepted engine")
        provider=nil;RepositoryBrowserExportFiles.discardAll()
        phase("Log Open/Save")
        // Log's Open and Save paths materialize separately from raw comparison.
        log.model.select([head.hash]);try await wait{log.model.files.contains{$0.path==path}}
        let file=log.model.files.first{$0.path==path}!;var opened:Data?,saveContent:Data?
        log.model.presentHistoricalOpen={content,_ in opened=content.bytes};log.model.presentHistoricalSave={content,_ in saveContent=content.bytes}
        selected();log.model.openHistoricalFile([file.id],action:.open);disabled();try await wait{!log.model.busy && LogWindowModel.activeFileOpenReads==0}
        try require(opened==filtered,"Log Open emitted raw blob")
        selected();log.model.saveHistoricalFile([file.id]);disabled();try await wait{!log.model.busy && LogWindowModel.activeFileOpenReads==0}
        try require(saveContent==filtered,"Log Save emitted raw blob")
        phase("Log export")
        let exportFolder=base.appendingPathComponent("log-export");try fm.createDirectory(at:exportFolder,withIntermediateDirectories:true)
        selected();var exportRequest:(String,[CommitFile],GitLibGit2Configuration?)?
        log.model.presentHistoricalExport={ [weak model=log.model] revision,files in exportRequest=(revision,files,model?.historicalExportBackend)}
        log.model.chooseHistoricalExport([file.id]);disabled()
        guard let exportRequest else {throw Failure(description:"Log export request missing")}
        log.model.exportHistoricalFiles(revision:exportRequest.0,files:exportRequest.1,to:exportFolder,backend:exportRequest.2)
        try await wait{!log.model.busy && LogWindowModel.activeFileOpenReads==0}
        try require(try Data(contentsOf:exportFolder.appendingPathComponent(path))==filtered,"Log folder choice lost materialization snapshot")
        phase("Comparison outputs")
        // Comparison's Open With/export choices precede the actual reads.
        let snapshot=try await repo.revisionFileComparison(from:.revision(first.hash),to:.revision(head.hash),paths:[path])
        compare.installEmbeddedSnapshot(snapshot,bare:false)
        var comparisonOpened:Data?
        compare.chooseHistoricalApplication={await withCheckedContinuation{chooser=$0}};compare.openHistoricalContent={content,_,_ in comparisonOpened=content.bytes}
        selected();compare.openRevisionFile([path],action:.openWith);try await wait{chooser != nil};disabled();chooser?.resume(returning:app);chooser=nil
        try await wait{!compare.busy};try require(comparisonOpened==filtered,"Comparison application choice changed captured engine")
        let compareFolder=base.appendingPathComponent("compare-export");try fm.createDirectory(at:compareFolder,withIntermediateDirectories:true)
        compare.chooseExportFolder={await withCheckedContinuation{chooser=$0}}
        selected();compare.exportFiles([path]);try await wait{chooser != nil};disabled();chooser?.resume(returning:compareFolder);chooser=nil
        try await wait{!compare.busy};try require(try Data(contentsOf:compareFolder.appendingPathComponent(path))==filtered,"Comparison export folder choice lost captured engine")
        phase("Raw baselines")
        // Source-disabled extraction is raw; raw internal readers and Blame
        // remain byte-identical even while the selected default engine filters.
        disabled();opened=nil;log.model.openHistoricalFile([file.id],action:.open);try await wait{!log.model.busy};try require(opened==raw,"Disabled GetOneFile applied smudge")
        let original=try await repo.historicalFile(revision:head.hash,path:path),blame=try await repo.blame(path:path,revision:head.hash)
        try require(original.bytes==raw && blame.contents==raw,"Materialization altered raw comparison/Blame baselines")
        phase("Standalone Cat")
        // Standalone Cat keeps the accepted setting through the destination
        // permission callback and subsequent repository-adoption task.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,askpass:nil)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("private/marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.captureCommandMaterializationBackend=captured;workspace.notifyFinder={}
        workspace.commandLineRepositoryPermission={_ in grant}
        let commandOutput=base.appendingPathComponent("cat-output.txt")
        workspace.commandLineOutputPermission={_ in disabled();return RepositoryAccessLease(url:base)}
        defer {workspace.stopMonitoringForTermination()}
        selected();workspace.handleCommandLine(arguments:["--command=cat","--path",root.appendingPathComponent(path).path,"--revision",head.hash,"--savepath",commandOutput.path],currentDirectory:root.path)
        try await wait{fm.fileExists(atPath:commandOutput.path) && RepositoryModel.activeCommandFileOperations==0 && !workspace.busy}
        try require(try Data(contentsOf:commandOutput)==filtered,"Cat destination permission replaced accepted engine")
        phase("Required filter failure")
        // Required-filter failure leaves the existing destination intact.
        _ = try await repo.run(["config","filter.qa.smudge","exit 9"]);selected();saveReply=nil;browser.model.open(entry,action:.save)
        try await wait{RepositoryBrowserWindowModel.activeOperations==0 && !browser.model.busy && browser.model.error != nil}
        try require(saveReply==nil && (try Data(contentsOf:saved))==filtered,"Failed required filter presented Save or replaced destination")
        // Exercise the actual native error acknowledgement. Starting the next
        // operation while a SwiftUI binding dismisses an animating NSAlert is
        // not a user-reachable interaction through the modal parent.
        func errorButton()->NSButton? {
            guard let sheet=browser.window?.attachedSheet else {return nil}
            return (sheet.defaultButtonCell?.controlView as? NSButton) ?? sheet.contentView.flatMap{views($0).compactMap{$0 as? NSButton}.first{$0.title=="OK"}}
        }
        try await wait{errorButton()?.isEnabled==true}
        guard let errorSheet=browser.window?.attachedSheet,let acknowledge=errorButton() else {throw Failure(description:"Required-filter error did not present native OK")}
        try require(acknowledge.title=="OK","Required-filter error lacks source OK acknowledgement")
        phase("Required filter native OK");acknowledge.performClick(nil)
        try await wait{browser.model.error==nil && browser.window?.attachedSheet==nil && errorSheet.sheetParent==nil}
        _ = try await repo.run(["config","filter.qa.smudge",quote(filter.path)])
        phase("Held filter cancellation")
        // Force-closing the owner cancels and reaps a real smudge child group.
        try Data().write(to:hold);selected();browser.model.open(entry,action:.save)
        try await wait{fm.fileExists(atPath:ready.path) && RepositoryBrowserWindowModel.activeOperations>0}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Smudge work lost application Quit ownership")
        browser.close();try await wait{RepositoryBrowserWindowModel.activeOperations==0 && pids.allSatisfy{kill($0,0) != 0}}
        try require(try Data(contentsOf:saved)==filtered,"Retired filter changed destination")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Historical output changed index")
        log.close();compare.invalidate();try await wait{drained()}
        print("PASS: native filtered historical opening/save/export/provider snapshots, raw baselines and owned cancellation")
    }
}
