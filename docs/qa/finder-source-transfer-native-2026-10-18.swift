import AppKit
import FinderSync
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor private final class FinderSourceTransferTarget: NSObject {
    var request: FinderRequest?
    @objc func invoke(_ item: NSMenuItem) { request = (item.representedObject as? FinderMenuCommand)?.request }
}

@main enum FinderSourceTransferVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<3000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Finder source transfer timeout: " + message)
    }
    @MainActor private final class Scope {
        let preferences: UserDefaults
        let suite: String
        let board = NSPasteboard.withUniqueName()
        var workspace: RepositoryModel?
        var windows: [NSWindow] = []
        var drops: [FileDropTransferWindowController] = []
        var moves: [FileMoveWindowController] = []
        var copies: [FileCopyWindowController] = []
        var release: [() -> Void] = []
        init() { let name = "TurtleGit.FinderSourceTransfer." + UUID().uuidString; suite = name; preferences = UserDefaults(suiteName: name)!; preferences.set(false, forKey: "ConfirmKillProcess"); preferences.set("dark", forKey: "appearance") }
        func close() async throws {
            defer { preferences.removePersistentDomain(forName: suite); board.releaseGlobally() }
            release.forEach { $0() }; release.removeAll()
            workspace?.cancelFinderSourceTransfer(); workspace?.stopMonitoringForTermination(); workspace?.closeRepository()
            drops.forEach { $0.model.confirmingQuit = false; $0.close() }
            moves.forEach { $0.model.confirmingQuit = false; $0.close() }
            copies.forEach { $0.model.confirmingQuit = false; $0.close() }
            for window in windows { if let child = window.attachedSheet { window.endSheet(child, returnCode: .cancel) }; window.close() }
            try await FinderSourceTransferVerification.wait("owned preparation/operation release") {
                FileDropTransferModel.activePreparations == 0 && FileDropTransferWindowController.activeReleases == 0 &&
                FileMoveWindowModel.activeOperations == 0 && FileCopyWindowModel.activeOperations == 0 &&
                self.workspace?.hasPendingRepositoryWork != true
            }
        }
    }
    @MainActor static func main() async throws { try await verify() }
    @MainActor static func verify() async throws {
        let scope = Scope()
        do { try await run(scope); try await scope.close() }
        catch { let original = error; do { try await scope.close() } catch { throw Failure(description: "\(original); cleanup: \(error)") }; throw original }
    }
    @MainActor private static func run(_ scope: Scope) async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Finder source QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        let source = root.appendingPathComponent("move 雪\n.txt"), second = root.appendingPathComponent("second.txt")
        let destination = root.appendingPathComponent("target 雪", isDirectory: true)
        let outsideFolder = root.deletingLastPathComponent().appendingPathComponent("external-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideFolder) }
        let external = outsideFolder.appendingPathComponent("external 雪\n.txt"), decoy = outsideFolder.appendingPathComponent("clipboard-decoy.txt")
        try Data("base\n".utf8).write(to: source); try Data("second\n".utf8).write(to: second)
        try Data("copied external\n".utf8).write(to: external); try Data("decoy\n".utf8).write(to: decoy)
        try await repository.stage([source.lastPathComponent,second.lastPathComponent]); _ = try await repository.commit(message: "baseline")
        try Data("staged\n".utf8).write(to: source); try await repository.stage([source.lastPathComponent]); try Data("working\n".utf8).write(to: source)
        DialogGeometry.install(preferences: scope.preferences)
        ProgressActionLog.install(store: ActionLogStore(storageURL: outsideFolder.appendingPathComponent("private-actions.log")),preferences: scope.preferences)
        let head = try await repository.run(["rev-parse","HEAD"]).stdout
        let index = try await repository.run(["ls-files","--stage","-z"]).stdout
        let owner = NSWindow(contentRect: NSRect(x: -2000,y: -2000,width: 700,height: 460), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.alphaValue = 0; owner.appearance = NSAppearance(named: .darkAqua); scope.windows.append(owner); owner.orderFront(nil)
        let workspace = RepositoryModel(startMonitoring: false,initializePreferences: false,repositoryFactory: { GitRepository(root: $0,executable: git) },snapshotWriter: { _ in false })
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = scope.preferences; workspace.workspaceWindow = owner; scope.workspace = workspace
        let delegate = TurtleGitApplicationDelegate(); delegate.startupArguments = []; delegate.startupCommandHandler = { _,_,_ in }; delegate.repositoryModel = workspace
        var destinationPanel: NSOpenPanel?, destinationReply: ((NSApplication.ModalResponse) -> Void)?, selectedDestination: URL?
        workspace.presentTransferDestinationPanel = { panel,parent,reply in
            destinationPanel = panel; destinationReply = reply; panel.alphaValue = 0; panel.appearance = parent?.appearance
            if let parent { parent.beginSheet(panel,completionHandler: nil) }
        }
        workspace.selectedTransferDestinationURL = { _ in selectedDestination }
        scope.release.append { if let reply = destinationReply { destinationReply = nil; reply(.cancel) } }
        workspace.configureDropTransfer = { child in child.window?.alphaValue = 0; scope.drops.append(child) }
        workspace.movePresentation = { child in child.window?.alphaValue = 0; scope.moves.append(child) }
        workspace.copyPresentation = { child in child.window?.alphaValue = 0; scope.copies.append(child) }

        // Actual Finder menu captures the item selection independently of clipboard.
        let snapshot = FinderSnapshot(roots: [root.path], states: [source.path: .modified,second.path: .normal], repositories: [root.path: .init()])
        var settings = FinderMenuSettings(); settings.extendedOnlyMask = 0; settings.showIcons = true
        let target = FinderSourceTransferTarget(), selector = #selector(FinderSourceTransferTarget.invoke(_:))
        func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(allItems) ?? [] } }
        func menu(_ urls: [URL], sourceSelection: [URL], toolbar: Bool = false) -> NSMenu {
            FinderMenuBuilder.make(paths: urls,snapshot: snapshot,settings: settings,comparisonMark: nil,target: target,actionSelector: selector,toolbar: toolbar,sourceSelection: sourceSelection,clipboardSources: [decoy])
        }
        let sourceMenu = menu([source],sourceSelection: [source])
        guard let transfer = allItems(sourceMenu).first(where: { ($0.representedObject as? FinderMenuCommand)?.request.isTransferSourceSelection == true }), let action = transfer.action else { throw Failure(description: "Native selected-item Transfer menu missing") }
        try require(transfer.isEnabled && transfer.image != nil,"Finder source command disabled or missing source icon")
        try require(!allItems(menu([source],sourceSelection: [],toolbar: true)).contains(where: { ($0.representedObject as? FinderMenuCommand)?.request.isTransferSourceSelection == true }),"Toolbar fabricated a source selection")
        scope.board.writeObjects([decoy as NSURL]); try require(NSApp.sendAction(action,to: transfer.target,from: transfer),"Captured Finder menu did not dispatch")
        guard let request = target.request, let url = request.url else { throw Failure(description: "Source transfer URL missing") }
        scope.board.clearContents(); scope.board.writeObjects([external as NSURL])
        try require(request.paths.map(\.path) == [source.path] && request.sources.isEmpty && FinderRequest(url: url)?.isTransferSourceSelection == true,"Clipboard drift redirected captured sources")
        workspace.handle(url)
        try await wait("source destination picker") { destinationReply != nil }
        try require(workspace.hasPendingRepositoryWork && delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Source picker lost application lifetime")
        try require(destinationPanel?.alphaValue == 0 && scope.drops.isEmpty,"Destination selection opened visible or premature transfer chooser")
        workspace.cancelFinderSourceTransfer()
        destinationReply?(.cancel); destinationReply = nil
        try await wait("cancelled source destination picker") { !workspace.hasPendingRepositoryWork && destinationPanel?.sheetParent == nil }
        let afterCancel = try await repository.run(["ls-files","--stage","-z"]).stdout
        try require(scope.drops.isEmpty && afterCancel == index,"Destination cancellation mutated Git or launched chooser")

        // Accepting a destination adopts its repository, then reviews captured sources.
        destinationPanel = nil; workspace.handle(url); try await wait("second source picker") { destinationReply != nil }
        selectedDestination = root; destinationReply?(.OK); destinationReply = nil
        try await wait("captured review chooser") { scope.drops.last?.model.ready == true }
        let chooser = scope.drops.last!
        try require(chooser.model.folder.path == root.path,"Source picker did not retain chosen destination repository")
        chooser.model.prepare(folder: destination); try await wait("review subfolder destination") { chooser.model.ready && !chooser.model.busy }
        try require(destinationPanel?.sheetParent == nil && chooser.model.sources.map(\.path) == [source.path] && chooser.model.folder.path == destination.path,"Chooser arrived before picker detach or lost captured source/destination")
        try require(chooser.model.presentationPreferences === scope.preferences && chooser.window?.alphaValue == 0,"Finder review lost captured preferences/invisible owner")
        try require(chooser.model.choices == [.move,.moveRename] && !chooser.model.canChoose(.copyAdd),"Pinned single versioned-source choices differ")
        chooser.model.confirmingQuit = true; chooser.model.accept(.moveRename)
        try require(!chooser.model.retired && scope.moves.isEmpty && !chooser.model.canChoose(.moveRename),"Quit confirmation allowed transfer")
        chooser.model.confirmingQuit = false; chooser.model.accept(.moveRename)
        try await wait("detached Move/Rename handoff") { !scope.moves.isEmpty }
        let moving = scope.moves.last!
        try await wait("Move/Rename source resolution") { !moving.model.busy }
        try require(chooser.window?.sheetParent == nil && chooser.model.retired && moving.model.folder.path == destination.path && moving.model.paths == [source.lastPathComponent] && moving.model.renameFirst,"Move/Rename handoff lost source contract or actual detach")
        chooser.model.accept(.moveRename)
        try require(scope.moves.count == 1,"Retired chooser delivered duplicate Move/Rename")
        try require(moving.model.presentationPreferences === scope.preferences,"Move/Rename lost source preferences")
        moving.model.confirmingQuit = true; moving.model.move(); try require(!moving.model.busy,"Quit confirmation started Git move"); moving.model.confirmingQuit = false
        moving.model.move(); try await wait("native rename sheet") { moving.namePicker != nil }
        let name = moving.namePicker!; try require(name.window?.alphaValue == 0,"Rename child became visible")
        name.nameField.stringValue = "renamed 雪\n.txt"; name.accept(); try await wait("actual checked move") { !moving.model.busy }
        let movedPath = destination.lastPathComponent + "/renamed 雪\n.txt"
        let movedIndex = try await repository.run(["show",":"+movedPath]).stdout
        try require(moving.model.moved == 1 && movedIndex == Data("staged\n".utf8) && (try Data(contentsOf: root.appendingPathComponent(movedPath))) == Data("working\n".utf8),"Finder Move/Rename lost staged versus working bytes")
        moving.close(); try await wait("workspace refresh after move") { !workspace.busy && !workspace.hasPendingRepositoryWork }

        // External source selection adopts destination and exposes only Copy/Add.
        let externalRequest = FinderRequest(action: .transferFiles,paths: [external]); selectedDestination = root; workspace.handle(externalRequest.url!)
        try await wait("external destination picker") { destinationReply != nil }; destinationReply?(.OK); destinationReply = nil
        let count = scope.drops.count; try await wait("external source review") { scope.drops.count > count || scope.drops.last?.model.sources == [external] }
        let copyingChooser = scope.drops.last!; try await wait("external review eligibility") { copyingChooser.model.ready }
        copyingChooser.model.prepare(folder: destination); try await wait("external subfolder destination") { copyingChooser.model.ready && !copyingChooser.model.busy }
        try require(copyingChooser.model.choices == [.copyAdd] && !copyingChooser.model.canChoose(.move),"External sources acquired Git move")
        copyingChooser.model.accept(.copyAdd); try await wait("detached Copy/Add handoff") { !scope.copies.isEmpty }
        let copying = scope.copies.last!
        try require(copyingChooser.window?.sheetParent == nil && copying.model.sources == [external] && copying.model.folder.path == destination.path && copying.model.presentationPreferences === scope.preferences,"Copy/Add lost captured source or destination")
        copying.model.confirmingQuit = true; copying.model.run(); try require(!copying.model.busy,"Quit confirmation started Copy/Add"); copying.model.confirmingQuit = false
        copying.model.run(); try await wait("Copy/Add Git operation") { !copying.model.busy }
        let copied = destination.lastPathComponent + "/" + external.lastPathComponent
        let copiedIndex = try await repository.run(["show",":"+copied]).stdout
        try require(copying.model.copied == 1 && !copying.model.failed && copiedIndex == Data("copied external\n".utf8) && (try Data(contentsOf: external)) == Data("copied external\n".utf8),"External Copy/Add failed or moved source")
        copying.close()
        let afterHead = try await repository.run(["rev-parse","HEAD"]).stdout
        try require(afterHead == head,"Source transfer created a commit")

        // Recent paths are a convenience, not authority: revalidation rejects stale/admin destinations.
        let recents = FileDropTransferModel(repository: repository,access: nil,preferences: scope.preferences,destination: destination)
        recents.loadSources([second],destination: destination); try await wait("recent destination") { !recents.busy }
        try require(recents.recentDestinations.first?.path == destination.path,"Accepted destination not remembered privately")
        let vanished = root.appendingPathComponent("vanished-recent",isDirectory: true)
        try FileManager.default.createDirectory(at: vanished,withIntermediateDirectories: true)
        recents.prepare(folder: vanished); try await wait("remembered temporary destination") { !recents.busy }
        try require(recents.ready && recents.recentDestinations.first?.path == vanished.path,"Temporary destination was not remembered")
        try FileManager.default.removeItem(at: vanished); recents.prepare(folder: vanished)
        try await wait("stale recent destination refusal") { !recents.busy }
        try require(!recents.ready && recents.error != nil && !recents.canChoose(.move),"Deleted recent destination enabled transfer")
        recents.prepare(folder: root.appendingPathComponent(".git")); try await wait("invalid recent destination refusal") { !recents.busy }
        try require(!recents.ready && recents.error != nil && !recents.canChoose(.move),"Invalid recent destination enabled transfer"); recents.retire()
        let multiple = FileDropTransferModel(repository: repository,access: nil,preferences: scope.preferences,destination: destination)
        multiple.loadSources([root.appendingPathComponent(movedPath),second],destination: destination); try await wait("multi-source eligibility") { !multiple.busy }
        try require(multiple.choices == [.move] && !multiple.canChoose(.moveRename),"Multiple sources acquired single-file rename"); multiple.retire()

        // A real nested native picker cannot outlive its hidden chooser or trigger acceptance.
        let pickerOwner = FileDropTransferWindowController(repository: repository,access: nil,preferences: scope.preferences,destination: destination); scope.drops.append(pickerOwner)
        var actualPicker: NSOpenPanel?; pickerOwner.makeOpenPanel = { let panel = NSOpenPanel();actualPicker = panel;return panel }
        try require(pickerOwner.present(owner: owner),"Owned transfer review absent")
        pickerOwner.model.loadSources([second],destination: destination); try await wait("picker owner ready") { pickerOwner.model.ready }
        pickerOwner.model.browse(); try await wait("owned native destination sheet") { actualPicker?.sheetParent != nil }
        try require(actualPicker?.alphaValue == 0 && actualPicker?.appearance?.name == owner.appearance?.name,"Nested chooser lost hidden appearance")
        pickerOwner.close(); try await wait("native picker and parent detach") { actualPicker?.sheetParent == nil && pickerOwner.window?.sheetParent == nil && FileDropTransferWindowController.activeReleases == 0 }

        // Retired async preparation still owns Quit until its actual worker returns.
        let held = FileDropTransferWindowController(repository: repository,access: nil,preferences: scope.preferences,destination: destination); scope.drops.append(held)
        var preparation: CheckedContinuation<URL,Never>?, closed = 0, accepted = 0
        held.model.resolveDestination = { _,_ in await withCheckedContinuation { preparation = $0 } }
        held.onClosed = { closed += 1 }; held.onAccepted = { _,_,_ in accepted += 1 }
        scope.release.append { if let reply = preparation { preparation = nil;reply.resume(returning: destination) } }
        try require(held.present(owner: owner),"Held chooser absent"); held.model.loadSources([second],destination: destination)
        try await wait("held destination preparation") { preparation != nil }; held.close()
        try require(FileDropTransferModel.activePreparations > 0 && FileDropTransferWindowController.activeReleases > 0 && delegate.applicationShouldTerminate(NSApp) == .terminateCancel && closed == 0,"Retirement released preparation/Quit before actual drain")
        preparation?.resume(returning: destination); preparation = nil
        try await wait("retired preparation receipt") { closed == 1 && FileDropTransferModel.activePreparations == 0 && FileDropTransferWindowController.activeReleases == 0 }
        try require(accepted == 0 && held.model.retired && !held.model.ready,"Late retired preparation published/accepted")
        print("PASS Finder source transfers: captured actual Finder item payloads; destination cancellation/adoption; native review and detached Move/Rename/Copy/Add; exact staged/working data; private recents; hidden picker ownership; Quit and preparation drain")
    }
}
