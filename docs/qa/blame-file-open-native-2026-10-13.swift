import AppKit
import Darwin
import TurtleGitCore

@main struct BlameFileOpenVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1500 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Blame File Open did not settle")
    }
    final class Provider:RepositoryBookmarkProvider {
        var starts=0,stops=0,moves:[String:URL]=[:]
        var rejectRemember=false,creates=0
        func create(for url:URL) throws -> Data {
            creates += 1
            if rejectRemember {throw NSError(domain:"TurtleGit.PrivateRecentFailure",code:27,userInfo:[NSLocalizedDescriptionKey:"Injected recent bookmark persistence failure"])}
            return Data(("PRIVATE:"+url.path).utf8)
        }
        func resolve(_ data:Data) throws -> ResolvedBookmark {
            let original=String(String(decoding:data,as:UTF8.self).dropFirst(8))
            return ResolvedBookmark(url:moves[original] ?? URL(fileURLWithPath:original),stale:moves[original] != nil)
        }
        func startAccessing(_ url:URL)->Bool { starts += 1;return true }
        func stopAccessing(_ url:URL) { stops += 1 }
    }
    @MainActor static func main() async { do { try await verify() } catch {
        for _ in 0..<500 { if BlameWindowModel.activeHistoryOperations==0 && BlameDocumentOpener.activeReads==0 && BlameWindowModel.activeSyntaxRequests==0 { break };try? await Task.sleep(nanoseconds:10_000_000) }
        fputs("Blame File Open failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let regexExecutable=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),provider=Provider()
        let history=try BlameRecentDocuments(url:folder.appendingPathComponent("private/blame-files.json"),provider:provider)
        var repos:[GitRepository]=[],files:[URL]=[]
        for name in ["first","second"] {
            let root=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:engine);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Open QA"),("user.email","open@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            let file=root.appendingPathComponent("雪:line\n.txt");try Data((name+" source\n").utf8).write(to:file);try await repo.stage([file.lastPathComponent]);_ = try await repo.commit(message:name+" #27")
            _ = try await repo.run(["config","bugtraq.url","https://example.invalid/issues/%BUGID%"]);_ = try await repo.run(["config","bugtraq.logregex","#([0-9]+)"])
            repos.append(repo);files.append(file)
        }
        let suite="TurtleGit.BlameOpen.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let firstScope=RepositoryAccessLease(url:repos[0].root,provider:provider)
        provider.rejectRemember=true
        let owner=BlameWindowController(repository:repos[0],access:firstScope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:regexExecutable,recentDocuments:history,requireScope:true,provider:provider)
        owner.window?.alphaValue=0
        defer { owner.close() }
        try await wait { !owner.model.busy && !owner.model.syntaxWorking && owner.model.snapshot != nil && owner.model.recentHistoryError != nil }
        try require(owner.model.error==nil && owner.model.path.utf8.elementsEqual(files[0].lastPathComponent.utf8) && owner.model.snapshot?.contents==Data("first source\n".utf8) && history.entries.isEmpty,"Initial recent persistence failure corrupted loaded document")
        let initialWarning=owner.model.recentHistoryError,initialLoaded=owner.model.onLoaded
        provider.rejectRemember=false;owner.model.reload()
        try await wait { !owner.model.busy && !owner.model.syntaxWorking && history.entries.count==1 }
        try require(initialWarning != nil && owner.model.recentHistoryError==nil && owner.model.error==nil,"Successful initial reload did not clear its own recent warning")
        let original=owner.model,window=owner.window!,index=try Data(contentsOf:repos[0].root.appendingPathComponent(".git/index"))
        var fileReply:((URL?)->Void)?,scopeReply:((URL?)->Void)?,changed=0
        owner.chooseFile={ panel,parent,reply in fileReply=reply;precondition(parent===window && panel.canChooseFiles && !panel.canChooseDirectories) }
        owner.chooseScope={ panel,parent,reply in scopeReply=reply;precondition(parent===window && panel.canChooseDirectories && !panel.canChooseFiles) }
        owner.onDocumentChanged={ changed += 1 }
        var fallback=0;BlameWindowController.openFocused(window) { fallback += 1 };try require(owner.model.openingDocument && fallback==0,"Global Open did not route to focused Blame")
        fileReply?(nil);try require(!owner.model.openingDocument && owner.model===original,"Cancel replaced document")
        owner.openDocument();fileReply?(files[1]);try require(scopeReply != nil && owner.model===original,"Outside-root open did not request permission")
        scopeReply?(nil);try require(!owner.model.openingDocument && owner.model===original,"Permission Cancel changed current document")
        owner.openDocument();fileReply?(files[1]);scopeReply?(repos[0].root)
        try await wait { !owner.model.openingDocument }
        try require(owner.model===original && owner.model.error != nil,"Wrong scope silently widened permission")
        original.onFind?();let retainedFind=owner.findWindow;retainedFind?.draft.text="source"
        provider.rejectRemember=true
        owner.openDocument();fileReply?(files[1]);scopeReply?(repos[1].root)
        try await wait { owner.model !== original && !owner.model.syntaxWorking && owner.model.recentHistoryError != nil }
        try require(owner.model.error==nil && owner.model.snapshot?.contents==Data("second source\n".utf8) && history.entries.count==1,"Replacement recent persistence failure became document load failure")
        let replacementWarning=owner.model.recentHistoryError,recordsBeforeStale=history.entries.map(\.id),createsBeforeStale=provider.creates
        initialLoaded?()
        try require(provider.creates==createsBeforeStale && history.entries.map(\.id)==recordsBeforeStale && owner.model.recentHistoryError==replacementWarning && owner.model.error==nil,"Replaced model's retained loaded callback retargeted current history/warning")
        provider.rejectRemember=false;owner.model.reload()
        try await wait { !owner.model.busy && !owner.model.syntaxWorking && history.entries.count==2 }
        try require(owner.model.recentHistoryError==nil && owner.model.error==nil,"Replacement reload could not retry recent persistence")
        owner.model.recentHistoryError="Unrelated recent archive warning"
        owner.model.onLoaded?()
        try require(owner.model.recentHistoryError=="Unrelated recent archive warning","Successful persistence cleared an unrelated recent warning")
        owner.model.recentHistoryError=nil
        try require(owner.window===window && original.retired && owner.model.repository.root.resolvingSymlinksInPath().path==repos[1].root.resolvingSymlinksInPath().path && owner.model.path==files[1].lastPathComponent && owner.model.selection==1 && changed==1,"SDI replacement/context mismatch: sameWindow=\(owner.window===window) retired=\(original.retired) root=\(owner.model.repository.root) expected=\(repos[1].root) path=\(owner.model.path) selection=\(String(describing:owner.model.selection)) changed=\(changed)")
        try require(BlameWindowController.focusedOwner(retainedFind?.window)===owner,"Find panel lost document-owner menu routing")
        try require(owner.findWindow===retainedFind && retainedFind?.model===owner.model && retainedFind?.draft.text=="source","File Open discarded/staled the modeless Find panel")
        try require(owner.model.issueProperties.showsBugIDColumn && owner.model.historyEntries.first?.issueIDs=="27","File Open omitted project history metadata")
        let second=owner.model
        try Data("updated HEAD source\n".utf8).write(to:files[1]);try await repos[1].stage([files[1].lastPathComponent]);_ = try await repos[1].commit(message:"New HEAD")
        second.reload();try await wait { !second.busy && second.snapshot?.contents==Data("updated HEAD source\n".utf8) }
        try require(second.snapshot?.contents==Data("updated HEAD source\n".utf8),"HEAD document Reload stayed pinned to its previous snapshot")
        let untracked=repos[1].root.appendingPathComponent("untracked.txt");try Data("not committed".utf8).write(to:untracked)
        owner.openDocument();fileReply?(untracked);try await wait { !owner.model.openingDocument }
        try require(owner.model===second && history.entries.count==2 && second.error != nil,"Failed Git open changed document/MRU or lost real Git error")
        let gitError=second.error;second.onLoaded?()
        try require(second.error==gitError,"Recent persistence retry cleared genuine Git error")
        owner.openRecent(history.entries.first { $0.lastKnownFile==files[0].path }!)
        try await wait { owner.model !== second && !owner.model.syntaxWorking }
        try require(owner.model.repository.root.resolvingSymlinksInPath().path==repos[0].root.resolvingSymlinksInPath().path && history.entries.first?.lastKnownFile==files[0].path,"Recent-file routing failed")
        let beforeRetire=owner.model
        let retiredLoaded=beforeRetire.onLoaded,rememberedBeforeClose=provider.creates,recordsBeforeClose=history.entries.map(\.id)
        owner.openDocument();let late=fileReply;owner.close();late?(files[1])
        retiredLoaded?()
        try require(beforeRetire.retired && owner.openPanel==nil && BlameDocumentOpener.activeReads==0,"Retired picker accepted a late result")
        try require(provider.creates==rememberedBeforeClose && history.entries.map(\.id)==recordsBeforeClose,"Retired loaded callback changed recent history")
        let reopened=try BlameRecentDocuments(url:folder.appendingPathComponent("private/blame-files.json"),provider:provider)
        try require(reopened.entries.count==2,"Recent archive did not reopen")
        let attributes=try FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent("private/blame-files.json").path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600,"Recent grants not private")
        // Hold root discovery only; initial document reads still complete.
        let helper=folder.appendingPathComponent("held-open"),marker=URL(fileURLWithPath:folder.appendingPathComponent("held-open").path+".ready")
        func quote(_ value:String)->String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        let script="""
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = '--show-toplevel' ] || { [ "$task_arg" = config ] && [ -f "$3/hold-reload" ]; }; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec \(quote(engine.path)) "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let held=BlameWindowController(repository:GitRepository(root:repos[0].root,executable:helper),access:firstScope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:regexExecutable,recentDocuments:history,requireScope:false,provider:provider)
        defer { held.close() }
        try await wait { !held.model.busy && !held.model.syntaxWorking }
        held.chooseFile={ _,_,reply in reply(files[1]) };held.openDocument()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && BlameDocumentOpener.activeReads==1 }
        let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit did not guard owned document reader")
        held.model.onCancelDocumentOpen?();try await wait { BlameDocumentOpener.activeReads==0 && !held.model.openingDocument && pids.allSatisfy { kill($0,0) != 0 } }
        try require(!held.model.retired && held.model.repository.root.resolvingSymlinksInPath().path==repos[0].root.resolvingSymlinksInPath().path,"Cancel replaced/retired the current document")
        try FileManager.default.removeItem(at:marker);held.openDocument();try await wait { FileManager.default.fileExists(atPath:marker.path) && BlameDocumentOpener.activeReads==1 }
        let retiringPIDs=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }
        held.close();try await wait { BlameDocumentOpener.activeReads==0 && retiringPIDs.allSatisfy { kill($0,0) != 0 } }
        try require(held.model.retired && held.model.repository.root.resolvingSymlinksInPath().path==repos[0].root.resolvingSymlinksInPath().path,"Retired read committed a replacement")
        try FileManager.default.removeItem(at:marker)
        let reloadOwner=BlameWindowController(repository:GitRepository(root:repos[0].root,executable:helper),access:firstScope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,regexExecutable:regexExecutable,requireScope:false,provider:provider)
        defer { reloadOwner.close() }
        try await wait { !reloadOwner.model.busy && !reloadOwner.model.syntaxWorking }
        let reload=reloadOwner.model,stable=reload.snapshot!.contents;reload.goToLine(1)
        try Data().write(to:repos[0].root.appendingPathComponent("hold-reload"));reload.reload()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && reload.busy }
        let reloadPIDs=try String(contentsOf:marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try require(reloadPIDs.count==2 && BlameWindowModel.activeHistoryOperations>0,"Reload lacks owned process/Quit lifetime")
        reload.cancelReload();try await wait { !reload.busy && BlameWindowModel.activeHistoryOperations==0 && reloadPIDs.allSatisfy { kill($0,0) != 0 } }
        try require(reload.snapshot?.contents==stable && reload.selection==1 && reload.error==nil,"Cancelled metadata reload lost stable document")
        try FileManager.default.removeItem(at:marker);reload.reload()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && reload.busy }
        let closePIDs=try String(contentsOf:marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        reloadOwner.close();try await wait { BlameWindowModel.activeHistoryOperations==0 && closePIDs.allSatisfy { kill($0,0) != 0 } }
        try require(reload.retired && !reload.busy && reload.snapshot?.contents==stable,"Closing metadata read accepted a late result")
        try await verifyPersistenceBoundaries(folder:folder,repositories:repos,files:files,preferences:prefs,regexExecutable:regexExecutable)
        for n in 0..<5 { let lease=RepositoryAccessLease(url:repos[0].root,provider:provider);try history.remember(root:repos[0].root,path:"file\(n).txt",lease:lease) }
        try require(history.entries.count==4 && history.entries.map(\.path)==["file4.txt","file3.txt","file2.txt","file1.txt"],"Four-entry source MRU order/dedup")
        do {
            let entry=history.entries[0],moved=folder.appendingPathComponent("moved-scope")
            provider.moves[repos[0].root.path]=moved
            let (restoredRoot,restoredFile,lease)=try history.acquire(entry,requireScope:true)
            try require(restoredRoot==moved && restoredFile==moved.appendingPathComponent(entry.path),"Moved scope did not retain relative file")
            try history.remember(root:restoredRoot,path:entry.path,lease:lease,replacing:entry.id)
            try require(history.entries.count==4 && history.entries.first?.id==entry.id,"Moved recent duplicated its registration")
        }
        try require(try Data(contentsOf:repos[0].root.appendingPathComponent(".git/index"))==index,"Open changed original index")
        print("Blame File Open: native picker configuration, file/scope Cancel, wrong-scope rejection, same-window cross-repository replacement, failed-read preservation, recent routing/private archive/four-entry order and late-picker retirement passed. Typed chooser replies and simulated scope grants; no signed or physical picker acceptance. Owned window closed.")
    }
    @MainActor static func verifyPersistenceBoundaries(folder:URL,repositories:[GitRepository],files:[URL],preferences:UserDefaults,regexExecutable:URL)async throws {
        let provider=Provider(),blocked=folder.appendingPathComponent("blocked-recent-parent")
        let archive=blocked.appendingPathComponent("recent.json")
        let history=try BlameRecentDocuments(url:archive,provider:provider)
        try Data("regular file blocks directory creation".utf8).write(to:blocked)
        let scope=RepositoryAccessLease(url:repositories[0].root,provider:provider)
        let owner=BlameWindowController(repository:repositories[0],access:scope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:preferences,regexExecutable:regexExecutable,recentDocuments:history,requireScope:true,provider:provider)
        owner.window?.alphaValue=0;defer{owner.close()}
        try await wait {!owner.model.busy && owner.model.snapshot != nil && owner.model.recentHistoryError != nil}
        let blockerBytes=try Data(contentsOf:blocked)
        try require(owner.model.error==nil && history.entries.isEmpty && blockerBytes==Data("regular file blocks directory creation".utf8),"Filesystem MRU failure changed initial document or blocker")
        owner.chooseFile={_,_,reply in reply(files[1])};owner.chooseScope={_,_,reply in reply(repositories[1].root)}
        let initial=owner.model;owner.openDocument()
        try await wait {owner.model !== initial && owner.model.snapshot != nil && owner.model.recentHistoryError != nil}
        try require(initial.retired && owner.model.error==nil && history.entries.isEmpty && owner.model.path.utf8.elementsEqual(files[1].lastPathComponent.utf8),"Filesystem MRU failure changed replacement source/error")
        try FileManager.default.removeItem(at:blocked);owner.model.reload()
        try await wait {!owner.model.busy && history.entries.count==1 && owner.model.recentHistoryError==nil}
        try require(owner.model.error==nil && history.entries[0].path.utf8.elementsEqual(files[1].lastPathComponent.utf8),"Filesystem MRU retry lost loaded path")

        let saved=try Data(contentsOf:archive),calls=provider.creates
        let revision=try await repositories[0].run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let historical=BlameWindowController(repository:repositories[0],access:scope,path:files[0].lastPathComponent,revision:revision,options:GitBlameOptions(),preferences:preferences,regexExecutable:regexExecutable,recentDocuments:history,requireScope:true,provider:provider)
        historical.window?.alphaValue=0;defer{historical.close()}
        try await wait {!historical.model.busy && historical.model.snapshot != nil}
        historical.model.onLoaded?()
        let afterHistorical=try Data(contentsOf:archive)
        try require(historical.model.error==nil && provider.creates==calls && history.entries.count==1 && afterHistorical==saved,"Historical revision registered in HEAD recent files")

        let raw=Data([0x63,0x61,0x66,0xe9,0x20,0x80,0x0a]),legacy=repositories[1].root.appendingPathComponent("legacy [bytes]\n.txt")
        try raw.write(to:legacy);try await repositories[1].stage([legacy.lastPathComponent]);_ = try await repositories[1].commit(message:"legacy source")
        owner.chooseFile={_,_,reply in reply(legacy)}
        let decoded=owner.model;owner.openDocument()
        try await wait {owner.model !== decoded && !owner.model.busy && owner.model.hasRetainedDocument && owner.model.error != nil}
        let undecoded=owner.model,decodeError=owner.model.error,beforeRecovery=provider.creates
        undecoded.onLoaded?()
        try require(undecoded.snapshot==nil && undecoded.error==decodeError && provider.creates==beforeRecovery && history.entries.count==1,"Undecoded replacement registered or lost its genuine decoding error")
        let encoding=try requireEncoding(GitBlameEncoding.available.first{$0.windowsCodePage==1252})
        undecoded.setEncoding(encoding)
        try await wait {!undecoded.busy && undecoded.snapshot != nil && history.entries.count==2}
        try require(undecoded.error==nil && undecoded.snapshot?.contents==raw && history.entries.first?.path.utf8.elementsEqual(legacy.lastPathComponent.utf8)==true,"Recovered retained bytes did not register exact loaded HEAD document")
        let callback=undecoded.onLoaded,records=history.entries.map(\.id),beforeClose=provider.creates
        owner.close();callback?()
        try require(undecoded.retired && provider.creates==beforeClose && history.entries.map(\.id)==records,"Closed recovered-document callback rewrote history")
        print("PASS: Blame recent filesystem/provider failures stay nonfatal, initial/replacement retries, exact-owner stale/retired refusal, historical no-MRU and retained-byte decode recovery")
    }
    private static func requireEncoding(_ encoding:GitBlameEncoding?)throws->GitBlameEncoding {
        guard let encoding else {throw Failure(description:"CP1252 unavailable for retained-byte recovery")};return encoding
    }
}
