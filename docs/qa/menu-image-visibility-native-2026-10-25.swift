// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main enum MenuImageVisibilityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Target: NSObject {
        var count = 0
        @objc func choose(_ sender: NSMenuItem) { count += 1 }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
    @MainActor static func visible(_ item: NSMenuItem) throws {
        if #available(macOS 27.0, *) {
            try require((item.value(forKey:"preferredImageVisibility") as? NSNumber)?.intValue == 1, "Image visibility not explicit: " + item.title)
        }
    }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Native menu did not settle")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] {
        // Reuse the copied Objective-C traversal required by decorated SwiftUI
        // report views; do not lazily bridge AppKit's live subview collection.
        let selector = #selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter = unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children = getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result = [view]
        for index in 0..<children.count {
            let object = children.object(at:index) as AnyObject
            guard let native = object as? NSObject, native.isKind(of:NSView.self) else { continue }
            result += views(unsafeBitCast(object,to:NSView.self))
        }
        return result
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let delegate = TurtleGitApplicationDelegate()
        defer { delegate.retireMenuImageVisibility() }
        delegate.installMenuImageVisibility(); delegate.installMenuImageVisibility()
        let suite = "TurtleGit.MenuImages." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let target = Target(), menu = NSMenu(), parent = NSMenuItem(title:"Commands",action:nil,keyEquivalent:""), nested = NSMenu()
        parent.submenu = nested; parent.image = MenuIcon.turtle.contextImage(defaults:prefs); menu.addItem(parent)
        let item = NSMenuItem(title:"Compare",action:#selector(Target.choose(_:)),keyEquivalent:"d")
        item.target = target; item.state = .mixed; item.tag = 71; item.representedObject = "captured"; nested.addItem(item)
        // SwiftUI and lazy native delegates can assign artwork after insertion.
        item.image = MenuIcon.compare.contextImage(defaults:prefs)
        try visible(parent); try visible(item)
        try require(item.target === target && item.action == #selector(Target.choose(_:)) && item.state == .mixed && item.tag == 71 && item.representedObject as? String == "captured" && item.keyEquivalent == "d", "Menu observer changed command semantics")
        _ = NSApp.sendAction(item.action!,to:item.target,from:item); try require(target.count == 1,"Observed action did not dispatch exactly once")
        prefs.set(false,forKey:"ShowAppContextMenuIcons")
        let disabled = NSMenuItem(title:"No artwork requested",action:nil,keyEquivalent:"")
        disabled.image = MenuIcon.copy.contextImage(defaults:prefs); nested.addItem(disabled)
        MenuImageVisibility.apply(to:menu); try require(disabled.image == nil,"Visibility policy manufactured disabled artwork")
        delegate.retireMenuImageVisibility()
        if #available(macOS 27.0, *) {
            let after = NSMenuItem(title:"Retired observer",action:nil,keyEquivalent:""); after.image = MenuIcon.copy.image(); menu.addItem(after)
            try require((after.value(forKey:"preferredImageVisibility") as? NSNumber)?.intValue == 0,"Retired observer changed a later menu")
        }
        delegate.installMenuImageVisibility()
        prefs.removeObject(forKey:"ShowAppContextMenuIcons")
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Menu QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let file = root.appendingPathComponent("file.txt")
        for number in 1...2 { try Data("\(number)\n".utf8).write(to:file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message:"Menu \(number)") }
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        prefs.set(false,forKey:"Gravatar"); prefs.set(false,forKey:"LogIncludeWorkingTreeChanges")
        let owner = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), model = owner.model, window = owner.window!
        defer { owner.close() }
        window.alphaValue = 0; window.setFrameOrigin(NSPoint(x:-30000,y:-30000)); window.orderFront(nil)
        try await wait { window.contentView?.layoutSubtreeIfNeeded(); return !model.busy && model.entries.count == 2 }
        guard let table = views(window.contentView!).compactMap({$0 as? HistoryTableView}).first,
              let coordinator = table.delegate as? RevisionTable.Coordinator, let popup = table.menu else { throw Failure(description:"Actual Log menu missing") }
        model.select([model.entries[0].hash]); try await wait { !model.files.isEmpty }
        coordinator.menuNeedsUpdate(popup)
        let commands = all(popup).filter { !$0.isSeparatorItem }
        try require(commands.count > 15,"Actual Log context menu unexpectedly narrow")
        for command in commands { try require(command.image != nil,"Actual Log action has no artwork: " + command.title); try visible(command) }
        guard let header=coordinator.headerMenu,let author=table.tableColumn(withIdentifier:.init("author")) else {throw Failure(description:"Actual Log column menu missing")}
        coordinator.menuNeedsUpdate(header)
        for command in all(header) where !command.isSeparatorItem {try require(command.image != nil,"Actual Log header has no artwork: "+command.title);try visible(command)}
        let originalHidden=author.isHidden
        prefs.set(false,forKey:"ShowAppContextMenuIcons");coordinator.menuNeedsUpdate(header)
        try require(all(header).filter{!$0.isSeparatorItem}.allSatisfy{$0.image==nil},"Header ignored private icon preference")
        guard let toggle=header.items.first(where:{$0.identifier?.rawValue=="Log.Columns.author"}),let action=toggle.action else {throw Failure(description:"Author column command missing")}
        try require(toggle.isEnabled && toggle.target != nil && toggle.representedObject != nil,"Icon preference changed column action ownership")
        _=NSApp.sendAction(action,to:toggle.target,from:toggle)
        try await wait{author.isHidden != originalHidden}
        try require(prefs.bool(forKey:"Log.Column.Visible.author")==originalHidden,"Column visibility did not persist in owner preferences")
        _=NSApp.sendAction(action,to:toggle.target,from:toggle)
        try require(author.isHidden != originalHidden,"Consumed header action replayed")
        prefs.set(true,forKey:"ShowAppContextMenuIcons");coordinator.menuNeedsUpdate(header)
        guard let restore=header.items.first(where:{$0.identifier?.rawValue=="Log.Columns.author"}),let restoreAction=restore.action else {throw Failure(description:"Fresh author column command missing")}
        try require(restore.image != nil && restore.state == (author.isHidden ? .off:.on),"Rebuilt header lost icon or column state")
        _=NSApp.sendAction(restoreAction,to:restore.target,from:restore)
        try await wait{author.isHidden==originalHidden}
        prefs.set(false,forKey:"ShowAppContextMenuIcons"); coordinator.menuNeedsUpdate(popup)
        try require(all(popup).filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil },"Actual Log ignored private icon preference")
        prefs.set(true,forKey:"ShowAppContextMenuIcons"); coordinator.menuNeedsUpdate(popup)
        for command in all(popup) where !command.isSeparatorItem { try require(command.image != nil,"Rebuilt Log action lost artwork"); try visible(command) }
        owner.close()
        try await wait { LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeActionReads == 0 }
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Menu checks changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Menu checks changed index")
        print("PASS: native menu visibility, lazy images, preference isolation, observer retirement, actual Log command tree and column action persistence/replay guards")
    }
}
