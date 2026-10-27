import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

@main struct CommitRefreshVerification {
    struct Failure: Error, CustomStringConvertible { var description: String }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws {
        if !value() { throw Failure(description: "Requirement failed at line \(line)") }
    }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out waiting for Commit refresh at line \(line)")
    }
    @MainActor static func settle() async throws { for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) } }
    @MainActor static func main() async {
        do { try await verify() } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.CommitRefresh.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Commit Tests"])
        _ = try await repo.run(["config", "user.email", "commit@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"]); _ = try await repo.commit(message: "base")
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt")); try await repo.stage(["tracked.txt"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        _ = try await repo.status()
        let beforeHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let beforeFile = try Data(contentsOf: root.appendingPathComponent("tracked.txt"))
        // A read that deliberately ignores cancellation must still be fenced.
        for fail in [false, true] {
            let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs)
            let model = controller.model
            var reply: CheckedContinuation<[StatusEntry], Error>?, token: OperationCancellation?
            model.queryCommitStatus = { _, request in
                token = request
                return try await withCheckedThrowingContinuation { reply = $0 }
            }
            model.message = "Preserve draft"
            model.reload(); try await wait { reply != nil }
            let branch = model.branch, entries = model.entries.map(\.path)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
            try require(token?.isCancelled == true && !model.busy && !model.canCommit && !model.canCancel)
            if fail { reply!.resume(throwing: Failure(description: "Late read error")) }
            else { reply!.resume(returning: StatusEntry.parse(Data("A  late.txt\0".utf8))) }
            reply = nil
            try await settle()
            try require(model.entries.map(\.path) == entries && model.branch == branch && model.message == "Preserve draft" && model.error == nil && !model.busy)
            model.reload(); try await settle(); try require(model.entries.map(\.path) == entries)
            controller.window?.close()
        }
        // Cancel disables immediately while confirmation is pending. No keeps
        // the original read running and its later result remains authoritative.
        do {
            let controller = CommitWindowController(repository: repo, access: nil, defaults: prefs), model = controller.model
            var reply: CheckedContinuation<[StatusEntry], Error>?, token: OperationCancellation?, approve: ((Bool) -> Void)?
            model.queryCommitStatus = { _, request in token = request; return try await withCheckedThrowingContinuation { reply = $0 } }
            model.message = "Retain pending draft"; model.messageOnly = true
            var confirmations = 0, completed: Bool?, notifications = 0
            model.confirmCancel = { confirmations += 1; approve = $0 }
            model.reload(); try await wait { reply != nil }
            let observer = model.objectWillChange.sink { notifications += 1 }
            model.cancel(completion: { completed = $0 })
            try require(model.busy && !model.canCancel && notifications > 0 && confirmations == 1 && token?.isCancelled == false)
            reply!.resume(returning: StatusEntry.parse(Data("MM tracked.txt\0".utf8))); reply = nil
            try await wait { !model.busy }
            try require(model.inputsBlocked && !model.canCancel && !model.canCommit && token?.isCancelled == false && completed == nil)
            model.reload(); try await settle(); try require(reply == nil)
            approve?(false)
            try require(completed == false && model.canCancel && model.canCommit && !model.inputsBlocked && token?.isCancelled == false)
            try require(model.entries.contains { $0.path == "tracked.txt" } && model.message == "Retain pending draft" && model.error == nil)
            model.queryCommitStatus = { try await repo.commitDialogStatus(amendToParent: $0, cancellation: $1) }
            model.reload(); try await wait { !model.busy }
            try require(model.branch == "main" && model.error == nil)
            observer.cancel(); controller.window?.close()
        }
        // Exercise the default production query against an actually running child.
        let wrapper = root.appendingPathComponent("blocked-refresh-git"), marker = root.appendingPathComponent("refresh-child.pid"), flag = root.appendingPathComponent("block-refresh"), metadataFlag = root.appendingPathComponent("block-metadata")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let program = "#!/bin/sh\ncase \"$*\" in *'status --porcelain=v1'*) if test -e " + quote(flag.path) + "; then printf '%s\\n' \"$$\" > " + quote(marker.path) + "; exec /bin/sleep 120; fi ;; *'--get user.name'*) if test -e " + quote(metadataFlag.path) + "; then printf '%s\\n' \"$$\" > " + quote(marker.path) + "; exec /bin/sleep 120; fi ;; esac\nexec " + quote(engine.path) + " \"$@\"\n"
        try Data(program.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let blocked = GitRepository(root: root, executable: wrapper)
        for closeDirectly in [false, true] {
            try Data().write(to: flag); try? FileManager.default.removeItem(at: marker)
            let controller = CommitWindowController(repository: blocked, access: nil, defaults: prefs), model = controller.model
            model.message = "Preserve real draft"
            var confirmations = 0, closes = 0, completion: Bool?, duplicate: Bool?, approve: ((Bool) -> Void)?
            model.confirmCancel = { confirmations += 1; approve = $0 }
            controller.onClosed = { closes += 1 }
            model.reload(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let child = Int32(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            defer { if kill(child, 0) == 0 { kill(child, SIGTERM) } }
            try require(kill(child, 0) == 0 && model.busy && model.canCancel)
            if closeDirectly { controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window)) }
            else {
                model.cancel(completion: { completion = $0 }); model.cancel(completion: { duplicate = $0 })
                try require(duplicate == false && !model.canCancel && confirmations == 1 && kill(child, 0) == 0)
                let declined = approve
                approve?(false)
                try require(completion == false && model.canCancel && model.busy && kill(child, 0) == 0)
                completion = nil; approve = nil
                model.cancel(completion: { completion = $0 })
                try require(confirmations == 2 && approve != nil && kill(child, 0) == 0)
                declined?(true); try require(kill(child, 0) == 0 && completion == nil)
                approve?(true)
            }
            try await wait { kill(child, 0) == -1 && errno == ESRCH && !model.busy }
            try await settle()
            try require(model.error == nil && model.message == "Preserve real draft")
            if closeDirectly { try require(confirmations == 0 && closes == 1 && !model.canCommit) }
            else {
                try require(confirmations == 2 && completion == true && closes == 1 && !model.canCancel)
                // A repeated reply after close cannot invoke another close.
                approve?(true); try require(closes == 1 && completion == true)
            }
            controller.window?.close()
        }
        // The repository actor can queue refresh behind this window's metadata
        // child. Approval cancels that owner too before awaiting the refresh.
        try? FileManager.default.removeItem(at: flag); try? FileManager.default.removeItem(at: marker)
        do {
            let controller = CommitWindowController(repository: blocked, access: nil, defaults: prefs), model = controller.model
            model.message = "Queued refresh draft"
            model.reload(); try await wait { !model.busy }
            try require(model.commitIdentityPrepared && model.error == nil)
            try Data().write(to: metadataFlag)
            model.setAuthor = true; model.authorChanged(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let child = Int32(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            defer { if kill(child, 0) == 0 { kill(child, SIGTERM) } }
            try require(model.loadingAuthorIdentity && kill(child, 0) == 0)
            model.reload(); try await settle(); try require(model.busy && model.loadingAuthorIdentity && kill(child, 0) == 0)
            var completed: Bool?, closes = 0, confirmations = 0
            controller.onClosed = { closes += 1 }
            model.confirmCancel = { confirmations += 1; $0(true) }
            model.cancel(completion: { completed = $0 })
            try await wait { kill(child, 0) == -1 && errno == ESRCH && completed != nil }
            try require(completed == true && confirmations == 1 && closes == 1 && !model.busy && !model.loadingAuthorIdentity && model.error == nil && model.message == "Queued refresh draft" && !model.canCommit)
            controller.window?.close()
        }
        for file in [wrapper,marker,flag,metadataFlag] { try? FileManager.default.removeItem(at: file) }
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterFile = try Data(contentsOf: root.appendingPathComponent("tracked.txt"))
        try require(afterHead == beforeHead && afterIndex == beforeIndex && afterFile == beforeFile)
        try await verifyMissingRecoveryDuringCancel(root:root,engine:engine,preferences:prefs)
        try await verifyCapturedShippingRead(root:root,engine:engine,preferences:prefs)
        print("PASS: Commit initial refresh ignores late values/errors after controller close; Cancel confirms before stopping a live status child; No preserves the running read, Yes reaps and closes once; immediate publication, completed-refresh/pending-answer gates and stale-answer/duplicate-cancel guards; declined cancel permits reload; approval reaps own metadata child ahead of queued refresh; late confirmation cannot close twice; HEAD/index/working bytes preserved. " + engine.path)
    }
    /// A real missing stage-zero entry reaches recovery while Cancel's answer
    /// is pending. The prompt must wait without abandoning the owned read.
    @MainActor static func verifyMissingRecoveryDuringCancel(root:URL,engine:URL,preferences:UserDefaults)async throws {
        for answer in ["no","yes","close"] {
            let folder=root.appendingPathComponent(".git/missing-recovery-cancel-"+answer)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:engine,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for (key,value) in [("user.name","Recovery Cancel QA"),("user.email","recovery@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            try Data("anchor\n".utf8).write(to:folder.appendingPathComponent("anchor"));try await repo.stage(["anchor"]);_=try await repo.commit(message:"anchor")
            let missing=folder.appendingPathComponent("lost.txt"),content=Data("staged recovery content\n".utf8)
            try content.write(to:missing);try await repo.stage(["lost.txt"]);try FileManager.default.removeItem(at:missing)
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            let controller=CommitWindowController(repository:repo,access:nil,defaults:preferences),model=controller.model
            controller.window?.alphaValue=0;controller.window?.setFrameOrigin(NSPoint(x:-20000,y:-20000))
            var reply:CheckedContinuation<[StatusEntry],Error>?,token:OperationCancellation?,approve:((Bool)->Void)?
            var completed:Bool?,prompts=0,notices=0,failures=[String](),closes=0
            controller.onClosed={closes += 1}
            model.queryCommitStatus={_,request in token=request;return try await withCheckedThrowingContinuation{reply=$0}}
            model.message="Recovery Cancel draft";model.messageOnly=true
            model.confirmCancel={approve=$0}
            model.missingStagedRecovery.choose={candidate in
                prompts += 1
                if candidate.path != "lost.txt" {failures.append("Unexpected recovery candidate: "+candidate.path)}
                if completed != false {failures.append("Recovery presented before Cancel was declined")}
                return .init(action:.restoreFromIndex)
            }
            model.missingStagedRecovery.showRefreshNotice={notices += 1}
            model.missingStagedRecovery.showFailure={failures.append($0)}
            func drain()async throws {
                // Release an injected continuation even when an assertion fails.
                if let pending=reply {reply=nil;pending.resume(throwing:OperationCancellationFailure.cancelled)}
                controller.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:controller.window));controller.window?.close()
                try await wait{CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && MissingStagedFileRecoverySession.activeRequests==0}
            }
            do {
                model.reload();try await wait{reply != nil}
                model.cancel(completion:{completed=$0})
                try require(approve != nil && model.busy && !model.canCancel && completed==nil && token?.isCancelled==false)
                let pending=reply!;reply=nil;pending.resume(returning:StatusEntry.parse(Data("AD lost.txt\0".utf8)))
                try await wait{model.missingStagedRecovery.busy}
                try require(prompts==0 && notices==0 && failures.isEmpty && model.busy && completed==nil && token?.isCancelled==false && !FileManager.default.fileExists(atPath:missing.path))
                let pendingIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
                try require(pendingIndex==index)
                if answer=="no" {
                    approve?(false)
                    try await wait{!model.busy && prompts==1}
                    try require(completed==false && token?.isCancelled==false && model.canCancel && model.canCommit && !model.inputsBlocked && model.error==nil)
                    try require(notices==1 && failures.isEmpty && model.message=="Recovery Cancel draft")
                    let restored=try Data(contentsOf:missing)
                    try require(restored==content)
                } else {
                    if answer=="yes" {approve?(true)}
                    else {controller.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:controller.window))}
                    try await wait{!model.busy && CommitWindowModel.activeReloads==0 && MissingStagedFileRecoverySession.activeRequests==0 && closes==1}
                    try require(token?.isCancelled==true && prompts==0 && notices==0 && failures.isEmpty && model.error==nil && !model.canCommit && !FileManager.default.fileExists(atPath:missing.path))
                    if answer=="yes" {try require(completed==true)}
                    approve?(true);try require(closes==1 && prompts==0)
                }
                let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
                try require(afterHead==head && afterIndex==index)
                try await drain()
            } catch {
                try? await drain()
                throw error
            }
            print("PASS: missing staged recovery during Cancel "+answer+"; owned read drained, prompt/mutation fenced, HEAD/index preserved")
        }
    }
    /// Uses the shipping reader unchanged. Assigning queryCommitStatus would
    /// deliberately select the legacy injection path and invalidate this check.
    @MainActor static func verifyCapturedShippingRead(root:URL,engine:URL,preferences:UserDefaults)async throws {
        let folder=root.appendingPathComponent(".git/captured-read-fixture"),log=folder.appendingPathComponent(".git/argv-log"),wrapper=folder.appendingPathComponent(".git/count-git"),hold=folder.appendingPathComponent(".git/hold-diff"),pidFile=folder.appendingPathComponent(".git/diff.pid")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:engine,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Captured Commit QA"),("user.email","capture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("parent\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"parent")
        try Data("last\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"last")
        try Data("staged\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);try Data("working\n".utf8).write(to:folder.appendingPathComponent("file"))
        let originalHead=try await repo.run(["rev-parse","HEAD"]).stdout,originalIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        inspect() {
          while [ "$#" -gt 0 ]; do
            case "$1" in -C|-c) shift;shift;; --*) shift;; *) break;; esac
          done
          printf '%s\n' "${1-}" >> \(quote(log.path))
          if [ "${1-}" = diff ] && [ -f \(quote(hold.path)) ]; then
            exec 9>\(quote(folder.appendingPathComponent(".git/owned-diff-resource").path))
            printf '%s\n' "$$" > \(quote(pidFile.path))
            while :; do /bin/sleep 0.02; done
          fi
        }
        inspect "$@"
        exec \(quote(engine.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let reader=GitRepository(root:folder,executable:wrapper,libgit2Configuration:.init(enabled:false))
        func capture(_ executable:String,_ arguments:[String])throws->(Int32,String) {
            let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
            process.standardOutput=pipe;process.standardError=FileHandle.nullDevice;try process.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            return (process.terminationStatus,String(decoding:bytes,as:UTF8.self))
        }
        func absent(_ pid:Int32)->Bool {kill(pid,0)==(-1) && errno==ESRCH}
        func ownedHeldChild(_ pid:Int32)throws->Bool {
            let (_,command)=try capture("/bin/ps",["-p",String(pid),"-o","command="])
            let arguments=command.trimmingCharacters(in:.whitespacesAndNewlines)
            let names=Set([wrapper.path,wrapper.standardizedFileURL.resolvingSymlinksInPath().path])
            guard names.contains(where:{arguments.hasPrefix("/bin/sh "+$0+" ") || arguments=="/bin/sh "+$0}) else{
                print("Captured helper argv mismatch: \(arguments); expected wrappers \(names)");return false
            }
            let (status,files)=try capture("/usr/sbin/lsof",["-a","-p",String(pid),"-Fn"])
            // Foundation may retain /var while lsof reports /private/var.
            // Compare the exact real filesystem path of this private open file.
            guard let resolved=realpath(folder.appendingPathComponent(".git/owned-diff-resource").path,nil) else{return false}
            defer {free(resolved)}
            let resource=String(cString:resolved)
            let matched=status==0 && files.split(separator:"\n").contains{String($0)=="n"+resource}
            if !matched {print("Captured helper resource mismatch: status=\(status), expected=\(resource), open=\(files)")}
            return matched
        }
        func drain(_ controller:CommitWindowController)async throws {
            controller.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:controller.window));controller.window?.close()
            let pid=(try? String(contentsOf:pidFile,encoding:.utf8)).flatMap{Int32($0.trimmingCharacters(in:.newlines))}
            func settled()->Bool {(pid.map(absent) ?? true) && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0}
            for _ in 0..<500 {if settled(){return};try await Task.sleep(nanoseconds:10_000_000)}
            // Cancellation normally reaps its own group. Fallback signals require
            // both this exact authored wrapper argv and its open private resource.
            if let pid,!absent(pid) {
                for signal in [SIGTERM,SIGKILL] {
                    guard try ownedHeldChild(pid) else {throw Failure(description:"Refusing signal to unverified captured-read child")}
                    if getpgid(pid)==pid {_=kill(-pid,signal)} else {_=kill(pid,signal)}
                    for _ in 0..<200 {if settled(){return};try await Task.sleep(nanoseconds:10_000_000)}
                    if absent(pid) {break}
                }
            }
            try require(settled())
        }
        func withOwnedController(_ operation:(CommitWindowController)async throws->Void)async throws {
            // Ownership is registered before the first throwing/awaited action.
            try? FileManager.default.removeItem(at:pidFile)
            let controller=CommitWindowController(repository:reader,access:nil,defaults:preferences)
            controller.window?.alphaValue=0;controller.window?.setFrameOrigin(NSPoint(x:-24000,y:-24000))
            do {try await operation(controller)}
            catch {
                let original=error
                do {try await drain(controller)} catch {fputs("Captured-read cleanup failed: \(error)\n",stderr)}
                throw original
            }
            try await drain(controller)
        }
        preferences.set(false,forKey:"Autocompletion");preferences.set(false,forKey:"Spellchecker");preferences.set(false,forKey:"TurtleGit.Commit.GitGuiInterface");preferences.set(true,forKey:"HintStagingMode")
        do {
            for (staging,amend) in [(false,false),(true,false),(false,true)] {
                _=try await repo.run(["config","--local","tgit.commitstagingsupport",staging ? "true":"false"])
                try Data().write(to:log)
                try await withOwnedController {controller in
                    let model=controller.model
                    model.amend=amend;model.amendDiffToLastCommit = !amend;model.message="Captured draft 🧪"
                    model.reload();try await wait{!model.busy && CommitWindowModel.activeReloads==0}
                    let commands=try String(contentsOf:log,encoding:.utf8).split(separator:"\n")
                    try require(model.error==nil && !model.entries.isEmpty && model.stagingEnabled==staging)
                    try require(commands.filter{$0=="diff"}.count==3 && commands.filter{$0=="status"}.count==1 && commands.filter{$0=="ls-files"}.count==1)
                    try require(model.statistics["file"] != nil && model.stagedStatistics["file"] != nil && model.unstagedStatistics["file"] != nil)
                    try require(amend ? model.comparisonBase != nil:model.comparisonBase==nil)
                }
            }
            for closing in [false,true] {
                try Data().write(to:log);try Data().write(to:hold)
                try await withOwnedController {controller in
                    let model=controller.model;model.message="Held captured draft"
                    model.reload();try await wait{FileManager.default.fileExists(atPath:pidFile.path)}
                    let pid=Int32(try String(contentsOf:pidFile,encoding:.utf8).trimmingCharacters(in:.newlines))!
                    let verified=try ownedHeldChild(pid);try require(verified)
                    try require(model.busy && model.entries.isEmpty && kill(pid,0)==0)
                    var cancellationCompleted:Bool?
                    if closing {controller.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:controller.window))}
                    else {model.confirmCancel={$0(true)};model.cancel(completion:{cancellationCompleted=$0})}
                    try await wait{CommitWindowModel.activeReloads==0 && absent(pid) && (closing || cancellationCompleted != nil)}
                    try require(model.entries.isEmpty && model.message=="Held captured draft" && model.error==nil && !model.canCommit)
                    if !closing {try require(cancellationCompleted==true)}
                }
                try? FileManager.default.removeItem(at:hold)
            }
        } catch {
            try? FileManager.default.removeItem(at:hold)
            throw error
        }
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let finalIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index")),finalFile=try Data(contentsOf:folder.appendingPathComponent("file"))
        try require(finalHead==originalHead && finalIndex==originalIndex && finalFile==Data("working\n".utf8))
    }

}
