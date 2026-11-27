import AppKit
import ImageIO
import Darwin
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyHistoricalGraphMetafile(_ bytes:Data,format:RevisionGraphFormat)throws {
        // Pinned RevisionGraphWnd::SaveGraphAs814–828 uses CreateEnhanced even
        // for .wmf. The Mac export's .wmf/.emf aliases are EMF vectors, not
        // ImageIO raster encodings. Validate their actual container independently.
        try require(bytes.count>=108 && bytes.count<=64*1024*1024,"Invalid graph EMF extent: "+format.rawValue)
        func word(_ offset:Int)->UInt32 {
            (0..<4).reduce(UInt32(0)){$0 | UInt32(bytes[offset+$1]) << UInt32($1*8)}
        }
        try require(word(0)==1 && word(4)==88 && word(40)==0x464d4520 && word(44)==0x10000,"Invalid graph EMF header: "+format.rawValue)
        try require(Int(word(48))==bytes.count && word(52)>1,"Invalid graph EMF declared bytes/records")
        try require(word(8)==0 && word(12)==0 && word(16)<1_000_000 && word(20)<1_000_000,"Invalid graph EMF inclusive viewport")
        try require(word(24)==0 && word(28)==0 && word(32)>0 && word(36)>0 && word(32)<=26_458_333 && word(36)<=26_458_333,"Empty graph EMF physical frame")
        try require(word(56)==3 && word(60)==0 && word(64)==0 && word(68)==0,"Graph EMF handles/description/palette header differs")
        try require([word(72),word(76),word(80),word(84)]==[960,960,254,254],"Graph EMF device/mm contract differs")
        var offset=88,count=1,draws=0,saves=0,sawEOF=false
        while offset<bytes.count {
            try require(bytes.count-offset>=8,"Truncated graph EMF record header")
            let kind=word(offset),size=Int(word(offset+4))
            try require(kind>0 && size>=8 && size%4==0 && size<=bytes.count-offset,"Invalid graph EMF record extent")
            if kind==33 {saves+=1}
            if kind==34 {saves-=1;try require(saves>=0,"Graph EMF restored an unowned drawing state")}
            if [UInt32(62),64,81].contains(kind) {draws+=1}
            if kind==14 {
                try require(size==20 && offset+size==bytes.count && word(offset+8)==0 && word(offset+12)==0 && word(offset+16)==20,"Invalid graph EMF EOF")
                sawEOF=true
            }
            offset+=size;count+=1
        }
        try require(offset==bytes.count && count==Int(word(52)) && sawEOF && draws>0 && saves==0,"Graph EMF record/count/drawing completion differs")
    }
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
        var rootGrants=0,outputGrants=0,outputRequests:[Data]=[]
        workspace.commandLineRepositoryPermission={_ in rootGrants += 1;return RepositoryAccessLease(url:root)}
        workspace.commandLineOutputPermission={url in outputGrants += 1;outputRequests.append(Data(url.standardizedFileURL.path.utf8));return RepositoryAccessLease(url:container)}
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
                case .wmf,.emf:try verifyHistoricalGraphMetafile(bytes,format:format)
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
            // Hold the real CLI Cat payload read, then close its actual owner.
            // Default GetOneFile uses the helper and bypasses the supplied Git wrapper.
            let cancelSuite=suite+".held-cli",cancelPrefs=UserDefaults(suiteName:cancelSuite)!
            cancelPrefs.set(false,forKey:"UseLibgit2");defer{cancelPrefs.removePersistentDomain(forName:cancelSuite)}
            let wrapper=container.appendingPathComponent("blocking-git"),marker=container.appendingPathComponent("cat-entered")
            let encodedGit=Data(git.path.utf8).base64EncodedString(),encodedMarker=Data(marker.path.utf8).base64EncodedString()
            let script="#!/usr/bin/python3\nimport sys,os,time,base64,pathlib\nreal=base64.b64decode('"+encodedGit+"').decode()\nif 'show' in sys.argv and '--end-of-options' in sys.argv and '--' in sys.argv:\n receipt=pathlib.Path(base64.b64decode('"+encodedMarker+"').decode()); pending=receipt.with_name(receipt.name+'.pending'); pending.write_text(str(os.getpid())); os.replace(pending,receipt)\n while True: time.sleep(0.05)\nos.execv(real,[real]+sys.argv[1:])\n"
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            let cancelled=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:wrapper)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("cancelled-marks.json")))
            cancelled.requiresRepositoryScope=false;cancelled.fileComparisonPreferences=cancelPrefs
            cancelled.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)};cancelled.commandLineOutputPermission={_ in RepositoryAccessLease(url:container)}
            let owner=NSWindow(contentRect:.init(x:0,y:0,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil);cancelled.workspaceWindow=owner
            defer {cancelled.stopMonitoringForTermination();owner.close()}
            cancelled.handleCommandLine(arguments:["--command=cat","--path",file.path,"--revision",base.hash,"--savepath",target.path],currentDirectory:root.path)
            try await wait {FileManager.default.fileExists(atPath:marker.path)}
            guard let heldPID=Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines)) else {throw Failure(description:"Held CLI Cat PID receipt invalid")}
            try require(kill(heldPID,0)==0,"Held CLI Cat process was not live")
            try require(cancelled.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations>0,"Cat lost Quit/owner work accounting")
            owner.close();try await wait {!cancelled.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations==0 && kill(heldPID,0) != 0}
            try require(kill(heldPID,0) == -1 && errno==ESRCH,"Held CLI Cat PID was not reaped")
            try require((try Data(contentsOf:target))==Data("second\n".utf8),"Retired Cat owner published bytes")
            let denied=RepositoryModel(startMonitoring:false,initializePreferences:false,comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("denied-marks.json")))
            denied.commandLineOutputPermission={_ in nil};defer{denied.stopMonitoringForTermination()}
            denied.handleCommandLine(arguments:["--command=cat","--path",file.path,"--revision=HEAD","--savepath",target.path],currentDirectory:root.path)
            try require(!denied.busy && !denied.hasPendingRepositoryWork,"Cancelled output authorization started Cat")
            let expectedOutputs=Array(repeating:Data(target.standardizedFileURL.path.utf8),count:3)+RevisionGraphFormat.allCases.map{Data(container.appendingPathComponent("graph."+$0.fileExtension).standardizedFileURL.path.utf8)}
            try require(rootGrants==1 && outputGrants==expectedOutputs.count && outputRequests==expectedOutputs,"Historical commands did not reuse repository permission or separately authorize exact outputs: repositories=\(rootGrants),outputs=\(outputGrants)/\(expectedOutputs.count),exactSequence=\(outputRequests==expectedOutputs)")
            let head=try await repo.rebaseCommit("HEAD")
            let afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(head.hash==tip.hash && afterIndex==index,"History commands modified HEAD/index")
            try require((try Data(contentsOf:file))==Data("working\n".utf8),"History commands modified working file")
            await cleanup();try require(!NSApp.windows.contains(where:{$0.isVisible}) && RepositoryModel.activeCommandFileOperations==0 && RevisionGraphWindowModel.activeOperations==0,"Historical command owners remained open")
            print("PASS: historical command family: Cat commit/blob/bare bytes and failure preservation; real owner-close cancellation and separate output grants; file/folder/reverse/unified ShowCompare; standalone reference inputs and Log selection; Graph native settings plus all nine hidden vector/raster export encodings; unchanged HEAD/index/working bytes; owned windows and helpers closed")
        } catch {fputs("Historical command state: busy=\(workspace.busy) error=\(workspace.error ?? "nil")\n",stderr);await cleanup();throw error}
    }
}
