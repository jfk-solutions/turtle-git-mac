import AppKit
import TurtleGitCore

@main struct BrowserRevisionSelectionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Browser revision timeout at \(line)")
    }
    @MainActor static func main() async {do {try await verify()}catch {fputs("Browser revision failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Browser Revision QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        try Data("old\n".utf8).write(to:root.appendingPathComponent("folder/file.txt"));try await repo.stage(["folder"]);_ = try await repo.commit(message:"Older revision")
        let older=try await repo.rebaseCommit("HEAD")
        try Data("new\n".utf8).write(to:root.appendingPathComponent("folder/file.txt"));try await repo.stage(["folder"]);_ = try await repo.commit(message:"Newer revision")
        let newer=try await repo.rebaseCommit("HEAD"),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BrowserRevision."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:newer.hash,preferences:prefs),model=owner.model
        defer {owner.close()}
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);owner.window?.orderFront(nil)
        let board=NSPasteboard.withUniqueName();model.clipboard=board;defer{board.releaseGlobally()}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        workspace.configureBrowserRevisionPicker(owner,repository:repo,access:nil)
        try await wait {!model.busy && model.snapshot != nil}
        try require(model.revisionLabel=="refs/heads/main" && model.revision==newer.hash && model.snapshot?.objectID==newer.hash,"Friendly label changed pinned revision")
        model.openFolder("folder");try await wait {model.snapshot?.directory=="folder"}
        try require(model.info.hasPrefix("folder: Showing 1 files"),"Folder summary lost source directory name")
        model.chooseRevision()
        guard let picker=owner.picker else {throw Failure(description:"Actual revision Log not opened")}
        try require(model.choosingRevision && !model.canUseMenu && !model.canEditColumns,"Parent remained interactive under picker")
        try require(picker.window?.sheetParent === owner.window && picker.window?.appearance?.name == .darkAqua && picker.window?.alphaValue == 0,"Picker did not inherit owner presentation")
        try require(picker.model.colorPreferences === prefs && picker.model.selecting && !picker.model.selectingMultiple && !picker.model.canShowWorkingTree,"Picker preferences/selection mode differ")
        try require(picker.model.onPreparedRevert != nil && picker.model.onPreparedRebase != nil && picker.model.onBrowseRepository != nil && picker.model.onFormatPatch != nil && picker.model.onContainingLog != nil && picker.model.onFileLog != nil && picker.model.onBlame != nil && picker.model.onFilePairCompare != nil && picker.model.onPreparedFileCompare != nil && picker.model.onFileCompare != nil && picker.model.onFileComparisons != nil && picker.model.onSubmoduleFileLog != nil,"Repository factory left picker Log actions disconnected")
        let generation=model.generation;model.refresh();model.openFolder("");model.copyFolder("folder")
        try require(model.generation==generation && model.snapshot?.directory=="folder" && board.string(forType:.string)==nil,"Modal picker allowed browser action")
        model.chooseRevision();try require(owner.picker === picker,"Duplicate picker opened")
        try await wait {!picker.model.busy && !picker.model.loadingHistory && picker.model.entries.contains{$0.hash==older.hash}}
        try require(picker.model.endRevision==newer.hash && picker.model.entries.allSatisfy{!$0.hash.isEmpty},"Picker did not pin history or exclude working row")
        picker.model.select([older.hash]);picker.model.accept()
        try await wait {owner.picker==nil && !model.busy && model.snapshot?.objectID==older.hash}
        try require(!model.choosingRevision && model.snapshot?.directory=="folder" && model.revision==older.hash,"Accepted revision lost folder or picker lifetime")
        let entry=model.entries[0],content=try await repo.repositoryBrowserFile(model.snapshot!,entry:entry)
        try require(content.bytes==Data("old\n".utf8),"Revision picker displayed newer bytes")
        model.copy();try require(board.string(forType:.string)==nil,"Empty selection unexpectedly copied")
        model.selection=[entry.id];model.copy();try require(board.string(forType:.string)=="file.txt\r\n","Owned contents clipboard differs")
        model.copyFolder("folder",hashes:true);try require(board.string(forType:.string)==model.folderObjectID("folder"),"Owned folder clipboard differs")
        model.chooseRevision();guard let cancelled=owner.picker else {throw Failure(description:"Second picker missing")}
        let beforeCancel=model.generation;cancelled.model.close()
        try await wait {owner.picker==nil && !model.choosingRevision && owner.window?.attachedSheet==nil}
        try require(model.generation==beforeCancel && model.snapshot?.objectID==older.hash,"Cancel changed browser revision")
        model.chooseRevision();guard let retired=owner.picker else {throw Failure(description:"Retirement picker missing")}
        let late=retired.model.finishSelection;owner.close();late(newer)
        try await wait {LogWindowModel.activeHistoryLoads==0 && RepositoryBrowserWindowModel.activeOperations==0}
        try require(!model.active && owner.picker==nil && model.revision==older.hash && retired.model.isInvalidated,"Closed owner accepted stale picker reply")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent("folder/file.txt")))==Data("new\n".utf8),"Browser revision workflow changed repository")
        print("PASS: browser revision labels/pinning, named folder summary, actual configured single-selection Log/private preferences/theme, duplicate/modal guards, accept/cancel/forced-close fences, private tree/list clipboard and unchanged HEAD/index/working bytes; owned windows closed")
    }
}
