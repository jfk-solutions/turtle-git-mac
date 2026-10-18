// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum MergeBlameVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<1800 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: message)
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "TurtleGit.MergeBlame." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var owners: [FileComparisonWindowController] = []
        func owner(_ name: String, _ a: String, _ b: String, encoding: ComparisonTextEncoding, blame: Bool = true) throws -> FileComparisonWindowController {
            let base = root.appendingPathComponent(name + "-base"), mine = root.appendingPathComponent(name + "-mine")
            try encoding.encode(a).write(to: base); try encoding.encode(b).write(to: mine)
            let request = try MergeToolInvocation.parse(arguments: ["--merge-tool", "--base", base.path, "--mine", mine.path, "--line", "2"] + (blame ? ["--blame"] : []), currentDirectory: root.path)!
            let controller = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: preferences, deferInitialLoad: true)
            owners.append(controller)
            controller.model.editorConfigEnabled = [true: false, false: false]
            try controller.model.configureMergeTool(request)
            controller.window!.alphaValue = 0; controller.window!.orderFront(nil)
            controller.model.beginTransferredDocument()
            return controller
        }
        func ready(_ controller: FileComparisonWindowController) async throws {
            try await wait("Blame native comparison did not settle") { !controller.model.busy && !controller.model.filtering && controller.model.alignment != nil }
        }
        func cleanup() async throws {
            owners.forEach { $0.close() }
            try await wait("Retired Blame work did not drain") { owners.allSatisfy { !$0.model.mergeToolHasPendingWork } }
        }
        do {
            let old = String(repeating: "a", count: 66), new = String(repeating: "b", count: 66)
            let a = old + "same\n" + old + "before\n", b = new + "same\n" + new + "after\n"
            let converted = try owner("bom", a, b, encoding: .utf8BOM)
            try await ready(converted)
            let model = converted.model
            try require(model.mergeToolBlame && model.mergeToolReadOnly && !model.canEdit(base: true) && !model.canEdit(base: false), "Blame lost its immutable read-only policy")
            try require(model.alignment?.rows.first?.base.text == old + "same\n" && model.alignment?.rows.first?.destination.text == new + "same\n", "Blame replaced displayed original metadata")
            try require(model.alignment?.rows.first?.base.state == .normal && model.alignment?.rows.first?.destination.state == .normal, "Metadata-only change became a visible changed row")
            try require(model.alignment?.differences.count == 1 && model.alignment?.differences.first?.lowerBound == 1, "Blame removed code differences or kept metadata differences")
            try require(model.alignment?.rows[1].base.lineNumber == 2 && model.alignment?.rows[1].destination.lineNumber == 2 && model.requestedSourceLine == 2, "Blame source line coordinates shifted")
            try await wait("Blame native text view did not attach") { converted.window?.contentView?.layoutSubtreeIfNeeded(); return model.activeFindText != nil }
            try require(model.activeFindText?.isEditable == false && model.activeFindText?.string.contains(new + "same") == true, "Native Blame text is editable or lost original metadata")
            let original = model.draftText(base: false)
            model.updateDraft("forbidden\n", base: false); model.editingEnabled = true
            try require(model.draftText(base: false) == original && !model.dirty && !model.canSavePaneAs, "Read-only Blame accepted a mutation or Save As")
            model.switchPaneMode(true)
            try await ready(converted)
            try require(model.onePaneActive && model.mergeToolBlame && model.mergeToolReadOnly && model.alignment?.differences.count == 1, "One-pane projection lost Blame keys or read-only state")
            model.switchPaneMode(false)
            try await ready(converted)
            let plain = try owner("plain", old + "same\n", new + "same\n", encoding: .utf8)
            try await ready(plain)
            try require(plain.model.document?.base.encoding != .utf8BOM && plain.model.alignment?.differences.count == 1, "Unconverted source UTF-8 incorrectly stripped metadata")
            var options = plain.model.comparisonOptions; options.ignoreCase = true
            plain.model.setComparisonOptions(options)
            try await ready(plain)
            try require(plain.model.alignment?.differences.isEmpty == true && plain.model.document?.base.text == old + "same\n", "Source case-filter conversion did not enable Blame keys while retaining text")
            // CRLF requires source conversion even without a BOM or text filters.
            preferences.set(false, forKey: "TurtleGitMerge.CaseInsensitive")
            let crlf = try owner("crlf", old + "same\r\n", new + "same\r\n", encoding: .utf8)
            try await ready(crlf)
            try require(crlf.model.alignment?.differences.isEmpty == true, "Source CRLF conversion bypassed Blame keys")
            let ordinary = try owner("ordinary", old + "same\r\n", new + "same\r\n", encoding: .utf8, blame: false)
            try await ready(ordinary)
            try require(!ordinary.model.mergeToolBlame && ordinary.model.alignment?.differences.count == 1, "Blame leaked into ordinary file comparison")
            let short = try owner("short", String(repeating: "a", count: 66) + "\r\n", String(repeating: "b", count: 66) + "\r\n", encoding: .utf8BOM)
            try await ready(short)
            try require(short.model.alignment?.differences.count == 1, "Exactly-66-unit source lines were stripped")
            let expectedBase = try ComparisonTextEncoding.utf8BOM.encode(a), expectedMine = try ComparisonTextEncoding.utf8BOM.encode(b)
            try require(try Data(contentsOf: root.appendingPathComponent("bom-base")) == expectedBase, "Blame comparison modified its base input")
            try require(try Data(contentsOf: root.appendingPathComponent("bom-mine")) == expectedMine, "Blame comparison modified its Mine input")
            try await cleanup()
            print("PASS: source Blame conversion gates, fixed-width keys, native read-only and original line/text ownership")
        } catch {
            try? await cleanup()
            throw error
        }
    }
}
