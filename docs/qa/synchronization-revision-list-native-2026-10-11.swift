// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore
@testable import TurtleGitMac

struct SynchronizationRevisionListVerification {
    @MainActor static func settle(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Sync revision list did not settle at fixture line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func table(_ window: NSWindow) -> NSTableView {
        window.contentView!.layoutSubtreeIfNeeded()
        return descendants(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumn(withIdentifier: .init("actions")) != nil }!
    }
    @MainActor static func verifyFind(_ owner: SynchronizationWindowController, outgoing: [LogEntry], incoming: [LogEntry]) async throws {
        let model = owner.model, window = owner.window!
        // This receiver is not an app bundle. Use the real Debug app's
        // packaged C++ matcher in the production controller's injectable route.
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = Bundle(url: project.appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app"))!
        let matcher = try IssueRegexRuntime.executable(bundle: app)
        let originalFindRoute = model.onHistoryFind
        defer { model.onHistoryFind = originalFindRoute }
        model.onHistoryFind = { [weak owner] tab, index in owner?.showHistoryFind(sourceTab: tab, selectionIndex: index, regexExecutable: matcher) }
        func menu(_ indexes: IndexSet) -> NSMenu {
            let list = table(window); list.selectRowIndexes(indexes, byExtendingSelection: false)
            let menu = list.menu!; menu.delegate?.menuNeedsUpdate?(menu); return menu
        }
        func invoke(_ item: NSMenuItem) { precondition(item.isEnabled && NSApp.sendAction(item.action!, to: item.target, from: item)) }
        func key(_ window: NSWindow, text: String, modifiers: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        model.tab = 0; try await settle { table(window).numberOfRows == outgoing.count }
        let single = menu(IndexSet(integer: 0)), capturedFind = single.items.first { $0.title == "Find" }!
        let capturedTarget = capturedFind.target // Retain the originating coordinator across tab replacement.
        precondition(capturedFind.image != nil)
        let titles = single.items.map(\.title)
        precondition(titles.firstIndex(of: "Find")! == titles.firstIndex(of: "Copy to clipboard")! + 1)
        precondition(titles.firstIndex(of: "Show branches this commit is on")! == titles.firstIndex(of: "Find")! + 1)
        precondition(menu(IndexSet([0, 1])).items.filter { $0.title == "Find" }.count == 1)
        single.delegate?.menuDidClose?(single)
        model.tab = 4; try await settle { table(window).numberOfRows == incoming.count }
        let incomingBefore = model.historyNavigation[4]?.id
        precondition(NSApp.sendAction(capturedFind.action!, to: capturedTarget, from: capturedFind))
        let outFind = owner.historyFind[0]!, outWindow = outFind.window!
        precondition(outWindow.parent === window && outWindow.alphaValue == window.alphaValue && outFind.searchIndex() == 0)
        try await settle { !outFind.loadingReferences }
        precondition(outFind.references.contains("refs/heads/main") && outFind.references.contains("refs/remotes/origin/main"))
        if CommandLine.arguments.count > 3 {
            let output = URL(fileURLWithPath: CommandLine.arguments[3])
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let appearance = outWindow.appearance
            for (theme, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                outWindow.appearance = NSAppearance(named: name)
                outWindow.contentView!.layoutSubtreeIfNeeded(); outWindow.contentView!.displayIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let pixels = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(outWindow.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { preconditionFailure("Find capture unavailable") }
                try NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("sync-find-" + theme + ".png"))
            }
            outWindow.appearance = appearance
        }
        let rootIndex = outgoing.firstIndex { $0.subject == "Root" }!
        outFind.searchBox.stringValue = "Root"; outFind.findNext()
        try await settle { !outFind.busy && model.historyNavigation[0]?.hash == outgoing[rootIndex].hash }
        precondition(model.tab == 4 && model.historyNavigation[4]?.id == incomingBefore)
        let selectedIncoming = table(window).selectedRowIndexes
        outFind.searchReference("refs/heads/remote-root")
        try await settle { !outFind.busy }
        precondition(outFind.status.stringValue.contains("No further match") && table(window).selectedRowIndexes == selectedIncoming)
        // A separate Find belongs to In Commits; Cmd+F does not reset the cursor.
        let inTable = table(window) as! HistoryTableView
        precondition(inTable.performKeyEquivalent(with: key(window, text: "f", modifiers: .command, code: 3)))
        let inFind = owner.historyFind[4]!
        precondition(inFind !== outFind && owner.historyFind.count == 2)
        try await settle { !inFind.loadingReferences }
        inFind.searchBox.stringValue = "Root"; inFind.findNext(); try await settle { !inFind.busy }
        precondition(inFind.status.stringValue.contains("No further match"))
        inFind.searchReference("refs/heads/side")
        try await settle { !inFind.busy && model.historyNavigation[4]?.hash == incoming.first { $0.subject.hasPrefix("Side parent") }?.hash }
        model.tab = 0
        try await settle { table(window).numberOfRows == outgoing.count && table(window).selectedRowIndexes == IndexSet(integer: rootIndex) }
        let outTable = table(window) as! HistoryTableView
        // Context Find focuses the same window and resets to its captured row.
        invoke(menu(IndexSet(integer: 0)).items.first { $0.title == "Find" }!)
        precondition(owner.historyFind[0] === outFind && outFind.searchIndex() == 0)
        outFind.matchCase.state = .on; outFind.searchBox.stringValue = "root"; outFind.findNext()
        try await settle { !outFind.busy }; precondition(outFind.status.stringValue.contains("No further match"))
        // LOGFILTER_ALL concatenates the subject with body/metadata/paths, so
        // a whole-corpus end anchor would not match a subject by itself.
        outFind.matchCase.state = .off; outFind.regex.state = .on; outFind.searchBox.stringValue = "^Main sec[o]nd"; outFind.findNext()
        let secondIndex = outgoing.firstIndex { $0.subject == "Main second" }!
        try await settle { !outFind.busy }
        precondition(!outFind.status.stringValue.contains("No further match"), outFind.status.stringValue)
        precondition(!outFind.acknowledgingFailure, "Regex search unexpectedly presented an error sheet")
        try await settle { !outFind.busy && outTable.selectedRowIndexes == IndexSet(integer: secondIndex) }
        precondition(model.preferences.bool(forKey: "LogDialog.FindRegex"))
        outFind.regex.state = .off; outFind.searchBox.stringValue = "qa@example.invalid"; outFind.findNext()
        try await settle { !outFind.busy && model.historyFindIndex[0] == secondIndex + 1 }
        // A changed-path search must use the complete history corpus, not just subjects.
        owner.showHistoryFind(sourceTab: 0, selectionIndex: 0)
        outFind.searchBox.stringValue = "tracked.txt"; outFind.findNext()
        let mergeIndex = outgoing.firstIndex { $0.subject == "Merge" }!
        try await settle { !outFind.busy && outTable.selectedRowIndexes == IndexSet(integer: mergeIndex) }
        owner.showHistoryFind(sourceTab: 0, selectionIndex: 0)
        outFind.searchBox.stringValue = "Root"
        outWindow.sendEvent(key(outWindow, text: "\r", modifiers: .shift, code: 36))
        try await settle { !outFind.busy && model.historyHighlights[0] == outgoing[rootIndex].hash && model.handledHistoryNavigation[0] == model.historyNavigation[0]?.id }
        precondition(outTable.selectedRowIndexes == IndexSet(integer: mergeIndex))
        let coordinator = outTable.delegate as! SynchronizationHistoryTable.Coordinator
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let rendered = coordinator.tableView(outTable, viewFor: outTable.tableColumn(withIdentifier: .init("message")), row: rootIndex) as! NSTableCellView
            precondition(NSFontManager.shared.traits(of: rendered.textField!.font!).contains(.italicFontMask))
        }
        // Ordinary row selection and keyboard reopening retain Find's cursor.
        outTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let retained = outFind.searchIndex()
        precondition(outTable.performKeyEquivalent(with: key(window, text: "f", modifiers: .command, code: 3)) && outFind.searchIndex() == retained)
        model.reload(); precondition(model.busy)
        try await settle { !outFind.searchBox.isEnabled && !inFind.searchBox.isEnabled }
        outFind.findNext(); precondition(!outFind.busy)
        try await settle { !model.busy && outFind.searchBox.isEnabled && inFind.searchBox.isEnabled }
        outFind.searchReference("refs/heads/not-a-real-find-reference")
        try await settle { outWindow.attachedSheet != nil }
        precondition(outFind.acknowledgingFailure && model.hasBlockingChild && !owner.windowShouldClose(window))
        let sheet = outWindow.attachedSheet!
        let ok = descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!
        ok.performClick(nil); try await settle { !outFind.acknowledgingFailure && outWindow.attachedSheet == nil && !model.hasBlockingChild }
        outFind.cancelButton.performClick(nil); try await settle { owner.historyFind[0] == nil }
        precondition(outFind.closed && outWindow.parent == nil && owner.historyFind[4] === inFind)
        let navigation = model.historyNavigation[0]?.id
        outFind.navigate(outgoing[0].hash, true); precondition(model.historyNavigation[0]?.id == navigation)
        precondition(outTable.performKeyEquivalent(with: key(window, text: "f", modifiers: .command, code: 3)))
        let reopened = owner.historyFind[0]!
        precondition(reopened !== outFind && reopened.searchIndex() == retained)
        reopened.close(); inFind.close(); precondition(owner.historyFind.isEmpty)
        // Parent closure force-closes both independently owned modeless dialogs.
        let closing = SynchronizationWindowController(repository: model.repository, access: nil, preferences: model.preferences)
        closing.showWindow(nil); try await settle { !closing.model.busy && !closing.model.hasBlockingChild }
        closing.showHistoryFind(sourceTab: 0); closing.showHistoryFind(sourceTab: 4)
        let children = Array(closing.historyFind.values); precondition(children.count == 2)
        try await settle { children.allSatisfy { !$0.loadingReferences } }
        let failing = closing.historyFind[0]!
        // Initial native combo/focus handoffs may schedule another reload;
        // wait for the actual search gate after both windows have loaded.
        try await settle { failing.canSearch() }
        failing.searchReference("refs/heads/not-a-real-find-reference")
        precondition(failing.busy, "Find error search did not start: canSearch=\(failing.canSearch()), loading=\(failing.loadingReferences), parentBusy=\(closing.model.busy), parentBlocked=\(closing.model.hasBlockingChild)")
        try await settle { !failing.busy }
        precondition(failing.acknowledgingFailure, "Find error was not acknowledged: status=\(failing.status.stringValue), canSearch=\(failing.canSearch()), parentBusy=\(closing.model.busy), parentBlocked=\(closing.model.hasBlockingChild)")
        try await settle { failing.acknowledgingFailure && failing.window?.attachedSheet != nil }
        precondition(!closing.windowShouldClose(closing.window!))
        closing.close(); precondition(closing.model.closed && closing.historyFind.isEmpty && children.allSatisfy { $0.closed && $0.window?.parent == nil && $0.window?.attachedSheet == nil })
        let closedNavigation = closing.model.historyNavigation
        children.forEach { $0.navigate(outgoing[0].hash, true) }
        precondition(closing.model.historyNavigation.count == closedNavigation.count)
        print("PASS: Sync Find context order/icon, captured origin, two-list independence, subject/metadata/path/regex/case search, Shift highlight, cursor, error ownership and cleanup")
    }
    @MainActor static func verifyExport(_ owner: SynchronizationWindowController, root: URL, git: URL, preferences: UserDefaults) async throws {
        let model = owner.model, repo = model.repository, window = owner.window!
        // The preceding off-list-parent test deliberately narrowed origin/main
        // to the side parent. Restore the unrelated fixture root temporarily so
        // Export also covers a displayed root commit, then restore that range.
        let narrowedRemote = try await repo.run(["rev-parse", "refs/remotes/origin/main"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "refs/heads/remote-root"])
        model.refresh()
        model.tab = 0
        try await settle { !model.busy && !model.hasBlockingChild && model.historyEntries.contains { $0.parents.isEmpty } && model.historyEntries.contains { $0.references.contains { $0.name.hasPrefix("refs/tags/") } } && table(window).numberOfRows == model.historyEntries.count }
        let outgoing = model.historyEntries
        func menu(_ indexes: IndexSet) -> NSMenu {
            let list = table(window); list.selectRowIndexes(indexes, byExtendingSelection: false)
            let menu = list.menu!; menu.delegate?.menuNeedsUpdate?(menu); return menu
        }
        func invoke(_ item: NSMenuItem) { precondition(item.isEnabled && NSApp.sendAction(item.action!, to: item.target, from: item)) }
        let refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let rootIndex = outgoing.firstIndex { $0.parents.isEmpty }!
        let captured = menu(IndexSet(integer: rootIndex)).items.first { $0.title == "Export this version…" }!
        let capturedTarget = captured.target
        precondition(captured.image != nil && !menu(IndexSet([0, 1])).items.contains { $0.title == "Export this version…" })
        precondition(window.attachedSheet == nil)
        table(window).menu!.delegate?.menuDidClose?(table(window).menu!)
        model.tab = 4; try await settle { table(window).numberOfRows == model.incomingCommits!.count }
        precondition(NSApp.sendAction(captured.action!, to: capturedTarget, from: captured))
        let first = owner.historyExportController!
        try await settle { !first.model.busy }
        precondition(first.window!.sheetParent === window && model.exportingHistory && model.hasBlockingChild && !owner.windowShouldClose(window))
        precondition(first.model.revision == outgoing[rootIndex].hash && first.model.target == .commit && first.model.wholeProject && first.model.directory.isEmpty)
        owner.showHistoryFind(sourceTab: 4); precondition(owner.historyFind.isEmpty)
        precondition(NSApp.sendAction(captured.action!, to: capturedTarget, from: captured) && owner.historyExportController === first)
        first.model.close(); try await settle { owner.historyExportController == nil && window.attachedSheet == nil && !model.exportingHistory }
        model.tab = 0; try await settle { table(window).numberOfRows == outgoing.count }
        let tagIndex = outgoing.firstIndex { $0.references.contains { $0.name.hasPrefix("refs/tags/") } }!
        let tags = outgoing[tagIndex].references.filter { $0.name.hasPrefix("refs/tags/") }
        let branch = outgoing[tagIndex].references.first { $0.name.hasPrefix("refs/heads/") }!
        _ = menu(IndexSet(integer: tagIndex))
        (table(window) as! HistoryTableView).contextReference = (tagIndex, branch.name)
        let tagMenu = table(window).menu!; tagMenu.delegate?.menuNeedsUpdate?(tagMenu)
        let exporting = tagMenu.items.first { $0.title == "Export this version…" }!
        precondition(tagMenu.items.firstIndex { $0.title == "Export this version…" }! > tagMenu.items.firstIndex { $0.title == "Create tag at this version…" }!)
        table(window).selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        invoke(exporting)
        let child = owner.historyExportController!
        try await settle { !child.model.busy }
        precondition(child.model.target == .tag && child.model.tag == tags[0].name && child.model.revision == tags[0].name)
        let destination = root.deletingLastPathComponent().appendingPathComponent("sync-export-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: destination) }
        child.model.destination = destination.path; child.model.export()
        try await settle { child.model.progress?.busy == false && child.model.progress?.success == true }
        let progress = child.model.progress!
        precondition(child.window!.attachedSheet != nil && model.hasBlockingChild && !owner.windowShouldClose(window))
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-p", destination.path, "tracked.txt"]
        let pipe = Pipe(); unzip.standardOutput = pipe; unzip.standardError = FileHandle.nullDevice
        try unzip.run(); let contents = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit()
        let expected = try await repo.run(["show", outgoing[tagIndex].hash + ":tracked.txt"]).stdout
        precondition(unzip.terminationStatus == 0 && contents == expected && contents == Data("resolution\n".utf8))
        progress.close(); try await settle { owner.historyExportController == nil && window.attachedSheet == nil && !model.exportingHistory }
        precondition(child.model.exported == destination)
        model.confirmingQuit = true
        precondition(NSApp.sendAction(exporting.action!, to: exporting.target, from: exporting) && owner.historyExportController == nil)
        model.confirmingQuit = false
        // Freeze only Export's catalog read, after Sync's own startup settles.
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        for forced in [false, true] {
            let directory = root.deletingLastPathComponent().appendingPathComponent("export-startup-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let trigger = directory.appendingPathComponent("trigger"), marker = directory.appendingPathComponent("pids"), helper = directory.appendingPathComponent("git")
            let script = """
            #!/bin/sh
            if [ -f \(quote(trigger.path)) ]; then
              for task_arg in "$@"; do
                if [ "$task_arg" = for-each-ref ]; then
                  /bin/sleep 60 &
                  task_child=$!
                  printf '%s %s\\n' "$$" "$task_child" > \(quote(marker.path + ".tmp"))
                  /bin/mv \(quote(marker.path + ".tmp")) \(quote(marker.path))
                  wait "$task_child"
                  exit 0
                fi
              done
            fi
            exec \(quote(git.path)) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slowRepo = GitRepository(root: root, executable: helper)
            let closing = SynchronizationWindowController(repository: slowRepo, access: nil, preferences: preferences)
            closing.showWindow(nil); defer { closing.close() }
            try await settle { !closing.model.busy && !closing.model.hasBlockingChild }
            try Data().write(to: trigger)
            closing.model.onHistoryExport?(outgoing[rootIndex].hash)
            let waiting = closing.historyExportController!
            try await settle { FileManager.default.fileExists(atPath: marker.path) }
            let pids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            precondition(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 } && waiting.model.busy)
            if forced { closing.close() } else { waiting.model.cancel() }
            try await settle { closing.historyExportController == nil && !closing.model.exportingHistory && pids.allSatisfy { kill($0, 0) != 0 } }
            precondition(waiting.model.references.isEmpty && waiting.model.currentBranch.isEmpty && waiting.model.error == nil && !waiting.model.busy)
        }
        let finalRefs = try await repo.run(["show-ref"]).stdout
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        precondition(finalRefs == refs && finalIndex == index && finalConfig == config)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", narrowedRemote])
        model.refresh(); try await settle { !model.busy && !model.hasBlockingChild }
        print("PASS: Sync Export source menu/icon, captured hash/tag, modal ownership, actual ZIP bytes, progress close, startup Cancel/forced owner close, process cleanup and unchanged Git state")
    }
    @MainActor static func verifyComparisonSelectionCases(root: URL, git: URL, preferences: UserDefaults) async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo = GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main","--template="])
        for (key,value) in [("user.name","Menu QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("core.abbrev","12")] { _ = try await repo.run(["config",key,value]) }
        func commit(_ title: String) async throws { _ = try await repo.run(["commit","--allow-empty","-m",title]) }
        try Data("root\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"])
        try await commit("Root")
        let localRoot = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["branch","side"])
        try await commit("Main parent subject longer than twenty characters")
        try await commit("Main second")
        _ = try await repo.run(["checkout","side"])
        try Data("side change\n".utf8).write(to:root.appendingPathComponent("side.txt")); try await repo.stage(["side.txt"])
        try await commit("Side parent & quoted subject longer than twenty characters")
        _ = try await repo.run(["checkout","main"])
        _ = try await repo.run(["merge","--no-ff","side","-m","Merge"])
        try Data("resolution\n".utf8).write(to:root.appendingPathComponent("tracked.txt"))
        try await repo.stage(["tracked.txt"])
        _ = try await repo.run(["commit","--amend","--no-edit"])
        try await commit("Tip")
        _ = try await repo.run(["checkout","-b","clean-merge",localRoot])
        _ = try await repo.run(["branch","clean-side"])
        try await commit("Clean first")
        _ = try await repo.run(["checkout","clean-side"]); try await commit("Clean second")
        _ = try await repo.run(["checkout","clean-merge"])
        _ = try await repo.run(["merge","--no-ff","clean-side","-m","Clean merge"])
        let cleanMerge = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["checkout","main"])

        // An unrelated tracking root makes the entire local history outgoing.
        _ = try await repo.run(["checkout","--orphan","remote-root"])
        try await commit("Unrelated remote root")
        let remoteHash = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["checkout","main"])
        _ = try await repo.run(["remote","add","origin",root.appendingPathComponent("unused.git").path])
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",remoteHash])
        _ = try await repo.run(["config","branch.main.remote","origin"])
        _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        let refs = try await repo.run(["show-ref"]).stdout, config = try Data(contentsOf:root.appendingPathComponent(".git/config")), index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner = SynchronizationWindowController(repository:repo,access:nil,preferences:preferences)
        owner.showWindow(nil); defer { owner.close() }
        let model = owner.model
        try await settle { !model.busy && model.outgoing != nil }
        model.force = true; model.refresh()
        try await settle { !model.busy && model.historyEntries.count == 6 }
        var native = table(owner.window!)
        let rows = model.historyEntries
        let mergeIndex = rows.firstIndex { $0.parents.count == 2 }!, rootIndex = rows.firstIndex { $0.parents.isEmpty }!
        var captured: [(ComparisonRevision,ComparisonRevision)] = []
        model.onHistoryCompare = { captured.append(($0,$1)) }
        func menu(_ indexes: IndexSet) -> NSMenu {
            native.selectRowIndexes(indexes,byExtendingSelection:false)
            let menu = native.menu!; menu.delegate?.menuNeedsUpdate?(menu); return menu
        }
        func invoke(_ item: NSMenuItem) { precondition(item.isEnabled && NSApplication.shared.sendAction(item.action!,to:item.target,from:item)) }
        var log: LogWindowController?
        model.onHistoryLog = { hash in
            let child = LogWindowController(repository:repo,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,initialRevision:hash)
            ReferenceLogWindowModel.configureRevisionLog(child.model,revision:hash)
            log = child; child.model.reload(); child.showWindow(nil)
        }
        let unreferenced = rows.firstIndex { $0.references.isEmpty && !$0.parents.isEmpty }!
        precondition(!menu(IndexSet(integer:unreferenced)).items.contains { $0.title == "Show log" })
        let rowRect = native.rect(ofRow:unreferenced)
        let mousePoint = native.convert(NSPoint(x:rowRect.midX,y:rowRect.midY),to:nil)
        let shifted = NSEvent.mouseEvent(with:.rightMouseDown,location:mousePoint,modifierFlags:.shift,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        let shiftedMenu = (native as! HistoryTableView).menu(for:shifted)!
        precondition((native as! HistoryTableView).contextExtendedMenu && native.selectedRowIndexes == IndexSet(integer:unreferenced))
        shiftedMenu.delegate?.menuNeedsUpdate?(shiftedMenu)
        let extendedLog = shiftedMenu.items.first { $0.title == "Show log" }!
        precondition(extendedLog.image != nil)
        _ = menu(IndexSet(integer:0)); invoke(extendedLog)
        try await settle { log?.model.busy == false && log?.model.selected.contains(rows[unreferenced].hash) == true }
        precondition(log!.model.endRevision == rows[unreferenced].hash)
        log!.close(); log = nil
        native.menu!.delegate?.menuDidClose?(native.menu!)
        precondition(!(native as! HistoryTableView).contextExtendedMenu)
        precondition(menu(IndexSet(integer:0)).items.contains { $0.title == "Show log" })
        precondition(!menu(IndexSet([0,1])).items.contains { $0.title == "Show log" })
        var capturedRange: HistoryRevisionRange?
        model.onHistoryLogRange = { range in
            capturedRange = range
            let child = LogWindowController(repository:repo,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false)
            ReferenceLogWindowModel.configureRangeLog(child.model,range:range)
            log = child; child.model.reload(); child.showWindow(nil)
        }
        let mainIndex = rows.firstIndex { $0.subject == "Main second" }!, sideIndex = rows.firstIndex { $0.subject.hasPrefix("Side parent") }!
        for selection in [IndexSet([0,1]),IndexSet([mainIndex,sideIndex])] {
            let first = rows[selection.first!].hash, last = rows[selection.last!].hash
            let ranges = [HistoryRevisionRange(from:last,to:first),HistoryRevisionRange(from:first,to:last),HistoryRevisionRange(from:last,to:first,kind:.symmetricDifference)]
            let items = menu(selection).items.filter { $0.title.hasPrefix("Show log of ") }
            precondition(items.count == 3)
            for (index,item) in items.enumerated() {
                let range = ranges[index]
                precondition(item.title == "Show log of " + range.from.prefix(8) + range.separator + range.to.prefix(8) && item.image != nil)
                _ = menu(IndexSet(integer:rootIndex)); invoke(item)
                try await settle { log?.model.busy == false }
                precondition(capturedRange == range && log!.model.revisionRange == range && log!.model.endRevision == nil && !log!.model.showWorkingTree)
                let expected = Set(try await repo.run(["rev-list",range.expression,"--"]).text.split(whereSeparator: \.isNewline).map(String.init))
                let actual = Set(log!.model.entries.filter { !$0.isBoundary }.map(\.hash))
                precondition(actual == expected, "Range \(range.expression) returned \(actual), expected \(expected)")
                log!.close(); log = nil
            }
        }
        precondition(!menu(IndexSet(integer:rootIndex)).items.contains { $0.title.hasPrefix("Show log of ") })
        precondition(!menu(IndexSet([0,1,2])).items.contains { $0.title.hasPrefix("Show log of ") })
        let guardedRange = menu(IndexSet([mainIndex,sideIndex])).items.first { $0.title.hasPrefix("Show log of ") }!
        let priorRange = capturedRange
        model.confirmingQuit = true
        precondition(!menu(IndexSet([mainIndex,sideIndex])).items.first { $0.title.hasPrefix("Show log of ") }!.isEnabled)
        precondition(NSApplication.shared.sendAction(guardedRange.action!,to:guardedRange.target,from:guardedRange))
        precondition(capturedRange == priorRange && log == nil)
        model.confirmingQuit = false
        owner.configureHistoryContainingReferences = { child in
            child.onLog = { name, select, range in
                let controller = LogWindowController(repository:repo,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,initialRevision:name)
                if let range { ReferenceLogWindowModel.configureRangeLog(controller.model,range:range) }
                else if let name { ReferenceLogWindowModel.configureRevisionLog(controller.model,revision:name) }
                log = controller; controller.model.reload(); controller.showWindow(nil)
            }
        }
        let containingItem = menu(IndexSet(integer:mergeIndex)).items.first { $0.title == "Show branches this commit is on" }!
        precondition(containingItem.image != nil && native.menu!.items.last === containingItem)
        _ = menu(IndexSet(integer:rootIndex)); invoke(containingItem)
        let containing = owner.historyContainingReferences.values.first!
        try await settle { !containing.busy && containing.snapshot != nil }
        let containsHash = rows[mergeIndex].hash
        let expectedReferences = Set(try await repo.run(["for-each-ref","--format=%(refname)","--contains",containsHash]).text.split(whereSeparator: \.isNewline).map(String.init))
        precondition(containing.snapshot!.hash == containsHash && Set(containing.rows.map(\.rawValue)) == expectedReferences && containing.window!.parent === owner.window)
        containing.showLog.performClick(nil); try await settle { log?.model.busy == false }
        precondition(log!.model.endRevision == containsHash && log!.model.selected == [containsHash])
        log!.close(); log = nil
        containing.onNavigate(rows[0].hash,true)
        try await settle { native.selectedRowIndexes == IndexSet(integer:0) }
        containing.onNavigate(rows[rootIndex].hash,false)
        try await settle { model.historyNavigation[0]?.hash == rows[rootIndex].hash }
        precondition(native.selectedRowIndexes == IndexSet(integer:0))
        precondition(model.historyHighlights[0] == rows[rootIndex].hash)
        let historyCoordinator = native.delegate as! SynchronizationHistoryTable.Coordinator
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            owner.window!.appearance = NSAppearance(named:appearance)
            let highlighted = historyCoordinator.tableView(native,viewFor:native.tableColumn(withIdentifier:.init("message")),row:rootIndex) as! NSTableCellView
            precondition(NSFontManager.shared.traits(of:highlighted.textField!.font!).contains(.italicFontMask) && !highlighted.textField!.drawsBackground)
        }
        owner.window!.appearance = nil
        let priorNavigation = model.historyNavigation[0]!.id
        containing.revision.stringValue = remoteHash; containing.refresh()
        try await settle { !containing.busy && containing.snapshot?.hash == remoteHash }
        containing.onNavigate(containing.snapshot!.hash,true)
        precondition(containing.status.stringValue == "The reference is not visible in Out Commits." && model.historyNavigation[0]!.id == priorNavigation && native.selectedRowIndexes == IndexSet(integer:0))
        containing.onNavigate(rows[0].hash,true)
        try await settle { containing.status.stringValue.isEmpty && native.selectedRowIndexes == IndexSet(integer:0) }
        let pickerItem = containing.chooser.menu!.items.first { $0.title == "Browse References" }!
        precondition(NSApplication.shared.sendAction(pickerItem.action!,to:pickerItem.target,from:pickerItem))
        try await settle { containing.picker != nil }
        precondition(model.hasBlockingChild && !menu(IndexSet(integer:mergeIndex)).items.first { $0.title == "Show branches this commit is on" }!.isEnabled)
        let nestedReferences = containing.picker as! ReferenceBrowserWindowController
        containing.close()
        precondition(containing.closed && nestedReferences.model.closed && owner.historyContainingReferences.isEmpty && !model.hasBlockingChild)
        let containingTarget = containingItem.target
        native.menu!.delegate?.menuDidClose?(native.menu!)
        model.tab = 4
        try await settle { table(owner.window!).numberOfRows == 0 }
        precondition(NSApplication.shared.sendAction(containingItem.action!,to:containingTarget,from:containingItem))
        let crossTabChild = owner.historyContainingReferences.values.first!
        try await settle { !crossTabChild.busy && crossTabChild.snapshot != nil }
        precondition(crossTabChild.snapshot!.hash == containsHash)
        crossTabChild.onNavigate(rows[rootIndex].hash,true)
        precondition(model.historyNavigation[0]?.hash == rows[rootIndex].hash && model.historyNavigation[4] == nil && model.tab == 4)
        try await Task.sleep(nanoseconds:20_000_000)
        precondition(table(owner.window!).selectedRowIndexes.isEmpty)
        model.tab = 0
        try await settle { table(owner.window!).numberOfRows == rows.count && table(owner.window!).selectedRowIndexes == IndexSet(integer:rootIndex) }
        native = table(owner.window!)
        let navigationID = model.historyNavigation[0]!.id
        precondition(model.handledHistoryNavigation[0] == navigationID)
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        model.tab = 4; try await settle { table(owner.window!).numberOfRows == 0 }
        model.tab = 0; try await settle { table(owner.window!).numberOfRows == rows.count }
        native = table(owner.window!)
        precondition(native.selectedRowIndexes.isEmpty && model.handledHistoryNavigation[0] == navigationID, "Recreated tables must not replay handled navigation")
        crossTabChild.close(); precondition(owner.historyContainingReferences.isEmpty)
        let closedNavigation = model.historyNavigation[0]!.id
        crossTabChild.onNavigate(rows[0].hash,true)
        precondition(model.historyNavigation[0]!.id == closedNavigation, "A closed references child cannot navigate its parent")
        model.finishPatchImport(oldHead:localRoot)
        try await settle { !model.busy && model.incomingCommits != nil && !model.hasBlockingChild }
        native = table(owner.window!)
        let incomingRows = model.historyEntries
        precondition(model.tab == 4 && incomingRows.count == 5)
        let incomingTarget = incomingRows.last!.hash
        let incomingItem = menu(IndexSet(integer:0)).items.first { $0.title == "Show branches this commit is on" }!
        invoke(incomingItem)
        let incomingChild = owner.historyContainingReferences.values.first!
        try await settle { !incomingChild.busy && incomingChild.snapshot?.hash == incomingRows[0].hash }
        native.menu!.delegate?.menuDidClose?(native.menu!)
        model.tab = 0; try await settle { table(owner.window!).numberOfRows == rows.count }
        native = table(owner.window!); native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let outgoingNavigation = model.historyNavigation[0]!.id
        incomingChild.onNavigate(incomingTarget,false)
        precondition(model.historyNavigation[4]?.hash == incomingTarget && model.historyNavigation[0]!.id == outgoingNavigation && model.historyHighlights[4] == incomingTarget)
        incomingChild.onNavigate(remoteHash,true)
        precondition(incomingChild.status.stringValue == "The reference is not visible in In Commits." && model.historyNavigation[4]?.hash == incomingTarget)
        try await Task.sleep(nanoseconds:20_000_000)
        precondition(native.selectedRowIndexes == IndexSet(integer:0))
        model.tab = 4; try await settle { table(owner.window!).numberOfRows == incomingRows.count && model.handledHistoryNavigation[4] == model.historyNavigation[4]?.id }
        native = table(owner.window!)
        precondition(native.selectedRowIndexes.isEmpty)
        incomingChild.onNavigate(incomingTarget,true)
        try await settle { incomingChild.status.stringValue.isEmpty && native.selectedRowIndexes == IndexSet(integer:incomingRows.count - 1) }
        incomingChild.onNavigate(incomingRows[0].hash,false)
        try await settle { model.historyHighlights[4] == incomingRows[0].hash && model.handledHistoryNavigation[4] == model.historyNavigation[4]?.id }
        let incomingCoordinator = native.delegate as! SynchronizationHistoryTable.Coordinator
        let highlightedHead = incomingCoordinator.tableView(native,viewFor:native.tableColumn(withIdentifier:.init("message")),row:0) as! NSTableCellView
        let headTraits = NSFontManager.shared.traits(of:highlightedHead.textField!.font!)
        precondition(incomingRows[0].isHead && headTraits.contains(.boldFontMask) && headTraits.contains(.italicFontMask) && native.selectedRowIndexes == IndexSet(integer:incomingRows.count - 1))
        incomingChild.close(); precondition(owner.historyContainingReferences.isEmpty)
        try await verifyFind(owner, outgoing: rows, incoming: incomingRows)
        model.tab = 0; try await settle { table(owner.window!).numberOfRows == rows.count }
        native = table(owner.window!)
        precondition(!menu(IndexSet([0,1])).items.contains { $0.title == "Show branches this commit is on" })
        model.confirmingQuit = true
        precondition(NSApplication.shared.sendAction(containingItem.action!,to:containingTarget,from:containingItem))
        precondition(owner.historyContainingReferences.isEmpty)
        model.confirmingQuit = false
        let originalPreference = preferences.object(forKey:"DiffByDoubleClickInLog")
        defer { if let originalPreference { preferences.set(originalPreference,forKey:"DiffByDoubleClickInLog") } else { preferences.removeObject(forKey:"DiffByDoubleClickInLog") } }
        preferences.set(false,forKey:"DiffByDoubleClickInLog")
        _ = menu(IndexSet(integer:mergeIndex))
        let initialComparisons = captured.count
        precondition(NSApplication.shared.sendAction(native.doubleAction!,to:native.target,from:native))
        precondition(captured.count == initialComparisons && log == nil)
        preferences.set(true,forKey:"DiffByDoubleClickInLog")
        precondition(NSApplication.shared.sendAction(native.doubleAction!,to:native.target,from:native))
        precondition(captured.last!.0 == .revision(rows[mergeIndex].parents[0]) && captured.last!.1 == .revision(rows[mergeIndex].hash))
        let returning = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        _ = menu(IndexSet([0,1])); native.keyDown(with:returning)
        precondition(captured.last!.0 == .revision(rows[0].parents[0]) && captured.last!.1 == .revision(rows[0].hash))
        let beforeRoot = captured.count
        _ = menu(IndexSet(integer:rootIndex)); native.keyDown(with:returning)
        precondition(NSApplication.shared.sendAction(native.doubleAction!,to:native.target,from:native))
        precondition(captured.count == beforeRoot)
        model.confirmingQuit = true
        _ = menu(IndexSet(integer:mergeIndex)); native.keyDown(with:returning)
        precondition(NSApplication.shared.sendAction(native.doubleAction!,to:native.target,from:native))
        precondition(captured.count == beforeRoot)
        model.confirmingQuit = false
        _ = menu(IndexSet(integer:mergeIndex))
        for modifier in [NSEvent.ModifierFlags.command,.control] {
            let modifiedReturn = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifier,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            native.keyDown(with:modifiedReturn)
            precondition(captured.count == beforeRoot, "Modified Return must not invoke the unmodified parent-compare shortcut")
        }
        preferences.set(false,forKey:"DiffByDoubleClickInLog")
        let parents = menu(IndexSet(integer:mergeIndex)).items.first { $0.title == "Compare with previous revision" }!.submenu!.items
        precondition(parents.count == 2)
        for (i,item) in parents.enumerated() {
            let hash = rows[mergeIndex].parents[i], parent = rows.first { $0.hash == hash }!
            let text = parent.subject as NSString
            let subject = text.length > 20 ? text.substring(to:20) + "..." : parent.subject
            precondition(item.title == "Parent \(i + 1): \"\(subject)\" (\(hash.prefix(8)))", "Source captions use twenty UTF-16 units and eight hash digits even with core.abbrev=12")
            precondition(item.image != nil)
            _ = menu(IndexSet(integer:rootIndex))
            invoke(item)
            precondition(captured.last!.0 == .revision(hash) && captured.last!.1 == .revision(rows[mergeIndex].hash), "Merge parent target must survive a changed selection")
        }
        let unified = menu(IndexSet(integer:mergeIndex)).items.first { $0.title == "Unified diff with" }!.submenu!.items
        precondition(unified.count == 5 && unified.prefix(3).map(\.title) == ["All Parents","Only Merged Files","Show extra changes after merge"])
        for (index,item) in unified.enumerated() {
            let extra = index == 2
            let flags = index == 0 ? ["-r","-p","-m","--stat"] : index == 1 ? ["-r","-p","-c","--stat"] : extra ? ["--cc"] : ["-r","-p","--stat"]
            let endpoints = index < 3 ? [rows[mergeIndex].hash] : [rows[mergeIndex].parents[index - 3],rows[mergeIndex].hash]
            let expected = try await repo.run(["diff-tree"] + flags + ["--no-ext-diff","--no-textconv","--no-color","--end-of-options"] + endpoints + ["--"]).stdout
            _ = menu(IndexSet(integer:rootIndex)); invoke(item)
            try await settle { !model.busy }
            precondition(model.error == nil && model.comparison.unifiedWindows.count == 1)
            let viewer = model.comparison.unifiedWindows.values.first!
            precondition(viewer.model.readOnly && viewer.model.exportDocument.bytes == expected && String(decoding:expected,as:UTF8.self).contains("resolution"))
            viewer.close(); precondition(model.comparison.unifiedWindows.isEmpty)
        }
        model.showHistoryDiff(.extraChanges(cleanMerge))
        try await settle { owner.window!.attachedSheet != nil }
        let notice = owner.window!.attachedSheet!
        precondition(descendants(notice.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No extra changes after merge" })
        let okay = descendants(notice.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "OK" }!
        okay.performClick(nil); try await settle { !model.busy && owner.window!.attachedSheet == nil }
        precondition(model.comparison.unifiedWindows.isEmpty && model.error == nil)
        let changes = menu(IndexSet([mergeIndex,rootIndex])).items.first { $0.title == "Compare change sets" }!
        invoke(changes); try await settle { !model.busy }
        precondition(model.error != nil && model.comparison.comparisonWindows.isEmpty, "A source root range error must not open a partial comparison")
        model.refresh(); try await settle { !model.busy && model.error == nil }
        let mergeChanges = menu(IndexSet([0,mergeIndex])).items.first { $0.title == "Compare change sets" }!
        let mergePatch = try await repo.run(["format-patch","--stdout",rows[mergeIndex].hash + "~1.." + rows[mergeIndex].hash,"--"]).stdout
        let tipPatch = try await repo.run(["format-patch","--stdout",rows[0].hash + "~1.." + rows[0].hash,"--"]).stdout
        precondition(String(decoding:mergePatch,as:UTF8.self).contains("side.txt") && !String(decoding:mergePatch,as:UTF8.self).contains("resolution"))
        invoke(mergeChanges)
        try await settle { !model.busy && model.comparison.comparisonWindows.values.first?.model.busy == false }
        precondition(model.error == nil && model.comparison.comparisonWindows.count == 1)
        let mergeViewer = model.comparison.comparisonWindows.values.first!
        precondition(mergeViewer.model.document?.base.bytes == tipPatch && mergeViewer.model.document?.destination.bytes == mergePatch)
        mergeViewer.close(); precondition(model.comparison.comparisonWindows.isEmpty)
        let rootMenu = menu(IndexSet(integer:rootIndex))
        precondition(!rootMenu.items.contains { $0.title == "Compare with previous revision" })
        precondition(rootMenu.items.contains { $0.title == "Compare with working tree" })
        precondition(!rootMenu.items.contains { $0.title == "Show changes as unified diff" })
        let contiguous = menu(IndexSet(integersIn:0..<3)).items.first { $0.title == "Compare revisions" }!
        precondition(!native.menu!.items.contains { $0.title == "Show changes as unified diff" || $0.title == "Compare change sets" })
        invoke(contiguous)
        precondition(captured.last!.0 == .revision(rows[2].hash) && captured.last!.1 == .revision(rows[0].hash))
        precondition(!menu(IndexSet([0,2,4])).items.contains { $0.title == "Compare revisions" })
        let disjointTwo = menu(IndexSet([0,4])).items.first { $0.title == "Compare revisions" }!
        invoke(disjointTwo)
        precondition(captured.last!.0 == .revision(rows[4].hash) && captured.last!.1 == .revision(rows[0].hash))
        model.confirmingQuit = true
        precondition(!menu(IndexSet([0,4])).items.first { $0.title == "Compare revisions" }!.isEnabled)
        let count = captured.count
        precondition(NSApplication.shared.sendAction(disjointTwo.action!,to:disjointTwo.target,from:disjointTwo))
        precondition(captured.count == count)
        model.confirmingQuit = false
        let finalRefs = try await repo.run(["show-ref"]).stdout, finalConfig = try Data(contentsOf:root.appendingPathComponent(".git/config")), finalIndex = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        precondition(finalRefs == refs && finalConfig == config && finalIndex == index)
        // Exclude the merge's side parent from the displayed outgoing range.
        let merge = rows[mergeIndex], missingParent = merge.parents[1]
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",missingParent])
        let narrowedRefs = try await repo.run(["show-ref"]).stdout
        model.refresh(); try await settle { !model.busy && !model.historyEntries.contains { $0.hash == missingParent } }
        let narrowedMerge = model.historyEntries.firstIndex { $0.hash == merge.hash }!
        let parentMenu = menu(IndexSet(integer:narrowedMerge)).items.first { $0.title == "Compare with previous revision" }!.submenu!
        precondition(parentMenu.items[1].title == "Parent 2 (\(missingParent.prefix(8)))")
        try await settle { model.historyParentSubjects[missingParent] != nil }
        let subject = rows.first { $0.hash == missingParent }!.subject as NSString
        let expected = "Parent 2: \"\(subject.substring(to:20))...\" (\(missingParent.prefix(8)))"
        precondition(parentMenu.items[1].title == expected, "The tracking menu must update when an off-list parent subject arrives")
        let cachedItem = parentMenu.items[1]
        _ = menu(IndexSet(integer:0)); invoke(cachedItem)
        precondition(captured.last!.0 == .revision(missingParent) && captured.last!.1 == .revision(merge.hash))
        let afterMetadataRefs = try await repo.run(["show-ref"]).stdout, afterMetadataConfig = try Data(contentsOf:root.appendingPathComponent(".git/config")), afterMetadataIndex = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        precondition(afterMetadataRefs == narrowedRefs && afterMetadataConfig == config && afterMetadataIndex == index)
        // Exercise real creation only in this dedicated disposable menu repository.
        owner.configureHistoryReference = { child in
            if child.model.isTag { child.model.onSwitch = { _, done in done() } }
        }
        let headBeforeCreation = try await repo.run(["rev-parse","HEAD"]).stdout
        for (isTag,name) in [(false,"sync-menu-branch"),(true,"sync-menu-tag")] {
            let index = model.historyEntries.firstIndex { $0.hash == merge.hash }!
            let item = menu(IndexSet(integer:index)).items.first { $0.title == (isTag ? "Create tag at this version…" : "Create branch at this version…") }!
            _ = menu(IndexSet(integer:0)); invoke(item)
            let child = owner.historyReferenceController!
            try await settle { !child.model.busy && !child.model.chooser.busy }
            precondition(child.window!.sheetParent === owner.window && child.model.chooser.revision == merge.hash)
            child.model.options.name = name; child.model.switchAfterCreation = false; child.model.pushAfterCreation = false
            child.model.create()
            try await settle { owner.historyReferenceController == nil && !model.busy }
            let createdHash = try await repo.run(["rev-parse",isTag ? "refs/tags/" + name : "refs/heads/" + name]).text.trimmingCharacters(in:.newlines)
            precondition(createdHash == merge.hash && model.historyEntries.first { $0.hash == merge.hash }!.references.contains { $0.name == (isTag ? "refs/tags/" : "refs/heads/") + name }, "Created \(name) at \(createdHash), expected \(merge.hash); refreshed refs \(model.historyEntries.first { $0.hash == merge.hash }!.references.map(\.name))")
        }
        let headAfterCreation = try await repo.run(["rev-parse","HEAD"]).stdout, configAfterCreation = try Data(contentsOf:root.appendingPathComponent(".git/config")), indexAfterCreation = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        precondition(headBeforeCreation == headAfterCreation && configAfterCreation == config && indexAfterCreation == index)
        try await verifyExport(owner, root: root, git: git, preferences: preferences)
        native = table(owner.window!)
        let finalContaining = menu(IndexSet(integer:0)).items.first { $0.title == "Show branches this commit is on" }!
        invoke(finalContaining)
        let forcedContaining = owner.historyContainingReferences.values.first!
        owner.close(); precondition(model.closed && !owner.window!.isVisible)
        precondition(forcedContaining.closed && owner.historyContainingReferences.isEmpty)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main", "--template="])
        for (key,value) in [("user.name","Revision QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("bugtraq.url","https://example.invalid/%BUGID%"),("bugtraq.message","Issue %BUGID%") ] { _ = try await repo.run(["config",key,value]) }
        for name in ["modify.txt","rename.txt","delete.txt"] { try Data((name + "\n").utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(["."]); _ = try await repo.commit(message:"Base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["commit","--allow-empty","-m","A second revision for selection tests"])
        try Data("modified\n".utf8).write(to: root.appendingPathComponent("modify.txt"))
        try Data("added\n".utf8).write(to: root.appendingPathComponent("added.txt"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("rename.txt"),to: root.appendingPathComponent("renamed.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
        try await repo.stage(["."]); _ = try await repo.commit(message:"Review colored refs and action icons\n\nDetails on a second line\nIssue 42")
        _ = try await repo.run(["tag","-a","v1.0","-m","Annotated tag"])
        _ = try await repo.run(["remote","add","origin",root.appendingPathComponent("no-server.git").path])
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",base])
        _ = try await repo.run(["config","branch.main.remote","origin"]); _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        _ = try await repo.run(["update-ref","refs/remotes/alpha/topic","HEAD"])
        _ = try await repo.run(["update-ref","refs/remotes/zeta/other","HEAD"])
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index")), config = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite = "TurtleGit.Sync.Revisions.QA." + UUID().uuidString, preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        preferences.set(false,forKey:"UseSystemLocaleForDates"); DialogGeometry.install(preferences:preferences)
        let owner = SynchronizationWindowController(repository:repo,access:nil,preferences:preferences), window = owner.window!, model = owner.model
        owner.showWindow(nil); defer { owner.close() }
        try await settle { !model.busy && model.outgoing != nil }
        let entry = model.historyEntries.first!
        model.requestHistoryActions(entry)
        try await settle { model.historyActions[entry.hash] != nil }
        precondition(model.historyActions[entry.hash] == [.modified,.added,.deleted,.replaced])
        let native = table(window), coordinator = native.delegate as! SynchronizationHistoryTable.Coordinator
        let clipboard = NSPasteboard(name: .init("TurtleGit.Sync.Clipboard.QA." + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        model.historyPasteboard = clipboard
        func copyItem(_ title: String) -> NSMenuItem {
            precondition(native.menu?.delegate === coordinator, "Revision menu lost its coordinator")
            native.menu!.delegate?.menuNeedsUpdate?(native.menu!)
            guard let item = native.menu!.items.first(where: { $0.title == "Copy to clipboard" })?.submenu?.items.first(where: { $0.title == title }) else {
                preconditionFailure("Missing clipboard command \(title); selected rows \(native.selectedRowIndexes); menu \(native.menu!.items.map(\.title))")
            }
            return item
        }
        func invoke(_ item: NSMenuItem) { precondition(item.isEnabled && NSApplication.shared.sendAction(item.action!,to:item.target,from:item)) }
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        let rows = model.historyEntries
        precondition(rows.count == 2)
        var comparisons: [(ComparisonRevision, ComparisonRevision)] = []
        model.onHistoryCompare = { comparisons.append(($0, $1)) }
        func comparisonItem(_ title: String) -> NSMenuItem {
            native.menu!.delegate?.menuNeedsUpdate?(native.menu!)
            return native.menu!.items.first { $0.title == title }!
        }
        let capturedComparison = comparisonItem("Compare revisions")
        precondition(capturedComparison.image != nil)
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        invoke(capturedComparison)
        precondition(comparisons.last!.0 == .revision(rows[1].hash) && comparisons.last!.1 == .revision(rows[0].hash))
        invoke(comparisonItem("Compare with working tree"))
        precondition(comparisons.last!.0 == .revision(rows[0].hash) && comparisons.last!.1 == .workingTree)
        let previous = comparisonItem("Compare with previous revision")
        invoke(previous)
        precondition(comparisons.last!.0 == .revision(rows[0].parents[0]) && comparisons.last!.1 == .revision(rows[0].hash))
        let count = comparisons.count
        model.confirmingQuit = true
        precondition(NSApplication.shared.sendAction(previous.action!,to:previous.target,from:previous))
        precondition(comparisons.count == count, "Captured comparison must respect owner guards")
        model.confirmingQuit = false
        // Exercise the same concrete comparison window used by RepositoryModel routing.
        var comparisonWindow: RevisionComparisonWindowController?
        model.onHistoryCompare = { from, to in
            let child = RevisionComparisonWindowController(repository:repo,access:nil,from:from,to:to)
            comparisonWindow = child; child.model.load(); child.showWindow(nil)
        }
        for title in ["Compare with working tree", "Compare with previous revision", "Compare revisions"] {
            native.selectRowIndexes(title == "Compare revisions" ? IndexSet(integersIn:0..<2) : IndexSet(integer:0),byExtendingSelection:false)
            invoke(comparisonItem(title))
            let child = comparisonWindow!
            try await settle { !child.model.busy }
            precondition(child.model.error == nil && child.model.snapshot != nil)
            let result = child.model.snapshot!
            precondition(result.to == (title == "Compare with working tree" ? .workingTree : .revision(rows[0].hash)))
            precondition(result.from == .revision(title == "Compare with working tree" ? rows[0].hash : title == "Compare revisions" ? rows[1].hash : rows[0].parents[0]))
            precondition(result.files.isEmpty == (title == "Compare with working tree"))
            child.close(); comparisonWindow = nil
        }
        model.onHistoryCompare = { comparisons.append(($0,$1)) }
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        for selection in [IndexSet(integer:0),IndexSet(integersIn:0..<2)] {
            native.selectRowIndexes(selection,byExtendingSelection:false)
            let item = comparisonItem("Show changes as unified diff")
            precondition(item.image != nil)
            let baseHash = selection.count == 1 ? rows[0].parents[0] : rows[1].hash
            let expected = try await repo.run(["diff-tree","-r","-p","--stat","--no-ext-diff","--no-textconv","--no-color","--end-of-options",baseHash,rows[0].hash,"--"]).stdout
            native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); invoke(item)
            try await settle { !model.busy }
            precondition(model.error == nil && model.comparison.unifiedWindows.count == 1)
            let viewer = model.comparison.unifiedWindows.values.first!
            precondition(viewer.model.readOnly && viewer.model.exportDocument.bytes == expected && String(decoding:expected,as:UTF8.self).contains("modify.txt"))
            viewer.close(); precondition(model.comparison.unifiedWindows.isEmpty)
        }
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        let changes = comparisonItem("Compare change sets")
        precondition(changes.image != nil)
        let firstPatch = try await repo.run(["format-patch","--stdout",rows[0].hash + "~1.." + rows[0].hash,"--"]).stdout
        let secondPatch = try await repo.run(["format-patch","--stdout",rows[1].hash + "~1.." + rows[1].hash,"--"]).stdout
        native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); invoke(changes)
        try await settle { !model.busy && model.comparison.comparisonWindows.values.first?.model.busy == false }
        precondition(model.error == nil && model.comparison.comparisonWindows.count == 1)
        let changeViewer = model.comparison.comparisonWindows.values.first!
        precondition(changeViewer.model.document?.base.bytes == firstPatch && changeViewer.model.document?.destination.bytes == secondPatch)
        precondition(changeViewer.model.snapshot.from == .revision(rows[0].hash) && changeViewer.model.snapshot.to == .revision(rows[1].hash))
        precondition(changeViewer.model.editableBase == nil && changeViewer.model.alignment != nil)
        changeViewer.close(); precondition(model.comparison.comparisonWindows.isEmpty)
        var browser: RepositoryBrowserWindowController?
        model.onHistoryBrowseRepository = { hash in
            let child = RepositoryBrowserWindowController(repository:repo,access:nil,revision:hash)
            browser = child; child.showWindow(nil)
        }
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let browse = comparisonItem("Browse repository")
        precondition(browse.image != nil)
        native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); invoke(browse)
        try await settle { browser?.model.busy == false }
        precondition(browser!.model.snapshot?.objectID == rows[0].hash)
        browser!.close(); browser = nil
        let productionCreation = model.onHistoryCreateReference
        var creationTarget: (Bool,String)?
        model.onHistoryCreateReference = { creationTarget = ($0,$1) }
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let remote = rows[0].references.first { $0.name.hasPrefix("refs/remotes/") }!.name
        invoke(comparisonItem("Create branch at this version…")); precondition(creationTarget?.0 == false && creationTarget?.1 == remote)
        (native as! HistoryTableView).contextReference = (0,"refs/remotes/zeta/other")
        invoke(comparisonItem("Create branch at this version…")); precondition(creationTarget?.1 == "refs/remotes/zeta/other")
        invoke(comparisonItem("Create tag at this version…")); precondition(creationTarget?.0 == true && creationTarget?.1 == remote)
        (native as! HistoryTableView).contextReference = nil
        model.onHistoryCreateReference = productionCreation
        native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        for title in ["Create branch at this version…","Create tag at this version…"] {
            let item = comparisonItem(title); precondition(item.image != nil)
            native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); invoke(item)
            let child = owner.historyReferenceController!
            try await settle { !child.model.busy && !child.model.chooser.busy }
            precondition(child.window!.sheetParent === window && model.creatingHistoryReference && model.hasBlockingChild)
            precondition(child.model.chooser.revision == rows[1].hash && !child.model.useHead)
            precondition(child.model.isTag == (title == "Create tag at this version…"))
            child.close(); precondition(owner.historyReferenceController == nil && !model.creatingHistoryReference && window.attachedSheet == nil)
            native.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        }
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        native.menu!.delegate?.menuNeedsUpdate?(native.menu!)
        precondition(!native.menu!.items.contains { $0.title == "Browse repository" || $0.title.hasPrefix("Create branch") || $0.title.hasPrefix("Create tag") })
        let capturedHashes = copyItem("Hashes")
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        invoke(capturedHashes); precondition(clipboard.string(forType:.string) == rows.map(\.hash).joined(separator:"\n"), "Menu payload must preserve the captured selection")
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        for (kind,expected) in [(SynchronizationHistoryCopy.authors, rows.map { "\($0.author) <\($0.email)>" }.joined(separator:"\n")),(.authorNames,rows.map(\.author).joined(separator:"\n")),(.authorEmails,rows.map(\.email).joined(separator:"\n")),(.subjects,LogEntry.historyClipboard(rows,subjectsOnly:true)),(.messages,LogEntry.historyClipboard(rows,subjectsOnly:false))] {
            invoke(copyItem(kind.rawValue)); precondition(clipboard.string(forType:.string) == expected)
        }
        precondition(!native.menu!.items.first(where: { $0.title == "Copy to clipboard" })!.submenu!.items.contains { $0.title == "Tag/branch names" })
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        invoke(copyItem("Tag/branch names")); precondition(clipboard.string(forType:.string)?.contains("refs/tags/v1.0\r\n") == true)
        (native as! HistoryTableView).contextReference = (0,"refs/tags/v1.0")
        invoke(copyItem("Tag/branch names")); precondition(clipboard.string(forType:.string) == "v1.0")
        (native as! HistoryTableView).contextReference = nil
        for kind in [SynchronizationHistoryCopy.detailsWithoutPaths,.details] {
            invoke(copyItem(kind.rawValue)); try await settle { !model.busy }
            let text = clipboard.string(forType:.string)!
            precondition(text.contains("Revision: " + entry.hash) && text.contains("Tag info: refs/tags/v1.0"))
            precondition(text.contains("modify.txt") == (kind == .details))
        }
        precondition(native.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == ["graph","actions","message","author","date","bugs"])
        func cell(_ id: String) -> NSTableCellView { coordinator.tableView(native, viewFor:native.tableColumn(withIdentifier:.init(id)),row:0) as! NSTableCellView }
        let actions = cell("actions")
        precondition(actions.toolTip == "Modified, Added/copied, Deleted, Replaced/renamed")
        precondition(descendants(actions).compactMap { $0 as? NSImageView }.filter { $0.image != nil }.count == 4)
        let message = cell("message").textField!
        precondition(NSFontManager.shared.traits(of: message.font!).contains(.boldFontMask), "The shared painter must retain HEAD's bold font")
        precondition(message.cell is LogReferenceTextCell && message.stringValue.contains("v1.0") && message.stringValue.contains("main"))
        var labels: [HistoryReferenceLabel] = []
        message.attributedStringValue.enumerateAttribute(.logReference,in:NSRange(location:0,length:message.attributedStringValue.length)) { value,_,_ in if let style = value as? LogReferenceStyle { labels.append(style.label) } }
        precondition(labels.contains { $0.kind == .annotatedTag } && labels.contains { $0.hasTracking })
        precondition(cell("date").textField!.stringValue == HistoryDateSettings.load(defaults:preferences).format(entry.date))
        precondition(cell("bugs").textField!.stringValue == "42")
        preferences.set(true,forKey:"RelativeTimes"); precondition(cell("date").textField!.toolTip == HistoryDateSettings.load(defaults:preferences).format(entry.date,absolute:true))
        preferences.set(true,forKey:"DrawTagsBranchesOnRightSide"); preferences.set(true,forKey:"FullCommitMessageOnLogLine")
        precondition(cell("message").textField!.stringValue.hasPrefix(entry.logLine(fullMessage:true)))
        preferences.set(false,forKey:"DrawTagsBranchesOnRightSide"); preferences.set(false,forKey:"FullCommitMessageOnLogLine")
        let hashItem = coordinator.headerMenu().items.first { ($0.representedObject as? String) == "hash" }!
        coordinator.toggleColumn(hashItem); precondition(!native.tableColumn(withIdentifier:.init("hash"))!.isHidden)
        precondition(preferences.bool(forKey:SynchronizationHistoryColumns.key(incoming:false,id:"hash")))
        coordinator.resetColumns(); precondition(native.tableColumn(withIdentifier:.init("hash"))!.isHidden)
        // Incoming lists use the same renderer but independent column preferences.
        model.finishPatchImport(oldHead:base); try await settle { !model.busy && model.incomingCommits != nil }
        let incoming = table(window), incomingCoordinator = incoming.delegate as! SynchronizationHistoryTable.Coordinator
        incomingCoordinator.toggleColumn(incomingCoordinator.headerMenu().items.first { ($0.representedObject as? String) == "hash" }!)
        precondition(preferences.bool(forKey:SynchronizationHistoryColumns.key(incoming:true,id:"hash")))
        precondition(!SynchronizationHistoryColumns.visible("hash",incoming:false,preferences:preferences))
        incomingCoordinator.resetColumns()
        if CommandLine.arguments.count > 3 {
            let output = URL(fileURLWithPath:CommandLine.arguments[3]); try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for (tab,name) in [(0,"outgoing"),(4,"incoming")] {
                model.tab = tab
                for (size,suffix) in [(NSSize(width:1080,height:640),""),(NSSize(width:860,height:500),"-minimum")] {
                    window.setContentSize(size)
                    for (theme,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                        window.appearance = NSAppearance(named:appearance); window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded()
                        try await Task.sleep(nanoseconds:250_000_000)
                        guard let capture = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID(window.windowNumber),[.boundsIgnoreFraming,.bestResolution]) else { preconditionFailure("Capture unavailable") }
                        let bitmap = NSBitmapImageRep(cgImage:capture)
                        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("sync-" + name + "-" + theme + suffix + ".png"))
                    }
                }
            }
        }
        // A slow action query is owned by this model and cannot publish after close.
        let helper = root.deletingLastPathComponent().appendingPathComponent("action-helper-" + UUID().uuidString)
        let marker = helper.appendingPathExtension("pid")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nfor arg in \"$@\"; do\n if [ \"$arg\" = diff-tree ]; then\n  echo $$ > " + quoted(marker.path + ".pending") + "\n  /bin/mv " + quoted(marker.path + ".pending") + " " + quoted(marker.path) + "\n  /bin/sleep 600 &\n  wait\n  exit 0\n fi\ndone\nexec " + quoted(repo.executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let slow = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { slow.invalidate(); try? FileManager.default.removeItem(at:helper); try? FileManager.default.removeItem(at:marker) }
        slow.requestHistoryActions(entry); slow.requestHistoryActions(entry)
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let pid = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(pid,0) == 0 { kill(-pid,SIGTERM) } }
        slow.invalidate()
        try await settle { kill(pid,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(slow.historyActions.isEmpty && slow.historyActionFailures.isEmpty)
        try FileManager.default.removeItem(at:marker)
        try Data(script.replacingOccurrences(of:"= diff-tree",with:"= show").utf8).write(to:helper)
        let copying = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        copying.historyPasteboard = clipboard; clipboard.clearContents(); clipboard.setString("retain on cancellation",forType:.string)
        defer { copying.invalidate() }
        copying.copyHistory([entry],kind:.details)
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let copyPID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(copyPID,0) == 0 { kill(-copyPID,SIGTERM) } }
        copying.invalidate(); try await settle { kill(copyPID,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!copying.busy && clipboard.string(forType:.string) == "retain on cancellation")
        try FileManager.default.removeItem(at:marker)
        let parents = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { parents.invalidate() }
        var mergeForCancellation = entry
        mergeForCancellation.parents = [entry.hash,base]
        let parentRead = Task { await parents.loadHistoryParentSubjects(mergeForCancellation) }
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let parentPID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(parentPID,0) == 0 { kill(-parentPID,SIGTERM) } }
        parents.invalidate(); await parentRead.value
        try await settle { kill(parentPID,0) != 0 && errno == ESRCH }
        precondition(parents.historyParentSubjects.isEmpty, "Off-list parent reads must not publish after owner close")
        try FileManager.default.removeItem(at:marker)
        let cancelledParents = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { cancelledParents.invalidate() }
        let cancelledRead = Task { await cancelledParents.loadHistoryParentSubjects(mergeForCancellation) }
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let cancelledPID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(cancelledPID,0) == 0 { kill(-cancelledPID,SIGTERM) } }
        cancelledRead.cancel(); await cancelledRead.value
        try await settle { kill(cancelledPID,0) != 0 && errno == ESRCH }
        precondition(!cancelledParents.closed && cancelledParents.historyParentSubjects.isEmpty, "Menu-task cancellation must stop its owned read while the owner stays open")

        try FileManager.default.removeItem(at:marker)
        try Data(script.utf8).write(to:helper)
        let diffing = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { diffing.invalidate() }
        diffing.showHistoryDiff(.revisions(base,entry.hash)); diffing.showHistoryDiff(.revisions(base,entry.hash))
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let diffPID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(diffPID,0) == 0 { kill(-diffPID,SIGTERM) } }
        diffing.invalidate(); try await settle { kill(diffPID,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!diffing.busy && diffing.comparison.unifiedWindows.isEmpty && diffing.error == nil, "An owned unified read must not open a viewer after owner close")
        try FileManager.default.removeItem(at:marker)
        try Data(script.replacingOccurrences(of:"= diff-tree",with:"= format-patch").utf8).write(to:helper)
        let changing = SynchronizationWindowModel(repository:GitRepository(root:root,executable:helper),access:nil,preferences:preferences)
        defer { changing.invalidate() }
        changing.compareHistoryChangeSets(first:entry.hash,second:entry.parents[0])
        try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let changePID = Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))!
        defer { if kill(changePID,0) == 0 { kill(-changePID,SIGTERM) } }
        changing.invalidate(); try await settle { kill(changePID,0) != 0 && errno == ESRCH }
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(!changing.busy && changing.comparison.comparisonWindows.isEmpty && changing.error == nil, "An owned change-set read must not open a viewer after owner close")
        let finalRefs = try await repo.run(["show-ref"]).stdout, finalIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf:root.appendingPathComponent(".git/config"))
        precondition(refs == finalRefs && index == finalIndex && config == finalConfig)
        model.onHistoryCreateReference?(false,entry.hash)
        let ownedReference = owner.historyReferenceController!
        try await settle { !ownedReference.model.busy && !ownedReference.model.chooser.busy }
        owner.close(); precondition(model.closed && !model.busy && !window.isVisible)
        precondition(owner.historyReferenceController == nil && !ownedReference.window!.isVisible && !model.creatingHistoryReference)

        try await verifyComparisonSelectionCases(root:root.appendingPathExtension("comparison-menu-cases"),git:repo.executable,preferences:preferences)
        print("PASS: native Sync source columns, original action icons, annotated/current/tracking ref labels, issue IDs, date/full-message settings, independent column toggles/reset, both lists/themes/sizes, clipboard menus/captured multi-selection/source text formats/full metadata/pointed names, native revision comparison menus/captured targets/owner guards/real comparison snapshots/root omission/merge parents/source captions/contiguous and disjoint selection/off-list parent menu updates/owned parent metadata cancellation/unified diff source bytes/all merge modes/no-extra notice/owned read-only viewers/native browse/remote suggestions/owned reference sheets/real branch and tag creation/refresh/conditional source Show log/native selected Log/default and configured activation/Return/root and close guards/changeset source bytes/readonly native comparison/root failure/owned format-patch cancellation, owned action and clipboard cancellation/late-callback fencing and unchanged Git state")
    }
}
@_cdecl("turtlegit_history_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        do { try await SynchronizationRevisionListVerification.main(); exit(0) }
        catch { print(error); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
