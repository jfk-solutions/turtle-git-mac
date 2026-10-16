import AppKit
import SwiftUI
import TurtleGitCore

private actor SettingsColorSMTPFixture: SMTPCredentialStore {
    func login() async throws -> String { "" }
    func store(login:String,password:String) async throws {}
    func clear() async throws {}
}
enum TwoPaneEngineVerification {
    @MainActor static func wait(_ ready:()->Bool) async throws { try await SettingsColorChoicesVerification.wait("Merge Colors regression",ready) }
}
@main struct SettingsColorChoicesVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func views(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func wait(_ stage:String,_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Settings colors timeout: " + stage)
    }
    @MainActor static func send(_ item:NSMenuItem) throws {
        try require(NSApp.sendAction(item.action!,to:item.target,from:item),"Native menu action did not route")
    }
    @MainActor static func edit(_ view:MergeColorChoiceView,_ rgb:UInt32) throws {
        view.well.color = NSColor(srgbRed:CGFloat(rgb >> 16 & 255)/255,green:CGFloat(rgb >> 8 & 255)/255,blue:CGFloat(rgb & 255)/255,alpha:0.2)
        try require(NSApp.sendAction(view.well.action!,to:view.well.target,from:view.well),"Native RGB action did not route")
        try require(view.well.color.alphaComponent == 1,"Source RGB retained opacity")
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_COLOR_CAPTURES"] else { return }
        let directory = URL(fileURLWithPath:path); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:350_000_000)
        let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
        child.arguments = ["-x","-o","-l",String(window.windowNumber),directory.appendingPathComponent(name + ".png").path]
        try child.run(); child.waitUntilExit(); try require(child.terminationStatus == 0,"Compositor capture failed")
    }
    @MainActor static func main() async {
        do { try await verify(); try await MergeColorsNativeVerification.verify(); print("PASS: connected Settings color controls and retained Merge Colors regression") } catch { fputs("Settings color choices failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let captures = ProcessInfo.processInfo.environment["TURTLEGIT_SETTINGS_COLOR_CAPTURES"] != nil
        NSApp.setActivationPolicy(captures ? .accessory : .prohibited)
        let suite = "TurtleGit.SettingsColorChoices." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); MergePalette.reload() }
        prefs.set(false,forKey:"VersionCheck")
        var initialStatus = StatusColorPreferences(); initialStatus.set(.conflict,rgb:[18,52,86]); initialStatus.save(prefs); initialStatus = .load(prefs)
        var initialLog = LogColorPreferences(); initialLog.set(.currentBranch,rgb:[69,103,137]); initialLog.set(.branchLine1,rgb:[35,69,103]); initialLog.save(prefs); initialLog = .load(prefs)
        var initialBlame = GitBlamePresentation(); initialBlame.recentColor = 0x112233; initialBlame.darkRecentColor = 0x223344; initialBlame.save(to:prefs)
        var initialUDiff = UnifiedDiffAppearance(); initialUDiff.light[.added] = .init(0x445566,0x778899); initialUDiff.dark[.added] = .init(0x334455,0x556677); initialUDiff.save(to:prefs)
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false)
        let navigation = SettingsNavigationController(workspace:workspace,appearance:AppAppearance(preferences:prefs),globalOnly:true,preferences:prefs,smtpCredentials:SettingsColorSMTPFixture())
        let window = NSWindow(contentRect:.init(x:0,y:0,width:1040,height:860),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "TurtleGit Settings"; window.isReleasedWhenClosed = false; window.contentViewController = navigation
        window.alphaValue = captures ? 1 : 0
        defer { navigation.invalidate(); window.contentViewController = nil; window.close(); NSColorPanel.shared.orderOut(nil) }
        navigation.viewDidAppear()
        let outline = views(navigation.view).compactMap { $0 as? NSOutlineView }.first!
        outline.expandItem(nil,expandChildren:true)
        func choose(_ title:String,_ count:Int) async throws {
            for row in 0..<outline.numberOfRows {
                if let view = outline.view(atColumn:0,row:row,makeIfNecessary:true), views(view).compactMap({ $0 as? NSTextField }).contains(where:{ $0.stringValue == title }) {
                    outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
                    try await wait(title) { navigation.view.layoutSubtreeIfNeeded(); return views(navigation.view).compactMap { $0 as? MergeColorChoiceView }.count == count }
                    return
                }
            }
            throw Failure(description:"Missing Settings page " + title)
        }
        func choice(_ id:String) throws -> MergeColorChoiceView {
            guard let value = views(navigation.view).compactMap({ $0 as? MergeColorChoiceView }).first(where:{ $0.identifier?.rawValue == id }) else { throw Failure(description:"Missing swatch " + id) }
            return value
        }
        func palette(_ id:String,_ dark:Bool) async throws {
            let control = views(navigation.view).compactMap { $0 as? NSSegmentedControl }.first { $0.identifier?.rawValue == id }!
            control.selectedSegment = dark ? 1 : 0; try require(NSApp.sendAction(control.action!,to:control.target,from:control),"Palette action did not route")
            try await Task.sleep(nanoseconds:30_000_000); navigation.view.layoutSubtreeIfNeeded()
        }
        let pages:[(String,Int,String,String)] = [("Colors 1",8,"StatusColors.conflict","colors-1"),("Colors 2",5,"LogColors.CurrentBranch","colors-2"),("Colors 3",8,"LogColors.BranchLine1","colors-3"),("TurtleGitBlame",2,"BlameColors.recent","blame-colors"),("Unified Diff",12,"UnifiedDiffColors.added.foreground","unified-colors"),("Colors",17,"MergeColors.added.foreground","merge-colors")]
        var detached:MergeColorChoiceView?
        let panel = NSColorPanel.shared, originalAlpha = panel.showsAlpha
        for (title,count,id,name) in pages {
            try await choose(title,count)
            let all = views(navigation.view).compactMap { $0 as? MergeColorChoiceView }
            for view in all {
                try require(view.choices.items.map(\.title) == ["Automatic","","More colors…"] && view.choices.items[0].image != nil,"Missing source menu/default swatch")
                try require(view.well.isEnabled && view.arrow.isEnabled,"Visible swatch disabled")
                let rect = view.convert(view.bounds,to:navigation.view)
                try require(rect.minX >= 0 && rect.maxX <= navigation.view.bounds.width + 1 && view.well.bounds.width > 0,"Swatch horizontal overflow: page=\(title) id=\(view.identifier?.rawValue ?? "none") rect=\(rect) root=\(navigation.view.bounds) viewports=\(views(navigation.view).compactMap { $0 as? SettingsPageViewport }.map { "clip=\($0.contentView.bounds) doc=\($0.pageDocument.frame)" })")
            }
            let target = try choice(id)
            try send(target.choices.items[0]); try await Task.sleep(nanoseconds:30_000_000)
            if title == "Colors 1" {
                try await wait("Automatic draft") { navigation.transaction.modified }
                target.presentPanel = { $0.orderOut(nil) }; try send(target.choices.items[2]); panel.orderOut(nil)
                try require(target.well.isActive && !panel.showsAlpha,"More colors did not own RGB panel"); detached = target
            } else if let detached {
                try require(!detached.well.isActive && panel.showsAlpha == originalAlpha,"Page detachment leaked panel ownership")
                try send(detached.choices.items[0]); try send(detached.choices.items[2])
                try require(!detached.well.isActive,"Detached swatch reclaimed panel")
            }
            for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance = NSAppearance(named:appearance); navigation.view.layoutSubtreeIfNeeded()
                try await capture(window,"settings-" + name + "-" + suffix)
            }
        }
        try require(StatusColorPreferences.load(prefs) == initialStatus && LogColorPreferences.load(prefs) == initialLog && GitBlamePresentation.load(from:prefs) == initialBlame && UnifiedDiffAppearance.load(from:prefs) == initialUDiff,"Automatic persisted before Apply")
        navigation.transaction.cancel(); try await wait("Cancel") { !navigation.transaction.modified }
        try await choose("Colors 1",8); let status = try choice("StatusColors.conflict")
        try require(SettingsColorValue.packed(initialStatus.rgb(.conflict)) == 0x123456,"Initial status seed mismatch")
        try edit(status,0xabcdef)
        try await choose("Colors 2",5); try edit(choice("LogColors.CurrentBranch"),0x102030)
        try await choose("Colors 3",8); try edit(choice("LogColors.BranchLine1"),0x405060)
        try await choose("TurtleGitBlame",2); try edit(choice("BlameColors.recent"),0x123456)
        try await palette("BlameColors.Palette",true); try edit(choice("BlameColors.recent"),0x654321)
        try await choose("Unified Diff",12); try edit(choice("UnifiedDiffColors.added.foreground"),0x345678)
        try await palette("UnifiedDiffColors.Palette",true); try edit(choice("UnifiedDiffColors.added.background"),0x765432)
        try await choose("Colors",17); try await palette("MergeColors.Palette",false); try edit(choice("MergeColors.added.foreground"),0x13579b)
        try await wait("Draft edits") { navigation.transaction.modified }
        navigation.transaction.apply(closeAfter:false); try await wait("Cached page Apply") { !navigation.transaction.busy && !navigation.transaction.modified }
        try require(navigation.transaction.error == nil,"Apply failed")
        try require(StatusColorPreferences.load(prefs).rgb(.conflict) == [171,205,239],"Status draft not applied")
        let log = LogColorPreferences.load(prefs)
        try require(log.rgb(.currentBranch) == [16,32,48] && log.rgb(.branchLine1) == [64,80,96] && log.rgb(.tag) == initialLog.rgb(.tag),"Cached Log pages overwrote role sets")
        let blame = GitBlamePresentation.load(from:prefs)
        try require(blame.recentColor == 0x123456 && blame.darkRecentColor == 0x654321 && blame.oldColor == initialBlame.oldColor,"Blame palette isolation failed")
        let udiff = UnifiedDiffAppearance.load(from:prefs)
        try require(udiff.colors(.added,dark:false).foreground == 0x345678 && udiff.colors(.added,dark:false).background == 0x778899 && udiff.colors(.added,dark:true).background == 0x765432 && udiff.colors(.added,dark:true).foreground == 0x334455,"Unified palette/channel isolation failed")
        try require(MergeColorPreferences.load(from:prefs).colors(.added,dark:false).foreground == 0x13579b,"Merge color draft not applied")
        // Disabling a live representable releases the panel and rejects late actions.
        let owner = NSWindow(contentRect:.init(x:0,y:0,width:200,height:50),styleMask:[.titled],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed = false
        let control = MergeColorChoiceView(); owner.contentView = control
        var edits = 0
        control.configure(value:0x112233,automatic:0,label:"Fixture",identifier:"fixture",namespace:"Fixture",changed:{ _ in edits += 1 })
        control.presentPanel = { $0.orderOut(nil) }; try send(control.choices.items[2]); panel.orderOut(nil)
        control.configure(value:0x112233,automatic:0,label:"Fixture",identifier:"fixture",namespace:"Fixture",enabled:false,changed:{ _ in edits += 1 })
        try send(control.choices.items[0]); try send(control.choices.items[2])
        try require(edits == 0 && !control.well.isActive && !control.well.isEnabled && panel.showsAlpha == originalAlpha,"Disabled picker accepted late actions/leaked panel")
        owner.close(); control.retire()
        control.configure(value:0,automatic:0,label:"Retired",identifier:"fixture",changed:{ _ in edits += 1 })
        try send(control.choices.items[0]); try require(edits == 0 && !control.well.isEnabled,"Retired picker revived")
        navigation.invalidate(); window.close()
        print("PASS: six native color Settings pages, source swatch/menu counts, Automatic and opaque sRGB drafts, cached-page Apply/Cancel and role isolation, independent Blame/Unified palettes, panel detachment/disable/retirement; owned windows/panel closed")
    }
}
