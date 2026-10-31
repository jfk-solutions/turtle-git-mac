// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum HistoryLocalizationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: Int = #line) throws {
        if !value { throw Failure(description: "History language line \(line): " + message) }
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func leaves(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { item in [item] + (item.submenu.map(leaves) ?? []) } }
    @MainActor static func wait(_ window: NSWindow?, line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1800 { window?.contentView?.layoutSubtreeIfNeeded(); if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "History language readiness line \(line)")
    }
    @MainActor static func dispatch(_ item: NSMenuItem) throws {
        guard let action = item.action else { throw Failure(description: "Missing native action " + item.title) }
        try require(NSApp.sendAction(action, to: item.target, from: item), "Native dispatch " + item.title)
    }
    @MainActor static func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        guard let item = leaves(menu).first(where: { $0.title == title }) else { throw Failure(description: "Missing caption \(title); actual \(leaves(menu).map(\.title))") }; return item
    }
    @MainActor static func templateContracts(_ directory: URL) throws {
        let bundleURL = directory.appendingPathComponent("NamedFields.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.turtlegit.qa.history-fields." + UUID().uuidString, "CFBundleDevelopmentRegion": "en"], format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Info.plist"))
        let translated = ["Pair {branch} / {hash}": "{hash} puis {branch}", "Missing {branch}": "Absent", "Duplicate {branch}": "{branch} {branch}", "Unknown {branch}": "{other}", "Malformed {branch}": "{branch", "Message": "DO-NOT-TRANSLATE-METADATA"]
        try PropertyListSerialization.data(fromPropertyList: translated, format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Localizable.strings"))
        guard let bundle = Bundle(url: bundleURL) else { throw Failure(description: "Private translation bundle") }
        let metadata = "Message{hash}%@", hash = "abc123{branch}%n"
        try require(HistoryLabels.text("Pair {branch} / {hash}", values: ["branch": metadata, "hash": hash], bundle: bundle) == hash + " puis " + metadata, "Named substitution reordered or translated inserted metadata")
        try require(HistoryLabels.text("Pair {branch} / {hash}", values: ["branch": "Message", "hash": hash], bundle: bundle) == hash + " puis Message", "Catalog-looking metadata was translated")
        for template in ["Missing {branch}", "Duplicate {branch}", "Unknown {branch}", "Malformed {branch}"] {
            try require(HistoryLabels.text(template, values: ["branch": metadata], bundle: bundle) == template.replacingOccurrences(of: "{branch}", with: metadata), "Malformed translation escaped fallback: " + template)
        }
        try require(HistoryLabels.text("Missing {branch}", values: [:], bundle: bundle) == "Missing {branch}", "Missing caller field partially rendered")
        try require(HistoryLabels.text("Pair {branch} / {hash}", values: ["branch": metadata, "hash": hash, "extra": "secret"], bundle: bundle) == "Pair {branch} / {hash}", "Unknown caller field accepted")
    }
    @MainActor static func verify() async throws {
        let locale = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[3]))
        let translations: [String: [String: String]] = [
            "de": ["Author": "Autor", "Message": "Meldung", "Show log": "Zeige Log", "Copy to clipboard": "In Zwischenablage kopieren", "Branch Name": "Zweig Name"],
            "fr": ["Author": "Auteur", "Message": "Commentaire", "Show log": "Voir le journal", "Copy to clipboard": "Copier dans le presse-papiers", "Branch Name": "Nom de la branche"],
            "en": ["Author": "Author", "Message": "Message", "Show log": "Show log", "Copy to clipboard": "Copy to clipboard", "Branch Name": "Branch Name"]]
        guard let expected = translations[locale] else { throw Failure(description: "Unsupported fixture locale") }
        try require(Bundle.main.preferredLocalizations.first == locale, "Process locale " + Bundle.main.preferredLocalizations.joined(separator: ","))
        for (key, value) in expected { try require(HistoryLabels.caption(key) == value, "Compiled catalog caption " + key) }
        try templateContracts(root)
        let branch = "Message{branch}%quote", subject = "Author {branch} %@", author = "Message"
        _ = try await repo.run(["init", "-b", branch])
        for (key, value) in [("user.name", author), ("user.email", "history-language@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("Message")
        for number in 1...2 { try Data("\(number)\n".utf8).write(to: file); try await repo.stage(["Message"]); _ = try await repo.commit(message: subject + " \(number)") }
        _ = try await repo.run(["branch", "Author"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: file)
        let hash = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let suite = "TurtleGit.HistoryLanguages." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!, board = NSPasteboard.withUniqueName()
        preferences.set(false, forKey: "Gravatar"); preferences.set(false, forKey: "LogIncludeWorkingTreeChanges"); preferences.set(true, forKey: "ShowAppContextMenuIcons")
        defer { preferences.removePersistentDomain(forName: suite); board.releaseGlobally() }

        let log = LogWindowController(repository: repo, access: nil, labelDefaults: preferences, savesColumnLayout: false, savesGeometry: false)
        log.window?.alphaValue = 0; log.window?.ignoresMouseEvents = true; log.window?.orderFront(nil); log.model.clipboard = board
        defer { log.close() }
        try await wait(log.window) { !log.model.busy && log.model.entries.count == 2 }
        guard let logTable = views(log.window?.contentView).compactMap({ $0 as? HistoryTableView }).first,
              let logCoordinator = NativeListSelection.originalDelegate(of: logTable) as? RevisionTable.Coordinator, let logMenu = logTable.menu else { throw Failure(description: "Actual Log native table/menu") }
        try await wait(log.window) { logTable.numberOfRows == 2 }
        try require(logTable.tableColumn(withIdentifier: .init("author"))?.title == expected["Author"] && logTable.tableColumn(withIdentifier: .init("message"))?.title == expected["Message"], "Log native column captions")
        try require(log.model.entries[0].subject == subject + " 2" && log.model.entries[0].author == author, "Repository subject/author translated")
        let noLimit = ["de": "Keine Limitierung", "fr": "Pas de restriction", "en": "No limitation"][locale]!
        _ = try item(noLimit, in: LogControlMenus.make(model: log.model, kind: .limit))
        var browsed: [String] = []; log.model.onBrowseRepository = { browsed.append($0) }
        log.model.select([hash]); try await wait(log.window) { !log.model.files.isEmpty }
        logCoordinator.menuNeedsUpdate(logMenu)
        _ = try item(expected["Copy to clipboard"]!, in: logMenu)
        guard let browse = leaves(logMenu).first(where: { $0.action.map(NSStringFromSelector) == "browseRepository" }) else { throw Failure(description: "Actual Log browse action") }
        try require(browse.title == HistoryLabels.caption("Browse repository"), "Log native action caption")
        try dispatch(browse); try require(browsed == [hash], "Localized Log action changed raw revision")
        logCoordinator.menuNeedsUpdate(logMenu)
        let staleLog = leaves(logMenu).first(where: { $0.action.map(NSStringFromSelector) == "browseRepository" })!
        log.close(); try dispatch(staleLog); try require(browsed == [hash], "Retired localized Log action executed")

        let refs = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/Author", preferences: preferences, picking: false) { _ in }
        refs.window?.alphaValue = 0; refs.window?.ignoresMouseEvents = true; refs.window?.orderFront(nil); refs.model.load()
        defer { refs.close() }
        try await wait(refs.window) { !refs.model.busy && refs.model.rows.count == 2 }
        guard let refTable = views(refs.window?.contentView).compactMap({ $0 as? NSTableView }).first(where: { $0.tableColumns.contains { $0.identifier.rawValue == "name" } }),
              let refCoordinator = NativeListSelection.originalDelegate(of: refTable) as? ReferenceBrowserNativeView.Coordinator, let refMenu = refTable.menu else { throw Failure(description: "Actual References native menu") }
        try await wait(refs.window) { refTable.numberOfRows == 2 }
        try require(refTable.tableColumn(withIdentifier: .init("name"))?.title == expected["Branch Name"], "References native header caption")
        if let filter = views(refs.window?.contentView).compactMap({ $0 as? NSSearchField }).first {
            let cue = ["de": "Filtern nach Refname, Betreff, Autoren, SHA-1", "fr": "Filtrer par Refname, Sujet, Auteurs, SHA-1", "en": "Filter by Refname, Subject, Authors, SHA-1"][locale]!
            try require(filter.placeholderString == cue, "References composed native filter caption: " + (filter.placeholderString ?? "nil"))
        } else { throw Failure(description: "References native filter missing") }
        refs.model.select([GitReferenceName("refs/heads/Author")], last: GitReferenceName("refs/heads/Author"))
        var loggedRefs: [String] = []; refs.model.onLog = { loggedRefs.append($0) }; refs.model.onMerge = {}
        refCoordinator.menuNeedsUpdate(refMenu)
        let showRef = try item(expected["Show log"]!, in: refMenu)
        let dynamicMerge = ["de": "Mit „" + branch + "“ zusammenführen…", "fr": "Fusionner dans « " + branch + " »…", "en": "Merge to \"" + branch + "\"…"][locale]!
        try require(refMenu.items.contains { $0.title == dynamicMerge } && dynamicMerge.contains(branch), "Dynamic current branch was translated/reinterpreted")
        try require(refs.model.rows.contains { $0.reference.name.rawValue == "refs/heads/Author" } && refs.model.rows.contains { $0.reference.name.rawValue == "refs/heads/" + branch }, "Literal reference identities changed")
        try require(showRef.attributedTitle?.string == showRef.title, "Localized default action lost bold caption identity")
        try dispatch(showRef); try require(loggedRefs == ["refs/heads/Author"], "Localized Reference action changed literal ref")
        refCoordinator.menuNeedsUpdate(refMenu); let staleRef = try item(expected["Show log"]!, in: refMenu)
        refs.close(); try dispatch(staleRef); try require(loggedRefs.count == 1, "Retired localized Reference action executed")

        let reflog = ReferenceLogWindowController(repository: repo, access: nil, reference: "refs/heads/" + branch, preferences: preferences)
        reflog.window?.alphaValue = 0; reflog.window?.ignoresMouseEvents = true; reflog.window?.orderFront(nil); reflog.model.reload()
        defer { reflog.close() }
        try await wait(reflog.window) { !reflog.model.busy && reflog.model.entries.count >= 2 }
        guard let reflogTable = views(reflog.window?.contentView).compactMap({ $0 as? ReferenceLogTableView }).first, let reflogCoordinator = reflogTable.owner else { throw Failure(description: "Actual Reflog native table") }
        try await wait(reflog.window) { reflogTable.numberOfRows == reflog.model.entries.count }
        try require(reflogTable.tableColumn(withIdentifier: .init("Message"))?.title == expected["Message"], "Reflog native header caption")
        _ = try item(expected["Message"]!, in: reflogCoordinator.headerMenu())
        reflogTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var loggedHashes: [String] = []; reflog.model.onLog = { loggedHashes.append($0) }
        let entry = reflog.model.entries[0]
        let refCell = reflogCoordinator.tableView(reflogTable, viewFor: reflogTable.tableColumn(withIdentifier: .init("Ref")), row: 0) as? NSTableCellView
        let messageCell = reflogCoordinator.tableView(reflogTable, viewFor: reflogTable.tableColumn(withIdentifier: .init("Message")), row: 0) as? NSTableCellView
        try require(refCell?.textField?.stringValue == entry.selector && messageCell?.textField?.stringValue == entry.message, "Native Reflog cells translated metadata")
        try require(entry.hash == hash && entry.selector.contains(branch) && entry.action == "commit" && entry.message == subject + " 2" && entry.subject == "commit: " + subject + " 2", "Reflog metadata translated")
        let reflogMenu = reflogCoordinator.menu(pasteboard: board), showReflog = try item(expected["Show log"]!, in: reflogMenu)
        _ = try item(expected["Copy to clipboard"]!, in: reflogMenu)
        try dispatch(showReflog); try require(loggedHashes == [hash], "Localized Reflog action changed raw hash")
        let copyMenu = reflogCoordinator.menu(pasteboard: board)
        try dispatch(try item("SHA-1", in: copyMenu)); try require(board.string(forType: .string) == hash, "Localized Reflog clipboard changed literal hash")
        let staleReflog = try item(expected["Show log"]!, in: reflogCoordinator.menu(pasteboard: board))
        reflog.close(); try dispatch(staleReflog); try require(loggedHashes == [hash], "Retired localized Reflog action executed")
        try await wait(nil) { LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 && LogWindowModel.activeActionReads == 0 && ReferenceBrowserWindowModel.activeReads == 0 && ReferenceLogWindowModel.activeRevisionReads == 0 }
        try require(try await repo.run(["rev-parse", "HEAD"]).stdout == head, "HEAD changed")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: file) == bytes, "Index/input changed")
        print("PASS language history: actual localized Log/References/Reflog native menus/headers; raw branch/author/subject/hash and single-pass template bytes; dispatched actions and retired guards; immutable HEAD/index/input")
    }
}
