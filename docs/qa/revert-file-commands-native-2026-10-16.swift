import AppKit
import TurtleGitCore

@main struct RevertFileCommandsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Revert file command timeout at line \(line)")
    }
    @MainActor static func descendants<T:NSView>(_ view:NSView?,of type:T.Type)->[T] {
        guard let view else {return []};return (view as? T).map{[$0]} ?? view.subviews.flatMap{descendants($0,of:type)}
    }
    @MainActor static func capture(_ window:NSWindow,to file:URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded();window.orderFront(nil)
        try await Task.sleep(nanoseconds:350_000_000)
        let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        process.arguments = ["-x","-o","-l",String(window.windowNumber),file.path]
        try process.run();process.waitUntilExit();window.orderOut(nil)
        try require(process.terminationStatus == 0 && FileManager.default.fileExists(atPath:file.path),"Passive Revert capture failed")
    }
    @MainActor static func main() async {do {try await verify()} catch {fputs("Revert file commands failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let first = "message 雪.txt",second = "other.bin",removed = "removed.txt"
        for path in [first,second,removed] {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage([first,second,removed]);_ = try await repo.commit(message:"base")
        let bytes = Data([0,255,128,13,10,0,65]);try Data("current\n".utf8).write(to:root.appendingPathComponent(first));try bytes.write(to:root.appendingPathComponent(second));_ = try await repo.run(["rm","--cached",removed])
        try Data("new file\n".utf8).write(to:root.appendingPathComponent("added.swift"));try await repo.stage(["added.swift"])
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")),head = try await repo.run(["rev-parse","HEAD"]).stdout
        let suite = "TurtleGit.RevertFiles." + UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner = RevertWindowController(repository:repo,access:nil,preferences:prefs),model = owner.model
        owner.window?.alphaValue = 0;owner.window?.orderFront(nil);defer {owner.close()}
        let clipboard = NSPasteboard.withUniqueName();model.commands.clipboard = clipboard;defer {clipboard.releaseGlobally()}
        model.setScope(["."]);try await wait {model.canInteract}
        let one = model.commands.fileMenu([first]),two = model.commands.fileMenu([second])
        try require(model.canPrepareFile(one) && !model.canPrepareFile(model.commands.fileMenu([removed])),"Source deleted-row Save/Mark gate lost")
        // Native watermark is original 128-point artwork, under the native cells.
        try await wait {!descendants(owner.window?.contentView,of:FileListWatermark.self).isEmpty}
        let watermark = descendants(owner.window?.contentView,of:FileListWatermark.self).first!
        try require(watermark.icon == .revertBackdrop && watermark.image != nil && watermark.artworkRect?.size == NSSize(width:128,height:128),"Revert artwork missing")
        try require(watermark.hitTest(.zero) == nil && watermark.superview === watermark.table,"Watermark captures input or escaped its table")
        prefs.set(false,forKey:"ShowListBackgroundImage");try require(watermark.artworkRect == nil,"Hidden list-background preference ignored");prefs.set(true,forKey:"ShowListBackgroundImage")
        // Mark and Compare follow the source selection mark, and reject stale popup versions.
        var compared:[(PreparedFileComparisonMark,PreparedFileComparisonMark)] = []
        model.onPreparedFileCompare = {compared.append(($0,$1))};model.markForComparison(one)
        let marked = model.preparedMenu(two);model.compareWithMarkedFile(marked)
        try require(compared.count == 1 && compared[0].0.path == first && compared[0].1.path == second && compared[0].0.revision.isEmpty,"Local mark comparison lost endpoints")
        let snapshot = try await repo.preparedPathComparison(from:.workingTree,fromPath:first,to:.workingTree,toPath:second)
        let document = try await repo.comparisonFile(snapshot,path:second)
        try require(document.base.bytes == Data("current\n".utf8) && document.destination.bytes == bytes,"Prepared comparison did not read exact working bytes")
        model.markForComparison(two);model.compareWithMarkedFile(marked);try require(compared.count == 1,"Old mark popup revived after replacement")
        let outside = model.commands.fileMenu([first],mark:second);model.markForComparison(outside)
        try require(model.comparisonMark?.path == second,"Mark used highlighted row instead of selection mark")
        // Finder's saved mark imports once, retaining its exact access lease and file URL.
        let external = root.deletingLastPathComponent().appendingPathComponent("marked-" + UUID().uuidString + ".bin")
        try Data("external".utf8).write(to:external);defer {try? FileManager.default.removeItem(at:external)}
        let store = WorkingComparisonMarkStore(storageURL:root.appendingPathComponent(".git/comparison-mark.json")),permission = RepositoryAccessLease(url:external)
        _ = try store.remember(file:external,permission:permission);let imported = try store.acquire()
        model.importWorkingComparisonMark(imported);model.compareWithMarkedFile(model.preparedMenu(model.commands.fileMenu([first])))
        try require(compared.count == 2 && compared[1].0.workingAccess?.mark.id == imported.mark.id && compared[1].0.workingAccess?.file == imported.file && compared[1].0.workingAccess?.permission === imported.permission,"Finder mark lost captured file/grant: count=\(compared.count), imported=\(imported.file), file=\(String(describing:compared.last?.0.workingAccess?.file))")
        model.markForComparison(model.commands.fileMenu([first]));model.importWorkingComparisonMark(imported)
        try require(model.comparisonMark?.path == first && model.comparisonMark?.workingAccess == nil,"Repeated old Finder import overwrote local mark")
        // Copy-column text is captured at popup creation and invalidated by refresh.
        let copy = model.captureColumnCopy([first],column:.fileName);copy?()
        try require(clipboard.string(forType:.string) == first + "\n","Captured filename column differs")
        model.reload();try await wait {model.canInteract};clipboard.clearContents();clipboard.setString("sentinel",forType:.string);copy?()
        try require(clipboard.string(forType:.string) == "sentinel","Stale column menu copied after refresh")
        // Production Save As owns its panel and source-style suggested name; Cancel writes nothing.
        let current = model.commands.fileMenu([first],mark:second)
        model.saveAs(current);try await wait {owner.window?.attachedSheet is NSSavePanel}
        let panel = owner.window!.attachedSheet as! NSSavePanel
        try require(panel.nameFieldStringValue == "other-.bin" && !model.canApply && RevertWindowModel.activeOperations == 1 && !owner.windowShouldClose(owner.window!),"Save panel name/target/owner lifetime differs")
        owner.window?.endSheet(panel,returnCode:.cancel);try await wait {model.canInteract}
        // A real copy uses an ordinary permitted output; Git metadata destinations stay rejected by Core.
        let destination = root.deletingLastPathComponent().appendingPathComponent("saved-" + UUID().uuidString + ".bin");defer {try? FileManager.default.removeItem(at:destination)}
        var choices:[String] = [];model.chooseSaveFile = {choices.append($0);return destination}
        model.saveAs(model.commands.fileMenu([first],mark:second));try await wait {model.canInteract}
        try require(choices == [second] && (try Data(contentsOf:destination)) == bytes,"Save As used highlights or changed binary bytes")
        if let folder = ProcessInfo.processInfo.environment["TURTLEGIT_REVERT_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            NSApp.setActivationPolicy(.accessory);owner.window!.alphaValue = 1;model.setChecked([first],value:true)
            for (appearance,name) in [(NSAppearance.Name.aqua,"revert"),(.darkAqua,"revert-dark")] {
                owner.window!.appearance = NSAppearance(named:appearance);try await capture(owner.window!,to:directory.appendingPathComponent(name + ".png"))
            }
            owner.window!.alphaValue = 0
        }
        // A cancelled destination question drains before one requested close; late URL performs no copy.
        var reply:CheckedContinuation<URL?,Never>?,closed = 0
        model.close = {closed += 1};model.chooseSaveFile = {_ in await withCheckedContinuation {reply = $0}}
        model.saveAs(model.commands.fileMenu([first]));try await wait {reply != nil}
        try require(model.cancel(closeAfter:true) && closed == 0 && !model.canInteract,"Pending save cancellation abandoned question")
        reply?.resume(returning:destination);reply = nil;try await wait {!model.busy}
        try require(closed == 1 && (try Data(contentsOf:destination)) == bytes,"Cancelled Save As wrote or closed more than once")
        // A forced owner close cancels an actual copy worker and suppresses late diagnostics.
        var worker:CheckedContinuation<Void,Error>?,token:OperationCancellation?
        model.chooseSaveFile = {_ in destination};model.saveWorkingFile = {_,_,request in token = request;try await withCheckedThrowingContinuation {worker = $0}}
        model.saveAs(model.commands.fileMenu([first]));try await wait {worker != nil};owner.close()
        try require(model.retired && token?.isCancelled == true && RevertWindowModel.activeOperations == 1,"Retired copy lost worker ownership")
        worker?.resume(throwing:Failure(description:"Late copy failure"));worker = nil;try await wait {RevertWindowModel.activeOperations == 0}
        try require(model.error == nil && (try Data(contentsOf:destination)) == bytes && watermark.superview == nil,"Retired worker published or left watermark attached")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"File commands changed index")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"File commands changed HEAD")
        print("PASS Revert file commands: source Save/Mark gates, exact prepared endpoints, Finder mark/access import, stale popup/column capture, original watermark/preferences/retirement, production Save As Cancel, exact binary save to marked row, cancelled question and retired worker drain")
    }
}
