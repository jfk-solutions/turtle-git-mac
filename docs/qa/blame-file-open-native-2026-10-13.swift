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
        func create(for url:URL) throws -> Data { Data(("PRIVATE:"+url.path).utf8) }
        func resolve(_ data:Data) throws -> ResolvedBookmark {
            let original=String(String(decoding:data,as:UTF8.self).dropFirst(8))
            return ResolvedBookmark(url:moves[original] ?? URL(fileURLWithPath:original),stale:moves[original] != nil)
        }
        func startAccessing(_ url:URL)->Bool { starts += 1;return true }
        func stopAccessing(_ url:URL) { stops += 1 }
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Blame File Open failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2]),provider=Provider()
        let history=try BlameRecentDocuments(url:folder.appendingPathComponent("private/blame-files.json"),provider:provider)
        var repos:[GitRepository]=[],files:[URL]=[]
        for name in ["first","second"] {
            let root=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:engine);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Open QA"),("user.email","open@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            let file=root.appendingPathComponent("雪:line\n.txt");try Data((name+" source\n").utf8).write(to:file);try await repo.stage([file.lastPathComponent]);_ = try await repo.commit(message:name)
            repos.append(repo);files.append(file)
        }
        let suite="TurtleGit.BlameOpen.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let firstScope=RepositoryAccessLease(url:repos[0].root,provider:provider)
        let owner=BlameWindowController(repository:repos[0],access:firstScope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,recentDocuments:history,requireScope:true,provider:provider)
        defer { owner.close() }
        try await wait { !owner.model.busy && !owner.model.syntaxWorking && history.entries.count==1 }
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
        owner.openDocument();fileReply?(files[1]);scopeReply?(repos[1].root)
        try await wait { owner.model !== original && !owner.model.syntaxWorking && history.entries.count==2 }
        try require(owner.window===window && original.retired && owner.model.repository.root.resolvingSymlinksInPath().path==repos[1].root.resolvingSymlinksInPath().path && owner.model.path==files[1].lastPathComponent && owner.model.selection==1 && changed==1,"SDI replacement/context mismatch: sameWindow=\(owner.window===window) retired=\(original.retired) root=\(owner.model.repository.root) expected=\(repos[1].root) path=\(owner.model.path) selection=\(String(describing:owner.model.selection)) changed=\(changed)")
        try require(BlameWindowController.focusedOwner(retainedFind?.window)===owner,"Find panel lost document-owner menu routing")
        try require(owner.findWindow===retainedFind && retainedFind?.model===owner.model && retainedFind?.draft.text=="source","File Open discarded/staled the modeless Find panel")
        let second=owner.model
        try Data("updated HEAD source\n".utf8).write(to:files[1]);try await repos[1].stage([files[1].lastPathComponent]);_ = try await repos[1].commit(message:"New HEAD")
        second.reload();try await wait { !second.busy && second.snapshot?.contents==Data("updated HEAD source\n".utf8) }
        try require(second.snapshot?.contents==Data("updated HEAD source\n".utf8),"HEAD document Reload stayed pinned to its previous snapshot")
        let untracked=repos[1].root.appendingPathComponent("untracked.txt");try Data("not committed".utf8).write(to:untracked)
        owner.openDocument();fileReply?(untracked);try await wait { !owner.model.openingDocument }
        try require(owner.model===second && history.entries.count==2,"Failed Git open changed document/MRU")
        owner.openRecent(history.entries.first { $0.lastKnownFile==files[0].path }!)
        try await wait { owner.model !== second && !owner.model.syntaxWorking }
        try require(owner.model.repository.root.resolvingSymlinksInPath().path==repos[0].root.resolvingSymlinksInPath().path && history.entries.first?.lastKnownFile==files[0].path,"Recent-file routing failed")
        let beforeRetire=owner.model
        owner.openDocument();let late=fileReply;owner.close();late?(files[1])
        try require(beforeRetire.retired && owner.openPanel==nil && BlameDocumentOpener.activeReads==0,"Retired picker accepted a late result")
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
          if [ "$task_arg" = '--show-toplevel' ]; then
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
        let held=BlameWindowController(repository:GitRepository(root:repos[0].root,executable:helper),access:firstScope,path:files[0].lastPathComponent,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,recentDocuments:history,requireScope:false,provider:provider)
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
}
