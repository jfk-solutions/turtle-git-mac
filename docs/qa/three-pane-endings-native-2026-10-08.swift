import AppKit
import SwiftUI
import TurtleGitCore

@main struct ThreePaneEndingsVerification {
    @MainActor static func views(_ parent: NSView) -> [NSTextView] {
        (parent as? NSTextView).map { [$0] } ?? parent.subviews.flatMap { views($0) }
    }
    // The four original source commands remain ordered, but the current native
    // menu also exposes the completed search/navigation, pane and format family.
    // Pinned BaseView::AddCutCopyAndPaste / RightView::AddContextItems /
    // BottomView::AddContextItems distinguish source versus writable result.
    @MainActor static func verifyMenu(_ menu: NSMenu, source: Bool, view: NSTextView,
                                     model: TextConflictWindowModel, icons: Bool = true) {
        let common = ["Find…", "Find Next Selected Text", "Find Previous Selected Text", "Clear Search Highlights",
                      "Mark Word at Caret in All Panes", "Clear Marked Word", "Go to Line…",
                      "Previous difference", "Next difference", "Previous conflict", "Next conflict", "View"]
        let blocks = ["Use text block from Mine", "Use text block from Theirs", "Use Mine before Theirs", "Use Theirs before Mine"]
        let suffix = source ? blocks + ["Save this pane as…", "Compare with Base", "Use this whole file", "Reload with encoding"]
                            : blocks + ["Convert tabs to spaces", "Convert spaces to tabs", "Trim right", "Line endings", "File Encoding"]
        let expected = (source ? ["Copy"] : ["Copy", "Cut", "Paste"]) + common + suffix
        let items = menu.items.filter { !$0.isSeparatorItem }
        precondition(items.map(\.title) == expected, "Unexpected native \(source ? "source" : "result") menu: \(items.map(\.title))")
        if source {
            let original = ["Copy", "Find…", "Go to Line…", "Use this whole file"]
            precondition(items.filter { original.contains($0.title) }.map(\.title) == original)
        }
        for item in items {
            precondition((item.image != nil) == icons, "Icon policy differs for \(item.title)")
            if let submenu = item.submenu {
                // AppKit may install its submenu-opening action when attaching
                // a submenu. This structural header is not a pane command leaf.
                precondition(["View", "Reload with encoding", "Line endings", "File Encoding"].contains(item.title))
                // AppKit owns the submenu-opening target/action and may adjust
                // the NSMenu title. Assert visible caption and exact ownership,
                // not those incidental implementation-managed properties.
                let ownerMatches=item.menu === menu
                let supermenuMatches=submenu.supermenu === menu
                let childrenOwned=submenu.items.allSatisfy { $0.menu === submenu }
                precondition(ownerMatches && supermenuMatches && childrenOwned && submenu !== menu && item.tag == 0 && item.keyEquivalent.isEmpty,
                    "Invalid submenu hierarchy: caption=\(item.title), owner=\(ownerMatches), supermenu=\(supermenuMatches), childrenOwned=\(childrenOwned), tag=\(item.tag), key=\(item.keyEquivalent.debugDescription), children=\(submenu.items.count)")
            } else if let action = item.action {
                precondition((item.target as? NSObject)?.responds(to:action) == true, "Native target missing: \(item.title)")
                if ["Copy", "Cut", "Paste"].contains(item.title) {
                    precondition(item.target as AnyObject? !== view && item.representedObject as AnyObject? === item.target as AnyObject?)
                    let selectors = ["Copy":"copySelection:", "Cut":"cutSelection:", "Paste":"pasteSelection:"]
                    precondition(action == NSSelectorFromString(selectors[item.title]!))
                } else { precondition(item.target as AnyObject? === view, "Action escaped its exact native pane: \(item.title)") }
            } else { preconditionFailure("Unexpected commandless leaf: \(item.title)") }
            let key: String = ["Go to Line…", "Find Next Selected Text", "Find Previous Selected Text"].contains(item.title) ? "g" : ""
            precondition(item.keyEquivalent == key, "Shortcut differs for \(item.title)")
        }
        let commonActions = ["Find…":"showFind:", "Find Next Selected Text":"turtleFindSelectionNext:",
            "Find Previous Selected Text":"turtleFindSelectionPrevious:", "Clear Search Highlights":"turtleClearFindHighlights:",
            "Mark Word at Caret in All Panes":"turtleMarkWord:", "Clear Marked Word":"turtleClearMarkedWord:",
            "Previous difference":"previousDifference:", "Next difference":"nextDifference:",
            "Previous conflict":"previousConflict:", "Next conflict":"nextConflict:"]
        for (title,action) in commonActions { precondition(menu.item(withTitle:title)!.action == NSSelectorFromString(action)) }
        let next = menu.item(withTitle:"Find Next Selected Text")!, previous = menu.item(withTitle:"Find Previous Selected Text")!
        precondition(next.keyEquivalentModifierMask == [.command,.option] && previous.keyEquivalentModifierMask == [.command,.option,.shift])
        let go = menu.item(withTitle:"Go to Line…")!
        precondition(go.action == NSSelectorFromString("goToSourceLine:") && go.keyEquivalentModifierMask == .control)
        let inspection = menu.item(withTitle:"View")!.submenu!
        precondition(inspection.items.map(\.title) == ["Line diff bar", "Line numbers"])
        for (index,item) in inspection.items.enumerated() {
            precondition(item.action == NSSelectorFromString(index == 0 ? "toggleLineDiffBar:" : "toggleLineNumbers:") && item.target as AnyObject? === view)
            precondition(item.state == ((index == 0 ? model.showLineDiffBar : model.showLineNumbers) ? .on : .off))
            precondition((item.image != nil) == icons && item.keyEquivalent.isEmpty)
        }
        let blockItems = items.filter { blocks.contains($0.title) }
        precondition(blockItems.map(\.tag) == [0,1,2,3] && blockItems.allSatisfy { $0.action == NSSelectorFromString(source ? "useSourceBlock:" : "useBlock:") })
        if source {
            precondition(menu.item(withTitle:"Save this pane as…")!.action == NSSelectorFromString("saveSourceAs:"))
            precondition(menu.item(withTitle:"Compare with Base")!.action == NSSelectorFromString("compareSourceWithBase:"))
            precondition(menu.item(withTitle:"Use this whole file")!.action == NSSelectorFromString("useSourceFile:"))
        } else {
            let endings = menu.item(withTitle:"Line endings")!.submenu!
            precondition(endings.items.map(\.title) == MergeLineEnding.allCases.map(\.menuTitle))
            for (index,item) in endings.items.enumerated() {
                precondition(item.tag == index && item.action == NSSelectorFromString("convertLineEndings:") && item.target as AnyObject? === view && (item.image != nil) == icons)
                precondition(item.state == (MergeLineEndings.styles(in:model.resultFormatText) == [MergeLineEnding.allCases[index]] ? .on : .off))
            }
        }
        let encodingMenu = menu.item(withTitle:source ? "Reload with encoding" : "File Encoding")!.submenu!
        let encoding = source ? model.document!.mineEncoding : model.encoding
        let legacy = encoding?.legacyCodePage != nil ? encoding! : model.legacyEncoding
        precondition(encodingMenu.items.map(\.title) == MergeFormatSelection.encodingChoices(legacy:legacy).map(\.rawValue))
        for (index,item) in encodingMenu.items.enumerated() {
            precondition((item.image != nil) == icons && item.keyEquivalent.isEmpty)
            precondition(item.state == (item.title == encoding?.rawValue ? .on : .off))
            precondition(item.action != nil && (item.target as? NSObject)?.responds(to:item.action!) == true)
            if source { precondition(item.action == NSSelectorFromString("chooseInputEncoding:") && item.representedObject as AnyObject? === item.target as AnyObject?) }
            else { precondition(item.tag == index && item.action == NSSelectorFromString("changeEncoding:") && item.target as AnyObject? === view && item.representedObject as? String == item.title) }
        }
    }
    static func convertedVisibleResult(_ text:String, conflicts:[NSRange], ending:MergeLineEnding)->String {
        // Unresolved marker payloads serialize hidden conflict records, not
        // editable view lines. Only the visible surrounding records convert.
        let raw=text as NSString
        var output="",offset=0
        for range in conflicts.sorted(by:{$0.location < $1.location}) {
            precondition(range.location>=offset && NSMaxRange(range)<=raw.length)
            output += MergeLineEndings.converting(raw.substring(with:NSRange(location:offset,length:range.location-offset)),to:ending)
            output += raw.substring(with:range);offset=NSMaxRange(range)
        }
        return output+MergeLineEndings.converting(raw.substring(from:offset),to:ending)
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Three-pane source verification failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
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
            let controller = TextConflictWindowController(repository: repo, access: nil, path: paths[index], preferences: menuDefaults)
            defer { controller.close() }
            controller.window?.alphaValue = 0
            controller.window?.setFrameOrigin(NSPoint(x: -24000, y: -24000))
            controller.window?.orderFront(nil)
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
            // Native pointer scrolling admits only attached, visible, settled panes.
            // Keep the real owner ordered but transparent and offscreen.
            for _ in 0..<1000 {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                if !model.lineWrapping.isGeometryPending,
                   (mine as? MergeContextMenuProviding)?.mergeSourceRowsReady == true,
                   (theirs as? MergeContextMenuProviding)?.mergeSourceRowsReady == true { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(controller.window?.isVisible == true && !model.lineWrapping.isGeometryPending)
            precondition((mine as? MergeContextMenuProviding)?.mergeSourceRowsReady == true && (theirs as? MergeContextMenuProviding)?.mergeSourceRowsReady == true)
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
            verifyMenu(sourceMenu, source:true, view:mine, model:model)
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
            let displayedBlock = model.alignedResultProjection!.displayRange(serializedRange:firstBlock.range)!
            merged.setSelectedRange(displayedBlock)
            let provider = merged as! MergeContextMenuProviding
            let resultNavigation = merged as! MergeLineNavigationProviding
            let resultGoto = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard).item(withTitle: "Go to Line…")!
            // The result now has aligned cells too: its numbered logical lines
            // omit removed/gap records, although those remain in native display.
            let resultCells = model.alignedResultProjection!.cells
            let resultLastLine = resultCells.compactMap(\.lineNumber).last!
            let resultLastRange = MergeSourceComparison.navigationRange(line:resultLastLine,cells:resultCells)!
            precondition((merged.string as NSString).substring(with:resultLastRange) == "tail")
            resultNavigation.chooseNavigationLine = { owner, limit in precondition(owner === controller.window && limit == resultLastLine); return limit }
            let unmodifiedResult = model.result
            _ = NSApp.sendAction(resultGoto.action!, to: resultGoto.target, from: resultGoto)
            while resultNavigation.navigationPending { try await Task.sleep(nanoseconds: 1_000_000) }
            precondition(merged.selectedRange() == resultLastRange && model.result == unmodifiedResult && !model.dirty)
            merged.setSelectedRange(displayedBlock)
            let resultMenu = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
            verifyMenu(resultMenu, source:false, view:merged, model:model)
            precondition(resultMenu.items.prefix(3).map(\.title) == ["Copy", "Cut", "Paste"])
            precondition(resultMenu.items.prefix(3).allSatisfy { $0.image != nil && $0.action != nil && ($0.target as? NSObject)?.responds(to: $0.action!) == true })
            precondition(resultMenu.item(withTitle: "Paste")!.isEnabled)
            let blockItems = resultMenu.items.filter { $0.action == NSSelectorFromString("useBlock:") }
            precondition(blockItems.count == 4 && blockItems.allSatisfy { $0.image != nil && $0.isEnabled })
            let format = resultMenu.item(withTitle: "Line endings")!.submenu!.item(withTitle: "CR")!
            menuDefaults.set(false, forKey: "ShowAppContextMenuIcons")
            let hiddenIcons = provider.mergeContextMenu(defaults: menuDefaults, pasteboard: clipboard)
            verifyMenu(hiddenIcons, source:false, view:merged, model:model, icons:false)
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
                precondition(!sourceLocked.item(withTitle: "Use this whole file")!.isEnabled && sourceLocked.item(withTitle: "Copy")!.isEnabled == !quit)
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
            // A retained blocked menu is still the refusal witness above. The
            // affirmative phase captures the actual current native editor/menu
            // after writability and aligned-cell publication have settled.
            var liveMerged:NSTextView?
            for _ in 0..<1000 {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                let candidate=views(controller.window!.contentView!).first { $0.accessibilityLabel()?.hasPrefix("Merged ·")==true }
                if let candidate,let candidateProvider=candidate as? MergeContextMenuProviding,
                   candidate.window === controller.window,candidate.isEditable,candidateProvider.mergeSourceRowsReady,
                   model.sourceToolsAllowed,model.selectionRequest==nil,candidate.string==model.resultDisplayText {
                    liveMerged=candidate;break
                }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            guard let liveMerged else {throw NSError(domain:"Three-pane format admission",code:1,userInfo:[NSLocalizedDescriptionKey:"ending=\(ending.menuTitle), busy=\(model.busy), quit=\(model.confirmingQuit), nativeReady=\(model.nativeEditorReady), tools=\(model.sourceToolsAllowed), pending=\(String(describing:model.selectionRequest)), error=\(model.error ?? "none")"])}
            let liveProvider=liveMerged as! MergeContextMenuProviding
            let baseline=model.resultPresentation,beforeEncoding=model.encoding,beforeEnding=model.resultLineEnding
            let baselineCells=model.alignedResultProjection!.cells
            let retainedConflicts=model.blocks.filter{!$0.isIgnored}.map(\.range)
            precondition(model.result.utf8.elementsEqual(untouchedResult.utf8) && !model.dirty)
            model.resetHistory()
            let history=liveMerged.undoManager!;history.groupsByEvent=false
            @MainActor func applyEnding(_ target:MergeLineEnding) throws {
                let fresh=liveProvider.mergeContextMenu(defaults:menuDefaults,pasteboard:clipboard)
                verifyMenu(fresh,source:false,view:liveMerged,model:model)
                let selected=fresh.item(withTitle:"Line endings")!.submenu!.item(withTitle:target.menuTitle)!
                precondition(selected.isEnabled && liveMerged.validateMenuItem(selected) && selected.target as AnyObject? === liveMerged,
                    "Current ending action not admitted: input=\(ending.menuTitle), target=\(target.menuTitle), editable=\(liveMerged.isEditable), ready=\(liveProvider.mergeSourceRowsReady)")
                history.beginUndoGrouping()
                let dispatched=NSApp.sendAction(selected.action!,to:selected.target,from:selected)
                history.endUndoGrouping()
                precondition(dispatched,"Current native ending action was not dispatched")
                let expected=convertedVisibleResult(untouchedResult,conflicts:retainedConflicts,ending:target)
                let expectedCells=baselineCells.map { cell in cell.state.isViewEmpty ? cell.text:MergeLineEndings.converting(cell.text,to:target) }
                precondition(model.result.utf8.elementsEqual(expected.utf8),
                    "Visible ending serialization differs: input=\(ending.menuTitle), target=\(target.menuTitle), actualBytes=\(model.result.utf8.count), expectedBytes=\(expected.utf8.count), error=\(model.error ?? "none")")
                precondition(model.encoding==beforeEncoding && model.resultLineEnding==target)
                precondition(model.alignedResultProjection!.cells.map{Data($0.text.utf8)} == expectedCells.map{Data($0.utf8)},"Ending conversion changed exact aligned record payloads")
                precondition(model.blocks.filter{!$0.isIgnored}.map { (model.result as NSString).substring(with:$0.range) } == retainedConflicts.map { (untouchedResult as NSString).substring(with:$0) },"Ending conversion rewrote retained unresolved payload")
            }
            try applyEnding(.cr)
            let crChangesRecords=baselineCells.contains { !$0.state.isViewEmpty && !MergeLineEndings.converting($0.text,to:.cr).utf8.elementsEqual($0.text.utf8) }
            if !crChangesRecords && beforeEnding == .cr {
                // Existing native no-op policy (applyFormatChoice's exact
                // equality guard) does not invent a dirty/history operation.
                precondition(model.resultPresentation==baseline && !model.dirty && !model.canUndo)
                // Still exercise a real changed ending plus strict Undo/Redo
                // for this already-CR input without weakening the no-op check.
                try applyEnding(.lf)
            }
            let formatted=model.resultPresentation,formattedEnding=model.resultLineEnding
            precondition(model.dirty && model.canUndo)
            model.undo()
            precondition(model.resultPresentation==baseline && model.result.utf8.elementsEqual(untouchedResult.utf8) && model.encoding==beforeEncoding && model.resultLineEnding==beforeEnding && !model.dirty && model.canRedo)
            model.redo()
            precondition(model.resultPresentation==formatted && model.resultLineEnding==formattedEnding && model.encoding==beforeEncoding && model.dirty)
            model.undo();model.resetHistory()
            precondition(model.resultPresentation==baseline && model.result.utf8.elementsEqual(untouchedResult.utf8) && !model.dirty && !model.canUndo && !model.canRedo)
            controller.close()
        }
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(initialHead == finalHead && initialIndex == finalIndex)
        for path in paths { let bytes = try Data(contentsOf: root.appendingPathComponent(path)); precondition(bytes == workingBytes[path]) }
        print("PASS: nine actual unmerged Git source pairs loaded by native three-pane controllers; all ending styles retain exact stage text, source numbering, read-only aligned rows/gaps and linked scrolling; native private-pasteboard Copy includes removed/conflict rows, skips Empty gaps, normalizes LF and retains emoji/partial selection, empty selection does not replace clipboard. HEAD/raw index/conflicted working bytes retained; Go to Line maps original source numbers past removed/gap rows and raw result last line; injected Cancel/out-of-range choices preserve selection, busy/Quit action guards pass; explicit native menu targets/original icons and icon setting, private Paste availability, busy/Quit metadata and direct-action refusal, enabled CR format action/Undo/Redo verified; owned hidden windows closed. No main app, physical input, screenshots or signed acceptance.")
    }
}
