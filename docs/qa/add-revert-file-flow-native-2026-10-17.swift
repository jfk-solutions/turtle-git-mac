// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
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
    @MainActor static func main() async {NSApp.setActivationPolicy(.prohibited);do {try await verify();print("PASS Add/Revert file flow: source checked-path order, one-shot accept, owned Save/Export/Open/editor, chooser release/cancel/retirement, late reply rejection and retained Quit lifetime")}
        catch {fputs("Add/Revert file flow failed: \(error)\n",stderr);exit(1)}}
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
}
