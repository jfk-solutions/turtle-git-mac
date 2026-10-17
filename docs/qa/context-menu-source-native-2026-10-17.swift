// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct FinderMenuSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Context Menu timeout at \(line)")
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func capture(_ window: NSWindow, name: String, folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { throw Failure(description: "PNG missing") }
            try data.write(to: folder.appendingPathComponent(name + "-" + suffix + ".png"))
        }; window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let suite = "TurtleGit.ContextSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitContextSource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("menu-settings.json")
        var publications = 0, notices = 0, notificationsCoherent = true
        let model = FinderContextMenuSettingsModel(defaults: prefs, publish: { value in publications += 1; return try value.write(to: shared) }, notify: {
            notices += 1; notificationsCoherent = notificationsCoherent && FinderMenuSettings.read(from: shared) == FinderMenuSettings.from(defaults: prefs)
        })
        let unknown = (0..<64).map { UInt64(1) << $0 }.first { $0 & FinderMenuEntry.allMask == 0 }!
        model.draft.topLevelMask |= unknown
        let initial = model.context(.primary), oldPaths = model.binding(\.excludedPaths, context: initial)
        model.set(.diff, checked: true, context: initial)
        let extended = model.draft.extendedOnlyMask
        model.selectAll(true, context: initial, expectedMask: model.mask(.primary))
        try require(model.draft.topLevelMask == FinderMenuEntry.allMask | unknown && model.draft.extendedOnlyMask == extended, "Select all lost unknown/page bits")
        model.selectAll(false, context: initial, expectedMask: model.mask(.primary))
        try require(model.draft.topLevelMask == unknown, "Deselect all lost unknown bits")
        model.restore(context: initial)
        try require(model.draft.topLevelMask == FinderMenuEntry.defaultTopMask && model.draft.extendedOnlyMask == extended, "Restore changed another page")
        oldPaths.wrappedValue = "/stale/"
        try require(model.draft.excludedPaths.isEmpty, "Pre-Restore binding remained live")
        model.setActive(.extended)
        model.set(.bisect, checked: true, context: model.context(.extended))
        model.restore(context: model.context(.primary))
        let changedExtended = model.draft.extendedOnlyMask
        model.setActive(nil)
        try require(model.apply() && publications == 1 && notices == 1 && notificationsCoherent && !model.modified, "Hidden authorized Apply/publication order failed")
        model.setActive(.primary)
        let invalid = model.binding(\.excludedPaths, context: model.context(.primary))
        invalid.wrappedValue = "/valid/\nrelative"
        try require(model.validationError?.contains("line 2") == true && !model.apply() && publications == 1 && model.error != nil, "Invalid exclusion reached publication")
        model.cancel(); invalid.wrappedValue = "/late/"
        try require(!model.modified && model.draft.excludedPaths.isEmpty && model.draft.extendedOnlyMask == changedExtended, "Cancel/stale binding failed")
        prefs.set(false, forKey: "ShowContextMenuIcons")
        try require(model.apply() && !model.draft.showIcons && notificationsCoherent, "Advanced icon preference overwritten")
        struct Reentry: Error {}
        var changed: FinderContextMenuSettingsModel!, nestedApply: Bool?, nestedBefore: FinderMenuSettings?
        changed = FinderContextMenuSettingsModel(defaults: prefs, publish: { _ in
            nestedBefore = changed.draft; nestedApply = changed.apply(); changed.cancel()
            if changed.draft != nestedBefore { throw Reentry() }
            changed.draft.excludedPaths = "/newer/"; return true
        }, notify: { preconditionFailure("Rejected publication notified Finder") })
        let persisted = FinderMenuSettings.from(defaults: prefs)
        changed.draft.hideForUnversioned.toggle()
        try require(!changed.apply() && nestedApply == false && changed.error != nil && changed.modified && FinderMenuSettings.from(defaults: prefs) == persisted, "Reentrant publication overwrote current draft/local preferences")
        // The actual source pages share one transaction and production viewport.
        let transaction = SettingsTransaction()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 900), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.title = "Context Menu – TurtleGit"
        defer { transaction.invalidate(); window.close() }
        let viewport = SettingsPageViewport(frame: .zero); window.contentView = viewport
        let primary = NSHostingView(rootView: FinderContextMenuSettingsPage(model: model).environment(\.settingsTransaction, transaction))
        let second = NSHostingView(rootView: FinderContextMenuSettingsPage(model: model, extendedOnly: true).environment(\.settingsTransaction, transaction))
        func install(_ host: NSView) {
            viewport.pageDocument.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: viewport.pageDocument.leadingAnchor), host.trailingAnchor.constraint(equalTo: viewport.pageDocument.trailingAnchor), host.topAnchor.constraint(equalTo: viewport.pageDocument.topAnchor), host.bottomAnchor.constraint(equalTo: viewport.pageDocument.bottomAnchor)])
            window.orderFront(nil); viewport.layoutSubtreeIfNeeded()
        }
        install(primary)
        try await wait { model.window === window && model.activePage == .primary && views(primary).contains { $0 is FinderMenuSettingsList.MenuTable } }
        guard let table = views(primary).compactMap({ $0 as? FinderMenuSettingsList.MenuTable }).first else { throw Failure(description: "Native source list missing") }
        try require(table.numberOfRows == 55 && table.headerView == nil && !table.allowsMultipleSelection, "Source list structure/count")
        for entry in FinderMenuEntry.allCases { try require(entry.availableInFinder && entry.image() != nil, "Source icon/route missing: " + entry.rawValue) }
        try await wait { (table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? FinderMenuSettingsList.MenuRow)?.check.isEnabled == true }
        guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FinderMenuSettingsList.MenuRow else { throw Failure(description: "Native checkbox row missing") }
        let before = model.mask(.primary), oldRow = cell.change
        cell.check.performClick(nil)
        try require(model.mask(.primary) == before ^ FinderMenuEntry.allCases[0].mask && table.selectedRow == 0, "Native checkbox did not toggle/select original row: enabled=\(cell.check.isEnabled), attached=\(cell.check.window === window), cellWindow=\(String(describing: cell.window)), tableWindow=\(table.window === window), modelWindow=\(model.window === window), active=\(String(describing: model.activePage)), selected=\(table.selectedRow), before=\(before), after=\(model.mask(.primary)), state=\(cell.check.state.rawValue), tableFrame=\(table.frame)")
        try await wait { cell.check.state == (model.mask(.primary) & FinderMenuEntry.allCases[0].mask == 0 ? .off : .on) }
        try await wait { (table.delegate as? FinderMenuSettingsList.Coordinator)?.mask == model.mask(.primary) }
        guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { throw Failure(description: "Native Space event missing") }
        table.keyDown(with: space)
        try require(model.mask(.primary) == before, "Native selected-row Space did not toggle")
        model.draft.excludedPaths = "/Users/example/Generated/\n/Volumes/Build*"
        transaction.apply(closeAfter: false); try await wait { !transaction.busy }
        try require(transaction.error == nil && !model.modified && notificationsCoherent, "Actual page registration/Apply failed")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_CONTEXT_SOURCE_CAPTURE"] { try await capture(window, name: "context-menu-source", folder: URL(fileURLWithPath: path)) }
        let stalePaths = model.binding(\.excludedPaths, context: model.context(.primary)), savedMask = model.mask(.primary)
        primary.removeFromSuperview(); install(second)
        try await wait { model.activePage == .extended && views(second).contains { $0 is FinderMenuSettingsList.MenuTable } }
        oldRow?(true); table.keyDown(with: space); stalePaths.wrappedValue = "/hidden/"
        try require(model.mask(.primary) == savedMask && model.draft.excludedPaths != "/hidden/", "Hidden page callbacks remained live")
        let priorPrimary = model.mask(.primary)
        model.selectAll(true, context: model.context(.extended), expectedMask: model.mask(.extended))
        model.restore(context: model.context(.extended))
        try require(model.mask(.extended) == FinderMenuEntry.defaultExtendedMask && model.mask(.primary) == priorPrimary, "Second-page restore changed first page")
        transaction.apply(closeAfter: false); try await wait { !transaction.busy }
        try require(transaction.error == nil && !model.modified && notificationsCoherent, "Shared second-page Apply failed")
        window.title = "Context Menu 2 – TurtleGit"
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_CONTEXT_SOURCE_CAPTURE"] { try await capture(window, name: "context-menu-2-source", folder: URL(fileURLWithPath: path)) }
        let closedContext = model.context(.extended), count = publications
        window.close(); model.set(.diff, checked: true, context: closedContext); model.restore(context: closedContext)
        try require(model.retired && !model.apply() && publications == count, "Closed owner published late")
        print("PASS native Context Menu source: 55 native icon/checkbox rows, source grouping, selected-row Space, page/owner callback guards, shared transaction, validation, unknown bits, Advanced icons, publication ordering and reentrant refusal")
    }
}
