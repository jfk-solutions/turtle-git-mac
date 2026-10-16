import AppKit
import TurtleGitCore

@main struct RebaseRevisionFilesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Revision Files timeout at \(line)")
    }
    @MainActor static func descendants(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{descendants($0)}}
    @MainActor static func capture(_ window:NSWindow,_ name:String) async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_FILES_CAPTURES"] else{return}
        let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:350_000_000)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent(name+".png").path]
        try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Compositor capture failed")
    }
    @MainActor static func main() async {do{try await verify()}catch{fputs("Rebase Revision Files failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let captureEnabled=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_FILES_CAPTURES"] != nil
        NSApp.setActivationPolicy(captureEnabled ? .accessory:.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),root=folder.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("original\n".utf8).write(to:root.appendingPathComponent("old.txt"));try Data("remove me\n".utf8).write(to:root.appendingPathComponent("deleted.txt"))
        try await repo.stage(["old.txt","deleted.txt"]);_ = try await repo.commit(message:"Initial files")
        let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","upstream"])
        try Data("upstream\n".utf8).write(to:root.appendingPathComponent("upstream.txt"));try await repo.stage(["upstream.txt"]);_ = try await repo.commit(message:"Upstream change")
        _ = try await repo.run(["switch","-c","topic",base.hash]);_ = try await repo.run(["mv","old.txt","renamed.txt"]);_ = try await repo.run(["rm","deleted.txt"])
        let binary=Data([0,255,10,128,1]);try binary.write(to:root.appendingPathComponent("binary.dat"));try await repo.stage(["binary.dat"]);_ = try await repo.commit(message:"Rename, delete and add binary")
        let revision=try await repo.rebaseCommit("HEAD")
        try Data("later working content\n".utf8).write(to:root.appendingPathComponent("renamed.txt"));try await repo.stage(["renamed.txt"]);_ = try await repo.commit(message:"Later edit")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout
        let suite="TurtleGit.RebaseRevisionFiles."+UUID().uuidString
        guard let prefs=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")}
        defer{prefs.removePersistentDomain(forName:suite)}
        let controller=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=controller.model,list=model.revisionFiles
        defer{model.retire();controller.close()}
        controller.window?.alphaValue=captureEnabled ? 1:0;controller.window?.orderFront(nil)
        model.load(upstream:"refs/heads/upstream")
        try await wait{!model.busy && !model.loadingPlan && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
        guard let occurrence=model.entries.first(where:{$0.commit.hash==revision.hash}) else{throw Failure(description:"Planned rename commit missing")}
        model.selection=[occurrence.id];model.selectCommit()
        try await wait{list.snapshot?.to == .revision(revision.hash) && RebaseWindowModel.activePreparationReads==0}
        try require(list.snapshot?.from == .revision(base.hash) && Set(model.files.map(\.path))==Set(["renamed.txt","deleted.txt","binary.dat"]),"Revision file snapshot differs")
        try require(list.visibleFiles.contains{$0.path=="renamed.txt" && $0.oldPath=="old.txt"} && !list.canOpenRevisionFile(["deleted.txt"]),"Rename/deletion identity lost")
        try await wait{descendants(controller.window?.contentView).compactMap{$0 as? NSTableView}.contains{$0.tableColumns.count==5}}
        let pasteboard=NSPasteboard.withUniqueName();list.clipboard=pasteboard;defer{pasteboard.releaseGlobally()}
        list.copyColumn(["renamed.txt"],column:.path);try require(pasteboard.string(forType:.string)?.contains("renamed.txt")==true,"Clipboard path absent")
        list.setFileColumn(.added,visible:false)
        try require(!StatusListColumnSettings.load(from:prefs,key:"RebaseDlg.RevisionFiles.Columns").visible.contains(.added) && !prefs.dictionaryRepresentation().keys.contains{ $0.hasPrefix(RevisionComparisonWindowModel.columnsKey) },"Rebase layout leaked into Changed Files settings")
        list.setFileColumn(.added,visible:true)
        try require([MenuIcon.compare,.unifiedDiff,.log,.blame,.export,.copy,.open,.editor,.saveAs].allSatisfy{$0.image() != nil},"Original command artwork missing")
        var compared:[String]=[],logged:[String]=[],blamed:[String]=[]
        list.openComparedFile={snapshot,file in compared.append(snapshot.from.label+":"+snapshot.to.label+":"+file.path)}
        list.onFileLog={path,hash in logged.append(path+":"+(hash ?? ""))};list.onBlame={path,hash in blamed.append(path+":"+hash)}
        list.compare(["renamed.txt"]);try await wait{!list.busy}
        list.logFiles(["renamed.txt"]);list.blameFiles(["deleted.txt"]);try await wait{!list.busy}
        try require(compared==[base.hash+":"+revision.hash+":renamed.txt"] && logged==["renamed.txt:"+revision.hash] && blamed==["deleted.txt:"+base.hash],"Comparison/history/deleted blame endpoints changed")
        var opened:[Data]=[]
        list.openHistoricalContent={content,_,_ in try require(content.revision == .revision(revision.hash),"Open read live revision");opened.append(content.bytes)}
        list.openRevisionFile(["renamed.txt"],action:.open);try await wait{!list.busy}
        list.chooseHistoricalApplication={URL(fileURLWithPath:"/Applications/QA.app")};list.openRevisionFile(["binary.dat"],action:.openWith);try await wait{!list.busy}
        try require(opened==[Data("original\n".utf8),binary],"Historical Open used working bytes or changed binary data")
        let saved=folder.appendingPathComponent("saved.bin");list.chooseHistoricalSave={_ in saved};list.saveRevisionFile(["binary.dat"]);try await wait{!list.busy}
        try require(try Data(contentsOf:saved)==binary,"Save As changed binary bytes")
        let exported=folder.appendingPathComponent("Export");try FileManager.default.createDirectory(at:exported,withIntermediateDirectories:true)
        list.chooseExportFolder={exported};list.exportFiles(Set(list.visibleFiles.map(\.path)));try await wait{!list.busy}
        try require(try Data(contentsOf:exported.appendingPathComponent("renamed.txt"))==Data("original\n".utf8),"Export used current working contents")
        try require(try Data(contentsOf:exported.appendingPathComponent("binary.dat"))==binary,"Export changed binary")
        try require(!FileManager.default.fileExists(atPath:exported.appendingPathComponent("deleted.txt").path),"Export materialized deleted file")
        let stale=list.captureFileMenu(["renamed.txt"])
        guard let latest=model.entries.first(where:{$0.commit.subject=="Later edit"}) else{throw Failure(description:"Later occurrence missing")}
        model.selection=[latest.id];model.selectCommit();try await wait{list.snapshot?.to == .revision(latest.commit.hash) && RebaseWindowModel.activePreparationReads==0}
        try require(!list.claimFileMenu(stale),"Popup from previous commit applied to replacement")
        model.selection=[occurrence.id];model.selectCommit();try await wait{list.snapshot?.to == .revision(revision.hash) && RebaseWindowModel.activePreparationReads==0}
        for (appearance,name) in [(NSAppearance.Name.aqua,"rebase-revision-files-light"),(.darkAqua,"rebase-revision-files-dark")] {
            controller.window?.appearance=NSAppearance(named:appearance);if let window=controller.window{try await capture(window,name)}
        }
        var held:CheckedContinuation<URL?,Never>?
        list.chooseExportFolder={await withCheckedContinuation{held=$0}}
        list.exportFiles(["binary.dat"]);try await wait{held != nil}
        try require(!model.canStart && !model.canAdd && !model.revisionMenuAvailable && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"File preparation lost Rebase/Quit guard")
        if let window=controller.window {try require(!controller.windowShouldClose(window),"Rebase closed during export preparation")}
        held?.resume(returning:exported);held=nil;try await wait{!list.busy && RevisionComparisonWindowModel.activeFileOperations==0}
        try require(list.error==nil,"Cancelled export published error")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout
        try require(afterHead==head && afterIndex==index,"Read-only revision actions changed HEAD/index")
        let status=try await repo.run(["status","--porcelain=v1","-z"]).stdout;try require(status.isEmpty,"Read-only actions changed working tree")
        // Same embedded list handles a root commit and an empty Base.
        model.draftEntries=try await repo.cherryPickPlan(revisions:[base.hash]).entries;model.plan=nil;model.selection=Set(model.draftEntries.map(\.id));model.selectCommit()
        try await wait{list.snapshot?.to == .revision(base.hash) && RebaseWindowModel.activePreparationReads==0}
        try require(list.snapshot?.from == .emptyTree && !list.canRevertFiles(["old.txt"],base:true),"Root commit fabricated parent")
        model.retire();try require(list.closed && !list.claimFileMenu(list.captureFileMenu(["old.txt"])),"Retired owner retained actions")
        print("PASS: native Rebase Revision Files shared table/columns/icons, parent/root snapshots, rename/deletion/binary compare/history/blame/Open/Save/export/clipboard, stale-menu and Cancel/Close/Quit ownership; unchanged HEAD/index/worktree; owned windows closed.")
    }
}
