// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore
extension NSWindow {
    @objc func notesBackendFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func notesBackendOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;notesBackendOrder(mode,relativeTo:number)}
}
@MainActor @main struct NotesBackendVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Notes backend native timeout at \(line)")}
    static func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.NotesBackend."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var helper:URL{base.appendingPathComponent("notes-helper")}
        var trace:URL{base.appendingPathComponent("trace")};var mode:URL{base.appendingPathComponent("mode")}
        var unreadable:URL{base.appendingPathComponent("unreadable")};var started:URL{base.appendingPathComponent("started")};var release:URL{base.appendingPathComponent("release")}
        var cli:GitRepository!,repo:GitRepository!,head="",headBytes=Data(),indexBytes=Data(),working=Data(),owners:[NSWindowController]=[]
        var environment:[String:String]=[:]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar")}
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.window?.orderFront(nil);return owner}
        func env(_ key:String,_ value:String){if environment[key]==nil{environment[key]=getenv(key).map{String(cString:$0)} ?? "\0"};setenv(key,value,1)}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            cli=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await cli.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Configured Notes Author"),("user.email","configured@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("core.notesRef","refs/notes/configured"),("tgit.logminsize","2")] {_=try await cli.run(["config",k,v])}
            working=Data("unchanged\n".utf8);try working.write(to:root.appendingPathComponent("file.txt"));try await cli.stage(["."]);_=try await cli.commit(message:"target")
            head=try await cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);headBytes=try Data(contentsOf:root.appendingPathComponent(".git/HEAD"));indexBytes=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let runtime=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
            let resource=base.appendingPathComponent("owned-resource");try Data().write(to:resource)
            let script="""
            #!/bin/sh
            exec 9< \(quote(resource.path))
            printf '%s\\n' "$*" >> \(quote(trace.path))
            phase=''
            for word in "$@"; do case "$word" in turtlegit-notes-read|turtlegit-notes-write) phase="$word" ;; esac; done
            mode='';if test -f \(quote(mode.path)); then mode=$(/bin/cat \(quote(mode.path))); fi
            if test "$phase" = turtlegit-notes-read && test -f \(quote(unreadable.path)); then printf 'invalid notes protocol\\n';exit 0;fi
            if { test "$mode" = holdread && test "$phase" = turtlegit-notes-read; } || { test "$mode" = holdwrite && test "$phase" = turtlegit-notes-write; }; then
              : > \(quote(started.path));while ! test -f \(quote(release.path));do /bin/sleep .02;done
            fi
            if test "$phase" = turtlegit-notes-write; then
              if test "$mode" = fail;then printf 'PRIVATE NOTES WRITE FAILURE\\n' >&2;exit 93;fi
              if test "$mode" = completed || test "$mode" = unknown;then
                \(quote(runtime.path)) "$@";status=$?
                if test "$status" -eq 0;then
                  if test "$mode" = unknown;then : > \(quote(unreadable.path));fi
                  printf 'PRIVATE NOTES AFTER WRITE FAILURE\\n' >&2;exit 94
                fi
                exit "$status"
              fi
            fi
            exec \(quote(runtime.path)) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0,helperURL:helper))
            env("GIT_NOTES_REF","refs/notes/native");env("GIT_AUTHOR_NAME","Environment Author");env("GIT_AUTHOR_EMAIL","environment-author@example.invalid");env("GIT_COMMITTER_NAME","Environment Committer");env("GIT_COMMITTER_EMAIL","environment-committer@example.invalid")
        }
        func owner()async throws->HistoryNotesWindowController{
            let owner=own(HistoryNotesWindowController(repository:repo,access:RepositoryAccessLease(url:root),revision:head,preferences:prefs));owner.model.load()
            try await wait{!owner.model.loading && !owner.model.hasPendingWork};try require(owner.model.snapshot != nil && owner.editor.isEditable,"Notes editor unavailable: \(owner.model.error ?? "none")");return owner
        }
        func draft(_ text:String,_ owner:InputWindowController){owner.editor.selectAll(nil);owner.editor.insertText(text,replacementRange:owner.editor.selectedRange());owner.textDidChange(Notification(name:NSText.didChangeNotification,object:owner.editor))}
        func control(_ value:String)throws{for marker in [started,release,unreadable]{try? FileManager.default.removeItem(at:marker)};try Data(value.utf8).write(to:mode)}
        func raw(_ ref:String)async throws->String?{let blob=try await cli.run(["notes","--ref="+ref,"list",head],successfulExitCodes:0...1);guard blob.exitCode==0 else{return nil};return String(data:try await cli.run(["cat-file","blob",blob.text.trimmingCharacters(in:.newlines)]).stdout,encoding:.utf8)}
        func calls()->String{(try? String(contentsOf:trace,encoding:.utf8)) ?? ""}
        func unchanged()throws{let head=try Data(contentsOf:root.appendingPathComponent(".git/HEAD")),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent("file.txt"));try require(head==headBytes && index==indexBytes && file==working,"Notes touched HEAD/index/working file")}
        func clean()async{
            try? Data().write(to:release)
            for owner in owners.reversed(){if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()}
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            for(key,value)in environment{if value=="\0"{unsetenv(key)}else{setenv(key,value,1)}};prefs.removePersistentDomain(forName:suite)
        }
    }
    static func drained()->Bool{HistoryNotesWindowModel.activeReads==0 && HistoryNotesWindowModel.activeMutations==0 && LogWindowModel.activeNoteReads==0 && LogWindowModel.activeNoteSaves==0 && InputWindowController.activeSaves==0 && CommitNotePresenter.activeWarnings==0}
    static func editor(_ c:Context)async throws{
        let owner=try await c.owner();try require(owner.model.snapshot?.notesRef=="refs/notes/configured" && owner.model.acceptedOperationRepository?.libgit2Configuration?.enabled==false && c.calls().contains("turtlegit-notes-read"),"Notes read obeyed master mask instead of source unconditional helper")
        c.env("GIT_NOTES_REF","refs/notes/changed");_=try await c.cli.run(["config","core.notesRef","refs/notes/changed-configured"]);c.prefs.set(true,forKey:"UseLibgit2");c.draft("literal note\nwith trailing newline\n",owner);owner.save()
        try await wait{owner.saved && !owner.hasPendingWork && drained()}
        let stored=try await c.raw("refs/notes/configured"),other=try await c.raw("refs/notes/changed"),environment=try await c.raw("refs/notes/native"),reconfigured=try await c.raw("refs/notes/changed-configured")
        try require(stored=="literal note\nwith trailing newline\n" && other==nil && environment==nil && reconfigured==nil && c.calls().contains("turtlegit-notes-write"),"Accepted Notes ref/text changed between read and save")
        let signature=try await c.cli.run(["show","-s","--format=%an%x00%ae%x00%cn%x00%ce","refs/notes/configured"]).stdout
        try require(signature==Data("Configured Notes Author\0configured@example.invalid\0Configured Notes Author\0configured@example.invalid\n".utf8),"Notes used environment overrides instead of configured libgit2 signature")
        try c.unchanged()
    }
    static func outcomes(_ c:Context)async throws{
        let failed=try await c.owner();c.draft("retry draft",failed);try c.control("fail");failed.save();try await wait{!failed.busy && !failed.model.saving}
        try require(!failed.saved && failed.editor.string=="retry draft" && failed.canAccept && failed.errorLabel.stringValue.contains("PRIVATE NOTES WRITE FAILURE"),"Known failed write discarded/disabled draft")
        try c.control("");failed.save();try await wait{failed.saved && !failed.hasPendingWork};try require(try await c.raw("refs/notes/configured")=="retry draft","Native retry failed to save preserved draft")
        let repair=try await c.owner();c.draft("configured identity repair",repair)
        _=try await c.cli.run(["config","--unset-all","user.name"]);_=try await c.cli.run(["config","--unset-all","user.email"])
        repair.save();try await wait{!repair.busy && !repair.model.saving}
        try require(!repair.saved && repair.editor.string=="configured identity repair" && !repair.errorLabel.stringValue.isEmpty,"Environment preflight overrode missing configured Notes signature")
        _=try await c.cli.run(["config","user.name","Configured Notes Author"]);_=try await c.cli.run(["config","user.email","configured@example.invalid"])
        repair.save();try await wait{repair.saved && !repair.hasPendingWork}
        let repairedRaw=try await c.raw("refs/notes/configured");try require(repairedRaw=="configured identity repair","Configured identity repair did not retain original Notes draft")
        let completed=try await c.owner();c.draft("completed write",completed);try c.control("completed");completed.save();try await wait{completed.saved && !completed.hasPendingWork}
        let completedRaw=try await c.raw("refs/notes/configured");try require(completed.model.error?.contains("Notes saved")==true && completedRaw=="completed write","Completed transport error was treated as unwritten retry")
        try c.control("");let unknown=try await c.owner();c.draft("unknown write",unknown);try c.control("unknown");unknown.save();try await wait{!unknown.busy && !unknown.model.saving}
        let unknownRaw=try await c.raw("refs/notes/configured");try require(!unknown.saved && unknown.editor.string=="unknown write" && unknown.errorLabel.stringValue.contains("may have been saved") && unknownRaw=="unknown write","Unknown write did not preserve editable draft and explicit receipt")
        try c.control("");try c.unchanged()
    }
    static func log(_ c:Context)async throws{
        let owner=c.own(LogWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),labelDefaults:c.prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)),m=owner.model
        m.entries=try await c.cli.history();m.graph=CommitGraph.layout(m.entries);m.selected=[c.head]
        m.editNotes();try await wait{owner.noteEditor != nil && !m.loadingNote}
        let editor=try unwrap(owner.noteEditor,"Log editor absent");let original=try unwrap(m.noteRequest,"Log snapshot absent")
        try require(m.noteOperationRepository?.libgit2Configuration?.enabled==false,"Log Notes lost accepted backend")
        c.env("GIT_NOTES_REF","refs/notes/changed");_=try await c.cli.run(["config","core.notesRef","refs/notes/changed-configured"]);c.prefs.set(true,forKey:"UseLibgit2");c.draft("Log selected note",editor);editor.save()
        try await wait{owner.noteEditor==nil && drained()}
        let value=try await c.raw(original.notesRef);try require(value=="Log selected note" && m.entries.first?.notes=="Log selected note","Log did not publish exact captured note readback")
        try c.unchanged()
    }
    static func ownership(_ c:Context)async throws{
        let owner=try await c.owner();c.draft("cancelled draft",owner);try c.control("holdwrite");owner.save();try await wait{FileManager.default.fileExists(atPath:c.started.path)}
        owner.cancel();try await wait{!owner.busy && !owner.model.saving}
        let capturedRef=try unwrap(owner.model.snapshot?.notesRef,"Cancelled save lost captured ref"),cancelledRaw=try await c.raw(capturedRef);try require(!owner.saved && owner.editor.string=="cancelled draft" && owner.canAccept && cancelledRaw==nil,"Cancelled write changed notes or dropped draft")
        owner.close();try c.control("holdread")
        let late=c.own(HistoryNotesWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),revision:c.head,preferences:c.prefs));var closed=false;late.onClosed={closed=true};late.model.load()
        try await wait{FileManager.default.fileExists(atPath:c.started.path)};late.close();try Data().write(to:c.release)
        try await wait{closed && !late.model.hasPendingWork && drained()}
        try require(late.model.invalidated && late.model.snapshot==nil && !late.saved,"Closed Notes owner published late read")
        try c.unchanged()
    }
    static func main()async{
        NSApp.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.notesBackendFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.notesBackendOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{let mode=CommandLine.arguments[3];if mode=="identity"{try await CommitNoteLifecycleVerification.identity()}else{try await c.prepare();switch mode{case "editor":try await editor(c);case "log":try await log(c);case "outcomes":try await outcomes(c);default:try await ownership(c)}};await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil},"Owned Notes work/windows survived cleanup");print("PASS: notes backend "+mode)}catch{await c.clean();fputs("Notes backend failure: \(error)\n",stderr);exit(1)}
    }
}
