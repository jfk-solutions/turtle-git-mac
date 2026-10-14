import AppKit
import TurtleGitCore

struct MergeSourceToolsNativeVerification {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSourceTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.SourceTools." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        defer { prefs.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let originals = ["head\r\nbase one\r\nbase two\r\ntail\r\n", "head\r\nmine one\r\nbase two\r\ntail\r\n", "head\r\nbase one\r\ntheir two\r\ntail\r\n"]
        for (url, text) in zip([base, mine, theirs], originals) { try Data(text.utf8).write(to: url) }
        let controller = TextConflictWindowController(repository: GitRepository(root: folder), access: nil, path: "source.cpp", workingMerge: try WorkingTextMerge(base: base, theirs: theirs, mine: mine), preferences: prefs)
        defer { controller.close() }
        let model = controller.model; model.load()
        try await ThreePaneEngineVerification.wait { !model.busy && model.document != nil }
        guard let document = model.document, let rows = model.sourceComparison?.rows else { throw Failure(message: "No source document") }
        var answer: ((NSApplication.ModalResponse) -> Void)?
        var target = folder.appendingPathComponent("left.out")
        model.sourceExporter.present = { _, _, completion in answer = completion }
        model.sourceExporter.selectedURL = { _ in target }
        model.exportSource(mine: false)
        try require(model.exportingSource && !controller.windowShouldClose(controller.window!), "Source export did not own Close")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Source export did not guard Quit")
        answer?(.cancel); answer?(.OK)
        try require(!model.exportingSource && !FileManager.default.fileExists(atPath: target.path), "Cancel/late reply wrote export")
        model.exportSource(mine: false); answer?(.OK)
        try await ThreePaneEngineVerification.wait { !model.exportingSource && MergeSourceExport.activeExports == 0 }
        try require(try Data(contentsOf: target) == MergePaneSaveAs.sourceBytes(rows: rows, mine: false, encoding: document.theirsEncoding ?? document.encoding), "Left pane export bytes differ")
        target = folder.appendingPathComponent("right.out"); model.exportSource(mine: true); answer?(.OK)
        try await ThreePaneEngineVerification.wait { !model.exportingSource }
        try require(try Data(contentsOf: target) == MergePaneSaveAs.sourceBytes(rows: rows, mine: true, encoding: document.mineEncoding ?? document.encoding), "Right pane export bytes differ")
        let child = try MergeSourceComparisonWindows.open(base: (document.baseEncoding ?? document.encoding).encode(document.base), side: (document.mineEncoding ?? document.encoding).encode(document.mine), name: "source.cpp", sideName: "Mine", preferences: prefs)
        let snapshotRoot = child.model.snapshot.root
        defer { child.close() }
        try await TwoPaneEngineVerification.settled(child.model)
        try require(!child.model.canEdit(base: true) && !child.model.canEdit(base: false) && !child.model.editingEnabled, "Source snapshot comparison is editable")
        child.model.editingEnabled = true; child.model.updateDraft("bad", base: false)
        try require(!child.model.editingEnabled && !child.model.dirty && child.model.draftText(base: false) == document.mine, "Direct editing changed a source snapshot")
        child.close(); try require(!FileManager.default.fileExists(atPath: snapshotRoot.path), "Source comparison leaked private snapshots")
        model.workingMerge = nil
        target = folder.appendingPathComponent("result.out"); model.encoding = .utf16LEBOM; model.result = "captured merged 🐢\r\n"; let result = model.result
        try require(model.sourceToolsAllowed, "Merged export gate: retired=\(model.retired), busy=\(model.busy), preparing=\(model.preparing), exporting=\(model.exportingSource), sheet=\(String(describing: model.window?.attachedSheet)), document=\(model.document != nil)")
        model.export()
        try require(model.sourceExporter.panel != nil && model.exportingSource, "Merged export did not present owned panel: \(String(describing: model.error))")
        answer?(.OK)
        try await ThreePaneEngineVerification.wait { !model.exportingSource }
        try require(try Data(contentsOf: target) == model.encoding.encode(result), "Merged export bytes differ")
        target = folder.appendingPathComponent("late.out"); model.exportSource(mine: true); model.retire(); answer?(.OK)
        try require(!FileManager.default.fileExists(atPath: target.path) && model.sourceExporter.panel == nil, "Retired export accepted late answer")
        for (url, text) in zip([base, mine, theirs], originals) { try require(try Data(contentsOf: url) == Data(text.utf8), "Source tool modified input") }
        print("PASS: owned left/right/result Save As, exact captured bytes, Cancel/late/Close/Quit gates, read-only source comparison and snapshot cleanup, original input preservation")
    }
}
