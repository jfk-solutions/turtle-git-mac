import AppKit
import TurtleGitCore

struct MergeLineDiffNativeVerification {
    @MainActor static func verify() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MergeLineDiff", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitLineDiff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.LineDiff." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let before = "snow 🦎\told value\r\nshared\nlast", after = "snow 🦎\tnew value\nshared\nlast"
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        try Data(before.utf8).write(to: base); try Data(after.utf8).write(to: mine)
        let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
        defer { owner.window?.close() }
        let model = owner.model; model.comparisonDefaults = defaults
        model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); model.refreshPreferences(); model.load()
        try await TwoPaneEngineVerification.settled(model)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await TwoPaneEngineVerification.wait { TwoPaneEngineVerification.editors(owner.window?.contentView).count == 2 }
        let editors = TwoPaneEngineVerification.editors(owner.window?.contentView)
        let strings = editors.map(\.string), selections = editors.map { $0.selectedRange() }, generation = model.alignmentGeneration
        try check(model.showLineDiffBar, "Source default must show line diff bar")
        model.setInlineDiff(false); model.setWhitespaceDisplay(.init(visible: false, endingIcons: true))
        let preview = MergeLineDiffPreview(frame: NSRect(x: 0, y: 0, width: 520, height: MergeLineDiffPreview.lineHeight(model.generalPreferences.nativeFont) * 2))
        guard let editor = editors.first, let hover = editor as? MergeLineDiffHoverProviding else { throw NSError(domain: "Missing hover receiver", code: 1) }
        hover.previewLine(atDisplayOffset: 2); preview.update(model)
        try check(model.previewRow == 0 && preview.displayedStrings == ["snow 🦎\told value", "snow 🦎\tnew value"], "Pointer preview must preserve Base/Mine ordering")
        try check(preview.displayedMarkers.allSatisfy { $0.contains { $0.kind == .tab } } && preview.displayedMarkers[0].contains { $0.kind == .ending(.crlf, changed: true) }, "Preview must force whitespace and preserve original EOL")
        let savedGeneral = model.generalPreferences
        var bounded = savedGeneral; bounded.maximumInlineLength = 1; bounded.save(to: defaults); model.refreshPreferences()
        try check(model.inlineDifference(0, force: true) == nil, "Preview must honor general inline bound")
        savedGeneral.save(to: defaults); model.refreshPreferences()
        hover.previewLine(atDisplayOffset: 2); preview.update(model)
        let inlineRange = NSRange(location: 8, length: 3)
        let diff = model.inlineDifference(0, force: true)
        try check(diff != nil && !diff!.base.isEmpty && model.inlineDifference(0) == nil, "Forced inline preview must be independent of main-pane toggle")
        try check(preview.displayedAttributes[0].attribute(.backgroundColor, at: inlineRange.location, effectiveRange: nil) != nil, "Missing line palette")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            preview.appearance = NSAppearance(named: name)
            guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { throw NSError(domain: "Missing preview bitmap", code: 1) }
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            let suffix = name == .aqua ? "light" : "dark"
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/merge-line-diff-" + suffix + ".png"))
        }
        try check(editors.map(\.string) == strings && editors.map { $0.selectedRange() } == selections && !model.canUndo && !model.dirty && model.alignmentGeneration == generation, "Hover must not mutate text/selection/history")
        model.showLineDiffBar = false; try check(!defaults.bool(forKey: "TurtleGitMerge.LineDiff"), "Visibility must persist")
        model.refreshPreferences(); try check(!model.showLineDiffBar, "Saved visibility must reload")
        model.showLineDiffBar = true
        hover.previewLine(atDisplayOffset: nil); preview.update(model); try check(preview.displayedStrings.isEmpty, "Mouse exit must clear preview")
        hover.previewLine(atDisplayOffset: Int.max); try check(model.previewRow == nil, "Invalid offsets must clear preview")
        model.previewLine(atRow: 0); model.singleFileMode = true; preview.update(model); try check(preview.displayedStrings.isEmpty, "One-file view must suppress bar")
        model.singleFileMode = false; model.rebuildAlignment(); try check(model.previewRow == nil, "Reload must clear old alignment row")
        try await TwoPaneEngineVerification.settled(model)
        model.previewLine(atRow: 0); model.retireImageLoader(); hover.previewLine(atDisplayOffset: 2); preview.update(model)
        try check(preview.displayedStrings.isEmpty && model.previewRow == nil, "Retired hover must be fenced")
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        try check(finalBase == Data(before.utf8) && finalMine == Data(after.utf8), "Preview changed disk")
        print("Line diff bar: source default/persistence, Base/Mine pointer ordering, forced inline and original whitespace/EOL, light/dark rendering, unchanged selection/history/files, invalid/exit/single-file/rebuild/retired gates passed. Owned window closed.")
    }
}
