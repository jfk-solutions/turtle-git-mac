import AppKit
import SwiftUI
import TurtleGitCore

// Only test-window placement differs; production views are unchanged.
final class MessageLineOffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main struct MessageLineVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(_ view: NSView) async throws {
        for _ in 0..<20 { view.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func host<V: View>(_ view: V, ordered: Bool = true) -> NSWindow {
        let x = (NSScreen.screens.map { $0.frame.maxX }.max() ?? 0) + 2000
        let window = MessageLineOffscreenWindow(contentRect: .init(x: x, y: 0, width: 1200, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(.init(x: x, y: 0))
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        if ordered { window.orderBack(nil) }
        precondition(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.displayIfNeeded()
        return window
    }
    @MainActor static func message(_ window: NSWindow) -> NSTextField {
        let list = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        let column = list.tableColumns.firstIndex { $0.identifier.rawValue == "message" }!
        return (list.view(atColumn: column, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!
    }
    @MainActor static func values(_ object: Any, depth: Int = 0) -> [String] {
        guard depth < 40, let element = object as? NSObject else { return [] }
        // SwiftUI's lightweight elements need not adopt the entire protocol.
        // Read only these three documented AppKit accessibility getters.
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
        }
        return [attribute("accessibilityValue") as? String, attribute("accessibilityLabel") as? String].compactMap { $0 }
            + (attribute("accessibilityChildren") as? [Any] ?? []).flatMap { values($0, depth: depth + 1) }
    }
    @MainActor static func check(_ enabled: Bool?, repo: GitRepository, entries: [LogEntry], plan: RebasePlan, prefs: UserDefaults) async throws {
        let focused = CommandLine.arguments.contains("--log-blame-only")
        if let enabled { prefs.set(enabled, forKey: "FullCommitMessageOnLogLine") } else { prefs.removeObject(forKey: "FullCommitMessageOnLogLine") }
        let full = enabled ?? false, expected = full ? "first line continued heading  body 雪 second body line " : "first line"
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        log.busy = true; log.entries = entries; log.graph = CommitGraph.layout(entries)
        for entry in entries { log.revisionActions[entry.hash] = [] }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.MessageLine.QA." + UUID().uuidString))
        log.clipboard = pasteboard; log.selected = Set(entries.map(\.hash))
        defer { pasteboard.releaseGlobally() }
        let blame = BlameWindowModel(repository: repo, access: nil, path: "file.txt", revision: "HEAD", labelDefaults: prefs)
        blame.historyEntries = entries; blame.selectedLogHashes = [entries[0].hash]
        let rebase = RebaseWindowModel(repository: repo, access: nil, messageDefaults: prefs)
        rebase.plan = plan; rebase.selection = [plan.entries[0].id]
        let logWindow = host(RevisionTable(model: log, savesColumnLayout: false).defaultAppStorage(prefs), ordered: !focused)
        let blameWindow = host(messageLineBlameHistoryView(blame).defaultAppStorage(prefs), ordered: !focused)
        let rebaseWindow = host(RebaseDialog(model: rebase).defaultAppStorage(prefs), ordered: !focused)
        defer { logWindow.close(); blameWindow.close(); rebaseWindow.close(); log.invalidate(); blame.invalidate(); rebase.revisionMenuLog.invalidate() }
        for window in [logWindow, blameWindow, rebaseWindow] { try await settle(window.contentView!) }
        // Hidden AppKit tables lazily create row views. Ask the production
        // data source for its real cells, just as the Log/Blame checks do.
        let rebaseTables = descendants(rebaseWindow.contentView!).compactMap { $0 as? NSTableView }
        var rebaseCells: [NSView] = []
        for table in rebaseTables {
            table.reloadData()
            for row in 0..<table.numberOfRows {
                for column in table.tableColumns.indices {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) {
                        rebaseCells.append(cell); cell.layoutSubtreeIfNeeded()
                    }
                }
            }
        }
        try await settle(rebaseWindow.contentView!)
        let logTable = descendants(logWindow.contentView!).compactMap { $0 as? NSTableView }.first!
        let menu = logTable.menu!
        menu.delegate?.menuNeedsUpdate?(menu)
        let copyMenu = menu.items.first { $0.title == "Copy to clipboard" }!.submenu!
        for (title, expectedCopy) in [
            ("Subjects", "* first line\r\n\r\n* root\r\n\r\n"),
            ("Messages", "* first line\r\ncontinued heading\r\n\r\nbody 雪\r\nsecond body line\r\n\r\n* root\r\n\r\n\r\n")
        ] {
            let item = copyMenu.items.first { $0.title == title }!
            precondition(item.isEnabled && item.image != nil)
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
            precondition(pasteboard.string(forType: .string) == expectedCopy, title + " actual menu clipboard output differs")
        }
        precondition(log.fullCommitMessageOnLogLine == full && blame.fullCommitMessageOnLogLine == full && rebase.fullCommitMessageOnLogLine == full)
        precondition(message(logWindow).stringValue.hasSuffix(expected) && message(blameWindow).stringValue == expected)
        let label = message(logWindow).attributedStringValue
        precondition(label.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil, "Reference label styling must be retained")
        let rebaseValues = (descendants(rebaseWindow.contentView!) + rebaseCells).flatMap { values($0) }
        if !focused && !rebaseValues.contains(expected) {
            let fields = descendants(rebaseWindow.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            let tables = rebaseTables.map { ["columns": $0.tableColumns.map(\.title), "rows": $0.numberOfRows] as [String: Any] }
            let diagnostic = try JSONSerialization.data(withJSONObject: ["expected": expected, "accessibility": rebaseValues, "fields": fields, "tables": tables])
            FileHandle.standardOutput.write(diagnostic); FileHandle.standardOutput.write(Data("\n".utf8))
        }
        if !focused { precondition(rebaseValues.contains(expected), "Actual Rebase row must show the configured message line") }
        precondition(message(logWindow).maximumNumberOfLines == 1 && message(blameWindow).maximumNumberOfLines == 1)
        precondition(blame.selectedLogHashes == [entries[0].hash] && rebase.selection == [plan.entries[0].id] && rebase.entries[0].action == plan.entries[0].action)
        prefs.set(!full, forKey: "FullCommitMessageOnLogLine")
        for window in [logWindow, blameWindow, rebaseWindow] { try await settle(window.contentView!) }
        precondition(log.fullCommitMessageOnLogLine == full && blame.fullCommitMessageOnLogLine == full && rebase.fullCommitMessageOnLogLine == full, "Source captures the preference at construction")
        precondition(message(logWindow).stringValue.hasSuffix(expected) && message(blameWindow).stringValue == expected)
        precondition(entries[0].message == "first line\ncontinued heading\n\nbody 雪\nsecond body line\n" && entries[0].subject == "first line continued heading")
    }
    @MainActor static func checkHighlights(repo: GitRepository, prefs: UserDefaults) async throws {
        let regexHelper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_REGEX"]!)
        for (full, fields, query, regex, expectedTerm) in [
            (false, HistorySearchFields([.subject, .referenceNames]), "line +main", false, "line"),
            (false, HistorySearchFields.messages, "first", false, ""),
            (true, HistorySearchFields.messages, "body", false, "body"),
            (true, HistorySearchFields.messages, "body|second", true, "body"),
            (true, HistorySearchFields.messages, "(?<=body) 雪", true, "")
        ] {
            prefs.set(full, forKey: "FullCommitMessageOnLogLine")
            let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs, historyRegexExecutable: regexHelper)
            model.search = query; model.searchFields = fields; model.searchRegex = regex; model.searchCaseSensitive = false
            model.showWorkingTree = false; model.reload()
            for _ in 0..<1500 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!model.busy && model.error == nil, "Real history highlight reload must finish")
            let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
            defer { window.close(); model.invalidate() }
            try await settle(window.contentView!)
            let field = message(window), value = field.attributedStringValue
            let heading = (value.string as NSString).range(of: "first line")
            precondition(heading.location != NSNotFound)
            let entry = model.entries[0]
            let ranges = model.searchHighlights[entry.hash]?["message"] ?? []
            if expectedTerm.isEmpty { precondition(!model.shouldHighlightMessage(entry) || ranges.isEmpty) }
            else {
                let term = (value.string as NSString).range(of: expectedTerm, options: [], range: NSRange(location: heading.location, length: value.length - heading.location))
                precondition(term.location != NSNotFound)
                let color = value.attribute(.foregroundColor, at: term.location, effectiveRange: nil) as! NSColor
                NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                    let channels = color.usingColorSpace(.sRGB)!
                    precondition(abs(channels.redComponent - 200.0/255) < 0.001 && channels.greenComponent == 0 && channels.blueComponent == 0)
                }
                precondition(value.attribute(.backgroundColor, at: heading.location, effectiveRange: nil) == nil, "Matches use foreground only")
            }
            let label = (value.string as NSString).range(of: "main")
            precondition(label.location != NSNotFound && value.attribute(.backgroundColor, at: label.location, effectiveRange: nil) is NSColor, "Reference badge styling retained")
            precondition(field.maximumNumberOfLines == 1 && !model.selected.isEmpty)
            // Update same-identity rows and verify stale colors disappear.
            model.searchHighlights = [:]; try await settle(window.contentView!)
            let cleared = message(window).attributedStringValue
            let oldMatch = expectedTerm.isEmpty ? heading : (value.string as NSString).range(of: expectedTerm, options: [], range: NSRange(location: heading.location, length: value.length - heading.location))
            precondition(cleared.attribute(.foregroundColor, at: oldMatch.location, effectiveRange: nil) == nil)
        }
    }
    @MainActor static func checkHighlightColumns(repo: GitRepository, prefs: UserDefaults) async throws {
        let entry = try await repo.history()[0]
        let ranges = try LogSearchHighlights.prepare([entry], query: "Message +example +" + String(entry.hash.prefix(6)), regex: false, caseSensitive: false, fields: [.authors, .emails, .revisions], fullMessage: false, labeled: [entry.hash], executable: nil)
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = [entry]; model.graph = CommitGraph.layout([entry]); model.searchHighlights = ranges; model.revisionActions[entry.hash] = []
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        for column in table.tableColumns { column.isHidden = false }
        table.reloadData(); try await settle(window.contentView!)
        for name in ["author", "committer", "email", "committerEmail", "hash"] {
            let index = table.tableColumns.firstIndex { $0.identifier.rawValue == name }!
            let text = (table.view(atColumn: index, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!.attributedStringValue
            for range in ranges[entry.hash]![name]! { precondition(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) is NSColor) }
        }
        let gated = try LogSearchHighlights.prepare([entry], query: "Message", regex: false, caseSensitive: false, fields: .paths, fullMessage: true, labeled: [], executable: nil)
        precondition(gated.isEmpty)
        let hiddenRefs = try LogSearchHighlights.prepare([entry], query: "first", regex: false, caseSensitive: false, fields: .subject, fullMessage: true, labeled: [], executable: nil)
        precondition(hiddenRefs.isEmpty, "Source suppresses custom message painting when all existing refs are hidden")
        var plain = entry; plain.references = []
        let plainRanges = try LogSearchHighlights.prepare([plain], query: "first", regex: false, caseSensitive: false, fields: .messages, fullMessage: false, labeled: [], executable: nil)
        precondition(plainRanges[entry.hash]?["message"] == [NSRange(location: 0, length: 5)])
        let colors = LogColorSettingsModel(preferences: prefs)
        colors.set(.filterMatch, rgb: [40,80,120]); colors.cancel(); precondition(colors.draft.rgb(.filterMatch) == [200,0,0])
        colors.set(.filterMatch, rgb: [40,80,120]); colors.apply(); precondition(LogColorPreferences.load(prefs).rgb(.filterMatch) == [40,80,120])
        colors.restoreDefaults(); colors.apply(); precondition(LogColorPreferences.load(prefs).rgb(.filterMatch) == [200,0,0])
    }
    @MainActor static func checkReferenceLayout(repo: GitRepository, prefs: UserDefaults) async throws {
        let entries = try await repo.history(), context = try await repo.historyReferenceContext()
        for (right, symbolize) in [(false, false), (true, false), (false, true), (true, true)] {
            prefs.set(right, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(symbolize, forKey: "SymbolizeRefNames")
            prefs.set(false, forKey: "FullCommitMessageOnLogLine")
            let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
            model.busy = true; model.entries = entries; model.graph = CommitGraph.layout(entries); model.referenceContext = context
            for entry in entries { model.revisionActions[entry.hash] = [] }
            let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
            defer { window.close(); model.invalidate() }
            try await settle(window.contentView!)
            let field = message(window), value = field.attributedStringValue, text = value.string as NSString
            try checkReferencePainter(field)
            let painted = (field.cell as! LogReferenceTextCell).badgeFrames
            precondition(painted.contains { $0.name == "refs/heads/main" && $0.style.label.hasTracking })
            precondition(painted.contains { $0.name == "refs/remotes/origin/main" && $0.style.label.hasTracking })
            let heading = text.range(of: "first line"), main = text.range(of: "main")
            precondition(heading.location != NSNotFound && main.location != NSNotFound)
            precondition(right ? heading.location < main.location : main.location < heading.location)
            precondition(value.attribute(.backgroundColor, at: main.location, effectiveRange: nil) is NSColor)
            precondition(value.attribute(.backgroundColor, at: heading.location, effectiveRange: nil) == nil)
            precondition(right ? field.toolTip == nil : field.toolTip == "first line")
            if symbolize {
                precondition(text.range(of: "/≡").location != NSNotFound && text.range(of: "origin/main").location == NSNotFound)
                let marker = text.range(of: "\u{FFFC}")
                precondition(marker.location != NSNotFound)
                precondition((value.attribute(.attachment, at: marker.location, effectiveRange: nil) as? NSTextAttachment)?.image != nil)
            } else { precondition(text.range(of: "origin/main").location != NSNotFound) }
            precondition(model.visibleReferenceLabels(for: entries[0]).map { $0.reference.name }.sorted() == entries[0].references.map(\.name).sorted())
            prefs.set(!right, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(!symbolize, forKey: "SymbolizeRefNames")
            precondition(model.drawTagsBranchesOnRightSide == right && model.symbolizeRefNames == symbolize)
        }
        prefs.set(false, forKey: "DrawTagsBranchesOnRightSide"); prefs.set(false, forKey: "SymbolizeRefNames")
        // Source HandleShowLabels redraws ordinary history without re-reading Git.
        prefs.set(true, forKey: "FullCommitMessageOnLogLine")
        let regexHelper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_REGEX"]!)
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs, historyRegexExecutable: regexHelper)
        model.showWorkingTree = false; model.search = "body"; model.searchFields = .messages; model.searchRegex = false; model.reload()
        for _ in 0..<1500 { if !model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil)
        // Isolate the existing branch-only repaint fixture from mandatory stash/bisect labels.
        model.entries = model.entries.map { var row = $0; row.references = row.references.filter { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/remotes/") }; return row }
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let before = message(window).attributedStringValue
        let body = (before.string as NSString).range(of: "body")
        precondition(before.attribute(.foregroundColor, at: body.location, effectiveRange: nil) is NSColor)
        model.toggleHistoryLabel(.localBranches); model.toggleHistoryLabel(.remoteBranches)
        precondition(!model.busy); try await settle(window.contentView!)
        let hidden = message(window).attributedStringValue, hiddenBody = (hidden.string as NSString).range(of: "body")
        precondition(hidden.attribute(.foregroundColor, at: hiddenBody.location, effectiveRange: nil) == nil)
        model.toggleHistoryLabel(.localBranches); try await settle(window.contentView!)
        let restored = message(window).attributedStringValue, restoredBody = (restored.string as NSString).range(of: "body")
        precondition(restored.attribute(.foregroundColor, at: restoredBody.location, effectiveRange: nil) is NSColor)
    }
    @MainActor static func checkDialogPreferenceControls(prefs: UserDefaults) async throws {
        let controls = [("Symbolize ref names", "SymbolizeRefNames"), ("Draw tag/branch labels on right side", "DrawTagsBranchesOnRightSide"), ("Display subject and body of commit messages", "FullCommitMessageOnLogLine")]
        for (_, key) in controls { prefs.set(false, forKey: key) }
        let window = host(LogDialogSettings().defaultAppStorage(prefs), ordered: false)
        window.setContentSize(NSSize(width: 1200, height: 1800))
        defer { window.close() }
        try await settle(window.contentView!)
        for (title, key) in controls {
            let buttons = descendants(window.contentView!).compactMap { $0 as? NSButton }
            guard let button = buttons.first(where: { $0.title == title || $0.accessibilityLabel() == title }) else {
                let diagnostic = try JSONSerialization.data(withJSONObject: ["missing": title, "buttons": buttons.map { [$0.title, $0.accessibilityLabel() ?? ""] }, "fields": descendants(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }])
                FileHandle.standardOutput.write(diagnostic); FileHandle.standardOutput.write(Data("\n".utf8))
                preconditionFailure("Actual source preference checkbox must be exposed")
            }
            precondition(button.isEnabled && button.state == .off)
            button.performClick(nil); try await settle(window.contentView!)
            precondition(prefs.bool(forKey: key) && button.state == .on)
            button.performClick(nil); try await settle(window.contentView!)
            precondition(!prefs.bool(forKey: key) && button.state == .off)
        }
    }
    @MainActor static func checkReferenceKinds(repo: GitRepository, prefs: UserDefaults) async throws {
        let entries = try await repo.history(), entry = entries[0]
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = entries; model.graph = CommitGraph.layout(entries)
        for row in entries { model.revisionActions[row.hash] = [] }
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let labels = model.visibleReferenceLabels(for: entry), text = message(window).attributedStringValue
        try checkReferencePainter(message(window))
        for (name, alias, kind, role) in [
            ("refs/stash", "stash", HistoryReferenceKind.stash, LogColorRole.stash),
            ("refs/bisect/old-a", "old", .bisectGood, .bisectGood),
            ("refs/bisect/new", "new", .bisectBad, .bisectBad),
            ("refs/bisect/unrecognized", "unrecognized", .unknown, .otherRef),
            ("refs/notes/custom", "custom", .notes, .noteNode),
            ("refs/custom/extra", "custom/extra", .unknown, .otherRef),
            ("refs/tags/annotated", "annotated", .annotatedTag, .tag),
            ("refs/tags/light", "light", .tag, .tag)
        ] {
            let label = labels.first { $0.reference.name == name }!
            precondition(label.text == alias && label.kind == kind)
            precondition(LogColorRole.reference(label.reference) == role)
            let range = (text.string as NSString).range(of: " " + alias + " ")
            precondition(range.location != NSNotFound && text.attribute(.backgroundColor, at: range.location, effectiveRange: nil) is NSColor)
        }
        let context = HistoryReferenceContext()
        precondition(context.labels(entry.references, visibility: .bisect).map(\.text).sorted() == ["new", "old"])
        precondition(Set(context.labels(entry.references, visibility: .otherRefs).map(\.text)) == ["unrecognized", "custom", "custom/extra"])
        precondition(entry.references.first { $0.name == "refs/tags/annotated" }?.kind == .annotatedTag)
    }
    @MainActor static func checkReferencePainter(_ field: NSTextField) throws {
        guard let cell = field.cell as? LogReferenceTextCell else { preconditionFailure("Production message cell must use the reference painter") }
        // Exercise the real cell painter into an owned, in-memory drawing context.
        // This is numerical headless QA, not a physical window screenshot.
        func draw(width: CGFloat) -> [LogReferenceTextCell.BadgeFrame] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            cell.drawInterior(withFrame: NSRect(x: 0, y: 0, width: width, height: 30), in: field)
            return cell.badgeFrames
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let frames = draw(width: 1600)
                precondition(frames.contains { $0.name == "refs/tags/annotated" && $0.style.pointed })
                precondition(frames.contains { $0.name == "refs/tags/light" && !$0.style.pointed })
                precondition(frames.allSatisfy { $0.rect.width > 8 && $0.rect.height == 30 })
                for frame in frames where frame.style.pointed {
                    let font = field.attributedStringValue.attribute(.font, at: frame.range.location, effectiveRange: nil) as! NSFont
                    let textWidth = (frame.style.label.text as NSString).size(withAttributes: [.font: font]).width
                    precondition(frame.rect.width >= textWidth + 16 - 0.5, "Annotated tag must reserve text padding plus eight-point tip")
                }
                precondition(zip(frames, frames.dropFirst()).allSatisfy { $0.0.rect.maxX <= $0.1.rect.minX + 0.01 })
                let clipped = draw(width: 45)
                precondition(clipped.count < frames.count && clipped.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 45 })
                if !clipped.isEmpty { precondition(abs(clipped.last!.rect.maxX - 45) < 0.01, "A partially visible ref paints through the clipped column edge") }
                let narrow = draw(width: 1)
                precondition(narrow.count <= 1 && narrow.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 1 })
            }
        }
        _ = draw(width: 1600)
        let rounded = LogReferenceDrawing.geometry(CGRect(x: 10, y: 20, width: 100, height: 18), tracking: true, pointed: false)
        precondition(rounded.interior == CGRect(x: 11, y: 21, width: 98, height: 16))
        precondition(rounded.shadow == CGRect(x: 13, y: 23, width: 98, height: 16))
        let pointed = LogReferenceDrawing.geometry(CGRect(x: 10, y: 20, width: 100, height: 18), tracking: false, pointed: true)
        precondition(pointed.body.width == 92 && pointed.tip == [CGPoint(x: 102, y: 20), CGPoint(x: 110, y: 29), CGPoint(x: 102, y: 38)])
        precondition(LogReferenceDrawing.mix([0, 195, 255], toward: 255, amount: 100) == [100, 218, 255])
        precondition(LogReferenceDrawing.mix([0, 195, 255], toward: 0, amount: 100) == [0, 119, 155])
        precondition(LogColorRole.reference(RevisionReference(name: "refs/stash-extra")) == .stash)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.MessageLine.Native.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Message QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("fixture\n".utf8).write(to: repo.root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "root")
        _ = try await repo.run(["commit", "--allow-empty", "-m", "first line\ncontinued heading\n\nbody 雪\nsecond body line\n"])
        _ = try await repo.run(["remote", "add", "origin", repo.root.path])
        _ = try await repo.run(["config", "branch.main.remote", "origin"])
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        for name in ["refs/stash", "refs/bisect/old-a", "refs/bisect/new", "refs/bisect/unrecognized", "refs/notes/custom", "refs/custom/extra"] { _ = try await repo.run(["update-ref", name, "HEAD"]) }
        _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "annotated", "-m", "fixture tag"])
        _ = try await repo.run(["tag", "light"])
        try Data("new\nold\n".utf8).write(to: repo.root.appendingPathComponent(".git/BISECT_TERMS"))
        let entries = try await repo.history()
        var options = RebaseOptions(); options.upstream = "HEAD^"; options.force = true
        let plan = try await repo.rebasePlan(options); precondition(plan.entries.count == 1)
        let paths = [".git/HEAD", ".git/index", ".git/config", ".git/refs/heads/main", ".git/refs/remotes/origin/main", ".git/BISECT_TERMS", ".git/refs/tags/annotated", ".git/refs/bisect/old-a", "file.txt"], before = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        for enabled in [nil, false, true] as [Bool?] { try await check(enabled, repo: repo, entries: entries, plan: plan, prefs: prefs) }
        try await checkHighlights(repo: repo, prefs: prefs)
        try await checkHighlightColumns(repo: repo, prefs: prefs)
        try await checkReferenceLayout(repo: repo, prefs: prefs)
        try await checkDialogPreferenceControls(prefs: prefs)
        try await checkReferenceKinds(repo: repo, prefs: prefs)
        try await checkReferenceMenus(repo: repo, prefs: prefs)
        try await checkReferenceByteRefresh(repo: repo, prefs: prefs)
        try await checkPointedPresets(git: URL(fileURLWithPath: CommandLine.arguments[2]), prefs: prefs)
        try await checkReferenceDeletion(git: URL(fileURLWithPath: CommandLine.arguments[2]), prefs: prefs)
        let after = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }; precondition(before == after)
        if CommandLine.arguments.contains("--log-blame-only") {
            print("PASS (focused): actual hidden Log/Blame message cells, unset/false/true captured preferences, folding/label styling/one-line cells/selection/metadata preserved, actual Subjects/Messages menu actions match source formatting on private pasteboard, real reload literal/regex highlight cells and reference/full-message gates verified, left/right label order and symbolization attachments/captured choices and label-mask highlight redraw verified; Rebase model preference and read-only plan/selection/action checked, rendered Rebase text UNVERIFIED; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        } else {
            print("PASS: offscreen native Log/Blame/Rebase message text and source captured preferences; unchanged repository bytes, all owned windows closed, no main app or replay operation")
        }
    }
    @MainActor static func checkReferenceMenus(repo: GitRepository, prefs: UserDefaults) async throws {
        prefs.set(HistoryReferenceVisibility.all.rawValue, forKey: "LogDialog.ReferenceVisibility." + repo.root.standardizedFileURL.path)
        var entries = try await repo.history(); var entry = entries[0]
        entry.references.removeAll { $0.name == "refs/stash" }; entries[0] = entry
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = entries; model.graph = CommitGraph.layout(entries); model.selected = [entry.hash]
        model.bare = try await repo.isBare(); precondition(!model.bare)
        for row in entries { model.revisionActions[row.hash] = [] }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.RefMenu.QA." + UUID().uuidString)); model.clipboard = pasteboard
        var pushed: [String] = [], checkedOut: [String] = []
        model.onPush = { pushed.append($0) }; model.onCheckout = { checkedOut.append($0) }
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        window.setContentSize(NSSize(width: 3000, height: 400))
        defer { window.close(); model.invalidate(); pasteboard.releaseGlobally() }
        try await settle(window.contentView!); model.busy = false
        let table = descendants(window.contentView!).compactMap { $0 as? HistoryTableView }.first!
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("message"))!.width = 2200
        try await settle(window.contentView!)
        let field = message(window)
        let cell = field.cell as! LogReferenceTextCell
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        cell.drawInterior(withFrame: field.bounds, in: field)
        NSGraphicsContext.restoreGraphicsState()
        let remote = cell.badgeFrames.first { $0.name == "refs/remotes/origin/main" }!
        let point = NSPoint(x: remote.rect.midX, y: remote.rect.midY)
        precondition(cell.reference(at: point)?.name == remote.name)
        let tablePoint = table.convert(point, from: field)
        precondition(table.reference(at: tablePoint)?.name == remote.name)
        func send(_ item: NSMenuItem) { precondition(item.isEnabled && item.image != nil, "Menu \(item.title): enabled=\(item.isEnabled), image=\(item.image != nil), busy=\(model.busy), bare=\(model.bare), selection=\(model.selected.count)"); precondition(NSApp.sendAction(item.action!, to: item.target, from: item), "Selector for \(item.title)") }
        let menu = table.menu!
        for (name, expectedCopy, pushTitle) in [("refs/heads/main", "main", "Push \"main\"…"), ("refs/remotes/origin/main", "remotes/origin/main", "Push…"), ("refs/tags/annotated", "annotated", "Push \"annotated\"…")] {
            table.contextReference = (0, name); menu.delegate?.menuNeedsUpdate?(menu)
            send(menu.items.first { $0.title == pushTitle }!)
            send(menu.items.first { $0.title == "Switch/Checkout to this…" }!)
            let copy = menu.items.first { $0.title == "Copy to clipboard" }!.submenu!.items.first { $0.title == "Tag/branch names" }!
            send(copy); precondition(pasteboard.string(forType: .string) == expectedCopy)
            precondition(pushed.last == name && checkedOut.last == name)
        }
        let stale = menu.items.first { $0.title.hasPrefix("Push") }!
        model.selected = [entries[1].hash]; send(stale); precondition(pushed.count == 3)
        model.selected = [entry.hash]; menu.delegate?.menuDidClose?(menu); precondition(table.contextReference == nil)
        table.contextReference = (0, remote.name)
        let keyboard = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0)!
        _ = table.menu(for: keyboard); precondition(table.contextReference == nil && model.selected == [entry.hash])
        menu.delegate?.menuNeedsUpdate?(menu)
        send(menu.items.first { $0.title == "Push…" }!); precondition(pushed.last == entry.hash)
        send(menu.items.first { $0.title == "Switch/Checkout to this…" }!); precondition(checkedOut.last == "refs/remotes/origin/main")
        let refs = menu.items.first { $0.title == "Copy to clipboard" }!.submenu!.items.first { $0.title == "Tag/branch names" }!
        send(refs); precondition(pasteboard.string(forType: .string) == entry.references.map { $0.name + "\r\n" }.joined())
        precondition(cell.reference(at: NSPoint(x: -1, y: -1)) == nil)
        let duplicate = NSMutableAttributedString()
        for _ in 0..<2 {
            let label = HistoryReferenceLabel(reference: entry.references.first { $0.name == remote.name }!)
            duplicate.append(NSAttributedString(string: " origin/main ", attributes: [.font: NSFont.systemFont(ofSize: 11), .logReference: LogReferenceStyle(label, color: .yellow)]))
        }
        cell.attributedStringValue = duplicate
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        cell.drawInterior(withFrame: field.bounds, in: field); NSGraphicsContext.restoreGraphicsState()
        precondition(cell.badgeFrames.count == 2)
        let first = cell.badgeFrames[0].rect, last = cell.badgeFrames[1].rect
        precondition(cell.reference(at: NSPoint(x: first.midX, y: first.midY)) == nil)
        precondition(cell.reference(at: NSPoint(x: last.midX, y: last.midY))?.name == remote.name)
        precondition(cell.reference(at: NSPoint(x: last.maxX, y: last.midY)) == nil)
        precondition(cell.reference(at: NSPoint(x: last.midX, y: last.maxY)) == nil)
        // Synthetic ref metadata avoids filesystem normalization of loose ref
        // filenames; validate this UI layer's byte identity independently.
        let names = ["refs/heads/caf\u{e9}", "refs/heads/cafe\u{301}"]
        var unicodeEntry = entry; unicodeEntry.references = names.map { RevisionReference(name: $0, kind: .localBranch) }
        model.entries = [unicodeEntry]; model.selected = [entry.hash]; model.graph = CommitGraph.layout([unicodeEntry])
        let unicodeLabels = NSMutableAttributedString()
        for reference in unicodeEntry.references {
            unicodeLabels.append(NSAttributedString(string: " " + String(reference.name.dropFirst(11)) + " ", attributes: [.font: NSFont.systemFont(ofSize: 11), .logReference: LogReferenceStyle(HistoryReferenceLabel(reference: reference), color: .yellow)]))
        }
        cell.attributedStringValue = unicodeLabels
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        cell.drawInterior(withFrame: field.bounds, in: field); NSGraphicsContext.restoreGraphicsState()
        precondition(cell.badgeFrames.count == 2)
        for (index, name) in names.enumerated() {
            let rect = cell.badgeFrames[index].rect
            precondition(cell.reference(at: NSPoint(x: rect.midX, y: rect.midY))!.name.utf8.elementsEqual(name.utf8))
            table.contextReference = (0, name); menu.delegate?.menuNeedsUpdate?(menu)
            send(menu.items.first { $0.title.hasPrefix("Push ") }!)
            precondition(pushed.last!.utf8.elementsEqual(name.utf8))
            send(menu.items.first { $0.title == "Switch/Checkout to this…" }!)
            precondition(checkedOut.last!.utf8.elementsEqual(name.utf8))
            send(menu.items.first { $0.title == "Copy to clipboard" }!.submenu!.items.first { $0.title == "Tag/branch names" }!)
            precondition(pasteboard.string(forType: .string)!.utf8.elementsEqual(String(name.dropFirst(11)).utf8))
        }
        var switched: [String] = []; model.onSwitchBranch = { switched.append($0) }
        unicodeEntry.references.append(RevisionReference(name: "refs/heads/current", isCurrent: true))
        unicodeEntry.references.append(RevisionReference(name: "refs/tags/tag"))
        model.entries = [unicodeEntry]; table.contextReference = nil; menu.delegate?.menuNeedsUpdate?(menu)
        let branchMenu = menu.items.first { $0.title == "Switch branch" }!.submenu!
        precondition(branchMenu.items.count == 2)
        for (index, choice) in branchMenu.items.enumerated() {
            send(choice); precondition(switched.last!.utf8.elementsEqual(names[index].utf8))
        }
        let staleSwitch = branchMenu.items[0]
        model.selected = [entries[1].hash]; send(staleSwitch); precondition(switched.count == 2)
        model.selected = [entry.hash]
        for name in ["refs/heads/current", "refs/tags/tag"] {
            table.contextReference = (0, name); menu.delegate?.menuNeedsUpdate?(menu)
            precondition(!menu.items.contains { $0.title.hasPrefix("Switch branch") })
        }
        table.contextReference = (0, names[1]); menu.delegate?.menuNeedsUpdate?(menu)
        let direct = menu.items.first { $0.title.hasPrefix("Switch branch ") }!
        precondition(direct.submenu == nil); send(direct)
        precondition(switched.last!.utf8.elementsEqual(names[1].utf8))
        model.busy = true; menu.delegate?.menuNeedsUpdate?(menu)
        precondition(menu.items.first { $0.title.hasPrefix("Switch branch ") }!.isEnabled == false)
        model.switchBranch(target: LogReferenceMenuTarget(hash: entry.hash, name: names[1])); precondition(switched.count == 3)
        model.busy = false; model.bare = true; menu.delegate?.menuNeedsUpdate?(menu)
        precondition(!menu.items.contains { $0.title.hasPrefix("Switch branch") }); model.bare = false
        // Check the captured canonical handoff against production read-only
        // CheckoutOptions validation using an existing real local branch.
        var validationEntry = entry; validationEntry.references = [RevisionReference(name: "refs/heads/main")]
        model.entries = [validationEntry]; table.contextReference = nil; menu.delegate?.menuNeedsUpdate?(menu)
        send(menu.items.first { $0.title == "Switch branch \"main\"" }!)
        var options = CheckoutOptions(); options.revision = switched.last!
        try await repo.validateCheckout(options)
        precondition(options.revision == "refs/heads/main")
        model.entries = [unicodeEntry]
        menu.delegate?.menuDidClose?(menu); menu.delegate?.menuNeedsUpdate?(menu)
        let calls = pushed.count; model.invalidate(); send(menu.items.first { $0.title == "Push…" }!); precondition(pushed.count == calls)
        send(staleSwitch); precondition(switched.count == 4)
    }
    @MainActor static func checkReferenceByteRefresh(repo: GitRepository, prefs: UserDefaults) async throws {
        let entries = try await repo.history(), a = "caf\u{e9}", b = "cafe\u{301}"
        var entry = entries[0]; entry.references = [RevisionReference(name: "refs/tags/" + a, kind: .tag, displayName: a)]
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = [entry]; model.graph = CommitGraph.layout([entry]); model.revisionActions[entry.hash] = []
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        func name() -> String {
            let text = message(window).attributedStringValue
            var name: String?
            text.enumerateAttribute(.logReference, in: NSRange(location: 0, length: text.length)) { style, _, _ in
                if let style = style as? LogReferenceStyle { name = style.label.reference.name }
            }
            return name!
        }
        precondition(name().utf8.elementsEqual(("refs/tags/" + a).utf8))
        entry.references = [RevisionReference(name: "refs/tags/" + b, kind: .tag, displayName: b)]
        model.entries = [entry]; try await settle(window.contentView!)
        precondition(name().utf8.elementsEqual(("refs/tags/" + b).utf8), "Same-hash NFC to NFD changes must reload the actual native message cell")
        let leading = "\u{301}topic", reference = RevisionReference(name: "refs/heads/" + leading)
        precondition(LogColorRole.reference(reference) == .localBranch)
        precondition(HistoryReferenceLabel(reference: reference).text.utf8.elementsEqual(leading.utf8))
        let clipboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.RefIdentity.QA." + UUID().uuidString)); defer { clipboard.releaseGlobally() }
        model.clipboard = clipboard; entry.references = [reference]; model.entries = [entry]; model.selected = [entry.hash]; model.busy = false
        model.copyReferenceNames(target: LogReferenceMenuTarget(hash: entry.hash, name: reference.name))
        precondition(clipboard.string(forType: .string)!.utf8.elementsEqual(leading.utf8))
    }
    @MainActor static func checkPointedPresets(git: URL, prefs: UserDefaults) async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("turtlegit-log-presets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Preset QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "base"])
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for name in ["refs/heads/topic", "refs/remotes/origin/a", "refs/remotes/origin/b", "refs/tags/base"] { _ = try await repo.run(["update-ref", name, base]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "next"])
        let paths = [".git/HEAD", ".git/config", ".git/refs/heads/main", ".git/refs/heads/topic", ".git/refs/remotes/origin/a", ".git/refs/remotes/origin/b", ".git/refs/tags/base"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = try await repo.history(); model.graph = CommitGraph.layout(model.entries); model.selected = [base]; model.bare = false
        for entry in model.entries { model.revisionActions[entry.hash] = [] }
        var created: [(Bool, String)] = [], merges: [String] = [], checkout: [String] = []
        model.onCreateReference = { created.append(($0, $1)) }; model.onMergeRevision = { merges.append($0) }; model.onCheckout = { checkout.append($0) }
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!)
        let table = descendants(window.contentView!).compactMap { $0 as? HistoryTableView }.first!, menu = table.menu!
        model.busy = false; let row = model.entries.firstIndex { $0.hash == base }!
        func send(_ title: String) {
            menu.delegate?.menuNeedsUpdate?(menu)
            let item = menu.items.first { $0.title == title }!; precondition(item.isEnabled && item.image != nil)
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        table.contextReference = (row, "refs/remotes/origin/b")
        send("Create branch at this version…"); precondition(created.last!.0 == false && created.last!.1 == "refs/remotes/origin/b")
        send("Create tag at this version…"); precondition(created.last!.0 && created.last!.1 == "refs/remotes/origin/a")
        send("Switch/Checkout to this…"); precondition(checkout.last == "refs/remotes/origin/b")
        table.contextReference = (row, "refs/heads/topic")
        send("Create branch at this version…"); precondition(created.last!.1 == "refs/remotes/origin/a")
        send(model.integrationTitle(.merge))
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil && merges == ["refs/heads/topic"])
        table.contextReference = nil; send("Switch/Checkout to this…"); precondition(checkout.last == "refs/remotes/origin/a")
        send("Create branch at this version…"); precondition(created.last!.1 == "refs/remotes/origin/a")
        let stale = menu.items.first { $0.title == "Create branch at this version…" }!
        model.selected = [model.entries[0].hash]; precondition(NSApp.sendAction(stale.action!, to: stale.target, from: stale))
        // A background menu has no immutable pointed target; test a pointed stale item.
        model.selected = [base]; table.contextReference = (row, "refs/remotes/origin/b"); menu.delegate?.menuNeedsUpdate?(menu)
        let pointed = menu.items.first { $0.title == "Create branch at this version…" }!, count = created.count
        model.selected = [model.entries[0].hash]; precondition(NSApp.sendAction(pointed.action!, to: pointed.target, from: pointed)); precondition(created.count == count)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
    }

    @MainActor static func checkReferenceDeletion(git: URL, prefs: UserDefaults) async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("deletion-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Deletion Native QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "base"])
        _ = try await repo.run(["branch", "topic"])
        for tag in ["v1", "v2"] { _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", tag]) }
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), main = try Data(contentsOf: root.appendingPathComponent(".git/refs/heads/main"))
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.entries = try await repo.history(); model.graph = CommitGraph.layout(model.entries); model.selected = [model.entries[0].hash]
        let hash = model.entries[0].hash; model.revisionActions[hash] = []
        let window = host(RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs), ordered: false)
        defer { window.close(); model.invalidate() }
        try await settle(window.contentView!); model.busy = false
        let table = descendants(window.contentView!).compactMap { $0 as? HistoryTableView }.first!, menu = table.menu!
        func rebuild(_ ref: String?) { table.contextReference = ref.map { (model.entries.firstIndex { $0.hash == hash }!, $0) }; menu.delegate?.menuNeedsUpdate?(menu) }
        func send(_ item: NSMenuItem) { precondition(item.isEnabled && item.image != nil); precondition(NSApp.sendAction(item.action!, to: item.target, from: item)) }
        func wait() async throws { let end = Date().addingTimeInterval(30); while model.busy && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }; precondition(!model.busy) }
        rebuild("refs/heads/main"); precondition(!menu.items.contains { $0.title.hasPrefix("Delete") })
        rebuild(nil)
        let all = menu.items.first { $0.title == "Delete branch/tag" }!.submenu!
        precondition(all.items.map(\.title) == ["refs/heads/topic", "refs/tags/v1", "refs/tags/v2", "All"])
        var prompted: [String] = []
        model.confirmReferenceDeletion = { request in prompted.append(request.name); return .abort }
        send(all.items.last!); try await wait(); precondition(prompted == ["refs/heads/topic"])
        let retained = try await repo.run(["show-ref", "--verify", "refs/heads/topic"]); precondition(retained.exitCode == 0)
        prompted = []; model.confirmReferenceDeletion = { request in prompted.append(request.name); return .delete }
        rebuild("refs/tags/v1"); let single = menu.items.first { $0.title == "Delete refs/tags/v1" }!; send(single); try await wait()
        precondition(prompted == ["refs/tags/v1"] && model.error == nil)
        let removed = try await repo.run(["show-ref", "--verify", "--quiet", "refs/tags/v1"], successfulExitCodes: 0...1); precondition(removed.exitCode == 1)
        prompted = []; model.confirmReferenceDeletion = { request in prompted.append(request.name); return request.name == "refs/heads/topic" ? .delete : .abort }
        rebuild(nil); send(menu.items.first { $0.title == "Delete branch/tag" }!.submenu!.items.last!); try await wait()
        precondition(prompted == ["refs/heads/topic", "refs/tags/v2"])
        let branchRemoved = try await repo.run(["show-ref", "--verify", "--quiet", "refs/heads/topic"], successfulExitCodes: 0...1); precondition(branchRemoved.exitCode == 1)
        let tagRetained = try await repo.run(["show-ref", "--verify", "refs/tags/v2"]); precondition(tagRetained.exitCode == 0)
        // Real lock failure after one success must stop All before the tag,
        // acknowledge once, and reload the partial result.
        for name in ["refs/heads/a", "refs/heads/b"] { _ = try await repo.run(["update-ref", name, "HEAD"]) }
        model.reload(); try await wait()
        let lock = root.appendingPathComponent(".git/refs/heads/b.lock"); try Data("owned lock\n".utf8).write(to: lock)
        prompted = []; var failures: [String] = []
        model.confirmReferenceDeletion = { request in prompted.append(request.name); return .delete }
        model.acknowledgeReferenceDeletionFailure = { failures.append($0) }
        rebuild(nil); send(menu.items.first { $0.title == "Delete branch/tag" }!.submenu!.items.last!); try await wait()
        precondition(prompted == ["refs/heads/a", "refs/heads/b"] && failures.count == 1)
        let firstRemoved = try await repo.run(["show-ref", "--verify", "--quiet", "refs/heads/a"], successfulExitCodes: 0...1)
        let secondRetained = try await repo.run(["show-ref", "--verify", "refs/heads/b"])
        precondition(firstRemoved.exitCode == 1 && secondRetained.exitCode == 0 && model.entries.first { $0.hash == hash }!.references.contains { $0.name == "refs/heads/b" })
        try FileManager.default.removeItem(at: lock)
        rebuild("refs/tags/v2"); let closedItem = menu.items.first { $0.title == "Delete refs/tags/v2" }!
        let count = prompted.count; model.invalidate(); send(closedItem); try await wait(); precondition(prompted.count == count)
        let headAfter = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), mainAfter = try Data(contentsOf: root.appendingPathComponent(".git/refs/heads/main"))
        precondition(headAfter == head && mainAfter == main)
    }

}
