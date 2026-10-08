import AppKit
import SwiftUI
import TurtleGitCore

@main struct ThreePaneEndingsVerification {
    @MainActor static func views(_ parent: NSView) -> [NSTextView] {
        (parent as? NSTextView).map { [$0] } ?? parent.subviews.flatMap { views($0) }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let menuSuite = "TurtleGit.MergeMenu.QA." + UUID().uuidString
        let menuDefaults = UserDefaults(suiteName: menuSuite)!
        defer { menuDefaults.removePersistentDomain(forName: menuSuite); menuDefaults.synchronize() }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Alignment QA"])
        _ = try await repo.run(["config", "user.email", "alignment@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["config", "core.autocrlf", "false"])
        let paths = MergeLineEnding.allCases.indices.map { "source-\($0).txt" }
        func contents(_ ending: MergeLineEnding, _ side: String) -> String {
            let prefix = (0..<80).map { side == "theirs" && $0 == 10 ? "independent" : "context \($0)" }
            let middle = side == "base" ? ["old"] : side == "mine" ? ["mine1 🦎", "mine2"] : ["theirs 雪"]
            return (prefix + ["head"] + middle + ["tail"]).joined(separator: ending.rawValue)
        }
        func write(_ side: String) throws {
            for (index, ending) in MergeLineEnding.allCases.enumerated() {
                try Data(contents(ending, side).utf8).write(to: root.appendingPathComponent(paths[index]))
            }
        }
        try write("base"); try await repo.stage(paths); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        try write("theirs"); try await repo.stage(paths); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try write("mine"); try await repo.stage(paths); _ = try await repo.commit(message: "mine")
        _ = try await repo.run(["merge", "--no-edit", "feature"], successfulExitCodes: 0...1)
        let conflicts = try await repo.conflicts(); precondition(conflicts.count == 9)
        let initialHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let initialIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let workingBytes = try Dictionary(uniqueKeysWithValues: paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
        for (index, ending) in MergeLineEnding.allCases.enumerated() {
            let controller = TextConflictWindowController(repository: repo, access: nil, path: paths[index])
            let model = controller.model
            model.editorPreferences.enableEditorConfig = false
            model.load()
            for _ in 0..<1000 {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                if !model.busy, let host = controller.window?.contentView, views(host).count >= 3 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(model.error == nil && model.sourceComparison?.rows.count == 86)
            let document = model.document!, rows = model.sourceComparison!.rows
            precondition(document.mine == contents(ending, "mine") && document.theirs == contents(ending, "theirs"))
            precondition(rows.suffix(5).map(\.mine.lineNumber) == [81, nil, 82, 83, 84])
            precondition(rows.suffix(5).map(\.theirs.lineNumber) == [81, nil, 82, nil, 83])
            let textViews = views(controller.window!.contentView!)
            let mine = textViews.first { $0.accessibilityLabel() == "Mine" }!
            let theirs = textViews.first { $0.accessibilityLabel() == "Theirs" }!
            precondition(!mine.isEditable && !theirs.isEditable)
            precondition(mine.string == rows.map(\.mine.displayText).joined(separator: "\n") + "\n")
            precondition(theirs.string == rows.map(\.theirs.displayText).joined(separator: "\n") + "\n")
            precondition(MergeLineEndings.styles(in: mine.string) == [.lf])
            let mineScroll = mine.enclosingScrollView!, theirScroll = theirs.enclosingScrollView!
            precondition((mineScroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers == rows.map(\.mine.lineNumber))
            precondition((theirScroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers == rows.map(\.theirs.lineNumber))
            mineScroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); mineScroll.reflectScrolledClipView(mineScroll.contentView)
            model.sourceDidScroll(mineScroll)
            precondition(mineScroll.contentView.bounds.minY > 0 && abs(mineScroll.contentView.bounds.minY - theirScroll.contentView.bounds.minY) < 1)
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            clipboard.declareTypes([.string], owner: nil)
            mine.setSelectedRange(NSRange(location: 0, length: (mine.string as NSString).length))
            precondition(mine.writeSelection(to: clipboard, type: .string))
            let prefix = (0..<80).map { "context \($0)" }
            precondition(clipboard.string(forType: .string) == (prefix + ["head", "old", "mine1 🦎", "mine2", "tail"]).joined(separator: "\n"))
            theirs.setSelectedRange(NSRange(location: 0, length: (theirs.string as NSString).length))
            precondition(theirs.writeSelection(to: clipboard, type: .string))
            let otherPrefix = Array(prefix.prefix(11)) + ["independent"] + Array(prefix.dropFirst(11))
            precondition(clipboard.string(forType: .string) == (otherPrefix + ["head", "old", "theirs 雪", "", "tail"]).joined(separator: "\n"))
            let emoji = (mine.string as NSString).range(of: "🦎")
            mine.setSelectedRange(emoji); precondition(mine.writeSelection(to: clipboard, type: .string))
            precondition(clipboard.string(forType: .string) == "🦎")
            let gap = rows.firstIndex { $0.mine.state == .empty }!
            let gapOffset = rows.prefix(gap).reduce(0) { $0 + ($1.mine.displayText as NSString).length + 1 }
            mine.setSelectedRange(NSRange(location: gapOffset, length: 1))
            precondition(!mine.writeSelection(to: clipboard, type: .string) && clipboard.string(forType: .string) == "🦎")
            mine.setSelectedRange(NSRange(location: 0, length: 0))
            precondition(!mine.writeSelection(to: clipboard, type: .string))
            precondition(!mine.writeSelection(to: clipboard, type: .rtf))
            mine.setSelectedRange(NSRange(location: 0, length: (mine.string as NSString).length))
            let sourceMenu = (mine as! MergeContextMenuProviding).mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
            precondition(sourceMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Copy", "Find…", "Go to Line…", "Use this whole file"])
            precondition(sourceMenu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
            let mineCells = rows.map(\.mine)
            let navigation = mine as! MergeLineNavigationProviding
            let goto = sourceMenu.item(withTitle: "Go to Line…")!
            precondition(goto.isEnabled && goto.keyEquivalent == "g" && goto.keyEquivalentModifierMask == .control)
            let expectedLast = MergeSourceComparison.navigationRange(line: mineCells.compactMap(\.lineNumber).last!, cells: mineCells)!
            navigation.chooseNavigationLine = { owner, limit in
                precondition(owner === controller.window && limit == mineCells.compactMap(\.lineNumber).last!)
                return limit
            }
            _ = NSApp.sendAction(goto.action!, to: goto.target, from: goto)
            while navigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(mine.selectedRange() == expectedLast)
            for choice: Int? in [nil, 0, Int.max] {
                navigation.chooseNavigationLine = { _, _ in choice }
                _ = NSApp.sendAction(goto.action!, to: goto.target, from: goto)
                while navigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
                precondition(mine.selectedRange() == expectedLast)
            }
            let merged = textViews.first { $0.accessibilityLabel()?.hasPrefix("Merged ·") == true }!
            let firstBlock = model.blocks.first!
            merged.setSelectedRange(firstBlock.range)
            let provider = merged as! MergeContextMenuProviding
            let resultNavigation = merged as! MergeLineNavigationProviding
            let resultGoto = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard).item(withTitle: "Go to Line…")!
            let resultRanges = MergeSourceComparison.navigationRanges(text: merged.string)
            resultNavigation.chooseNavigationLine = { _, limit in precondition(limit == resultRanges.count); return limit }
            let unmodifiedResult = model.result
            _ = NSApp.sendAction(resultGoto.action!, to: resultGoto.target, from: resultGoto)
            while resultNavigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(merged.selectedRange() == resultRanges.last! && model.result == unmodifiedResult && !model.dirty)
            merged.setSelectedRange(firstBlock.range)
            let resultMenu = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
            precondition(resultMenu.items.prefix(3).map(\.title) == ["Copy", "Cut", "Paste"])
            precondition(resultMenu.items.prefix(3).allSatisfy { $0.image != nil && ($0.target as? NSTextView) === merged })
            precondition(resultMenu.item(withTitle: "Paste")!.isEnabled)
            let blockItems = resultMenu.items.filter { $0.action == NSSelectorFromString("useBlock:") }
            precondition(blockItems.count == 4 && blockItems.allSatisfy { $0.image != nil && $0.isEnabled })
            let format = resultMenu.item(withTitle: "Line endings")!.submenu!.item(withTitle: "CR")!
            menuDefaults.set(false, forKey: "ShowAppContextMenuIcons")
            let hiddenIcons = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
            print("ICON POLICY DIAGNOSTIC", MenuPresentationSettings.applicationContextIcons(defaults: menuDefaults), hiddenIcons.items.map { ($0.title, $0.image != nil, $0.isSeparatorItem) }); fflush(stdout)
            precondition(hiddenIcons.items.allSatisfy { $0.image == nil })
            menuDefaults.set(true, forKey: "ShowAppContextMenuIcons")
            clipboard.clearContents()
            precondition(!provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard).item(withTitle: "Paste")!.isEnabled)
            let untouchedResult = model.result
            for quit in [false, true] {
                model.busy = !quit; model.confirmingQuit = quit
                let locked = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
                precondition(!locked.item(withTitle: "Cut")!.isEnabled && !locked.item(withTitle: "Paste")!.isEnabled)
                precondition(locked.items.filter { $0.action == NSSelectorFromString("useBlock:") }.allSatisfy { !$0.isEnabled })
                precondition(locked.item(withTitle: "Line endings")!.submenu!.items.allSatisfy { !$0.isEnabled })
                precondition(locked.item(withTitle: "File Encoding")!.submenu!.items.allSatisfy { !$0.isEnabled })
                let sourceLocked = (mine as! MergeContextMenuProviding).mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
                precondition(!sourceLocked.item(withTitle: "Use this whole file")!.isEnabled && sourceLocked.item(withTitle: "Copy")!.isEnabled)
                precondition(!sourceLocked.item(withTitle: "Go to Line…")!.isEnabled)
                navigation.chooseNavigationLine = { _, _ in preconditionFailure("Blocked Go to Line invoked chooser") }
                _ = NSApp.sendAction(goto.action!, to: goto.target, from: goto)
                precondition(!navigation.navigationPending && mine.selectedRange() == expectedLast)
                precondition(!merged.validateMenuItem(format) && !merged.validateMenuItem(blockItems[0]))
                _ = NSApplication.shared.sendAction(format.action!, to: format.target, from: format)
                _ = NSApplication.shared.sendAction(blockItems[0].action!, to: blockItems[0].target, from: blockItems[0])
                precondition(model.result == untouchedResult)
            }
            model.busy = false; model.confirmingQuit = false
            model.resetHistory()
            let history = merged.undoManager!; history.groupsByEvent = false; history.beginUndoGrouping()
            _ = NSApplication.shared.sendAction(format.action!, to: format.target, from: format)
            history.endUndoGrouping()
            precondition(model.result == MergeLineEndings.converting(untouchedResult, to: .cr) && model.dirty)
            model.undo(); precondition(model.result == untouchedResult && !model.dirty)
            model.redo(); precondition(model.result == MergeLineEndings.converting(untouchedResult, to: .cr))
            model.undo(); model.resetHistory()
            precondition(!model.dirty)
            controller.close()
        }
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(initialHead == finalHead && initialIndex == finalIndex)
        for path in paths { let bytes = try Data(contentsOf: root.appendingPathComponent(path)); precondition(bytes == workingBytes[path]) }
        print("PASS: nine actual unmerged Git source pairs loaded by native three-pane controllers; all ending styles retain exact stage text, source numbering, read-only aligned rows/gaps and linked scrolling; native private-pasteboard Copy includes removed/conflict rows, skips Empty gaps, normalizes LF and retains emoji/partial selection, empty selection does not replace clipboard. HEAD/raw index/conflicted working bytes retained; Go to Line maps original source numbers past removed/gap rows and raw result last line; injected Cancel/out-of-range choices preserve selection, busy/Quit action guards pass; explicit native menu targets/original icons and icon setting, private Paste availability, busy/Quit metadata and direct-action refusal, enabled CR format action/Undo/Redo verified; owned hidden windows closed. No main app, physical input, screenshots or signed acceptance.")
    }
}
