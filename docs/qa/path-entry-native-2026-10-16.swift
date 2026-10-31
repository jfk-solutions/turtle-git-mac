import AppKit
import TurtleGitCore

@main struct PathEntryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Scope: RepositoryBookmarkProvider {
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
        func startAccessing(_ url: URL) -> Bool { true }
        func stopAccessing(_ url: URL) {}
    }
    @MainActor static var owners: [NSWindowController] = []
    @MainActor static var phase = "setup"
    @MainActor static var observation: () -> String = { "No dialog mounted" }
    @MainActor static func beginPhase(_ name: String, state: @escaping () -> String) {
        phase = name; observation = state; print("Path entry phase: " + name + "; " + state()); fflush(stdout)
    }
    @MainActor static func turn() async { await withCheckedContinuation { reply in DispatchQueue.main.async { reply.resume() } } }
    @MainActor static func fieldState(_ owner:NSWindowController,_ model:String)->String {
        let fields = descendants(owner.window?.contentView).compactMap { $0 as? PathEntryField.Field }.map {
            "label=\(String(reflecting:$0.accessibilityLabel())) value=\(String(reflecting:$0.stringValue)) enabled=\($0.isEnabled) attached=\($0.window != nil) accepts=\($0.coordinator?.acceptsInput==true) retired=\($0.coordinator?.retired==true)"
        }
        return "owner=\(owner.window?.title ?? "missing") model={\(model)} fields={\(fields.joined(separator:"; "))}"
    }
    @MainActor static func boundField(_ field:PathEntryField.Field,expected:String,value:()->String) async throws {
        // Waiting for a native binding transaction may not overwrite or silently
        // tolerate a model reset by an unfinished initial load.
        for _ in 0..<2000 {
            try require(value()==expected,"Draft changed before native binding at \(phase): expected=\(String(reflecting:expected)); \(observation())")
            if field.stringValue==expected {return}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw Failure(description:"Native binding did not reflect accepted draft at \(phase); \(observation())")
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Path entry timeout at \(line), phase=\(phase); \(observation())")
    }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.close() }; owners = [] }
        catch { owners.forEach { $0.close() }; owners = []; fputs("Path entry failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Path QA"), ("user.email", "path@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("source\n".utf8).write(to: root.appendingPathComponent("source.txt")); try await repo.stage(["source.txt"]); _ = try await repo.commit(message: "baseline")
        let folder = root.appendingPathComponent("folder with space"), outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for name in ["file 雪\n.patch", "file [literal].zip", ".hidden", "FileCase.txt"] { try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let scope = RepositoryAccessLease(url: root, provider: Scope()), token = OperationCancellation()
        func query(_ text: String, base: URL? = nil, restricted: Bool = false, grants: [RepositoryAccessLease]? = nil) throws -> [String] {
            try PathEntryQuery(text: text, base: base ?? root, permissions: grants ?? [scope], requiresScopes: restricted).results(cancellation: token)
        }
        try require(try query("fo") == ["folder with space/"], "Relative folder completion lost slash/space")
        try require(try query("fi").contains("file 雪\n.patch") && query("fi").contains("file [literal].zip"), "Literal Unicode/newline/glob file names lost")
        try require(try query("../fo", base: folder) == ["../folder with space/"], "Parent-relative prefix changed")
        try require(try query(".").contains(".hidden") && !query("f").contains(".hidden"), "Explicit hidden-prefix completion lost")
        try require(try query("https://example.invalid/path").isEmpty, "URL entered filesystem lookup")
        try require(try query("fo", restricted: true) == ["folder with space/"] && query(outside.path + "/", restricted: true).isEmpty && query("escape/", restricted: true).isEmpty && query("fo", restricted: true, grants: []).isEmpty, "Grant or symlink boundary lost")
        let account = root.appendingPathComponent("account-home", isDirectory:true)
        let container = account.appendingPathComponent("Library/Containers/org.test.TurtleGit/Data", isDirectory:true)
        try FileManager.default.createDirectory(at:container,withIntermediateDirectories:true)
        try Data("account fixture".utf8).write(to:account.appendingPathComponent("account-file.txt"))
        try Data("container fixture".utf8).write(to:container.appendingPathComponent("container-file.txt"))
        let accountScope=RepositoryAccessLease(url:account,provider:Scope())
        let accountQuery=PathEntryQuery(text:"~/account-",base:container,permissions:[accountScope],requiresScopes:true,accountHome:account)
        try require(try accountQuery.results(cancellation:token)==[account.path+"/account-file.txt"],"Account-home completion used container/base path")
        let deniedAccount=PathEntryQuery(text:"~/account-",base:container,permissions:[],requiresScopes:true,accountHome:account)
        try require(try deniedAccount.results(cancellation:token).isEmpty,"Account-home spelling granted enumeration access")
        let containerQuery=PathEntryQuery(text:"~/container-",base:account,permissions:[accountScope],requiresScopes:true,accountHome:container)
        try require(try containerQuery.results(cancellation:token)==[container.path+"/container-file.txt"],"Explicit isolated completion home was ignored")
        let policySuite="TurtleGit.AccountDefaults."+UUID().uuidString, policyPrefs=UserDefaults(suiteName:policySuite)!
        defer{policyPrefs.removePersistentDomain(forName:policySuite)}
        let accountPath=UserAccountPaths.homeDirectory.path
        let reportModel=SupportReportWindowModel(systemInformation:"Fixture",preferences:policyPrefs)
        reportModel.field(\.details,context:reportModel.context).wrappedValue=accountPath+"/private-fixture"
        try require(reportModel.preview.contains("<HOME>/private-fixture") && !reportModel.preview.contains(accountPath+"/private-fixture"),"Default report redaction missed account-home path")
        let privateDiagnostics=account.appendingPathComponent("Library/Logs/DiagnosticReports",isDirectory:true)
        try FileManager.default.createDirectory(at:privateDiagnostics,withIntermediateDirectories:true)
        try require(reportModel.diagnosticReportsDirectory.path==UserAccountPaths.homeDirectory.appendingPathComponent("Library/Logs/DiagnosticReports",isDirectory:true).path,"Default report chooser policy differs from account redaction home")
        let reportOwner=SupportReportWindowController(systemInformation:"Fixture",home:account.path,preferences:policyPrefs);owners.append(reportOwner)
        var reportLocation:URL?
        reportOwner.presentOpen={panel,_,reply in reportLocation=panel.directoryURL;reply(.cancel)}
        reportOwner.importReport(context:reportOwner.model.context)
        try require(reportLocation?.resolvingSymlinksInPath().path==privateDiagnostics.resolvingSymlinksInPath().path && !reportOwner.model.picking,"Report chooser default differs from account discovery/redaction home")
        reportOwner.close();reportModel.invalidate()
        let keyModel=SSHKeyGenerationModel()
        try require(keyModel.suggestedFolder.path==UserAccountPaths.homeDirectory.appendingPathComponent(".ssh",isDirectory:true).path && !keyModel.valid,"SSH default folder changed authorization or used container home")
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try PathEntryQuery(text: "fo", base: root, permissions: [], requiresScopes: false).results(cancellation: stopped); throw Failure(description: "Cancelled completion ran") } catch is OperationCancellationFailure {}
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        var index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.PathEntry." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let rename = RenameWindowController(repository: repo, access: nil, source: "source.txt", preferences: prefs)
        let clone = CloneWindowController(directory: root, access: nil, preferences: prefs, executable: repo.executable)
        let worktree = WorktreeCreateWindowController(repository: repo, access: nil, preferences: prefs)
        let export = ExportWindowController(repository: repo, access: nil, revision: "HEAD", preferences: prefs)
        owners = [rename, clone, worktree, export]
        // Controllers own their initial reads. Do not initiate duplicate loads
        // or change a draft before its own load and mounted binding have settled.
        beginPhase("controller-owned initial reference loads", state: {"worktreeBusy=\(worktree.model.busy) chooserBusy=\(worktree.model.chooser.busy) worktreeError=\(String(reflecting:worktree.model.error)) chooserError=\(String(reflecting:worktree.model.chooser.error)) exportBusy=\(export.model.busy) exportPending=\(export.model.hasPendingWork) exportError=\(String(reflecting:export.model.error))"})
        try await wait {!worktree.model.busy && !worktree.model.chooser.busy && !export.model.busy && !export.model.hasPendingWork}
        try require(worktree.model.error==nil && worktree.model.chooser.error==nil && export.model.error==nil,"Controller initial reads failed: "+observation())
        index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let configurations: [(NSWindowController, String, String, () -> String, (String) -> Void, () -> Bool, () -> String)] = [
            (rename, "New name", "fo", { rename.model.name }, { rename.model.name = $0 },
             { rename.model.canEdit }, { "name=\(String(reflecting:rename.model.name)) busy=\(rename.model.busy) pending=\(rename.model.pendingOperations) error=\(String(reflecting:rename.model.error))" }),
            (clone, "Destination directory", root.path + "/fo", { clone.model.directory }, { clone.model.directory = $0 },
             { clone.model.canEditForm }, { "directory=\(String(reflecting:clone.model.directory)) busy=\(clone.model.busy) pending=\(clone.model.hasPendingWork) error=\(String(reflecting:clone.model.error))" }),
            (worktree, "Worktree directory", root.path + "/fo", { worktree.model.directory }, { worktree.model.directory = $0 },
             { worktree.model.commandsAvailable && !worktree.model.busy && !worktree.model.progress && !worktree.model.chooser.busy && worktree.model.chooser.pickerTarget==nil },
             { "directory=\(String(reflecting:worktree.model.directory)) busy=\(worktree.model.busy) chooserBusy=\(worktree.model.chooser.busy) error=\(String(reflecting:worktree.model.error)) chooserError=\(String(reflecting:worktree.model.chooser.error))" }),
            (export, "Archive file", root.path + "/fi", { export.model.destination }, { export.model.destination = $0 },
             { export.model.canEditForm }, { "destination=\(String(reflecting:export.model.destination)) busy=\(export.model.busy) pending=\(export.model.hasPendingWork) error=\(String(reflecting:export.model.error))" })]
        var firstField: PathEntryField.Field?, firstEditor: PathEntryField.Editor?, firstCoordinator: PathEntryField.Coordinator?
        for (owner, label, prefix, value, set, ready, modelState) in configurations {
            beginPhase(label + " initial load and native mount", state: {fieldState(owner,modelState())})
            owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
            var field: PathEntryField.Field?
            try await wait {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                field = descendants(owner.window?.contentView).compactMap { $0 as? PathEntryField.Field }.first { $0.accessibilityLabel() == label }
                return ready() && field?.isEnabled == true && field?.window === owner.window && field?.coordinator?.acceptsInput == true
            }
            await turn();owner.window?.contentView?.layoutSubtreeIfNeeded()
            let control = field!, coordinator = control.coordinator!
            try require(ready() && control.stringValue==value(),"Initial mounted field/model disagree: " + observation())
            beginPhase(label + " draft binding", state: {fieldState(owner,modelState())})
            set(prefix)
            try await boundField(control,expected:prefix,value:value)
            beginPhase(label + " native typing/completion", state: {fieldState(owner,modelState())})
            coordinator.present = { _ in } // Test actual TextKit completion without physical popup tracking.
            owner.window?.makeFirstResponder(control)
            guard let editor = control.currentEditor() as? PathEntryField.Editor else { throw Failure(description: "Custom path field editor absent: " + label) }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("l", replacementRange: editor.selectedRange())
            try await wait { value() == prefix + "l" && !coordinator.choices.isEmpty }
            var selected = 0
            let choices = editor.completions(forPartialWordRange: editor.rangeForUserCompletion, indexOfSelectedItem: &selected) ?? []
            try require(!choices.isEmpty && selected == -1 && editor.rangeForUserCompletion.length == editor.string.utf16.count, "Native completion split a path word or selected it prematurely")
            let chosen = choices[0]
            editor.insertCompletion(chosen, forPartialWordRange: editor.rangeForUserCompletion, movement: NSReturnTextMovement, isFinal: true)
            try await wait { value() == chosen }
            try require(control.stringValue == chosen, "Native choice did not bind exactly: " + label)
            if label == "New name" { firstField = control; firstEditor = editor; firstCoordinator = coordinator }
            else { owner.close() }
        }
        beginPhase("Rename held completion replacement and retirement", state: {fieldState(rename,"name=\(String(reflecting:rename.model.name)) busy=\(rename.model.busy) pending=\(rename.model.pendingOperations)")})
        // Held reads are cancelled/retained through retirement, and cannot reopen
        // a popup or replace a changed draft once they return successfully.
        let field = firstField!, coordinator = firstCoordinator!
        rename.model.name = "fo"; try await wait { field.stringValue == "fo" }
        rename.window?.makeFirstResponder(field)
        let editor = field.currentEditor() as? PathEntryField.Editor ?? firstEditor!
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var reply: CheckedContinuation<[String], Error>?, captured: OperationCancellation?, presented = 0
        coordinator.read = { _, token in captured = token; return try await withCheckedThrowingContinuation { reply = $0 } }
        coordinator.present = { _ in presented += 1 }
        coordinator.request(); try await wait { reply != nil }
        rename.model.name = "different"; try await wait { field.stringValue == "different" }
        reply?.resume(returning: ["folder with space/"]); reply = nil; try await wait { PathEntryField.Coordinator.activeReads == 0 }
        try require(captured?.isCancelled == true && presented == 0 && rename.model.name == "different", "Changed input accepted old completion")
        rename.model.name = "fo"; try await wait { field.stringValue == "fo" }; rename.window?.makeFirstResponder(field)
        let active = field.currentEditor() as! PathEntryField.Editor; active.setSelectedRange(NSRange(location: active.string.utf16.count, length: 0))
        coordinator.request(); try await wait { reply != nil }; rename.close()
        try require(captured?.isCancelled == true && PathEntryField.Coordinator.activeReads > 0, "Closed field released pending reader")
        reply?.resume(returning: ["late"]); reply = nil; try await wait { PathEntryField.Coordinator.activeReads == 0 }
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try require(coordinator.retired && presented == 0 && rename.model.name == "fo", "Retired delegate/popup changed the model")
        beginPhase("Git state preservation",state:{"completionReaders=\(PathEntryField.Coordinator.activeReads)"})
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Completion changed Git state")
        print("PASS: source filesystem completion in four native dialog fields, literal paths/scopes, real TextKit binding/selection, cancellation and retired reply guards; unchanged HEAD/index")
    }
}
