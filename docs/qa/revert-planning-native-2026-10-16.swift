import AppKit
import TurtleGitCore

@main struct RevertPlanningVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Revert planning timeout at line \(line)")
    }
    @MainActor static func main() async {do {try await verify()} catch {fputs("Revert planning failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let paths = ["one 雪.txt","two.txt","clean.txt","old.txt"]
        for path in paths {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_ = try await repo.commit(message:"base")
        for path in paths.prefix(2) {try Data("changed\n".utf8).write(to:root.appendingPathComponent(path))}
        _ = try await repo.run(["mv","old.txt","renamed.txt"])
        try Data("added\n".utf8).write(to:root.appendingPathComponent("added.txt"));try await repo.stage(["added.txt"])
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("unknown.txt"))
        let suite = "TurtleGit.RevertPlanning." + UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        defer {prefs.removePersistentDomain(forName:suite)}
        let controller = RevertWindowController(repository:repo,access:nil,preferences:prefs),model = controller.model
        controller.window?.alphaValue = 0
        let clipboard = NSPasteboard.withUniqueName();model.commands.clipboard = clipboard
        defer {controller.close();clipboard.releaseGlobally()}
        model.setScope(["."]);try await wait {!model.busy && RevertWindowModel.activeOperations == 0}
        try require(model.error == nil && Set(model.entries.map(\.path)) == [paths[0],paths[1],"renamed.txt","added.txt"],"Root scope included clean/unversioned or lost changed rows")
        try require(model.checked == ["added.txt"] && model.hasUnversionedItems,"Initial source checks or unversioned note lost")
        model.setChecked([paths[0]],value:true);model.highlighted = [paths[1]];model.reload()
        try await wait {!model.busy};try require(model.checked == [paths[0],"added.txt"] && model.highlighted == [paths[1]],"Refresh lost checks/highlight")
        let frozen = model.entries,index = try Data(contentsOf:root.appendingPathComponent(".git/index")),head = try await repo.run(["rev-parse","HEAD"]).stdout
        // A superseded status read cannot publish a partial or late table.
        let ordinaryRead = model.readStatus;var held:CheckedContinuation<[WorkingTreeFile],Error>?,heldToken:OperationCancellation?
        model.readStatus = {token in heldToken = token;return try await withCheckedThrowingContinuation {held = $0}}
        model.reload();try await wait {held != nil};try require(model.entries == frozen && !model.canApply,"Read replaced prior snapshot before completion")
        model.readStatus = ordinaryRead;model.reload();try await wait {!model.busy}
        try require(heldToken?.isCancelled == true,"Superseded worker was not cancelled")
        held?.resume(returning:[]);held = nil;try await wait {RevertWindowModel.activeOperations == 0}
        try require(model.entries == frozen,"Late snapshot replaced current rows")
        // A related-dialog refresh queued behind a failed read must still drain and reload.
        var reads = 0
        model.readStatus = {token in reads += 1;if reads == 1 {return try await withCheckedThrowingContinuation {held = $0}};return try await ordinaryRead(token)}
        model.reload();try await wait {held != nil};model.requestReload()
        held?.resume(throwing:Failure(description:"Injected read failure"));held = nil
        try await wait {reads == 2 && !model.busy};try require(model.entries == frozen && model.error == nil,"Queued refresh was lost after failed read")
        model.readStatus = ordinaryRead
        // Direct normal files appear and start checked; bursts union exact same-repository paths.
        model.setScope(["clean.txt"]);try await wait {!model.busy};try require(model.entries.map(\.path) == ["clean.txt"] && model.checked == ["clean.txt"],"Direct clean file missing")
        model.setScope([paths[0]]);try await wait {!model.busy}
        try require(model.addDropped([root.appendingPathComponent(paths[1])]) && model.addDropped([root.appendingPathComponent("added.txt")]),"Same-root drop rejected")
        try await wait {!model.busy && RevertWindowModel.activeOperations == 0}
        try require(Set(model.entries.map(\.path)) == [paths[0],paths[1],"added.txt"] && model.checked == [paths[0],paths[1],"added.txt"],"Burst drop lost scope/checks")
        let nested = root.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        _ = try await GitRepository(root:nested,executable:repo.executable).run(["init","-b","main"])
        let nestedFile = nested.appendingPathComponent("foreign.txt");try Data().write(to:nestedFile)
        let beforeDrop = model.entries;try require(model.addDropped([nestedFile]),"Contained drop not queued for repository validation")
        try await wait {!model.busy};try require(model.error != nil && model.entries == beforeDrop,"Nested repository changed original scope");model.error = nil;try await wait {model.canInteract}
        // Shared menu backend retains literal paths, private clipboard and source old-name targets.
        model.setScope(["."]);try await wait {!model.busy}
        var logs:[String] = [],blames:[String] = [],comparisons:[[String]] = []
        model.onFileLog = {logs.append($0)};model.commands.onBlame = {blames.append($0)};model.onCompare = {comparisons.append($0)}
        model.commands.fileAction(.oldNameLog,snapshot:model.commands.fileMenu(["renamed.txt"]))
        model.commands.fileAction(.blame,snapshot:model.commands.fileMenu([paths[0]]));model.diff([paths[0]])
        model.commands.copy([paths[0]],information:.relativePaths)
        try require(logs == ["old.txt"] && blames == [paths[0]] && comparisons == [[paths[0]]] && clipboard.string(forType:.string) == paths[0] + "\n","Revert file handoff or clipboard lost path: logs=\(logs), blame=\(blames), compare=\(comparisons), clipboard=\(String(describing:clipboard.string(forType:.string)))")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Read-only planning changed index")
        let stale = model.commands.fileMenu([paths[0]]);model.reload();try await wait {!model.busy};model.commands.fileAction(.blame,snapshot:stale)
        try require(blames.count == 1,"Refresh revived stale file menu")
        // Optional native columns persist independently of Working Tree; reset No and Yes share owner lifetime.
        model.setColumn(.fileName,visible:true);_ = model.saveColumns(order:[.status,.path,.fileName],widths:[.path:410])
        let reopen = RevertWindowModel(repository:repo,access:nil,preferences:prefs)
        try require(reopen.fileColumns == model.fileColumns && prefs.object(forKey:"WorkingTree.FileColumns.Version") == nil,"Column preferences crossed owners");reopen.invalidate()
        let columns = model.fileColumns;var resetReply:CheckedContinuation<Bool,Never>?,accepted = 0
        model.resetColumns(choose:{await withCheckedContinuation {resetReply = $0}},accepted:{accepted += 1})
        try await wait {resetReply != nil};try require(!model.canApply && RevertWindowModel.activeOperations == 1,"Reset question lost worker lifetime")
        resetReply?.resume(returning:false);resetReply = nil;try await wait {!model.busy};try require(model.fileColumns == columns && accepted == 0,"Reset No changed columns")
        model.resetColumns(choose:{true},accepted:{accepted += 1});try await wait {!model.busy}
        try require(model.fileColumns == RevertWindowModel.defaultColumns && accepted == 1,"Reset Yes did not restore defaults")
        // Model callbacks and actual native key equivalents both honor the active owner and busy gate.
        var accepts:[[String]] = [];model.onAccepted = {accepts.append($0.map(\.path))};model.close = {}
        model.setChecked(Set(model.entries.map(\.path)),value:false);model.setChecked([paths[0]],value:true)
        controller.commandKeyWindow = {controller.window}
        func event(_ key:UInt16,_ flags:NSEvent.ModifierFlags)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:key)!}
        try require(controller.window!.performKeyEquivalent(with:event(36,.control)) && accepts == [[paths[0]]],"Ctrl Return did not submit checked rows")
        try require(controller.window!.performKeyEquivalent(with:event(96,[])) && model.busy,"F5 did not refresh")
        model.apply();try require(accepts.count == 1,"Busy apply submitted");try await wait {!model.busy}
        // Begin a new planning invocation after the intercepted acceptance.
        model.setScope(["."]);try await wait {!model.busy}
        // Context Revert No preserves bytes; Yes creates the existing real progress child and blocks the parent.
        var questions = 0
        model.requestRevert(model.commands.fileMenu([paths[0]]))
        try await wait {controller.window?.attachedSheet != nil}
        let questionWindow = controller.window!.attachedSheet!
        try require(questionWindow.defaultButtonCell?.title == "Yes" && !controller.windowShouldClose(controller.window!),"Source Revert question default or owner gate changed")
        controller.window?.endSheet(questionWindow,returnCode:.alertSecondButtonReturn)
        try await wait {!model.busy}
        questions += 1
        try require(questions == 1 && controller.revertProgress == nil && (try Data(contentsOf:root.appendingPathComponent(paths[0]))) == Data("changed\n".utf8),"Revert No changed working data")
        model.confirmRevert = {_ in questions += 1;return true};model.requestRevert(model.commands.fileMenu([paths[0]]))
        try await wait {controller.revertProgress != nil};let child = controller.revertProgress!
        defer {child.close();for copy in child.model.trashedFiles {try? FileManager.default.removeItem(at:copy)}}
        try require(model.hasChild && !model.canInteract,"Progress child did not block parent")
        try await wait {!child.model.busy};try require(!child.model.failed && (try Data(contentsOf:root.appendingPathComponent(paths[0]))) == Data("base\n".utf8),"Context revert did not restore working file")
        child.close();try await wait {!model.busy && !model.hasChild};try require(!model.entries.contains{$0.path == paths[0]},"Child completion did not refresh Revert")
        let staged = try await repo.run(["diff","--cached","--name-only"]).text
        try require(staged.contains("added.txt") && staged.contains("renamed.txt"),"One-file revert changed unrelated staged paths")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Planning changed HEAD")
        // Cancel waits for an owned read; late completion closes once and cannot publish.
        let draining = RevertWindowModel(repository:repo,access:nil,preferences:prefs)
        var drainReply:CheckedContinuation<[WorkingTreeFile],Error>?,closed = 0
        draining.close = {closed += 1};draining.readStatus = {_ in try await withCheckedThrowingContinuation {drainReply = $0}}
        draining.setScope(["."]);try await wait {drainReply != nil}
        try require(draining.cancel(closeAfter:true) && !draining.addDropped([root.appendingPathComponent(paths[1])]),"Closing read accepted a new drop")
        try require(closed == 0 && draining.busy,"Cancel abandoned read before drain")
        drainReply?.resume(returning:[]);drainReply = nil;try await wait {!draining.busy}
        try require(closed == 1 && draining.entries.isEmpty,"Cancelled read published or failed to close once");draining.invalidate()
        // Forced close owns a still-draining read and refuses publication/launch afterward.
        model.readStatus = {token in heldToken = token;return try await withCheckedThrowingContinuation {held = $0}}
        model.reload();try await wait {held != nil};let last = model.entries
        controller.close();try require(model.retired && heldToken?.isCancelled == true && RevertWindowModel.activeOperations > 0,"Forced close abandoned pending read")
        held?.resume(returning:[]);held = nil;try await wait {RevertWindowModel.activeOperations == 0 && StatusWindowModel.activeOperations == 0}
        try require(model.entries == last && !model.addDropped([root.appendingPathComponent(paths[1])]),"Closed owner accepted late work")
        print("PASS Revert planning: atomic scoped status/queued failure refresh, checks/direct clean files, superseded reads, burst drops/nested rejection, captured menus/private clipboard, independent columns/reset, native F5/Ctrl Return, No/Yes real Revert child, index/HEAD preservation and forced-close drain")
    }
}
