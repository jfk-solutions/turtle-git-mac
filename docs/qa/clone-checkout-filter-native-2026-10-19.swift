// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import CryptoKit
import TurtleGitCore

@MainActor enum CloneCheckoutFilterVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Clone filter timeout at \(line)")}
    static func drained()->Bool{CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0 && CloneProgressWindowController.activeReleases==0}
    static func verify()async throws{
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3]),fm=FileManager.default
        let global=ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]!,source=base.appendingPathComponent("source"),module=base.appendingPathComponent("module-source"),filter=base.appendingPathComponent("smudge"),ready=base.appendingPathComponent("smudge.ready"),hold=base.appendingPathComponent("smudge.hold"),fail=base.appendingPathComponent("smudge.fail"),failModule=base.appendingPathComponent("smudge.fail-module"),filterLog=base.appendingPathComponent("smudge.log")
        func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$TURTLEGIT_CLONE_FILTER_MARKER" >> "$0.log"
        if [ -f "$0.fail" ]; then exit 9; fi
        case "$PWD" in */module) if [ -f "$0.fail-module" ]; then exit 9; fi;; esac
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
        let candidates=[git.deletingLastPathComponent().appendingPathComponent("git-lfs"),URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/git-runtime/Git/bin/git-lfs")]
        guard let actualLFS=candidates.first(where:{fm.isExecutableFile(atPath:$0.path)}) else {throw Failure(description:"Actual bundled Git LFS binary is required")}
        let lfs=base.appendingPathComponent("record-lfs"),lfsLog=base.appendingPathComponent("lfs.log")
        let lfsScript="""
        #!/bin/sh
        printf '%s|%s|%s\\n' "$PWD" "$*" "$TURTLEGIT_CLONE_FILTER_MARKER" >> \(quote(lfsLog.path))
        exec \(quote(actualLFS.path)) "$@"
        """
        try lfsScript.write(to:lfs,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:lfs.path)
        let lfsBytes=Data("actual offline LFS object\n".utf8),oid=SHA256.hash(data:lfsBytes).map{String(format:"%02x",$0)}.joined(),storage=base.appendingPathComponent("lfs-storage")
        let object=storage.appendingPathComponent("objects/"+oid.prefix(2)+"/"+oid.dropFirst(2).prefix(2)+"/"+oid)
        try fm.createDirectory(at:object.deletingLastPathComponent(),withIntermediateDirectories:true);try lfsBytes.write(to:object)
        let pointer=Data(("version https://git-lfs.github.com/spec/v1\noid sha256:"+oid+"\nsize "+String(lfsBytes.count)+"\n").utf8)
        func repository(_ path:URL)async throws->GitRepository{
            try fm.createDirectory(at:path,withIntermediateDirectories:true);let repo=GitRepository(root:path,executable:git,askpass:nil)
            _ = try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Clone filter QA"),("user.email","clone@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
            return repo
        }
        let repo=try await repository(source)
        for(key,value)in[("filter.qa.clean","cat"),("filter.qa.smudge",quote(filter.path)),("filter.qa.required","true"),("filter.lfs.clean","cat"),("filter.lfs.smudge",quote(lfs.path)+" smudge -- %f"),("filter.lfs.required","true"),("lfs.storage",storage.path),("lfs.url","http://127.0.0.1:1/network-disabled"),("protocol.file.allow","always")]{_ = try await repo.run(["config","--file",global,key,value])}
        let child=try await repository(module)
        for candidate in [repo,child]{
            try Data("*.txt filter=qa\n*.lfs filter=lfs -text\n".utf8).write(to:candidate.root.appendingPathComponent(".gitattributes"))
            try Data("source content\n".utf8).write(to:candidate.root.appendingPathComponent("file.txt"));try pointer.write(to:candidate.root.appendingPathComponent("asset.lfs"))
            try await candidate.stage([".gitattributes","file.txt","asset.lfs"]);_ = try await candidate.commit(message:"filtered fixture")
        }
        _ = try await repo.run(["submodule","add","--",module.path,"module"]);_ = try await repo.commit(message:"nested checkout")
        let originalHead=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        _ = try await repo.run(["config","--file",global,"filter.lfs.process","exit 87"])
        // Source setup itself may invoke filters; only subsequent Clone calls
        // contribute to the assertions below.
        try? fm.removeItem(at:filterLog);try? fm.removeItem(at:lfsLog)
        let suite="TurtleGit.CloneCheckoutFilter."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(true,forKey:"UseLibgit2");prefs.set(2,forKey:"UseLibgit2_mask");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(true,forKey:"ConfirmKillProcess")
        let grant=RepositoryAccessLease(url:base),backend=GitLibGit2Configuration.load(from:prefs,helperURL:helper)
        let parent=NSWindow(contentRect:.init(x:0,y:0,width:800,height:480),styleMask:[.titled,.closable],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;parent.appearance=NSAppearance(named:.darkAqua);parent.orderFront(nil)
        var owners:[CloneProgressWindowController]=[],optionsOwners:[CloneWindowController]=[]
        defer{owners.forEach{$0.close()};optionsOwners.forEach{$0.close()};parent.close();clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite)}
        func progress(_ name:String,recursive:Bool=false,noCheckout:Bool=false,bare:Bool=false) -> CloneProgressWindowController{
            var options=CloneOptions();options.source=source.path;options.recursive=recursive;options.noCheckout=noCheckout;options.bare=bare
            let model=CloneProgressWindowModel(options:options,destination:base.appendingPathComponent(name),executable:git,destinationAccess:grant,sourceAccess:grant,keyAccess:nil,preferences:prefs,backend:backend)
            model.outputClipboard=clipboard
            let owner=CloneProgressWindowController(model:model);owners.append(owner);owner.window?.appearance=parent.appearance;owner.window?.alphaValue=0;parent.beginSheet(owner.window!);model.start();return owner
        }
        func finish(_ owner:CloneProgressWindowController)async throws{owner.model.close();try await wait{owner.presentationClosed && owner.window?.sheetParent==nil && parent.attachedSheet==nil && !owner.model.hasPendingWork}}
        // Accepted options and backend survive settings/form changes after the
        // actual options window reserves its submission.
        let options=CloneWindowController(directory:base,access:grant,preferences:prefs,executable:git);optionsOwners.append(options);options.window?.orderFront(nil)
        options.model.captureBackend={.load(from:prefs,helperURL:helper)};options.model.source=source.path
        let picked=base.appendingPathComponent("options clone");try fm.createDirectory(at:picked,withIntermediateDirectories:true)
        options.model.directory=base.appendingPathComponent("unchosen destination").path
        var folderReply:((NSApplication.ModalResponse)->Void)?
        options.model.selectedPanelURL={_ in picked};options.model.presentOpenPanel={panel,window,reply in folderReply=reply;window.beginSheet(panel,completionHandler:reply)}
        options.model.browseDirectory();try await wait{folderReply != nil && options.model.openPanel?.sheetParent===options.window}
        prefs.set(false,forKey:"UseLibgit2");folderReply?(.cancel);folderReply?(.OK)
        try await wait{options.model.openPanel==nil && !options.model.activeOperation}
        try require(options.model.directory != picked.path && options.window?.attachedSheet==nil,"Cancelled destination picker applied duplicate acceptance")
        folderReply=nil;options.model.browseDirectory();try await wait{folderReply != nil && options.model.openPanel?.sheetParent===options.window};folderReply?(.OK)
        try await wait{options.model.openPanel==nil && !options.model.activeOperation}
        try require(GitReferenceName.equal(options.model.directory,picked.path),"Destination chooser did not apply after actual detach")
        prefs.set(true,forKey:"UseLibgit2")
        let context=options.model.formContext,binding=options.model.field(\CloneWindowModel.noCheckout,context:options.model.formContext)
        options.model.clone();prefs.set(false,forKey:"UseLibgit2");binding.wrappedValue=true
        try await wait{options.progressController?.model.hasPendingWork==false && options.progressController?.model.commandFinished==true}
        let accepted=options.progressController!.model
        try require(accepted.backend.requests(.clone) && !accepted.options.noCheckout && options.model.formContext != context && accepted.success,"Accepted options/backend changed during Clone: \(accepted.output)")
        try require(try Data(contentsOf:accepted.destination.appendingPathComponent("file.txt"))==Data("FILTERED content\n".utf8),"Initial native clone omitted custom smudge")
        try require(try Data(contentsOf:accepted.destination.appendingPathComponent("asset.lfs"))==lfsBytes,"Configured git-lfs one-shot smudge omitted")
        accepted.close();try await wait{options.progressController==nil};options.close();prefs.set(true,forKey:"UseLibgit2")
        let recursive=progress("recursive clone",recursive:true);try await wait{!recursive.model.hasPendingWork && !recursive.model.busy}
        try require(recursive.model.success && recursive.model.commandSucceeded,"Recursive native filtered clone failed: \(recursive.model.output)")
        for path in ["file.txt","module/file.txt"]{try require(try Data(contentsOf:recursive.model.destination.appendingPathComponent(path))==Data("FILTERED content\n".utf8),"Recursive checkout smudge/cwd missing at "+path)}
        try require(try Data(contentsOf:recursive.model.destination.appendingPathComponent("module/asset.lfs"))==lfsBytes,"Recursive git-lfs one-shot omitted")
        let entries=try String(contentsOf:filterLog),lfsEntries=try String(contentsOf:lfsLog)
        try require(entries.contains("recursive clone/module|") && entries.contains("|private-clone-context") && lfsEntries.contains("smudge -- asset.lfs|private-clone-context"),"Checkout filters lost repository cwd, original environment or literal filename")
        try await finish(recursive)
        let before=try String(contentsOf:filterLog),beforeLFS=try String(contentsOf:lfsLog)
        for (name,bare,noCheckout) in [("no-checkout",false,true),("bare.git",true,false)]{
            let owner=progress(name,noCheckout:noCheckout,bare:bare);try await wait{!owner.model.hasPendingWork}
            try require(owner.model.success && !fm.fileExists(atPath:owner.model.destination.appendingPathComponent("file.txt").path),"Bare/no-checkout executed working checkout")
            try await finish(owner)
        }
        try require(try String(contentsOf:filterLog)==before && (try String(contentsOf:lfsLog))==beforeLFS,"Bare/no-checkout spawned filters")
        // Required failures are failed command receipts, not successful clones
        // with a silent raw fallback. Initial versus nested targets differ.
        try Data().write(to:fail)
        let failed=progress("initial failure");try await wait{!failed.model.hasPendingWork}
        try require(failed.model.commandFinished && !failed.model.commandSucceeded && !failed.model.success && failed.model.postActions==[.retry] && failed.model.completionRange != nil && !fm.fileExists(atPath:failed.model.destination.path),"Required initial filter failure lost source cleanup/error receipt: \(failed.model.output)")
        try await finish(failed)
        _ = try await repo.run(["config","--file",global,"filter.qa.required","false"])
        let optional=progress("optional filter failure");try await wait{!optional.model.hasPendingWork}
        try require(optional.model.success && (try Data(contentsOf:optional.model.destination.appendingPathComponent("file.txt")))==Data("source content\n".utf8),"Optional filter failure did not retain raw checkout bytes")
        try await finish(optional);_ = try await repo.run(["config","--file",global,"filter.qa.required","true"])
        try fm.removeItem(at:fail);try Data().write(to:failModule)
        let nestedFailure=progress("recursive failure",recursive:true);try await wait{!nestedFailure.model.hasPendingWork}
        try require(!nestedFailure.model.success && !nestedFailure.model.commandSucceeded && fm.fileExists(atPath:nestedFailure.model.destination.appendingPathComponent(".git").path) && nestedFailure.model.postActions==[.retry],"Nested failure did not preserve completed superproject: \(nestedFailure.model.output)")
        try await finish(nestedFailure);try fm.removeItem(at:failModule)
        // Actual native No/Yes question while a real smudge process is held.
        try Data().write(to:hold)
        let cancelled=progress("cancelled filter");var question:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?
        cancelled.presentCancellation={alert,window,reply in question=alert;answer=reply;alert.beginSheetModal(for:window,completionHandler:reply)}
        try await wait{fm.fileExists(atPath:ready.path) && cancelled.model.hasPendingWork}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && !cancelled.model.commandFinished && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held filter lost command/Quit ownership")
        cancelled.model.cancel();try await wait{question?.window.sheetParent===cancelled.window};question!.buttons[1].performClick(nil)
        try await wait{!cancelled.model.confirmingCancellation && cancelled.window?.attachedSheet==nil}
        answer?(.alertFirstButtonReturn)
        try require(pids.allSatisfy{kill($0,0)==0} && !cancelled.model.cancelling,"Duplicate Yes overrode actual No")
        cancelled.model.cancel();try await wait{question?.window.sheetParent===cancelled.window};question!.buttons[0].performClick(nil)
        try await wait{!cancelled.model.hasPendingWork && pids.allSatisfy{kill($0,0) != 0}}
        try require(cancelled.model.cancelled && !cancelled.model.success && cancelled.window?.attachedSheet==nil,"Accepted cancellation did not wait native/filter drain")
        try await finish(cancelled);try fm.removeItem(at:ready)
        let forced=progress("forced filter close");var closed=0;forced.onClosed={closed += 1}
        try await wait{fm.fileExists(atPath:ready.path) && forced.model.hasPendingWork}
        let forcedPIDs=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        forced.close();try require(forced.model.hasPendingWork && closed==0,"Forced close released filter before actual worker drain")
        try await wait{!forced.model.hasPendingWork && forced.presentationClosed && forcedPIDs.allSatisfy{kill($0,0) != 0}}
        try require(closed==1 && !forced.model.success && parent.attachedSheet==nil,"Forced close delivered success/duplicate release")
        try fm.removeItem(at:hold)
        try require(try Data(contentsOf:source.appendingPathComponent("asset.lfs"))==pointer,"Clone checkout changed source LFS pointer")
        try require(try Data(contentsOf:source.appendingPathComponent(".git/index"))==index,"Clone checkout changed source index")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;try require(afterHead==originalHead,"Clone checkout changed source HEAD")
        owners.forEach{$0.close()};optionsOwners.forEach{$0.close()};parent.close();try await wait{drained()}
        print("PASS: native Clone custom/git-lfs checkout filters, recursive/captured options, no-checkout/bare, required failure and owned cancellation")
    }
}
