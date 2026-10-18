import AppKit
import ImageIO
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyHistoricalCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","History command QA"),("user.email","history@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.autocrlf","false")] {_ = try await repo.run(["config",key,value])}
        let path="nested/file 雪[*].txt",file=FileTransferPaths.fileURL(root.path+"/"+path)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("base\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["branch","topic",base.hash])
        try Data("second\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"second")
        let tip=try await repo.rebaseCommit("HEAD"),blob=try await repo.run(["rev-parse","HEAD:"+path]).text.trimmingCharacters(in:.newlines)
        try Data("working\n".utf8).write(to:file)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.HistoryCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(true,forKey:"ShowRevGraphOverview")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        workspace.fileComparisonQuestion={_ in true}
        var rootGrants=0,outputGrants=0
        workspace.commandLineRepositoryPermission={_ in rootGrants += 1;return RepositoryAccessLease(url:root)}
        workspace.commandLineOutputPermission={_ in outputGrants += 1;return RepositoryAccessLease(url:container)}
        let helper=URL(fileURLWithPath:"build/graph-layout-runtime/GraphLayout/graph-layout")
        workspace.revisionGraphWindowFactory={repository,access,preferences,load in RevisionGraphWindowController(repository:repository,access:access,preferences:preferences,layoutExecutable:helper,automaticallyLoad:load)}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ arguments:[String]) {workspace.error=nil;workspace.handleCommandLine(arguments:arguments,currentDirectory:root.path)}
        func compare(_ from:String,_ to:String) async throws -> FileComparisonWindowController {
            invoke(["--command=showcompare","--path",file.path,"--revision1",from,"--revision2",to])
            try await wait {!workspace.busy && windows(FileComparisonWindowController.self).first?.model.document != nil && windows(FileComparisonWindowController.self).first?.model.filtering==false}
            return try requireOne(windows(FileComparisonWindowController.self))
        }
        @MainActor func cleanup() async {
            workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}
            for _ in 0..<1800 {if RepositoryModel.activeCommandFileOperations==0 && RevisionGraphWindowModel.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 && !workspace.busy {return};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do {
            let target=container.appendingPathComponent("cat-output.bin");try Data("old".utf8).write(to:target)
            invoke(["--command=cat","--path",file.path,"--revision",base.hash,"--savepath",target.path])
            try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
            try require(workspace.error==nil && (try Data(contentsOf:target))==Data("base\n".utf8),"Cat did not publish historical file: "+(workspace.error ?? "nil"))
            invoke(["--command=cat","--path",file.path,"--revision",blob,"--savepath",target.path])
            try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
            try require(workspace.error==nil && (try Data(contentsOf:target))==Data("second\n".utf8),"Cat blob route failed")
            invoke(["--command=cat","--path",file.path,"--revision=missing-ref","--savepath",target.path])
            try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
            try require(workspace.error != nil && (try Data(contentsOf:target))==Data("second\n".utf8),"Cat failure removed/replaced the destination")
            let forward=try await compare(base.hash,tip.hash)
            try require(forward.model.document?.base.bytes==Data("base\n".utf8) && forward.model.document?.destination.bytes==Data("second\n".utf8),"ShowCompare file sides were reversed");forward.close()
            let reverse=try await compare(String(repeating:"0",count:40),base.hash)
            try require(reverse.model.document?.base.bytes==Data("working\n".utf8) && reverse.model.document?.destination.bytes==Data("base\n".utf8),"Working-tree-to-revision comparison lost its direction");reverse.close()
            invoke(["--command=showcompare","--path",root.path,"--revision1",base.hash,"--revision2",tip.hash])
            try await wait {!workspace.busy && windows(RevisionComparisonWindowController.self).first?.model.snapshot != nil && windows(RevisionComparisonWindowController.self).first?.model.busy==false}
            let folder=try requireOne(windows(RevisionComparisonWindowController.self))
            try require(folder.model.snapshot?.files.contains(where:{$0.path==path})==true,"Directory ShowCompare lost changed files");folder.close()
            var unified:Data?
            workspace.commandUnifiedPresentation={unified=$0}
            invoke(["--command=showcompare","--path",file.path,"--revision1",base.hash,"--revision2",tip.hash,"--unified","--alternative"])
            try await wait {!workspace.busy && unified != nil}
            let patch=String(decoding:unified!,as:UTF8.self)
            try require(patch.contains("-base") && patch.contains("+second") && !patch.contains("+working"),"Unified ShowCompare lost pinned revisions")
            invoke(["/command:commitisonrefs","/rev:"+base.hash])
            try await wait {!workspace.busy && windows(CommitContainingReferencesWindowController.self).first?.snapshot != nil && windows(CommitContainingReferencesWindowController.self).first?.busy==false}
            let refs=try requireOne(windows(CommitContainingReferencesWindowController.self))
            try require(refs.preferences === prefs && refs.snapshot?.hash==base.hash && refs.rows.contains(GitReferenceName("refs/heads/topic")),"Standalone containing-reference command lost revision/settings/rows")
            refs.showLog.performClick(nil)
            try await wait {windows(LogWindowController.self).first?.model.entries.contains(where:{$0.hash==base.hash})==true && windows(LogWindowController.self).first?.model.busy==false}
            let log=try requireOne(windows(LogWindowController.self));try require(log.model.selected.contains(base.hash),"Standalone Show Log did not select requested commit");log.close();refs.close()
            invoke(["--command=commitisonrefs"])
            try await wait {!workspace.busy && windows(CommitContainingReferencesWindowController.self).first?.busy==false}
            let blank=try requireOne(windows(CommitContainingReferencesWindowController.self))
            try require(blank.revision.stringValue.isEmpty && blank.snapshot==nil,"Empty source revision should open an empty input")
            blank.revision.stringValue="edited invalid";blank.refresh();try await wait {!blank.busy}
            invoke(["--command=commitisonrefs","--rev",tip.hash])
            try await wait {!workspace.busy && windows(CommitContainingReferencesWindowController.self).count==2 && windows(CommitContainingReferencesWindowController.self).contains(where:{$0.snapshot?.hash==tip.hash && !$0.busy})}
            try require(blank.revision.stringValue=="edited invalid","New references request replaced the old input")
            for owner in windows(CommitContainingReferencesWindowController.self) {owner.close()}
            invoke(["--command=revisiongraph"])
            try await wait {!workspace.busy && windows(RevisionGraphWindowController.self).first?.model.geometry != nil && windows(RevisionGraphWindowController.self).first?.model.busy==false}
            let graph=try requireOne(windows(RevisionGraphWindowController.self));try require(graph.model.showOverview,"Graph command lost owning settings");graph.close()
            for format in RevisionGraphFormat.allCases {
                let output=container.appendingPathComponent("graph."+format.fileExtension)
                invoke(["--command=revisiongraph","--output",output.path])
                try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
                try require(workspace.error==nil && windows(RevisionGraphWindowController.self).isEmpty,"Graph output opened a window or failed: "+(workspace.error ?? "nil"))
                let bytes=try Data(contentsOf:output)
                switch format {
                case .svg:try require(String(decoding:bytes,as:UTF8.self).contains("<svg"),"SVG output missing")
                case .graphviz:try require(String(decoding:bytes,as:UTF8.self).contains("digraph"),"Graphviz output missing")
                case .pdf:try require(bytes.starts(with:Data("%PDF".utf8)),"PDF output missing")
                default:guard let source=CGImageSourceCreateWithData(bytes as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw Failure(description:"Invalid graph raster: "+format.rawValue)};try require(image.width>0 && image.height>0,"Empty raster")
                }
            }
            // A command for a virtual path in a bare repository resolves its
            // existing ancestor without asking Git to chdir to a missing folder.
            let bare=container.appendingPathComponent("bare.git")
            _ = try await repo.run(["clone","--bare","--",root.path,bare.path])
            try Data("current non-directory".utf8).write(to:bare.appendingPathComponent("nested"))
            let bareWorkspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("bare-marks.json")))
            bareWorkspace.requiresRepositoryScope=false;bareWorkspace.fileComparisonPreferences=prefs
            bareWorkspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:bare)};bareWorkspace.commandLineOutputPermission={_ in RepositoryAccessLease(url:container)}
            defer {bareWorkspace.stopMonitoringForTermination()}
            bareWorkspace.handleCommandLine(arguments:["--command=cat","--path",bare.appendingPathComponent(path).path,"--revision",tip.hash,"--savepath",target.path],currentDirectory:bare.path)
            try await wait {!bareWorkspace.busy && !bareWorkspace.hasPendingRepositoryWork}
            try require(bareWorkspace.error==nil && (try Data(contentsOf:target))==Data("second\n".utf8),"Bare historical output failed: "+(bareWorkspace.error ?? "nil"))
            try require((try Data(contentsOf:bare.appendingPathComponent("nested")))==Data("current non-directory".utf8),"Historical read changed a blocking current path")
            // Hold the real Cat Git subprocess, then close its actual owner.
            let wrapper=container.appendingPathComponent("blocking-git"),marker=container.appendingPathComponent("cat-entered")
            let encodedGit=Data(git.path.utf8).base64EncodedString(),encodedMarker=Data(marker.path.utf8).base64EncodedString()
            let script="#!/usr/bin/python3\nimport sys,os,time,base64,pathlib\nreal=base64.b64decode('"+encodedGit+"').decode()\nif 'cat-file' in sys.argv and '--filters' in sys.argv:\n pathlib.Path(base64.b64decode('"+encodedMarker+"').decode()).write_text('entered')\n while True: time.sleep(0.05)\nos.execv(real,[real]+sys.argv[1:])\n"
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            let cancelled=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:wrapper)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("cancelled-marks.json")))
            cancelled.requiresRepositoryScope=false;cancelled.fileComparisonPreferences=prefs
            cancelled.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)};cancelled.commandLineOutputPermission={_ in RepositoryAccessLease(url:container)}
            let owner=NSWindow(contentRect:.init(x:0,y:0,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil);cancelled.workspaceWindow=owner
            defer {cancelled.stopMonitoringForTermination();owner.close()}
            cancelled.handleCommandLine(arguments:["--command=cat","--path",file.path,"--revision",base.hash,"--savepath",target.path],currentDirectory:root.path)
            try await wait {FileManager.default.fileExists(atPath:marker.path)}
            try require(cancelled.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations>0,"Cat lost Quit/owner work accounting")
            owner.close();try await wait {!cancelled.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations==0}
            try require((try Data(contentsOf:target))==Data("second\n".utf8),"Retired Cat owner published bytes")
            let denied=RepositoryModel(startMonitoring:false,initializePreferences:false,comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("denied-marks.json")))
            denied.commandLineOutputPermission={_ in nil};defer{denied.stopMonitoringForTermination()}
            denied.handleCommandLine(arguments:["--command=cat","--path",file.path,"--revision=HEAD","--savepath",target.path],currentDirectory:root.path)
            try require(!denied.busy && !denied.hasPendingRepositoryWork,"Cancelled output authorization started Cat")
            try require(rootGrants==1 && outputGrants==10,"Historical commands did not reuse repository permission or separately authorize all outputs")
            let head=try await repo.rebaseCommit("HEAD")
            let afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(head.hash==tip.hash && afterIndex==index,"History commands modified HEAD/index")
            try require((try Data(contentsOf:file))==Data("working\n".utf8),"History commands modified working file")
            await cleanup();try require(!NSApp.windows.contains(where:{$0.isVisible}) && RepositoryModel.activeCommandFileOperations==0 && RevisionGraphWindowModel.activeOperations==0,"Historical command owners remained open")
            print("PASS: historical command family: Cat commit/blob/bare bytes and failure preservation; real owner-close cancellation and separate output grants; file/folder/reverse/unified ShowCompare; standalone reference inputs and Log selection; Graph native settings plus seven hidden export encodings; unchanged HEAD/index/working bytes; owned windows and helpers closed")
        } catch {fputs("Historical command state: busy=\(workspace.busy) error=\(workspace.error ?? "nil")\n",stderr);await cleanup();throw error}
    }
}
