// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum BlameSymlinkVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String)throws { if !condition { throw Failure(description:message) } }
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2400 { if ready(){return};try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Symlink Blame timeout at \(line)")
    }
    final class Provider:RepositoryBookmarkProvider {
        func create(for url:URL)throws->Data { Data(url.path.utf8) }
        func resolve(_ data:Data)throws->ResolvedBookmark { ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false) }
        func startAccessing(_ url:URL)->Bool { true }
        func stopAccessing(_ url:URL) {}
    }
    static func drained()->Bool {
        BlameDocumentOpener.activeReads==0 && BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeHistoryLoads==0 && RepositoryBrowserWindowModel.activeOperations==0
    }
    static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        let root=base.appendingPathComponent("repository"),provider=Provider()
        try fm.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git,askpass:nil)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Link QA"),("user.email","link@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let secret=base.appendingPathComponent("outside-secret"),secretBytes=Data("Never attribute or read these target contents\n".utf8)
        try secretBytes.write(to:secret)
        try Data("regular source\n".utf8).write(to:root.appendingPathComponent("regular.txt"))
        let path="nested/link 雪\n.txt",outside="outside-link",dangling="dangling-link",directory="directory-link"
        let initial="../../outside-secret",current="../../missing-target"
        try fm.createSymbolicLink(atPath:root.appendingPathComponent(path).path,withDestinationPath:initial)
        try fm.createSymbolicLink(atPath:root.appendingPathComponent(outside).path,withDestinationPath:"../outside-secret")
        try fm.createSymbolicLink(atPath:root.appendingPathComponent(dangling).path,withDestinationPath:"missing-target")
        try fm.createSymbolicLink(atPath:root.appendingPathComponent(directory).path,withDestinationPath:"nested")
        try await repo.stage(["regular.txt",path,outside,dangling,directory]);_ = try await repo.commit(message:"Initial symbolic links")
        let first=try await repo.rebaseCommit("HEAD")
        try fm.removeItem(at:root.appendingPathComponent(path));try fm.createSymbolicLink(atPath:root.appendingPathComponent(path).path,withDestinationPath:current)
        try await repo.stage([path]);_ = try await repo.commit(message:"Change link target text")
        let second=try await repo.rebaseCommit("HEAD")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.BlameSymlink."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        let scope=RepositoryAccessLease(url:root,provider:provider),recent=try BlameRecentDocuments(url:base.appendingPathComponent("private/recent.json"),provider:provider)
        var blameOwners:[BlameWindowController]=[],logOwners:[LogWindowController]=[],browsers:[RepositoryBrowserWindowController]=[]
        defer { blameOwners.forEach{$0.close()};logOwners.forEach{$0.close()};browsers.forEach{$0.close()};prefs.removePersistentDomain(forName:suite) }
        func owner(_ file:String,_ revision:String="HEAD",_ executable:URL?=nil)async throws->BlameWindowController {
            let value=BlameWindowController(repository:GitRepository(root:root,executable:executable ?? git,askpass:nil),access:scope,path:file,revision:revision,preferences:prefs,recentDocuments:recent,requireScope:true,provider:provider)
            blameOwners.append(value);value.window?.alphaValue=0;value.window?.orderFront(nil)
            try await wait{!value.model.busy && !value.model.syntaxWorking}
            try require(value.model.snapshot != nil,"Initial Blame failed: \(value.model.error ?? "no diagnostic")")
            return value
        }
        let document=try await owner("regular.txt"),originalWindow=document.window
        var scopeRequests=0,fileReply:((URL?)->Void)?
        document.chooseScope={_,_,reply in scopeRequests += 1;reply(nil)}
        document.chooseFile={panel,_,reply in precondition(!panel.resolvesAliases);fileReply=reply}
        for (name,expected) in [(outside,"../outside-secret"),(dangling,"missing-target"),(directory,"nested"),(path,current)] {
            let previous=document.model
            document.openDocument();fileReply?(root.appendingPathComponent(name))
            try await wait{document.model !== previous && !document.model.syntaxWorking || !previous.openingDocument && previous.error != nil}
            try require(document.model !== previous && previous.retired && document.window===originalWindow,"Document replacement failed for \(name): \(previous.error ?? "none")")
            try require(document.model.path.utf8.elementsEqual(name.utf8) && document.model.snapshot?.contents==Data(expected.utf8) && document.model.lines.count==1,"Blame followed target or changed lexical link path")
            try require(document.model.repositoryAccess?.contains(root)==true && document.model.labelDefaults===prefs,"Replacement lost captured permission/preferences")
        }
        try require(scopeRequests==0,"Granted link parent unexpectedly requested target permission")
        let entry=recent.entries.first{GitReferenceName.equal($0.path,outside)}!
        let acquired=try recent.acquire(entry,requireScope:true)
        try require(acquired.1.path.utf8.elementsEqual(root.appendingPathComponent(outside).path.utf8),"Recent entry resolved external leaf")
        let previous=document.model;document.openRecent(entry)
        try await wait{document.model !== previous && !document.model.syntaxWorking}
        try require(document.model.path==outside && document.model.snapshot?.contents==Data("../outside-secret".utf8),"Recent link failed to reopen")
        let archive=try BlameRecentDocuments(url:base.appendingPathComponent("private/recent.json"),provider:provider)
        try require(archive.entries.count==4,"Recent link archive did not preserve four distinct lexical leaves")
        // Historical Blame and parent actions remain valid without any disk leaf.
        try fm.removeItem(at:root.appendingPathComponent(path))
        let historical=try await owner(path,second.hash)
        try require(historical.model.snapshot?.contents==Data(current.utf8),"Historical missing link was rejected")
        let choices=try await repo.blameParentComparisons(revision:second.hash,path:path)
        guard let target=historical.model.sourceParentTarget(second.hash) else { throw Failure(description:"Attributed link lacks source parent target") }
        var prior:(String,String,Int)?,priorOptions:GitBlameOptions?
        historical.model.onPrevious={prior=($0,$1,$2);priorOptions=$3}
        historical.model.performHistoryParent(target,choices:choices,action:.previous)
        try require(prior?.0==path && prior?.1==first.hash && prior?.2==1 && priorOptions==historical.model.appliedOptions,"Previous Blame lost lexical link path/revision/options")
        let older=try await owner(prior!.0,prior!.1)
        try require(older.model.snapshot?.contents==Data(initial.utf8),"Previous Blame attributed current target")
        var historyChoices:[GitBlameParentComparison]?
        guard let historyTarget=historical.model.historyTarget([historical.model.historyEntries.first{$0.hash==second.hash}!]) else { throw Failure(description:"Link history target missing") }
        historical.model.prepareHistoryParents(historyTarget){historyChoices=$0}
        try await wait{historyChoices != nil && !historical.model.readingHistoryParents}
        try require(historyChoices?.first?.path==path,"History navigation lost link identity")
        historical.model.reload();try await wait{!historical.model.busy && !historical.model.syntaxWorking}
        try require(historical.model.snapshot?.contents==Data(current.utf8),"Historical Reload followed missing working link")
        // Browser's existing Blame item must lead to the same historical blob.
        let browser=RepositoryBrowserWindowController(repository:repo,access:scope,revision:second.hash,preferences:prefs,initialFile:path);browsers.append(browser);browser.window?.orderFront(nil)
        try await wait{!browser.model.busy && RepositoryBrowserWindowModel.activeOperations==0}
        guard let linkEntry=browser.model.entries.first(where:{$0.path==path}) else { throw Failure(description:"Browser link missing") }
        var browserBlame:(String,String)?;browser.model.onBlame={browserBlame=($0,$1)};browser.model.showEntryBlame(linkEntry)
        try require(linkEntry.kind == .symlink && browserBlame?.0==path && browserBlame?.1==second.hash,"Browser Blame did not route symbolic-link blob")
        // Both Log contexts retain their advertised Blame action, regardless of
        // the working target's existence or permission.
        try fm.createSymbolicLink(atPath:root.appendingPathComponent(path).path,withDestinationPath:"../../other-dangling")
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")
        let log=LogWindowController(repository:repo,access:scope,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);logOwners.append(log);log.window?.orderFront(nil)
        try await wait{!log.model.busy && !log.model.entries.isEmpty}
        var logBlame:(String,String)?;log.model.onBlame={logBlame=($0,$1)}
        log.model.select([second.hash]);try await wait{log.model.files.contains{$0.path==path}}
        let historicalFile=log.model.files.first{$0.path==path}!
        try require(log.model.canBlameFile([historicalFile.id]),"Historical link Blame disabled")
        log.model.blameFile([historicalFile.id]);try require(logBlame?.0==path && logBlame?.1==second.hash,"Historical Log handoff incorrect")
        logBlame=nil;log.model.select([""]);try await wait{log.model.files.contains{$0.path==path}}
        let workingFile=log.model.files.first{$0.path==path}!
        log.model.blameFile([workingFile.id]);try await wait{!log.model.busy && LogWindowModel.activeFileOpenReads==0}
        try require(logBlame?.0==path && logBlame?.1==second.hash,"Working Log followed/rejected dangling target: \(log.model.error ?? "none")")
        logBlame=nil;log.model.confirmingQuit=true;log.model.blameFile([workingFile.id]);try require(logBlame==nil && LogWindowModel.activeFileOpenReads==0,"Quit admitted link Blame");log.model.confirmingQuit=false
        // Incoming Finder and CLI routes use the leaf's parent permission and
        // keep the exact path rather than adopting a directory/external target.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,askpass:nil)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("private/marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.blameRecentDocuments=recent;workspace.notifyFinder={}
        workspace.commandLineRepositoryPermission={_ in scope}
        defer { workspace.stopMonitoringForTermination();Array(workspace.blameWindows.values).forEach{$0.close()} }
        workspace.open(root);try await wait{!workspace.busy && workspace.root != nil}
        for name in [outside,dangling,directory] {
            workspace.handle(FinderRequest(action:.blame,paths:[root.appendingPathComponent(name)]).url!)
            try await wait{workspace.blameWindows.values.contains{$0.model.path==name && !$0.model.busy}}
            let opened=workspace.blameWindows.values.first{$0.model.path==name}!
            try require(opened.model.snapshot?.path==name && opened.model.snapshot?.contents != secretBytes,"Incoming Finder link followed target")
            opened.close()
        }
        workspace.handleCommandLine(arguments:["/command:blame","/path:"+root.appendingPathComponent(outside).path],currentDirectory:root.path)
        try await wait{workspace.blameWindows.values.contains{$0.model.path==outside && !$0.model.busy}}
        try require(workspace.blameWindows.values.first{$0.model.path==outside}?.model.snapshot?.contents==Data("../outside-secret".utf8),"CLI link Blame changed leaf identity")
        Array(workspace.blameWindows.values).forEach{$0.close()}
        // Failure retains the prior document/MRU rather than adopting target.
        let untracked=root.appendingPathComponent("untracked-link");try fm.createSymbolicLink(atPath:untracked.path,withDestinationPath:"../outside-secret")
        let stable=document.model,count=recent.entries.count
        document.openDocument();fileReply?(untracked);try await wait{!stable.openingDocument}
        try require(document.model===stable && stable.error != nil && recent.entries.count==count,"Failed link Git read replaced document/MRU")
        do { _ = try BlameDocumentLocation.lexicalFile(root:root,path:"../outside-secret");throw Failure(description:"Traversal admitted") } catch is FinderServiceAuthorizationFailure {}
        try fm.createSymbolicLink(atPath:root.appendingPathComponent("escaped-parent").path,withDestinationPath:base.path)
        do { _ = try BlameDocumentLocation.lexicalFile(root:root,path:"escaped-parent/outside-secret");throw Failure(description:"Escaping parent admitted") } catch is FinderServiceAuthorizationFailure {}
        // A held real discovery process remains owned through Cancel and
        // forced retirement; neither reply may replace the document.
        func quote(_ text:String)->String { "'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        let helper=base.appendingPathComponent("held-discovery"),marker=base.appendingPathComponent("held-discovery.ready")
        let script="""
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = '--show-toplevel' ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec \(quote(git.path)) "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let held=try await owner(outside,"HEAD",helper),heldModel=held.model
        held.chooseFile={_,_,reply in reply(root.appendingPathComponent(dangling))}
        held.openDocument();try await wait{fm.fileExists(atPath:marker.path) && BlameDocumentOpener.activeReads==1}
        let cancelPIDs=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(cancelPIDs.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held link reader lost Quit ownership")
        held.model.onCancelDocumentOpen?();try await wait{BlameDocumentOpener.activeReads==0 && !heldModel.openingDocument && cancelPIDs.allSatisfy{kill($0,0) != 0}}
        try require(held.model===heldModel && !heldModel.retired,"Cancel adopted link reader result")
        try fm.removeItem(at:marker);held.openDocument();try await wait{fm.fileExists(atPath:marker.path) && BlameDocumentOpener.activeReads==1}
        let closePIDs=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        held.close();try await wait{BlameDocumentOpener.activeReads==0 && closePIDs.allSatisfy{kill($0,0) != 0}}
        try require(heldModel.retired && held.model===heldModel,"Retired link reader committed replacement")
        try require(try Data(contentsOf:secret)==secretBytes,"Outside target changed")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Blame changed index")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout;try require(finalHead==head,"Blame changed HEAD")
        blameOwners.forEach{$0.close()};logOwners.forEach{$0.close()};browsers.forEach{$0.close()};try await wait{drained()}
        print("PASS: symlink Blame document/recent/Browser/Log/history family")
    }
}
