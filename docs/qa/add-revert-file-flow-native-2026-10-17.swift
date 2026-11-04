// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC

private extension NSWindow {
    @objc func directRevertOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-28000,y:-28000));directRevertOrder(mode,relativeTo:number)
    }
    @objc func directRevertConstrain(_ frame:NSRect,to screen:NSScreen?)->NSRect {frame}
}
import TurtleGitCore

@main struct AddRevertFileFlowVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else {return []};return [root]+root.subviews.flatMap {views($0)}}
    @MainActor static func wait(_ owner:NSWindow? = nil,line:Int = #line,_ ready:()->Bool) async throws {
        var settled = 0
        for _ in 0..<2400 {try await Task.sleep(nanoseconds:10_000_000);owner?.contentView?.layoutSubtreeIfNeeded();settled = ready() ? settled+1:0;if settled == 2 {return}}
        throw Failure(description:"Add/Revert file flow wait at \(line)")
    }
    @MainActor static var ownedReadersDrained:Bool {
        CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeReloads==0 &&
        CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeFileDrops==0 &&
        CommitWindowModel.activeIssueProviderOperations==0 && CommitWindowModel.activeCommitPreflights==0 &&
        CommitWindowModel.activePreferenceOperations==0 && StatusWindowModel.activeOperations==0 &&
        AddWindowModel.activeOperations==0 && RevertWindowModel.activeOperations==0 &&
        LogWindowModel.activeWorkingCommandReads==0 && LogWindowModel.activeHistoryLoads==0 &&
        LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeActionReads==0 &&
        LogWindowModel.activeReferenceReads==0 && LogWindowModel.activeFileOpenReads==0 &&
        LogWindowModel.activeNoteReads==0 && LogWindowModel.activeNoteSaves==0 &&
        LogWindowModel.activeWorkingLFSReads==0 && RevertProgressWindowModel.activeOperations==0 &&
        RevertProgressWindowController.activeReleases==0
    }
    @MainActor static func closeAndDrainOwnedWindows() async -> Bool {
        for window in NSApp.windows {
            if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)}
            window.close()
        }
        for _ in 0..<3000 {
            if ownedReadersDrained && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {return true}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        return false
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directRevertOrder(_:relativeTo:)))!)
        method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directRevertConstrain(_:to:)))!)
        defer {
            method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directRevertOrder(_:relativeTo:)))!)
            method_exchangeImplementations(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:)))!,class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directRevertConstrain(_:to:)))!)
        }
        let mode=CommandLine.arguments.count>3 ? CommandLine.arguments[3]:"flow"
        do {
            if mode=="direct-revert" {try await verifyDirectRevert()}
            else if mode=="commit-commands" {try await CommitCommandMenuVerification.verify()}
            else {try await verify()}
            let drained=await closeAndDrainOwnedWindows()
            try require(drained,"Grouped Add/Revert readers, releases or native windows did not drain")
        } catch {
            let drained=await closeAndDrainOwnedWindows()
            if !drained {throw Failure(description:"\(error); grouped Add/Revert cleanup did not drain")}
            throw error
        }
        if mode=="direct-revert" {print("PASS direct Revert selection family")}
        else if mode=="commit-commands" {print("PASS grouped Commit command controls")}
        else {print("PASS Add/Revert file flow: source checked-path order, one-shot accept, owned Save/Export/Open/editor, chooser release/cancel/retirement, late reply rejection and retained Quit lifetime")}
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","File Flow QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let paths = ["z.txt","file2.txt","A.txt","file10.txt"],expected = ["A.txt","file10.txt","file2.txt","z.txt"]
        for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_ = try await repo.commit(message:"base")
        for path in paths {try Data((path+" changed\n").utf8).write(to:root.appendingPathComponent(path))}
        let head = try await repo.run(["rev-parse","HEAD"]).stdout,stage = try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite = "TurtleGit.FileFlow."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        @MainActor func add() async throws -> AddWindowController {
            let owner = AddWindowController(repository:repo,access:nil,defaults:prefs)
            owner.window!.alphaValue = 0;owner.window!.orderFront(nil);owner.model.setScope(paths);owner.model.reload()
            try await wait(owner.window) {!owner.model.busy && owner.model.entries.count == paths.count}
            return owner
        }
        // TortoiseGit collects checked rows then sorts pathnames, irrespective of a visual sort.
        do {
            let owner = try await add();defer {owner.close()};let model = owner.model
            let table = views(owner.window?.contentView).compactMap {$0 as? NSTableView}.first!
            table.sortDescriptors = [NSSortDescriptor(key:"path",ascending:false)]
            model.checked = GitPathSet(paths);var accepted:[[String]] = [],closed = 0
            model.onAccepted = {accepted.append($0)};model.close = {closed += 1}
            model.apply();model.apply()
            try require(accepted == [expected] && closed == 1 && !model.canApply,"Add accept lost source path order or dispatched twice")
        }
        do {
            let owner = RevertWindowController(repository:repo,access:nil,preferences:prefs);defer {owner.close()}
            owner.window!.alphaValue = 0;owner.window!.orderFront(nil);let model = owner.model;model.setScope(["."])
            try await wait(owner.window) {!model.busy && model.entries.count == paths.count}
            model.sortOrder = [StatusFileSort(column:.path,order:.reverse)];model.checked = GitPathSet(paths)
            var accepted:[[String]] = [],closed = 0;model.onAccepted = {accepted.append($0.map(\.path))};model.close = {closed += 1}
            model.apply();model.apply()
            try require(accepted == [expected] && closed == 1 && !model.canApply,"Revert accept followed visual sort or dispatched twice")
        }
        // The captured source survives selection changes while a chooser/launch owns the dialog.
        do {
            let owner = try await add();defer {owner.close()};let model = owner.model
            var choice:CheckedContinuation<URL?,Never>?,launch:CheckedContinuation<Void,Error>?,opened:[String] = [],application:URL?
            model.chooseApplication = {await withCheckedContinuation {choice = $0}}
            model.openWorkingFile = {file,app in opened.append(file.lastPathComponent);application = app;try await withCheckedThrowingContinuation {launch = $0}}
            let task = model.requestOpen(paths[0],action:.openWith)!
            try await wait {choice != nil}
            try require(model.busy && AddWindowModel.activeOperations == 1 && !model.canApply && model.requestOpen(paths[1],action:.open) == nil,"Chooser lost ownership or allowed duplicate work")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Chooser failed to block Quit")
            model.highlighted = [paths[1]];let app = root.appendingPathComponent("Fixture.app")
            choice?.resume(returning:app);choice = nil;try await wait {launch != nil}
            try require(opened == [paths[0]] && application == app,"Open With retargeted selection or lost chosen application")
            owner.close();try require(model.retired && AddWindowModel.activeOperations == 1,"Forced close released launch before completion")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired launch lost Quit lease")
            launch?.resume(throwing:Failure(description:"late launch error"));launch = nil;await task.value
            try require(AddWindowModel.activeOperations == 0 && model.error == nil,"Retired launch published error or leaked ownership")
        }
        // Cancellation before a late chooser approval prevents any launch, while keeping its lease until reply.
        do {
            let owner = try await add();defer {owner.close()};let model = owner.model
            var choice:CheckedContinuation<URL?,Never>?,opened = 0
            model.chooseApplication = {await withCheckedContinuation {choice = $0}};model.openWorkingFile = {_,_ in opened += 1}
            let task = model.requestOpen(paths[0],action:.openWith)!
            try await wait {choice != nil};model.cancel()
            try require(AddWindowModel.activeOperations == 1,"Cancelled chooser released counter before its reply")
            choice?.resume(returning:root.appendingPathComponent("late.app"));choice = nil;await task.value
            try require(opened == 0 && model.error == nil && AddWindowModel.activeOperations == 0,"Late chooser approval launched or published after cancellation")
        }
        // Both real copy routes include selection of their destination in the owned operation.
        do {
            let owner = try await add();defer {owner.close()};let model = owner.model
            let target = root.appendingPathComponent("saved.bin"),folder = root.appendingPathComponent("exported")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            var selected = "";model.chooseSaveFile = {path in selected = path;return target}
            await model.requestSave(paths[0])?.value
            try require(selected == paths[0] && (try Data(contentsOf:target)) == Data((paths[0]+" changed\n").utf8),"Owned Save As copied wrong file")
            model.chooseExportFolder = {folder};await model.requestExport([paths[2],paths[1]])?.value
            for path in [paths[2],paths[1]] {try require(try Data(contentsOf:folder.appendingPathComponent(path)) == Data((path+" changed\n").utf8),"Owned Export lost captured source")}
            var editors:[String] = [];model.openAlternativeEditor = {editors.append($0.lastPathComponent)}
            await model.requestOpen(paths[3],action:.editor)?.value
            try require(editors == [paths[3]] && !model.busy && AddWindowModel.activeOperations == 0,"Alternative editor did not drain its owner")
            try FileManager.default.removeItem(at:target);try FileManager.default.removeItem(at:folder)
        }
        // Exercise actual native sheets, their cancellation release, reuse, forced closure and late duplicate callbacks.
        do {
            let owner = try await add();defer {owner.close()};let model = owner.model
            let task = model.requestSave(paths[0])!
            try await wait(owner.window) {owner.filePanels.currentPanel?.sheetParent === owner.window}
            let first = owner.filePanels.currentPanel!
            try require(model.busy && !owner.windowShouldClose(owner.window!) && AddWindowModel.activeOperations == 1,"Real Save panel lacked owned busy/close gate")
            owner.filePanels.receive(first,response:.cancel);owner.filePanels.receive(first,response:.OK)
            await task.value;try await wait(owner.window) {!model.busy && owner.window?.attachedSheet == nil && owner.filePanels.currentPanel == nil}
            try require(model.information.isEmpty && model.error == nil,"Duplicate cancelled native panel result published")
            let next = model.requestExport([paths[0]])!
            try await wait(owner.window) {owner.filePanels.currentPanel?.sheetParent === owner.window}
            let last = owner.filePanels.currentPanel!;owner.close();owner.filePanels.receive(last,response:.OK);await next.value
            try require(model.retired && AddWindowModel.activeOperations == 0 && model.information.isEmpty && model.error == nil,"Forced native chooser reply escaped retirement")
        }
        do {
            let owner = RevertWindowController(repository:repo,access:nil,preferences:prefs);defer {owner.close()}
            owner.window!.alphaValue = 0;owner.window!.orderFront(nil);let model = owner.model;model.setScope(["."])
            try await wait(owner.window) {!model.busy && model.entries.count == paths.count}
            model.highlighted = [paths[0]];var opened = 0;model.commands.openWorkingFile = {_,_ in opened += 1}
            model.commands.fileAction(.openWith,snapshot:model.commands.fileMenu([paths[0]],mark:paths[0]))
            try await wait(owner.window) {owner.filePanels.currentPanel?.sheetParent === owner.window}
            let panel = owner.filePanels.currentPanel!
            try require(StatusWindowModel.activeOperations == 1 && !owner.windowShouldClose(owner.window!),"Revert chooser lost shared owner lease")
            owner.close();owner.filePanels.receive(panel,response:.OK)
            try await wait {StatusWindowModel.activeOperations == 0}
            try require(model.retired && opened == 0 && model.commands.error == nil,"Late retired Revert chooser launched or published")
        }
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout,finalStage = try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(head == finalHead && stage == finalStage,"File flow changed HEAD or staged contents")
        for path in paths {try require(try Data(contentsOf:root.appendingPathComponent(path)) == Data((path+" changed\n").utf8),"File flow changed source bytes")}
    }
    @MainActor final class DirectContext {
        let folder:URL,git:URL,kind:String,prefs:UserDefaults,suite:String
        var repository:GitRepository!,router:RepositoryModel!,source:NSWindowController?
        var commit:CommitWindowController?,status:StatusWindowController?,add:AddWindowController?,log:LogWindowController?
        var pendingReply:((NSApplication.ModalResponse)->Void)?,questions=0
        var progresses:[RevertProgressWindowController]=[],payloads:[[StatusEntry]]=[],executionPayloads:[[StatusEntry]]=[]
        var heldExecution:CheckedContinuation<Void,Never>?,holdExecution=false
        var head=Data(),index=Data()
        init(base:URL,git:URL,kind:String) {
            self.git=git;self.kind=kind;folder=base.appendingPathComponent(kind)
            suite="TurtleGit.DirectRevert."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["EnableGravatar","Gravatar","UseLibgit2","Autocompletion","ConfirmKillProcess","RevertWithRecycleBin"] {prefs.set(false,forKey:key)}
            for key in ["HintStagingMode","AddBeforeCommit","LogIncludeWorkingTreeChanges","Commit.SkipCancelConfirmation"] {prefs.set(true,forKey:key)}
            prefs.set(0,forKey:"AutoCloseGitProgress")
        }
        func prepare() async throws {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repository=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repository.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Direct Revert QA"),("user.email","revert@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            try Data("base\n".utf8).write(to:folder.appendingPathComponent("modified.txt"));try await repository.stage(["modified.txt"]);_=try await repository.commit(message:"private direct base")
            try Data("private working draft\n".utf8).write(to:folder.appendingPathComponent("modified.txt"));try Data("private unknown\n".utf8).write(to:folder.appendingPathComponent("unknown.txt"))
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            let engine=git
            router=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:engine,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false})
            router.fileComparisonPreferences=prefs;router.notifyFinder={}
            router.presentRevertQuestion={ [self] _,alert,reply in capture(alert,reply:reply);return true}
            router.makeDirectRevertProgress={ [self] repository,access,rows,amend,againstHead,preferences,policy in
                payloads.append(rows)
                let child=RevertProgressWindowController(repository:repository,access:access,entries:rows,amend:amend,againstHead:againstHead,autoCloseSuccess:false,preferences:preferences,policy:policy)
                child.model.execute={ [self] rows,token,notify,output in
                    executionPayloads.append(rows)
                    if holdExecution {await withCheckedContinuation{heldExecution=$0}}
                    return try await repository.revertWorkingFiles(rows,amend:amend,amendDiffToLastCommit:againstHead,policy:policy,cancellation:token,progress:notify,onOutput:output)
                }
                progresses.append(child);return child
            }
            router.open(folder);try await AddRevertFileFlowVerification.wait {!router.busy && router.root?.path==folder.path}
            let action:RepositoryAction=kind=="commit" ? .commit:kind=="add" ? .add:kind=="status" ? .status:.log
            // Explicit file-only Add intentionally stages directly. Including
            // the folder takes the actual reviewed-dialog route; the two file
            // scopes retain the modified row as well as the unversioned row.
            router.activate(action,paths:kind=="add" ? [".","modified.txt","unknown.txt"]:[])
            try await AddRevertFileFlowVerification.wait {
                let controllers=NSApp.windows.compactMap{$0.delegate as? NSWindowController}
                switch kind {
                case "commit":commit=controllers.compactMap{$0 as? CommitWindowController}.first{$0.model.repository.root.path==folder.path};source=commit;return commit?.model.fileListAvailable==true && commit?.model.hasHead==true
                case "status":status=controllers.compactMap{$0 as? StatusWindowController}.first{$0.model.repository.root.path==folder.path};source=status;return status?.model.busy==false && status?.model.hasStatusSnapshot==true
                case "add":add=controllers.compactMap{$0 as? AddWindowController}.first{$0.model.repository.root.path==folder.path};source=add;return add?.model.busy==false && add?.model.entries.count==2
                default:log=controllers.compactMap{$0 as? LogWindowController}.first{$0.model.repository.root.path==folder.path};source=log;return log?.model.busy==false && log?.model.entries.contains{$0.hash.isEmpty}==true
                }
            }
            if let add {add.presentRevertQuestion={ [self] _,alert,reply in capture(alert,reply:reply);return true}}
            if let log {
                log.model.select([""]);try await AddRevertFileFlowVerification.wait {!log.model.busy && log.model.selectedWorkingTree && log.model.visibleFiles.contains{$0.path=="unknown.txt"}}
            }
        }
        func capture(_ alert:NSAlert,reply:@escaping(NSApplication.ModalResponse)->Void) {
            precondition(alert.buttons.map(\.title)==["Yes","No"] && alert.buttons[0].keyEquivalent=="\r" && alert.window.defaultButtonCell === (alert.buttons[0].cell as? NSButtonCell),"Source Revert confirmation default is not Yes")
            precondition(pendingReply==nil,"Duplicate direct Revert question")
            questions += 1;pendingReply=reply
        }
        var busy:Bool {commit?.model.busy ?? status?.model.busy ?? add?.model.busy ?? log?.model.busy ?? false}
        func request(_ paths:[String]) {
            if let commit {
                let snapshot=commit.model.fileMenu(paths,mark:"modified.txt")
                commit.model.withFileMenu(snapshot){commit.model.revertFiles(snapshot.entries)}
            } else if let status {status.model.requestRevert(status.model.fileMenu(paths,mark:"modified.txt"))}
            else if let add {
                add.model.highlighted=GitPathSet(paths);add.model.selectionMark="modified.txt"
                add.model.onRevertRequest(add.model.entries.filter{GitPathSet(paths).contains($0.path)})
            } else if let log {
                log.model.selectedFiles=paths.count>1 ? ["unknown.txt"]:[];log.model.selectedFiles=GitPathSet(paths)
                let snapshot=log.model.fileMenuSnapshot(GitPathSet(paths))
                log.model.withFileMenu(snapshot){log.model.requestWorkingFiles(.revert,ids:paths)}
            }
        }
        func cancel() {if let commit {_=commit.model.cancelFileOperation()} else if let status {_=status.model.cancelOperation()} else if let add {add.model.cancel()} else if let log {_=log.model.cancelWorkingCommandRead()}}
        func answer(_ response:NSApplication.ModalResponse,duplicate:Bool=false) throws {
            guard let reply=pendingReply else{throw Failure(description:"Missing \(kind) Revert reply")};pendingReply=nil
            reply(response);if duplicate {reply(response == .alertFirstButtonReturn ? .alertSecondButtonReturn:.alertFirstButtonReturn)}
        }
        func preserved() async throws {
            let currentHead=try await repository.run(["rev-parse","HEAD"]).stdout,currentIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            try AddRevertFileFlowVerification.require(currentHead==head && currentIndex==index,"Direct Revert failure/cancellation changed HEAD/index")
            try AddRevertFileFlowVerification.require(try Data(contentsOf:folder.appendingPathComponent("modified.txt"))==Data("private working draft\n".utf8),"Unknown-path failure partially reverted its versioned cohort")
        }
        func clean() async -> Bool {
            router?.stopMonitoringForTermination();source?.close();for child in progresses {child.close()}
            // Admission may have created a controller before prepare() found
            // its delegate. This receiver owns every native window here.
            for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
            pendingReply?(.abort);pendingReply=nil;heldExecution?.resume();heldExecution=nil
            await router?.shutdownFinderPublication()
            var drained=false
            for _ in 0..<3000 {
                if AddRevertFileFlowVerification.ownedReadersDrained && router?.hasPendingRepositoryWork != true && NSApp.windows.allSatisfy({!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}) {drained=true;break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            if drained {prefs.removePersistentDomain(forName:suite)}
            return drained
        }
    }
    @MainActor static func verifyDirectRevert() async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let confirmationCases:[(Character,Character,Bool)]=[("M"," ",true),(" ","T",true),("U","U",false),("R"," ",false),("C"," ",false),(" "," ",false)]
        for pair in confirmationCases {
            let record=String([pair.0,pair.1])+" literal.txt\0"+((pair.0=="R" || pair.0=="C") ? "original.txt\0":"")
            guard let row=StatusEntry.parse(Data(record.utf8)).first else {throw Failure(description:"Confirmation status fixture did not parse")}
            try require(WorkingFileRevertPresentation.needsConfirmation([row],directories:[])==pair.2,"Aggregated status changed the source M/T confirmation rule")
            try require(!WorkingFileRevertPresentation.needsConfirmation([row],directories:[row.path]),"Directory/gitlink requested a destructive file warning")
        }
        for kind in ["commit","add","status","log"] {
            let c=DirectContext(base:base,git:git,kind:kind)
            do {
                try await c.prepare();let mixed=["modified.txt","unknown.txt"]
                c.request(mixed);try await wait {c.pendingReply != nil};try require(c.busy && c.payloads.isEmpty,"Source did not retain its confirmation owner")
                try c.answer(.alertSecondButtonReturn,duplicate:true);try await wait {!c.busy};try require(c.payloads.isEmpty,"No/duplicate confirmation started progress")
                c.request(mixed);try await wait {c.pendingReply != nil}
                try c.answer(.alertFirstButtonReturn);c.cancel()
                try await wait {!c.busy};try require(c.payloads.isEmpty,"Cancel during accepted-question drainage admitted mutation")
                c.request(mixed);try await wait {c.pendingReply != nil};try c.answer(.alertFirstButtonReturn,duplicate:true)
                try await wait {c.progresses.last?.model.busy==false && c.progresses.last?.model.failed==true}
                guard let failed=c.progresses.last else{throw Failure(description:"Direct selection did not produce progress")}
                try require(c.payloads.count==1 && GitPathSet(c.payloads[0].map(\.path))==GitPathSet(mixed) && c.busy && c.router.hasPendingRepositoryWork,"Mixed selection was narrowed, replanned or released before result review")
                try require(!NSApp.windows.contains{$0.delegate is RevertWindowController},"Status-list Revert opened an extra planning dialog")
                try require(failed.model.submodulePaths.isEmpty && failed.model.trashedFiles.isEmpty,"Mixed no-Trash failure offered successful post-actions")
                try await c.preserved()
                c.prefs.set(true,forKey:"RevertWithRecycleBin");failed.model.retry();try await wait {!failed.model.busy}
                try require(failed.model.failed && !failed.model.policy.recycle && c.executionPayloads.count==2 && c.executionPayloads.allSatisfy{GitPathSet($0.map(\.path))==GitPathSet(mixed)} && c.busy,"Retry changed disposal policy, narrowed names or reported success")
                try await c.preserved();failed.model.close();try await wait {!c.busy && !c.router.hasPendingRepositoryWork};c.prefs.set(false,forKey:"RevertWithRecycleBin")
                c.holdExecution=true;c.request(["modified.txt"]);try await wait {c.pendingReply != nil};try c.answer(.alertFirstButtonReturn)
                try await wait {c.heldExecution != nil};c.source?.close()
                try await wait {c.progresses.last?.model.retired==true}
                try require(c.router.hasPendingRepositoryWork && RevertProgressWindowModel.activeOperations>0,"Closed source dropped a still-running Revert worker")
                c.heldExecution?.resume();c.heldExecution=nil
                try await wait {!c.router.hasPendingRepositoryWork && RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0}
                try await c.preserved();let cleaned=await c.clean();try require(cleaned,"Direct Revert readers/releases did not drain")
                try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Direct Revert owned windows remained open")
                print("Direct Revert \(kind): Yes default, No/duplicate/accepted-drain cancellation, complete mixed error/Retry, captured policy, actual progress-close ownership and forced-close worker drainage passed")
            } catch {if !(await c.clean()) {fputs("Direct Revert cleanup did not drain; private evidence retained\n",stderr)};throw error}
        }
    }

}
