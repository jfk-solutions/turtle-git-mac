// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func completionMailOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));completionMailOrder(mode,relativeTo:number)}
}
@MainActor
@main enum RebaseCompletionMailVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Rebase completion mail \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase completion mail timeout \(line)")}
    static func drained()->Bool {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && RebaseCompletionMailWindowModel.activeOperations==0 && RebaseCompletionMailWindowController.activeReleases==0 && SendPatchWindowModel.activeLoads==0}
    static func views(_ view:NSView)->[NSView] {
        // Snapshot the public Objective-C collection before walking AppKit's
        // decorated SwiftUI descendants; avoid a lazy live-array bridge.
        let selector = #selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {
            let object=children.object(at:index) as AnyObject
            guard let native=object as? NSObject,native.isKind(of:NSView.self) else {continue}
            result += views(unsafeBitCast(object,to:NSView.self))
        }
        return result
    }
    static var cleanupIssues=[String]()
    static func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    @MainActor final class Context {
        let root:URL,repository:GitRepository,prefs:UserDefaults,suite:String,gate:URL
        var exports=[RebaseCompletionMailWindowController](),workspaces=[RepositoryModel](),replays=[RebaseWindowController]()
        init(_ name:String)throws {
            let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
            root=base.appendingPathComponent(name+" Café",isDirectory:true);gate=root.appendingPathComponent(".git/export-gate",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let wrapper=base.appendingPathComponent("held-helper"),git=CommandLine.arguments[2]
            let script="""
            #!/bin/sh
            is_export() {
              while [ "$#" -gt 0 ]; do
                case "$1" in -c|-C|--git-dir|--work-tree) shift; shift;; --literal-pathspecs|--no-literal-pathspecs|--no-optional-locks) shift;; *) break;; esac
              done
              [ "${1-}" = format-patch ]
            }
            if ! is_export "$@"; then exec \(quote(git)) "$@"; fi
            gate=\(quote(gate.path))
            mkdir -p "$gate";printf '%s\\0' "$@" > "$gate/argv"
            \(quote(git)) "$@"
            result=$?
            : > "$gate/entered"
            if [ -f "$gate/hold" ]; then
              exec 9> "$gate/owned-resource"
              while [ ! -f "$gate/release" ]; do /bin/sleep .02; done
            fi
            if [ -f "$gate/fail" ]; then printf 'private-completion-export-sentinel\\n' >&2;exit 73;fi
            exit "$result"
            """
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            repository=GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.CompletionMail."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for(key,value)in [("UseLibgit2",false),("Gravatar",false),("ConfirmKillProcess",false),("FormatPatchNoPrefix",true),("FormatPatchSendMail",false)] {prefs.set(value,forKey:key)}
            prefs.set(99,forKey:"FormatPatchNum");prefs.set("unrelated-saved-revision",forKey:"FormatPatchSince")
        }
        func seed()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Export QA"),("user.email","export@example.invalid"),("commit.gpgsign","false")] {_=try await repository.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("base.txt"));try await repository.stage(["base.txt"]);_=try await repository.run(["commit","-m","Base"])
            let base=try await repository.rebaseCommit("HEAD")
            _=try await repository.run(["switch","-c","upstream"])
            try Data("upstream\n".utf8).write(to:root.appendingPathComponent("upstream.txt"));try await repository.stage(["upstream.txt"]);_=try await repository.run(["commit","-m","Upstream"])
            _=try await repository.run(["switch","-c","topic",base.hash])
            for path in ["alpha.txt","beta.txt"] {try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path]);_=try await repository.run(["commit","-m",path])}
        }
        func flag(_ value:String)throws {try FileManager.default.createDirectory(at:gate,withIntermediateDirectories:true);try Data().write(to:gate.appendingPathComponent(value))}
        var entered:Bool {FileManager.default.fileExists(atPath:gate.appendingPathComponent("entered").path)}
        func args()throws->[String] {try Data(contentsOf:gate.appendingPathComponent("argv")).split(separator:0).map{String(decoding:$0,as:UTF8.self)}}
        func patches()throws->[URL] {try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension=="patch"}.sorted{$0.lastPathComponent<$1.lastPathComponent}}
        func create(_ preset:FormatPatchPreset?=nil,presentation:((NSWindowController)->Void)?=nil)throws->RebaseCompletionMailWindowController {
            let owner=RebaseCompletionMailWindowController(repository:repository,access:nil,preset:preset ?? FormatPatchPreset(startRevision:"upstream",endRevision:"topic")!,preferences:prefs,presentation:presentation)
            exports.append(owner);owner.window?.isReleasedWhenClosed=false;return owner
        }
        func cleanup()async {
            try? flag("release")
            for workspace in workspaces {workspace.stopMonitoringForTermination()}
            for replay in replays {replay.model.retire();replay.close()}
            for owner in exports {owner.close()}
            do {try await wait{drained() && exports.allSatisfy{!$0.transportBatchWorkPending}}}
            catch {cleanupIssues.append(root.path+": "+String(describing:error));print("COMPLETION MAIL CLEANUP FAILED: "+root.path)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func exportDiagnostic(_ owner:RebaseCompletionMailWindowController?,workspace:RepositoryModel?,phase:String)->String {
        let windows=NSApp.windows.prefix(30).map {window in
            "class=\(String(describing:window.windowController.map{type(of:$0)})) title=\(window.title) visible=\(window.isVisible) number=\(window.windowNumber) parent=\(window.sheetParent?.windowNumber ?? 0) sheet=\(window.attachedSheet?.windowNumber ?? 0)"
        }.joined(separator:" | ")
        guard let owner else{return "phase=\(phase) registry=\(workspace?.rebaseCompletionMailWindows.count ?? -1) workspaceError=\(workspace?.error ?? "nil") windows=[\(windows)]"}
        let model=owner.model
        return "phase=\(phase) busy=\(model.busy) success=\(model.success) cancelled=\(model.cancelled) error=\(model.error ?? "nil") retired=\(model.retired) files=\(model.files.map(\.path)) canPresent=\(owner.canPresent) confirmingQuit=\(owner.confirmingQuit) notice=\(owner.notice?.messageText ?? "nil") active=\(owner.activeOperation) pending=\(owner.transportBatchWorkPending) progressVisible=\(owner.window?.isVisible ?? false) sheet=\(owner.window?.attachedSheet?.title ?? "nil") parent=\(owner.window?.sheetParent?.title ?? "nil") mail=\(owner.mail != nil) options=\(owner.mail?.options != nil) mailProgress=\(owner.mail?.progress != nil) windowControllerExact=\(owner.window?.windowController === owner) registry=\(workspace?.rebaseCompletionMailWindows.count ?? -1) operations=\(RebaseCompletionMailWindowModel.activeOperations) releases=\(RebaseCompletionMailWindowController.activeReleases) output=\(String(model.output.suffix(4000))) windows=[\(windows)]"
    }
    static func accept(_ owner:RebaseCompletionMailWindowController)async throws {
        try await wait{owner.notice != nil && !owner.model.busy}
        guard let notice=owner.notice,let button=notice.buttons.first,let action=button.action else{throw Failure(description:"Native export notice missing")}
        try require(notice.buttons.count==1 && notice.window.sheetParent===owner.window && notice.window.alphaValue==0,"Export notice escaped its owned hidden sheet")
        try require(NSApp.sendAction(action,to:button.target,from:button),"Native export acknowledgement dispatch failed")
    }
    static func handoff()async throws {
        let c=try Context("handoff");do {
            try await c.seed()
            // Use the real workspace factory and completed Rebase callback; the
            // remaining cases isolate export ownership with the same controller.
            let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in c.repository},snapshotWriter:{_ in true})
            c.workspaces.append(workspace);workspace.fileComparisonPreferences=c.prefs;workspace.open(c.root)
            try await wait{!workspace.busy && workspace.root==c.root}
            workspace.activate(.rebase)
            try await wait{NSApp.windows.contains{$0.windowController is RebaseWindowController}}
            guard let replay=NSApp.windows.compactMap({$0.windowController as? RebaseWindowController}).first(where:{$0.model.repository.root.path==c.root.path}) else{throw Failure(description:"Actual workspace Rebase factory absent")}
            c.replays.append(replay);replay.window?.isReleasedWhenClosed=false
            replay.model.editorExecutable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"]!)
            func replayDiagnostic(_ phase:String)->String {
                let model=replay.model
                return "phase=\(phase) workspaceRetired=\(workspace.isRetired) workspaceRoot=\(workspace.root?.path ?? "nil") ownerRoot=\(model.repository.root.path) ownerAttached=\(replay.window?.windowController === replay) retired=\(model.retired) busy=\(model.busy) canStart=\(model.canStart) branch=\(model.options.branch) upstream=\(model.options.upstream) plan=\(String(describing:model.plan?.disposition)) planUpstream=\(model.plan?.options.upstream ?? "nil") active=\(model.active) finished=\(model.finished) completed=\(model.completedSuccessfully) error=\(model.error ?? "nil") confirmation=\(model.confirmation ?? "nil") question=\(model.hasReplayQuestion) sheet=\(replay.window?.attachedSheet?.title ?? "nil") columns=\(RebaseWindowModel.activeColumnReads) prepare=\(RebaseWindowModel.activePreparationReads) replay=\(RebaseWindowModel.activeReplayOperations) stash=\(RebaseWindowModel.activeStashRestorations) output=\(String(model.output.suffix(4000)))"
            }
            replay.model.load(upstream:"upstream")
            do {try await wait{!replay.model.busy && replay.model.plan?.options.upstream=="upstream" && replay.model.canStart && drained()}}
            catch {print("COMPLETION HANDOFF DIAGNOSTIC: "+replayDiagnostic("ready"));throw error}
            replay.model.completionAfterFetch=true;replay.model.request("start")
            if let question=replay.model.pendingConfirmation {replay.model.answerConfirmation(question,proceed:true)}
            do {try await wait{!replay.model.busy && replay.model.completedSuccessfully && drained()}}
            catch {print("COMPLETION HANDOFF DIAGNOSTIC: "+replayDiagnostic("completed"));throw error}
            // Exercise the embedded revision-file mutation callback through
            // its actual revert action, retaining the real local refresh bridge.
            guard let occurrence=replay.model.entries.first(where:{$0.commit.subject=="alpha.txt"}) else{throw Failure(description:"Completed source occurrence absent")}
            replay.model.selection=[occurrence.id];replay.model.selectCommit()
            let list=replay.model.revisionFiles
            try await wait{!list.busy && list.visibleFiles.contains{$0.path=="alpha.txt"} && drained()}
            try require(list.canRevertFiles(["alpha.txt"],base:false),"Actual embedded revision revert unavailable")
            let beforeRevert=try await c.repository.rebaseCommit("HEAD")
            let originalChanged=list.onFilesChanged;var changes=0,notices=0
            list.onFilesChanged={changes += 1;originalChanged()};list.fileActionNotice={_ in notices += 1}
            c.prefs.set(false,forKey:"RevertWithRecycleBin")
            try Data("private dirty alpha\n".utf8).write(to:c.root.appendingPathComponent("alpha.txt"))
            list.revertFiles(["alpha.txt"],base:false)
            try await wait{changes==1 && notices==1 && !list.busy && !replay.model.busy && RevisionComparisonWindowModel.activeFileOperations==0 && drained()}
            let restored=try Data(contentsOf:c.root.appendingPathComponent("alpha.txt")),afterRevert=try await c.repository.rebaseCommit("HEAD")
            try require(list.error==nil && restored==Data("alpha.txt\n".utf8) && afterRevert.hash==beforeRevert.hash,"Revision child revert/refresh changed HEAD or failed to restore actual file")
            try await wait{replay.model.completedSuccessfully && !replay.model.busy && replay.model.canPerformCompletionAction(.mail) && drained()}
            let from=replay.model.options.upstream,to=replay.model.options.branch
            // Baseline the index after the deliberate native child mutation.
            let head=try await c.repository.rebaseCommit("HEAD"),index=try await c.repository.run(["ls-files","--stage","-z"]).stdout
            try c.flag("hold");replay.model.performCompletionAction(.mail)
            do {try await wait{c.entered && NSApp.windows.contains{$0.windowController is RebaseCompletionMailWindowController}}}
            catch {print("COMPLETION EXPORT DIAGNOSTIC: "+exportDiagnostic(nil,workspace:workspace,phase:"export admission"));throw error}
            guard let owner=NSApp.windows.compactMap({$0.windowController as? RebaseCompletionMailWindowController}).first(where:{$0.model.repository.root.path==c.root.path}) else{throw Failure(description:"Completion did not enter dedicated export workflow")}
            c.exports.append(owner)
            try require(owner.model.busy && owner.mail==nil && replay.model.retired,"Composer appeared before export/Rebase owner drained")
            try require(!NSApp.windows.contains{$0.windowController is FormatPatchWindowController && $0.isVisible},"Completion unexpectedly opened editable Format Patch")
            let argv=try c.args();try require(argv.contains(from+".."+to) && !argv.contains("--no-prefix") && !argv.contains("-99") && !argv.contains("unrelated-saved-revision"),"Completion ignored captured exact range or leaked saved Format Patch options")
            try c.flag("release")
            do {try await wait{owner.mail?.options != nil && !owner.model.busy && RebaseCompletionMailWindowModel.activeOperations==0}}
            catch {print("COMPLETION EXPORT DIAGNOSTIC: "+exportDiagnostic(owner,workspace:workspace,phase:"composer after export"));throw error}
            guard let options=owner.mail?.options else{throw Failure(description:"Real Send Mail composer absent")}
            do {try await wait{options.model.pendingLoads==0}}
            catch {print("COMPLETION EXPORT DIAGNOSTIC: "+exportDiagnostic(owner,workspace:workspace,phase:"composer metadata drain"));throw error}
            let files=try c.patches()
            try require(owner.model.success && files.count==2 && options.model.rows.map(\.file)==owner.model.files && options.model.rows.count==2,"Composer did not receive all exact verified exported files")
            for file in files {let bytes=try String(contentsOf:file,encoding:.utf8);try require(bytes.contains("diff --git a/") && bytes.contains(" b/"),"Saved NoPrefix unexpectedly changed source export")}
            let after=try await c.repository.rebaseCommit("HEAD"),afterIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout
            try require(after.hash==head.hash && afterIndex==index,"Completion mail export changed HEAD/index")
            try require(c.prefs.bool(forKey:"FormatPatchNoPrefix") && !c.prefs.bool(forKey:"FormatPatchSendMail"),"Completion export rewrote saved dialog options")
            var closed=0;let originalClosed=owner.onClosed
            owner.onClosed={closed += 1;originalClosed()}
            owner.close()
            do {try await wait{closed==1 && !owner.transportBatchWorkPending && options.model.isRetired && SendPatchWindowModel.activeLoads==0}}
            catch {print("COMPLETION EXPORT DIAGNOSTIC: "+exportDiagnostic(owner,workspace:workspace,phase:"public close"));throw error}
            try require(owner.model.retired && owner.mail==nil && options.window?.isVisible != true && closed==1,"Public close after composer did not release exact child/owner once")
            await c.cleanup();try require(drained() && c.exports.allSatisfy{!$0.transportBatchWorkPending},"Handoff cleanup left active export/composer work")
        }catch{await c.cleanup();throw error}
    }
    static func outcomes()async throws {
        for route in ["empty","failure","cancel"] {
            let c=try Context(route);do {
                try await c.seed();let head=try await c.repository.rebaseCommit("HEAD"),index=try await c.repository.run(["ls-files","--stage","-z"]).stdout
                if route != "empty" {try c.flag("hold")};if route=="failure" {try c.flag("fail")}
                let preset=route=="empty" ? FormatPatchPreset(startRevision:"topic",endRevision:"topic"):nil
                let owner=try c.create(preset);var closed=0;owner.onClosed={closed += 1};owner.start()
                if route != "empty" {try await wait{c.entered && owner.model.busy};if route=="cancel" {owner.model.cancel()}else{try c.flag("release")}}
                try await wait{owner.notice != nil && !owner.model.busy && RebaseCompletionMailWindowModel.activeOperations==0}
                try require(owner.mail==nil,"Unsuccessful/empty export opened a composer")
                if route=="empty" {try require(owner.model.empty && owner.notice?.alertStyle == .informational && owner.notice?.messageText=="No patches were created to attach.","Empty source result lost informational notice")}
                else {
                    let files=try c.patches();try require(!owner.model.success && files.count==2,"Failure/cancel lost already-created patch files")
                    if route=="failure" {try require(owner.notice?.alertStyle == .critical && owner.model.output.contains("private-completion-export-sentinel"),"Actual failure diagnostic missing")}
                    else {try require(owner.model.cancelled && owner.notice?.alertStyle == .informational,"Cancelled export lost cancellation state")}
                }
                try await accept(owner);try await wait{closed==1 && !owner.transportBatchWorkPending}
                let after=try await c.repository.rebaseCommit("HEAD"),afterIndex=try await c.repository.run(["ls-files","--stage","-z"]).stdout
                try require(after.hash==head.hash && afterIndex==index && closed==1,"Notice acknowledgement changed repository or closed twice")
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    static func ownership()async throws {
        for route in ["retire","quit"] {
            let c=try Context(route);do {
                try await c.seed();try c.flag("hold")
                var presented=[NSWindowController](),closed=0
                let owner=try c.create(presentation:{presented.append($0);$0.showWindow(nil)});owner.onClosed={closed += 1};owner.start()
                try await wait{c.entered && owner.model.busy}
                if route=="retire" {
                    owner.close();try c.flag("release");try await wait{closed==1 && RebaseCompletionMailWindowModel.activeOperations==0}
                    let replacement=try c.create(presentation:{presented.append($0);$0.showWindow(nil)});replacement.start()
                    try await wait{replacement.mail?.options != nil && !replacement.model.busy}
                    try require(owner.mail==nil && owner.model.retired && presented.count==1 && replacement.canPresent,"Late old export published composer or retired replacement")
                }else {
                    owner.confirmingQuit=true;try c.flag("release")
                    try await wait{!owner.model.busy && RebaseCompletionMailWindowModel.activeOperations==0}
                    try require(owner.model.success && owner.mail==nil && presented.isEmpty,"Quit confirmation allowed composer handoff")
                    owner.confirmingQuit=false;try await wait{owner.mail?.options != nil}
                    try require(presented.count==1 && !owner.model.retired,"Dismissed Quit did not resume exact owned composer once")
                }
                await c.cleanup();try require(closed==1,"Export owner did not close once after all children drained")
            }catch{await c.cleanup();throw error}
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.completionMailOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,replacement);defer{method_exchangeImplementations(original,replacement)}
        let mode=CommandLine.arguments[3]
        switch mode {case "handoff":try await handoff();case "outcomes":try await outcomes();case "ownership":try await ownership();default:throw Failure(description:"Unknown completion mail case")}
        try require(cleanupIssues.isEmpty && drained(),"Owned completion cleanup failed: "+cleanupIssues.joined(separator:"; "))
        print("PASS: Rebase completion mail "+mode)
    }
}
