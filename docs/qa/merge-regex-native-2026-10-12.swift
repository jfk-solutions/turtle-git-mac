import AppKit
import Foundation
import TurtleGitCore

@main struct MergeRegexNativeVerification {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("Timed out waiting for owned regex work")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await verify(parser: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    @MainActor static func verify(parser: URL) async throws {
        let suite = "TurtleGit.MergeRegex.Native." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        UserDefaults.standard.setVolatileDomain(["TurtleGit.DiffTools": try JSONEncoder().encode(DiffToolPreferences())], forName: "NSArgumentDomain")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeRegex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let filter = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let list = MergeRegexFilterListController(defaults: preferences)
        list.model.accept(filter, oldName: nil)
        precondition(list.model.selected == filter && MergeRegexFilters.load(defaults: preferences).isEmpty)
        list.window?.close() // Outer Cancel/close retains no changes on disk.
        precondition(MergeRegexFilters.load(defaults: preferences).isEmpty)
        let saved = MergeRegexFilterListController(defaults: preferences)
        saved.model.accept(filter, oldName: nil); saved.model.saveAndClose()
        precondition(MergeRegexFilters.load(defaults: preferences) == [filter])
        let rename = MergeRegexFilterListController(defaults: preferences)
        rename.model.accept(.init(name: "Dates", expression: "date=.*", replacement: ""), oldName: "Versions")
        precondition(rename.model.filters.count == 1 && rename.model.filters[0].name == "Dates")
        rename.model.remove(); precondition(rename.model.filters.isEmpty); rename.window?.close()
        precondition(MergeRegexFilters.load(defaults: preferences) == [filter])

        let edit = MergeRegexFilterEditModel(filter: filter); edit.executable = parser
        var accepted: MergeRegexFilter?
        edit.accepted = { accepted = $0 }
        edit.expression = "("; edit.accept(); try await wait { !edit.validating }
        precondition(edit.error != nil && accepted == nil)
        edit.expression = "([0-9]+)"; edit.replacement = "$1"; edit.accept(); try await wait { !edit.validating }
        precondition(accepted?.replacement == "$1")
        edit.retire()

        let a = root.appendingPathComponent("base.txt"), b = root.appendingPathComponent("new.txt")
        let beforeA = Data("version 12\r\nkeep\r\nold\r\n".utf8), beforeB = Data("version 81\r\nkeep\r\nnew\r\n".utf8)
        try beforeA.write(to: a); try beforeB.write(to: b)
        let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: a, destination: b), permissions: [])
        let model = controller.model; model.regexExecutable = parser; model.regexDefaults = preferences
        model.load(); try await wait { !model.busy && model.document != nil }
        model.refreshRegexFilters(); model.selectRegexFilter(filter.name)
        try await wait { !model.filtering }
        precondition(model.alignment?.rows[0].base.state == .filtered && model.alignment?.differences == [2..<3])
        precondition(model.draftText(base: true) == String(decoding: beforeA, as: UTF8.self))
        model.selectRegexFilter(nil)
        precondition(model.regexFilterName == nil && model.alignment?.differences.count == 2)
        model.selectRegexFilter(filter.name); model.selectRegexFilter(nil)
        try await wait { MergeRegexOperations.activeRequests == 0 }
        precondition(model.regexFilterName == nil && model.alignment?.rows[0].base.state != .filtered)
        model.selectRegexFilter(filter.name); try await wait { !model.filtering }
        // Recompute keys for writable drafts without changing source bytes.
        model.editingEnabled = true
        model.updateDraft("version 900\r\nkeep\r\nnewer\r\n", base: false); model.rebuildAlignment()
        try await wait { !model.filtering }
        precondition(model.alignment?.rows[0].base.state == .filtered)
        precondition(model.alignment?.rows.last?.destination.text == "newer\r\n")
        let image = MergePalette.color(.filtered)
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        var lightGreen: CGFloat = 0, darkGreen: CGFloat = 0
        light.performAsCurrentDrawingAppearance { lightGreen = image.usingColorSpace(.deviceRGB)!.greenComponent }
        dark.performAsCurrentDrawingAppearance { darkGreen = image.usingColorSpace(.deviceRGB)!.greenComponent }
        precondition(lightGreen > 0.99 && darkGreen < 0.4)
        controller.window?.close()
        try await wait { MergeRegexOperations.activeRequests == 0 }
        let afterA = try Data(contentsOf: a), afterB = try Data(contentsOf: b)
        precondition(afterA == beforeA && afterB == beforeB)

        let slow = root.appendingPathComponent("slow-regex")
        try Data("#!/bin/sh\n/bin/sleep 2\nexit 1\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        let retired = MergeRegexFilterEditModel(filter: filter); retired.executable = slow
        retired.accepted = { _ in preconditionFailure("Late validation must not accept") }
        retired.accept(); retired.retire()
        try await wait { MergeRegexOperations.activeRequests == 0 }
        saved.window?.close(); rename.window?.close()
        print("Merge regex native: transactional list/rename/delete, validation errors, ECMAScript capture, original-byte panes, green light/dark colors, writable-draft recomputation, stale selection fencing and retired validation cleanup passed. Hidden windows closed; private preferences/files only.")
    }
}
