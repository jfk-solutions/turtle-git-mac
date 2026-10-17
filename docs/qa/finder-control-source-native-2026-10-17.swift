// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct FinderControlSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Bookmarks: RepositoryBookmarkProvider {
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), stale: false) }
        func startAccessing(_ url: URL) -> Bool { true }
        func stopAccessing(_ url: URL) {}
    }
    @MainActor static var manager: FinderWatchManager?
    @MainActor static var windows = [NSWindow]()
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Finder control wait at line \(line)")
    }
    @MainActor static func cleanup() async { windows.forEach { $0.close() }; await manager?.shutdown() }
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); await cleanup(); print("PASS: Finder control family, exact overlay drafts/owned page contexts, shared publication, captured watch batches and owned choosers") }
        catch { await cleanup(); fputs("Finder control family failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_CONTROL_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture API unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own window missing") }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + "-" + suffix + ".png"))
            print("Captured \(name)-\(suffix): \(config.width)x\(config.height)")
        }
    }
    @MainActor static func verify() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.FinderControls." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let publication = folder.appendingPathComponent("private-group/overlay-settings.json")
        var notifications = 0, failPublication = false, extensionEnabled = false, extensionRequests = 0
        var oldExtensionContext: FinderOverlaySettingsModel.FormContext?
        let overlay = FinderOverlaySettingsModel(preferences: prefs, publish: { value in
            if failPublication { throw Failure(description: "Private publication failed") }; return try value.write(to: publication)
        }, notify: { notifications += 1 }, extensionState: { extensionEnabled }, openExtensionManager: { extensionRequests += 1 })
        let transaction = SettingsTransaction(); defer { transaction.invalidate() }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; windows.append(window)
        for page in [FinderOverlaySettingsModel.Page.overlays, .handlers, .icons] {
            window.title = page == .overlays ? "Icon Overlays – TurtleGit" : page == .handlers ? "Overlay Handlers – TurtleGit" : "Icon Set – TurtleGit"
            let viewport = SettingsPageViewport(frame: .zero)
            let host = NSHostingView(rootView: FinderOverlaySettingsPage(model: overlay, handlersOnly: page == .handlers, iconsOnly: page == .icons).environment(\.settingsTransaction, transaction))
            window.contentView = viewport; viewport.pageDocument.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: viewport.pageDocument.leadingAnchor), host.trailingAnchor.constraint(equalTo: viewport.pageDocument.trailingAnchor), host.topAnchor.constraint(equalTo: viewport.pageDocument.topAnchor), host.bottomAnchor.constraint(equalTo: viewport.pageDocument.bottomAnchor)])
            window.setContentSize(.init(width: 800, height: 660)); window.orderFront(nil)
            try await wait { overlay.formContext.page == page }
            let context = overlay.formContext
            if page == .overlays {
                oldExtensionContext = context
                extensionEnabled = true; overlay.refreshExtensionStatus(context: context)
                try require(overlay.extensionEnabled && !overlay.modified, "Extension status dirtied badge preferences")
                overlay.manageExtension(context: context); try require(extensionRequests == 1, "Active extension manager action refused")
                let sheet = NSWindow(contentRect: .init(x:0,y:0,width:200,height:100), styleMask:[.titled], backing:.buffered, defer:false)
                sheet.isReleasedWhenClosed = false; windows.append(sheet); window.beginSheet(sheet, completionHandler: nil)
                overlay.manageExtension(context: context); try require(extensionRequests == 1, "A modal child allowed extension management")
                window.endSheet(sheet); sheet.orderOut(nil); sheet.close()
                overlay.field(\.excludePaths, context: context).wrappedValue = "/repo/café*"
                try await wait { transaction.modified }; transaction.apply(closeAfter: false); try await wait { !transaction.busy }
                try require(!overlay.modified && notifications == 1, "Initial overlay Apply")
                let old = overlay.field(\.excludePaths, context: overlay.formContext)
                old.wrappedValue = "/repo/cafe\u{301}*"
                try require(overlay.modified, "Canonical path edit not modified")
                try await wait { transaction.modified }; transaction.apply(closeAfter: false); try await wait { !transaction.busy }
                try require(notifications == 2 && FinderOverlaySettings.read(from: publication).excludePaths.utf8.elementsEqual("/repo/cafe\u{301}*".utf8), "Exact overlay path publication")
                old.wrappedValue = "after Apply"; try require(!overlay.modified, "Apply left old field live")
                let beforeNone = overlay.field(\.unversionedAsModified, context: overlay.formContext)
                overlay.field(\.cacheMode, context: overlay.formContext).wrappedValue = .none
                beforeNone.wrappedValue = true
                overlay.field(\.unversionedAsModified, context: overlay.formContext).wrappedValue = true
                try require(!overlay.draft.unversionedAsModified, "None mode enabled propagation")
                overlay.cancel(); beforeNone.wrappedValue = true; try require(!overlay.modified, "Cancel retained dependency callbacks")
                let leaving = overlay.field(\.excludePaths, context: overlay.formContext)
                overlay.suspend(.overlays); overlay.activate(.overlays); leaving.wrappedValue = "after revisit"
                try require(!overlay.modified, "Page revisit revived callback")
            } else if page == .handlers {
                overlay.manageExtension(context: oldExtensionContext!); overlay.refreshExtensionStatus(context: oldExtensionContext!)
                try require(extensionRequests == 1, "A departed overlay page retained external actions")
                overlay.field(\.excludePaths, context: context).wrappedValue = "wrong page"
                overlay.handler(.conflicted, context: context).wrappedValue = false
                try require(!overlay.modified, "Handler page changed another page/core handler")
                overlay.handler(.ignored, context: overlay.formContext).wrappedValue = false
                overlay.field(\.showSkipWorktree, context: overlay.formContext).wrappedValue = false
                try require(overlay.draft.hiddenStates.contains(.ignored) && !overlay.draft.showSkipWorktree, "Optional handler controls")
            } else {
                let prior = overlay.formContext
                overlay.field(\.iconSet, context: prior).wrappedValue = .modern
                overlay.preview(context: prior).wrappedValue = true
                try require(overlay.largeIcons && overlay.draft.iconSet == .modern, "Symbols/icon set controls")
                overlay.suspend(.icons); overlay.activate(.icons); overlay.preview(context: prior).wrappedValue = false
                try require(overlay.largeIcons, "Retained preview callback changed revisited page")
            }
            try await capture(window, name: page == .overlays ? "overlay-controls-source" : page == .handlers ? "overlay-handlers-source" : "overlay-icons-source")
        }
        failPublication = true; let before = try Data(contentsOf: publication)
        try require(!overlay.apply() && overlay.modified && notifications == 2 && (try Data(contentsOf: publication)) == before, "Failed publication discarded/notified draft")
        failPublication = false; try require(overlay.apply() && notifications == 3 && !overlay.modified, "Shared handler/icon Apply failed")
        let retired = overlay.field(\.iconSet, context: overlay.formContext); window.close(); retired.wrappedValue = .flat
        try require(!overlay.apply() && !overlay.modified, "Closed overlay owner accepted callbacks/Apply")
        overlay.manageExtension(context: oldExtensionContext!); try require(extensionRequests == 1, "Closed overlay owner opened System Settings")
        let registration = FinderBackgroundService(); registration.registrationStatus = { .notFound }
        registration.embeddedServiceAvailable = { true }; registration.updateStatus()
        try require(registration.message == "Background service is not enabled.", "Packaged unregistered service was reported missing")
        registration.embeddedServiceAvailable = { false }; registration.updateStatus()
        try require(registration.message == "The background service is missing from this build.", "Actually missing service lost its diagnostic")
        registration.retire()
        // Real private watch/cache mutations; file chooser acceptance is injected.
        let provider = Bookmarks(), access = try RepositoryAccessStore(storageURL: folder.appendingPathComponent("private/watches.json"), provider: provider)
        let cache = FinderSnapshotStore(url: folder.appendingPathComponent("private-group/status.json"))
        var watchPublications = 0
        let watcher = FinderWatchManager(permissions: access, cache: cache, requireScope: false, scopeProvider: provider, repositoryFactory: { GitRepository(root: $0, executable: engine) }, notify: { watchPublications += 1 })
        manager = watcher
        var roots = [URL](), heads = [Data](), indexes = [Data]()
        for name in ["First project", "Second project"] {
            let root = folder.appendingPathComponent(name); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = GitRepository(root: root, executable: engine); _ = try await repo.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Finder QA"), ("user.email", "finder@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
            roots.append(root); heads.append(try await repo.run(["rev-parse", "HEAD"]).stdout); indexes.append(try Data(contentsOf: root.appendingPathComponent(".git/index")))
            await watcher.add(root)
        }
        try await wait { watcher.rows.count == 2 && watcher.pendingOperations == 0 && watcher.rows.allSatisfy { $0.status.hasPrefix("Updated") } }
        let controls = FinderWatchPageModel(manager: watcher)
        let watchWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        watchWindow.isReleasedWhenClosed = false; watchWindow.alphaValue = 0; watchWindow.title = "Finder Repositories – TurtleGit"; windows.append(watchWindow)
        watchWindow.contentView = NSHostingView(rootView: FinderWatchedRepositoriesPage(manager: watcher, controls: controls)); watchWindow.setContentSize(.init(width: 960, height: 600)); watchWindow.orderFront(nil)
        try await wait { controls.canInteract }
        let ids = Set(watcher.rows.map(\.id)); controls.selection(context: controls.context).wrappedValue = ids
        let both = controls.context
        var reply: ((Bool) -> Void)?, message = "", questionCount = 0
        controls.ask = { _, text, answer in message = text; reply = answer; questionCount += 1 }
        controls.remove(context: both)
        try require(controls.hasSheet && message.contains(roots[0].path) && message.contains(roots[1].path), "Batch removal did not capture both names")
        controls.selection(context: both).wrappedValue = []
        try require(controls.selected == ids, "Question allowed retained selection change")
        let cancelledReply = reply; reply?(false); cancelledReply?(true)
        try require(!controls.hasSheet && watcher.rows.count == 2, "Duplicate/cancelled removal changed watches")
        controls.suspend(); controls.activate(); controls.remove(context: both)
        try require(questionCount == 1, "Revisited page accepted old remove action")
        let first = watcher.rows[0].id
        controls.selection(context: controls.context).wrappedValue = [first]
        var chooser: ((URL?) -> Void)?, chooserCount = 0
        controls.chooseFolder = { _, initial, answer in chooser = answer; chooserCount += 1 }
        controls.chooseRoot(renew: true, context: controls.context)
        let late = chooser; controls.suspend(); controls.activate(); late?(roots[0])
        try require(!controls.hasSheet && watcher.rows.count == 2 && chooserCount == 1, "Suspended chooser published")
        let beforeRenew = watcher.serviceRevision
        controls.chooseRoot(renew: true, context: controls.context)
        chooser?(URL(fileURLWithPath: watcher.rows.first { $0.id == first }!.path, isDirectory: true))
        try await wait { watcher.serviceRevision > beforeRenew && !watcher.busy && watcher.pendingOperations == 0 && watcher.rows.allSatisfy { $0.status.hasPrefix("Updated") } }
        let grant = folder.appendingPathComponent("extra-git-access")
        try FileManager.default.createDirectory(at: grant, withIntermediateDirectories: true)
        controls.choosePermission(renew: false, context: controls.context); chooser?(grant); chooser?(grant)
        try await wait { !watcher.busy && watcher.pendingOperations == 0 && watcher.additionalPermissions(first).count == 1 }
        let permission = watcher.additionalPermissions(first)[0].id
        controls.permission(context: controls.context).wrappedValue = permission
        controls.removePermission(context: controls.context)
        let staleGrantReply = reply; controls.suspend(); controls.activate(); staleGrantReply?(true)
        try require(watcher.additionalPermissions(first).count == 1, "Retired permission question removed access")
        controls.removePermission(context: controls.context); reply?(true)
        try await wait { !watcher.busy && watcher.pendingOperations == 0 && watcher.additionalPermissions(first).isEmpty }
        controls.reconcile()
        controls.chooseFolder = nil; controls.chooseRoot(renew: true, context: controls.context)
        try await wait { watchWindow.attachedSheet is NSOpenPanel }
        let panel = watchWindow.attachedSheet as! NSOpenPanel
        try require(panel.sheetParent === watchWindow, "Chooser used another/global window")
        controls.suspend(); try await wait { watchWindow.attachedSheet == nil }; controls.activate()
        try require(!controls.hasSheet, "Page suspension retained native chooser")
        controls.selection(context: controls.context).wrappedValue = ids
        try await capture(watchWindow, name: "finder-watch-controls-source")
        let refreshPublications = watchPublications
        controls.refresh(context: controls.context)
        try await wait { watchPublications >= refreshPublications + 2 && watcher.pendingOperations == 0 && watcher.rows.allSatisfy { $0.status.hasPrefix("Updated") } }
        controls.remove(context: controls.context); let accepted = reply; accepted?(true); accepted?(true)
        try await wait { watcher.rows.isEmpty && !watcher.busy && watcher.pendingOperations == 0 }
        let snapshot = try JSONDecoder().decode(FinderSnapshot.self, from: Data(contentsOf: cache.url))
        try require(snapshot.roots.isEmpty && snapshot.states.isEmpty, "Batch remove left cached watched roots")
        controls.reconcile(); try require(controls.selected.isEmpty, "Removed rows left selection")
        watchWindow.close(); controls.activate(); controls.chooseRoot(renew: false, context: controls.context)
        try require(!controls.canInteract && !controls.hasSheet, "Closed watcher page revived")
        for (position, root) in roots.enumerated() {
            let repo = GitRepository(root: root, executable: engine), head = try await repo.run(["rev-parse", "HEAD"]).stdout
            try require(head == heads[position] && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == indexes[position], "Watch controls changed repository HEAD/index")
        }
    }
}
