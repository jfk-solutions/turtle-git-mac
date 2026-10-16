import AppKit
import SwiftUI
import TurtleGitCore

private actor SettingsLayoutSMTPFixture: SMTPCredentialStore {
    func login() async throws -> String { "" }
    func store(login:String,password:String) async throws {}
    func clear() async throws {}
}
@main struct SettingsNavigationLayoutVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func views(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func wait(_ stage:String,_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Settings layout timeout: " + stage)
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_LAYOUT_CAPTURES"] else { return }
        let directory = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:350_000_000)
        let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        child.arguments = ["-x","-o","-l",String(window.windowNumber),directory.appendingPathComponent(name + ".png").path]
        try child.run(); child.waitUntilExit(); try require(child.terminationStatus == 0,"Compositor capture failed")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Settings navigation layout failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let captures = ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_LAYOUT_CAPTURES"] != nil
        NSApp.setActivationPolicy(captures ? .accessory : .prohibited)
        let suite = "TurtleGit.SettingsNavigationLayout." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"VersionCheck")
        defer { prefs.removePersistentDomain(forName:suite) }
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false)
        let navigation = SettingsNavigationController(workspace:workspace,appearance:AppAppearance(preferences:prefs),globalOnly:false,preferences:prefs,initialPage:.mergeColors,smtpCredentials:SettingsLayoutSMTPFixture())
        let window = NSWindow(contentRect:.init(x:0,y:0,width:1080,height:820),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentViewController = navigation
        window.alphaValue = captures ? 1 : 0
        defer { navigation.invalidate(); window.contentViewController = nil; window.close(); NSColorPanel.shared.orderOut(nil) }
        navigation.viewDidAppear(); navigation.view.layoutSubtreeIfNeeded()
        try require(navigation.view.bounds.width >= 860 && navigation.view.bounds.height >= 540,"Settings opened at a collapsed minimum size")
        let outline = views(navigation.view).compactMap { $0 as? NSOutlineView }.first!
        let viewport = views(navigation.view).compactMap { $0 as? SettingsPageViewport }.first!
        func row(_ id:String) -> Int? {
            for index in 0..<outline.numberOfRows {
                if outline.view(atColumn:0,row:index,makeIfNecessary:true)?.identifier?.rawValue == "Settings.Page." + id { return index }
            }
            return nil
        }
        func choose(_ id:String) async throws {
            guard let row = row(id) else { throw Failure(description:"Missing row " + id) }
            outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            try await wait("choose " + id) { navigation.view.layoutSubtreeIfNeeded(); return navigation.selected.rawValue == id }
        }
        let heading = views(navigation.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "Settings.PageHeading" }!
        try await wait("nested initial page") { views(navigation.view).compactMap { $0 as? MergeColorChoiceView }.count == 17 }
        try require(navigation.selected == .mergeColors && heading.stringValue == "Colors" && heading.toolTip == "Diff Viewer › Merge Editor › Colors","Nested heading/path missing")
        try require(row("mergeColors") == outline.selectedRow,"Nested initial selection did not expand ancestors")
        // Unrelated collapse survives a repository-context tree rebuild.
        let general = outline.item(atRow:row("general")!)!
        outline.collapseItem(general)
        workspace.root = URL(fileURLWithPath:CommandLine.arguments[1]); navigation.updateRepository()
        try await wait("tree rebuild") { row("mergeColors") == outline.selectedRow && row("remote") != nil }
        try require(heading.stringValue == "Colors" && !outline.isItemExpanded(outline.item(atRow:row("general")!)!),"Rebuild lost nested selection or unrelated collapse")
        // A validation error must reveal a third-level page even after its parent is collapsed.
        outline.expandItem(outline.item(atRow:row("general")!)!)
        try await choose("general")
        outline.collapseItem(outline.item(atRow:row("diff")!)!,collapseChildren:true)
        navigation.transaction.register("fixture.nested",participant:.init(page:.mergeColors,modified:{ true },validate:{ "Nested fixture validation" },apply:{ false },cancel:{}))
        navigation.transaction.apply(closeAfter:false)
        try await wait("nested validation routing") { !navigation.transaction.busy && navigation.selected == .mergeColors && row("mergeColors") == outline.selectedRow }
        try require(heading.stringValue == "Colors" && navigation.transaction.error == "Nested fixture validation","Validation route/heading failed")
        navigation.transaction.unregister("fixture.nested"); navigation.transaction.cancel()
        // Page content scrolls independently while the property-sheet actions stay visible.
        window.setContentSize(.init(width:860,height:540)); navigation.view.layoutSubtreeIfNeeded()
        try await wait("small page viewport") { navigation.view.layoutSubtreeIfNeeded(); return viewport.contentView.bounds.height > 100 && viewport.pageDocument.bounds.height >= 640 }
        let rootBounds = navigation.view.bounds
        for title in ["OK","Cancel","Apply","Help"] {
            let button = views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title == title }!
            let rect = button.convert(button.bounds,to:navigation.view)
            try require(rootBounds.insetBy(dx:-1,dy:-1).contains(rect),"Footer button clipped at small size: " + title)
        }
        try require(viewport.pageDocument.bounds.width >= 600 && viewport.pageDocument.bounds.height > viewport.contentView.bounds.height,"Normal page geometry not retained for scrolling")
        let legalBounds = viewport.contentView.constrainBoundsRect(NSRect(origin:.init(x:90,y:100),size:viewport.contentView.bounds.size))
        viewport.contentView.scroll(to:legalBounds.origin); viewport.reflectScrolledClipView(viewport.contentView)
        let savedOrigin = viewport.contentView.bounds.origin
        try await choose("colors1"); try await choose("mergeColors")
        try await wait("page scroll restoration") { navigation.view.layoutSubtreeIfNeeded(); return abs(viewport.contentView.bounds.origin.y - savedOrigin.y) < 1 }
        try require(abs(viewport.contentView.bounds.origin.x - savedOrigin.x) < 1,"Horizontal page origin lost: saved=\(savedOrigin), restored=\(viewport.contentView.bounds.origin)")
        // Native cells bound long captions and retain full hover/accessibility text.
        let captionRow = row("issueProviders")!, cell = outline.view(atColumn:0,row:captionRow,makeIfNecessary:true) as! NSTableCellView
        cell.layoutSubtreeIfNeeded()
        let text = cell.textField!
        try require(cell.toolTip == "Issue Tracker Integration" && text.toolTip == cell.toolTip && text.lineBreakMode == .byTruncatingTail,"Full sidebar caption unavailable")
        try require(text.frame.maxX <= cell.bounds.maxX + 1 && text.frame.minX >= 0,"Sidebar text escaped native cell")
        // Capture both ends of the actual small page; these are scroll-position diagnostics.
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:appearance)
            viewport.restoreOrigin(.zero); navigation.view.layoutSubtreeIfNeeded()
            try await capture(window,"settings-layout-small-top-" + suffix)
            viewport.restoreOrigin(.init(x:0,y:10000)); navigation.view.layoutSubtreeIfNeeded()
            guard let last = views(navigation.view).compactMap({ $0 as? MergeColorChoiceView }).first(where:{ $0.identifier?.rawValue == "MergeColors.whitespace.foreground" }) else { throw Failure(description:"Missing lower native Merge control") }
            last.scrollToVisible(last.bounds)
            for inner in views(viewport.pageDocument).compactMap({ $0 as? NSScrollView }) {
                if let document = inner.documentView { inner.contentView.scroll(to:.init(x:0,y:max(0,document.bounds.height - inner.contentView.bounds.height))); inner.reflectScrolledClipView(inner.contentView) }
            }
            viewport.pageDocument.scrollToVisible(last.convert(last.bounds,to:viewport.pageDocument))
            navigation.view.layoutSubtreeIfNeeded()
            try require(last.visibleRect.height > 0,"Lower native Merge control cannot be reached by scrolling")
            try await capture(window,"settings-layout-small-bottom-" + suffix)
        }
        // Colors 1 supplies an actual AppKit Restore Default button. Check the
        // common viewport with it rather than assuming SwiftUI vends NSButtons.
        try await choose("colors1")
        try await wait("native Restore Default") { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? NSButton }.contains { $0.title == "Restore Default" } }
        let restore = views(navigation.view).compactMap { $0 as? NSButton }.first { $0.title == "Restore Default" }!
        restore.scrollToVisible(restore.bounds)
        viewport.pageDocument.scrollToVisible(restore.convert(restore.bounds,to:viewport.pageDocument))
        navigation.view.layoutSubtreeIfNeeded()
        try require(restore.visibleRect.height > 0 && restore.visibleRect.width > 0,"Lower native page action cannot be reached by scrolling")
        try await choose("mergeColors")
        window.setContentSize(.init(width:1080,height:820)); navigation.view.layoutSubtreeIfNeeded()
        viewport.restoreOrigin(.zero); navigation.view.layoutSubtreeIfNeeded()
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:appearance)
            try await capture(window,"settings-layout-merge-colors-" + suffix)
        }
        navigation.invalidate()
        let closedSelection = navigation.selected
        outline.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        navigation.updateRepository()
        try require(navigation.selected == closedSelection && !navigation.canDismiss && viewport.pageDocument.subviews.isEmpty,"Retired navigation recreated a page")
        window.close()
        print("PASS: recursive nested Settings headings/initial selection/rebuild/error reveal, retained expansion and per-page scroll, small-window footer/content access, bounded native sidebar captions/tooltips, retired navigation fences; owned window/panel closed")
    }
}
