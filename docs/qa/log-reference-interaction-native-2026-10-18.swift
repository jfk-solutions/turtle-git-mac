// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum LogReferenceInteractionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reference interaction timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func paint(_ field: LogReferenceTextField) throws {
        guard let cell = field.referenceCell else { throw Failure(description: "Reference painter missing") }
        let width = max(1, Int(ceil(field.bounds.width))), height = max(1, Int(ceil(field.bounds.height)))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        cell.drawInterior(withFrame: field.bounds, in: field)
    }
    @MainActor static func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
    @MainActor static func ax(_ object:Any,_ name:String)->Any? {
        guard let element=object as? NSObject else{return nil}
        let selector=NSSelectorFromString(name)
        if element.responds(to:selector),let value=element.perform(selector)?.takeUnretainedValue(){return value}
        // AppKit's actual NSTableRow/NSTableColumn accessibility proxies still
        // publish legacy attributes. Traverse them rather than treating the
        // absence of a modern selector as an empty native table subtree.
        let attributes=["accessibilityRole":"AXRole","accessibilityChildren":"AXChildren","accessibilityValue":"AXValue","accessibilityIdentifier":"AXIdentifier","accessibilityHelp":"AXHelp","accessibilityLabel":"AXDescription"]
        guard let attribute=attributes[name] else{return nil}
        let getter=NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to:getter) else{return nil}
        let names=NSSelectorFromString("accessibilityAttributeNames")
        if element.responds(to:names),let supported=element.perform(names)?.takeUnretainedValue() as? [String],!supported.contains(attribute){return nil}
        return element.perform(getter,with:attribute)?.takeUnretainedValue()
    }
    @MainActor static func axTree(_ root:Any)->[NSObject] {
        var seen=Set<ObjectIdentifier>(),result=[NSObject]()
        func visit(_ object:Any,_ depth:Int) {
            guard depth<24,result.count<2000,let value=object as? NSObject,seen.insert(ObjectIdentifier(value)).inserted else{return}
            result.append(value)
            let children=ax(value,"accessibilityChildren") as? [Any] ?? []
            for child in NSAccessibility.unignoredChildren(from:children){visit(child,depth+1)}
        }
        for value in NSAccessibility.unignoredChildrenForOnlyChild(from:root){visit(value,0)}
        return result
    }
    @MainActor static func axSummary(_ object:NSObject)->String {
        let attributes=["accessibilityRole","accessibilityValue","accessibilityIdentifier","accessibilityHelp","accessibilityLabel"].map{ $0+"="+String(reflecting:ax(object,$0)) }
        return String(describing:type(of:object))+"@"+String(describing:ObjectIdentifier(object))+" "+attributes.joined(separator:" ")+" children="+String((ax(object,"accessibilityChildren") as? [Any])?.count ?? -1)
    }
    @MainActor static func messageElements(_ root:Any,text:String)->[NSAccessibilityElement] {
        axTree(root).compactMap{$0 as? NSAccessibilityElement}.filter {
            $0.accessibilityRole() == .staticText && ($0.accessibilityValue() as? String)==text
        }
    }
    @MainActor static func semanticMessage(_ table:NSTableView,row:Int,text:String,hash:String) throws->NSAccessibilityElement {
        if let column=table.tableColumns.firstIndex(where:{$0.identifier.rawValue.lowercased()=="message"}){_=table.view(atColumn:column,row:row,makeIfNecessary:true)}
        table.layoutSubtreeIfNeeded()
        guard let rowView=table.rowView(atRow:row,makeIfNecessary:true) else{throw Failure(description:"Actual AX row view missing")}
        rowView.layoutSubtreeIfNeeded()
        let tree=axTree(table),rowTree=axTree(rowView)
        guard let message=messageElements(rowView,text:text).first else {
            let diagnostic=tree.compactMap { value->String? in
                guard let role=ax(value,"accessibilityRole") as? String else{return nil}
                return role+":"+String(reflecting:ax(value,"accessibilityValue"))+":"+String(reflecting:ax(value,"accessibilityLabel"))
            }
            throw Failure(description:"Actual unignored native table AX tree omitted message \(String(reflecting:text)); tree=\(diagnostic.prefix(100)) rowNodes=\(rowTree.count)")
        }
        try require(!message.accessibilityFrame().isEmpty,"Accessible subject has no actual native geometry")
        let identity=[message.accessibilityIdentifier(),message.accessibilityHelp(),message.accessibilityLabel()].compactMap{$0}.joined(separator:" ")
        try require(identity.contains(hash) && message.accessibilityHelp()==hash,"Accessible subject lost exact commit identity: "+identity)
        try require(tree.contains{($0 as? NSAccessibilityElement) === message},"Actual row message is omitted from unignored table AX subtree: row=\(row), expectedText=\(String(reflecting:text)), expectedHash=\(hash), expectedElement=\(axSummary(message)), table=\(axSummary(table)), rowView=\(axSummary(rowView)), tree=\(tree.prefix(100).map{axSummary($0)}), rowTree=\(rowTree.prefix(30).map{axSummary($0)})")
        return message
    }
    @MainActor static func replayMessages(repo:GitRepository,preferences:UserDefaults)async throws {
        let hash=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        var plan=try await repo.cherryPickPlan(revisions:[hash])
        guard var duplicate=plan.entries.first else{throw Failure(description:"Actual replay plan entry missing")}
        duplicate.occurrence=1;plan.entries.append(duplicate)
        let oldFull=preferences.object(forKey:"FullCommitMessageOnLogLine")
        preferences.set(true,forKey:"FullCommitMessageOnLogLine")
        defer{if let oldFull{preferences.set(oldFull,forKey:"FullCommitMessageOnLogLine")}else{preferences.removeObject(forKey:"FullCommitMessageOnLogLine")}}
        let model=RebaseWindowModel(repository:repo,access:nil,messageDefaults:preferences);model.plan=plan
        let window=NSWindow(contentRect:.init(x:-24000,y:-24000,width:1200,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0
        window.contentView=NSHostingView(rootView:RebaseReplayTable(model:model,dates:HistoryDateSettings(useSystemLocale:false)))
        defer{model.retire();window.contentView=nil;window.close()}
        window.orderBack(nil)
        try await wait{window.contentView?.layoutSubtreeIfNeeded();return views(window.contentView!).compactMap{$0 as? RebaseReplayNativeTable}.first?.numberOfRows==2}
        guard let table=views(window.contentView!).compactMap({$0 as? RebaseReplayNativeTable}).first else{throw Failure(description:"Actual replay native table missing")}
        let first=try semanticMessage(table,row:0,text:"Reference subject  body ",hash:hash),second=try semanticMessage(table,row:1,text:"Reference subject  body ",hash:hash)
        try require(first !== second && first.accessibilityIdentifier() != second.accessibilityIdentifier(),"Duplicate replay hash occurrences share semantic identity")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try require(model.selection==[model.entries[0].id],"Actual replay row selection lost occurrence identity")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try require(model.selection==[model.entries[1].id],"Second duplicate replay row selected the first occurrence")
        plan.entries.removeLast();model.plan=plan
        try await wait{window.contentView?.layoutSubtreeIfNeeded();return table.numberOfRows==1}
        try require(first.accessibilityFrame().isEmpty && first.accessibilityValue()==nil,"Removed duplicate occurrence retained semantic text/geometry after real provider update")
        let rebound=try semanticMessage(table,row:0,text:"Reference subject  body ",hash:hash)
        try require(rebound.accessibilityIdentifier() != first.accessibilityIdentifier(),"Replay reuse did not replace removed occurrence identity")
        model.retire()
        try require(rebound.accessibilityFrame().isEmpty && rebound.accessibilityValue()==nil,"Retired replay owner retained message content/geometry")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (name, value) in [("user.name", "Reference QA"), ("user.email", "reference@example.invalid"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", name, value]) }
        let file = root.appendingPathComponent("file"); try Data("older\n".utf8).write(to: file)
        try await repo.stage(["file"]); _ = try await repo.commit(message: "Plain subject without reference")
        try Data("unchanged\n".utf8).write(to:file)
        try await repo.stage(["file"]); _ = try await repo.commit(message: "Reference subject\n\nbody")
        _ = try await repo.run(["config", "branch.main.description", "Main description\nsecond line"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), original = try Data(contentsOf: file)
        let suite = "TurtleGit.LogReferenceInteraction." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!, clipboard = NSPasteboard.withUniqueName()
        prefs.set(false, forKey: "Gravatar"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        let owner = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false), model = owner.model, window = owner.window!
        var held: CheckedContinuation<[GitReferenceName: String], Error>?, token: OperationCancellation?
        defer { held?.resume(throwing: OperationCancellationFailure.cancelled); owner.close(); prefs.removePersistentDomain(forName: suite); clipboard.releaseGlobally() }
        do {
        window.alphaValue = 0; window.orderFront(nil); model.clipboard = clipboard
        try await wait { window.contentView?.layoutSubtreeIfNeeded(); return !model.busy && model.entries.count == 2 && views(window.contentView!).contains { $0 is HistoryTableView } }
        let table = views(window.contentView!).compactMap { $0 as? HistoryTableView }.first!
        model.select([model.entries[0].hash]); try await wait { !model.busy && !model.files.isEmpty }
        let column = table.column(withIdentifier: .init("message"))
        table.tableColumns[column].width = 900; table.layoutSubtreeIfNeeded()
        guard var field = (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField as? LogReferenceTextField else { throw Failure(description: "Production reference text field missing") }
        try paint(field)
        let subject=try semanticMessage(table,row:0,text:"Reference subject",hash:model.entries[0].hash)
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try await wait{!model.busy && model.selected==[model.entries[1].hash] && model.message.contains("Plain subject without reference")}
        let plain=try semanticMessage(table,row:1,text:"Plain subject without reference",hash:model.entries[1].hash)
        try require(subject !== plain,"Reference and ordinary rows shared one semantic subject element")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try await wait{!model.busy && model.selected==[model.entries[0].hash] && model.message.contains("Reference subject")}
        window.contentView?.layoutSubtreeIfNeeded();table.layoutSubtreeIfNeeded()
        guard let selectedField=(table.view(atColumn:column,row:0,makeIfNecessary:true) as? NSTableCellView)?.textField as? LogReferenceTextField else{throw Failure(description:"Selected actual reference field missing")}
        field=selectedField;try paint(field)
        guard let frame = field.referenceCell?.badgeFrames.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Visible local badge missing") }
        var point = NSPoint(x: frame.rect.midX, y: frame.rect.midY)
        try require(field.tooltip(at: point) == "Description:\nMain description\nsecond line", "Local badge did not prefer multiline description")
        try require(field.tooltip(at: NSPoint(x: field.bounds.maxX - 2, y: point.y)) == "Reference subject", "Subject fallback changed outside label")
        // A config edit is refreshed on hover without changing history/selection.
        try await wait { LogWindowModel.activeReferenceReads == 0 }
        _ = try await repo.run(["config", "branch.main.description", "Updated description"])
        model.hoverReference(hash: model.entries[0].hash, name: nil)
        field.updateHover(at: point)
        try await wait { model.referenceDescriptions["refs/heads/main"] == "Updated description" && LogWindowModel.activeReferenceReads == 0 }
        // The published metadata may trigger a native layout/reuse pass. New
        // size/text correctly retires its old paint map before the next draw;
        // exercise the currently displayed field after that actual layout.
        window.contentView?.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
        guard let currentField = (table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField as? LogReferenceTextField else { throw Failure(description: "Updated reference field missing") }
        field = currentField; try paint(field)
        guard let updatedFrame = field.referenceCell?.badgeFrames.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Updated local paint geometry missing") }
        point = NSPoint(x: updatedFrame.rect.midX, y: updatedFrame.rect.midY)
        let updatedTooltip = field.tooltip(at: point)
        try require(updatedTooltip == "Description:\nUpdated description", "Hover read did not update description; tooltip=\(String(describing: updatedTooltip)), model=\(String(describing: model.referenceDescriptions["refs/heads/main"])), attached=\(field.window === window), badges=\(field.referenceCell?.badgeFrames.count ?? -1)")
        try await wait { LogWindowModel.activeReferenceReads == 0 }
        let children = field.accessibilityChildren()?.compactMap { $0 as? LogReferenceAccessibleBadge } ?? []
        guard let badge = children.first(where: { $0.name == "refs/heads/main" }) else { throw Failure(description: "Accessible canonical badge missing") }
        try require(badge.isAccessibilityEnabled() && badge.accessibilityValue() as? String == "refs/heads/main" && !badge.accessibilityFrame().isEmpty, "Accessible badge lost canonical identity/frame")
        var captured: NSMenu?
        table.presentContextMenu = { menu, _, _ in captured = menu }
        let acceptedMenu = badge.accessibilityPerformShowMenu()
        try require(acceptedMenu && table.contextReference?.name == "refs/heads/main", "Accessible badge did not target pointed native context; accepted=\(acceptedMenu), context=\(String(describing: table.contextReference)), items=\(captured?.items.count ?? -1), allowed=\(table.contextMenuAvailable()), enabled=\(badge.isAccessibilityEnabled())")
        guard let copy = captured.flatMap({ allItems($0).first { $0.title == "Tag/branch names" } }), let action = copy.action else { throw Failure(description: "Pointed source reference clipboard action missing") }
        _ = NSApp.sendAction(action, to: copy.target, from: copy)
        try require(clipboard.string(forType: .string) == "main", "Accessible context copied a display label or row background instead of canonical ref")
        model.busy = true; try require(!badge.accessibilityPerformPress(), "Busy accessible badge action executed"); model.busy = false
        // New attributes retire the old paint hit map immediately, before redraw.
        let attributed = field.attributedStringValue
        let subjectBeforeReuse=try semanticMessage(table,row:0,text:"Reference subject",hash:model.entries[0].hash)
        field.attributedStringValue = attributed
        try require(subjectBeforeReuse.accessibilityValue() as? String == "Reference subject","Paint-only reference invalidation incorrectly removed unchanged semantic message")
        try require(field.referenceCell?.badgeFrames.isEmpty == true && !badge.accessibilityPerformPress(), "Old paint/AX geometry survived a new document assignment")
        try paint(field)
        let fresh = field.accessibilityChildren()?.compactMap { $0 as? LogReferenceAccessibleBadge } ?? []
        try require(fresh.first?.isAccessibilityEnabled() == true && !badge.isAccessibilityEnabled(), "New paint failed to replace stale accessible generation")
        let currentSubject=try semanticMessage(table,row:0,text:"Reference subject",hash:model.entries[0].hash)
        let messageColumn=table.tableColumns[column]
        messageColumn.isHidden=true
        try require(currentSubject.accessibilityFrame().isEmpty && currentSubject.accessibilityValue()==nil && messageElements(table,text:"Reference subject").isEmpty,"Hidden message column retained exposed subject geometry/content")
        messageColumn.isHidden=false;table.layoutSubtreeIfNeeded();try paint(field)
        let visibleSubject=try semanticMessage(table,row:0,text:"Reference subject",hash:model.entries[0].hash)
        // Hold a noncooperative description read through retirement; the counter
        // and scope stay owned until its actual reply, with no late publication.
        model.hoverReference(hash: model.entries[0].hash, name: nil)
        model.readReferenceDescriptions = { cancellation in token = cancellation; return try await withCheckedThrowingContinuation { held = $0 } }
        model.hoverReference(hash: model.entries[0].hash, name: "refs/heads/main")
        try await wait { held != nil && LogWindowModel.activeReferenceReads > 0 }
        let before = model.referenceDescriptions
        owner.close()
        try require(token?.isCancelled == true && LogWindowModel.activeReferenceReads > 0, "Retired hover lost cancellation or pending ownership")
        held?.resume(returning: ["refs/heads/main": "late"]); held = nil
        try await wait { LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeActionReads == 0 }
        try require(visibleSubject.accessibilityFrame().isEmpty && visibleSubject.accessibilityValue()==nil,"Retired owner retained accessible message content/geometry")
        try require(model.referenceDescriptions == before && fresh.allSatisfy { !$0.isAccessibilityEnabled() && !$0.accessibilityPerformShowMenu() }, "Retired hover or AX callback published late state")
        try await replayMessages(repo:repo,preferences:prefs)
        try require((try await repo.run(["rev-parse", "HEAD"]).stdout) == head, "Read-only reference interactions changed HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: file) == original, "Reference interactions changed index/input")
        print("PASS: native unignored Log/Rebase message AX trees, occurrence identities, actual row selection/details, local branch descriptions, canonical badge context, stale/hidden/retired geometry and actual read drain")
        } catch {
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            owner.close()
            try? await wait { LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeActionReads == 0 }
            throw error
        }
    }
}
