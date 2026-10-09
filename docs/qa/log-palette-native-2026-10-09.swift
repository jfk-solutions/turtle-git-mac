import AppKit
import SwiftUI
import TurtleGitCore

@main struct LogPaletteVerification {
    @MainActor static func settle(_ host: NSView, until condition: () -> Bool) async throws {
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(condition(), "Native Log color control timeout")
    }
    @MainActor static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,type) } }
    static func channels(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent,c.greenComponent,c.blueComponent].map { Int(($0*255).rounded()) }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); NSApp.appearance = NSAppearance(named: .aqua)
        let suite = "TurtleGit.LogPalette.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (name,value) in [("user.name","Palette QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",name,value]) }
        _ = try await repo.run(["commit","--allow-empty","-m","palette subject"])
        for name in ["refs/heads/side","refs/remotes/origin/main","refs/tags/v1","refs/stash","refs/bisect/good-abc","refs/bisect/bad","refs/bisect/skip-abc","refs/notes/custom","refs/custom/value"] { _ = try await repo.run(["update-ref",name,"HEAD"]) }
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let entries = try await repo.log()
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs); model.busy = true; model.entries = entries; model.selected = [entries[0].hash]; model.graph = CommitGraph.project(entries, walk: HistoryWalkOptions()).graph
        defer { model.invalidate() }
        let host = NSHostingView(rootView: RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 1200,height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        try await settle(host) { !descendants(host,NSTableView.self).isEmpty }
        let table = descendants(host,NSTableView.self).first!
        func message() -> NSAttributedString {
            let column = table.tableColumns.firstIndex { $0.identifier.rawValue == "message" }!
            return (table.view(atColumn: column,row: 0,makeIfNecessary: true) as! NSTableCellView).textField!.attributedStringValue
        }
        func labelColor(_ label: String, foreground: Bool = false) -> NSColor {
            let value = message(), range = (value.string as NSString).range(of: " " + label + " ")
            precondition(range.location != NSNotFound, "Missing actual ref label " + label)
            return value.attribute(foreground ? .foregroundColor : .backgroundColor, at: range.location, effectiveRange: nil) as! NSColor
        }
        precondition(table.numberOfRows == 1 && !table.autosaveTableColumns && table.selectedRowIndexes == IndexSet(integer: 0))
        for ref in entries[0].references {
            let role = LogColorRole.reference(ref)
            precondition(channels(labelColor(ref.label)) == role.rgb, "Actual label role " + ref.name)
            precondition(labelColor(ref.label).alphaComponent == 1)
            let expected = role.rgb[0]*30 + role.rgb[1]*59 + role.rgb[2]*11 <= 12800 ? [255,255,255] : [0,0,0]
            precondition(channels(labelColor(ref.label,foreground: true)) == expected)
        }
        let graphIndex = table.tableColumns.firstIndex { $0.identifier.rawValue == "graph" }!
        let graph = table.view(atColumn: graphIndex,row: 0,makeIfNecessary: true) as! GraphCell
        precondition(graph.preferences === prefs && graph.graph != nil)
        let settings = LogColorSettingsModel(preferences: prefs), updates = StatusColorUpdates.shared, oldRevision = updates.revision
        settings.set(.tag,rgb: [3,127,249]); settings.set(.branchLine7,rgb: [10,20,30]); settings.setLineWidth(5); settings.setNodeSize(20); settings.apply()
        precondition(updates.revision == oldRevision + 1)
        try await settle(host) { channels(labelColor("v1")) == [3,127,249] }
        precondition(channels(labelColor("v1",foreground: true)) == [255,255,255] && table.selectedRowIndexes == IndexSet(integer: 0) && model.selected == [entries[0].hash])
        let freshGraph = table.view(atColumn: graphIndex,row: 0,makeIfNecessary: true) as! GraphCell
        precondition(freshGraph.preferences === prefs && LogColorPreferences.load(freshGraph.preferences).lineWidth == 5 && LogColorPreferences.load(freshGraph.preferences).nodeSize == 20)
        let bitmap = freshGraph.bitmapImageRepForCachingDisplay(in: freshGraph.bounds)!
        freshGraph.cacheDisplay(in: freshGraph.bounds,to: bitmap)
        precondition(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        // Public native ColorWell target/action and AppKit button acceptance.
        let settingsHost = NSHostingView(rootView: LogColorsSettings(model: settings))
        let settingsWindow = NSWindow(contentRect: .init(x: 0,y: 0,width: 590,height: 830),styleMask: [.titled],backing: .buffered,defer: false)
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = settingsHost; defer { settingsWindow.close() }
        try await settle(settingsHost) { descendants(settingsHost,NSColorWell.self).count == 14 && descendants(settingsHost,NSButton.self).contains { $0.title == "Apply" } }
        let wells = descendants(settingsHost,NSColorWell.self), buttons = descendants(settingsHost,NSButton.self)
        precondition(buttons.filter { $0.title == "Default" }.count == 14)
        let apply = buttons.first { $0.title == "Apply" }!, cancel = buttons.first { $0.title == "Cancel" }!, restore = buttons.first { $0.title == "Restore Defaults" }!
        precondition(!apply.isEnabled && !cancel.isEnabled)
        wells[0].color = NSColor(srgbRed: 10.0/255,green: 20.0/255,blue: 30.0/255,alpha: 1)
        precondition(NSApp.sendAction(wells[0].action!,to: wells[0].target,from: wells[0]))
        precondition(settings.draft.rgb(.currentBranch) == [10,20,30])
        try await settle(settingsHost) { apply.isEnabled && cancel.isEnabled }
        cancel.performClick(nil); precondition(!settings.changed && settings.draft.rgb(.currentBranch) == LogColorRole.currentBranch.rgb)
        restore.performClick(nil); precondition(settings.changed && settings.draft.lineWidth == 2 && settings.draft.nodeSize == 10 && prefs.integer(forKey: LogColorPreferences.lineWidthKey) == 5)
        try await settle(settingsHost) { apply.isEnabled }
        apply.performClick(nil)
        precondition(prefs.integer(forKey: LogColorPreferences.lineWidthKey) == 2 && prefs.integer(forKey: LogColorPreferences.nodeSizeKey) == 10)
        try await settle(host) { channels(labelColor("v1")) == LogColorRole.tag.rgb }
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout
        precondition(finalHead == head)
        // Real active custom-term session: Log metadata reaches role routing.
        _ = try await repo.run(["commit","--allow-empty","-m","middle"])
        _ = try await repo.run(["commit","--allow-empty","-m","last"])
        _ = try await repo.run(["bisect","start","--term-good=old","--term-bad=new","HEAD","HEAD~2"])
        let bisectHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let bisectModel = LogWindowModel(repository: repo, access: nil, selecting: true, labelDefaults: prefs)
        defer { bisectModel.invalidate() }
        bisectModel.allBranches = true
        bisectModel.reload()
        for _ in 0..<1000 { if !bisectModel.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!bisectModel.busy && bisectModel.error == nil && bisectModel.bisectActive, bisectModel.error ?? "Bisect metadata timeout")
        precondition(bisectModel.bisectGoodTerm == "old" && bisectModel.bisectBadTerm == "new")
        let custom = bisectModel.entries.flatMap(\.references).filter { $0.name.hasPrefix("refs/bisect/old") || $0.name.hasPrefix("refs/bisect/new") }
        precondition(custom.count >= 2)
        for ref in custom { precondition(LogColorRole.reference(ref,goodTerm: bisectModel.bisectGoodTerm,badTerm: bisectModel.bisectBadTerm) == (ref.name.hasPrefix("refs/bisect/old") ? .bisectGood : .bisectBad)) }
        let afterLogHead = try await repo.run(["rev-parse","HEAD"]).stdout
        precondition(afterLogHead == bisectHead)
        _ = try await repo.run(["bisect","reset"])
        precondition(!window.isVisible && !settingsWindow.isVisible)
        print("PASS: real Git reference roles, opaque native attributed backgrounds and contrast text; existing hidden RevisionTable reloads after Apply/default restore; private graph preferences reach real GraphCell and offscreen drawing executes; real active custom old/new bisect metadata and role routing without Log changing HEAD; fourteen native color wells/default buttons, actual Cancel/Apply/Restore actions, draft-only restore and private preferences/window cleanup. No displayed pixels, physical gestures, exact graph topology or signed acceptance claimed.")
    }
}
