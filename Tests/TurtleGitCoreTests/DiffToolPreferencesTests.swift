// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class DiffToolPreferencesTests: XCTestCase {
    private func program(_ name: String, enabled: Bool = true) -> DiffToolProgram {
        var result = DiffToolProgram(); result.enabled = enabled; result.applicationPath = "/Applications/" + name + ".app"; return result
    }
    private func association(_ pattern: String, _ name: String, enabled: Bool = true) -> DiffToolAssociation {
        var result = DiffToolAssociation(); result.pattern = pattern; result.program = program(name, enabled: enabled); return result
    }
    func testSourceSelectionPrecedenceAndAlternateDisabledAssociation() throws {
        var settings = DiffToolPreferences(); settings.program = program("Default")
        settings.associations = [association("*.TXT", "Extension"), association("base.txt", "Base"), association("result.txt", "Result", enabled: false)]
        XCTAssertNil(try settings.selected(base: "a/base.txt", destination: "b/RESULT.TXT"))
        XCTAssertEqual(try settings.selected(base: "a/base.txt", destination: "b/RESULT.TXT", alternate: true)?.applicationPath, "/Applications/Result.app")
        XCTAssertEqual(try settings.selected(base: "a/base.txt", destination: "b/other.txt")?.applicationPath, "/Applications/Base.app")
        XCTAssertEqual(try settings.selected(base: "base.bin", destination: "other.txt")?.applicationPath, "/Applications/Extension.app")
        XCTAssertEqual(try settings.selected(base: "a.bin", destination: "b.bin")?.applicationPath, "/Applications/Default.app")
        XCTAssertNil(try settings.selected(base: "a.png", destination: "b.png"))
        settings.associations.append(association(".png", "Image"))
        XCTAssertEqual(try settings.selected(base: "a.png", destination: "b.png")?.applicationPath, "/Applications/Image.app")
        XCTAssertNil(try settings.selected(base: "a.png", destination: "b.png", alternate: true))
    }
    func testArgumentsRemainLiteralAndReplacementIsSinglePass() throws {
        var tool = program("Tool"); tool.arguments = "--title=\"%bname\" '%base' %mine ''"
        let values = ["base": "/a/%mine ; $(echo no)", "mine": "/b/a file", "bname": "one ' two %base"]
        XCTAssertEqual(try tool.expandedArguments(values: values), ["--title=one ' two %base", "/a/%mine ; $(echo no)", "/b/a file", ""])
        tool.arguments = "--wait"
        XCTAssertEqual(try tool.expandedArguments(values: values), ["--wait", values["base"]!, values["mine"]!])
        tool.arguments = "%merged"
        XCTAssertEqual(try tool.expandedArguments(values: ["merged": "/result"], files: ["base", "theirs", "mine", "merged"]), ["/result"])
        for malformed in ["'unfinished", "trailing\\", "NUL\0argument"] { XCTAssertThrowsError(try DiffToolProgram.argumentTokens(malformed)) }
    }
    func testPersistenceUniqueKeysAndMergeFilenamePrecedence() throws {
        let suite = "TurtleGit.ToolTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var diff = DiffToolPreferences(); diff.program = program("Default", enabled: false); diff.associations = [association("*.txt", "Text")]
        try diff.save(to: defaults); XCTAssertEqual(DiffToolPreferences.load(from: defaults), diff)
        diff.associations.append(association(".TXT", "Duplicate")); XCTAssertFalse(diff.valid); XCTAssertThrowsError(try diff.save(to: defaults))
        var merge = MergeToolPreferences(); merge.program = program("Default")
        merge.associations = [association(".txt", "Extension"), association(".file.txt", "Filename")]; merge.blockWhileMerging = true
        try merge.save(to: defaults); XCTAssertEqual(MergeToolPreferences.load(from: defaults), merge)
        XCTAssertEqual(try merge.selected(path: "dir/FILE.TXT")?.applicationPath, "/Applications/Filename.app")
        XCTAssertEqual(try merge.selected(path: "other.txt")?.applicationPath, "/Applications/Extension.app")
        XCTAssertNil(try merge.selected(path: "file.txt", alternate: true))
    }
    func testExternalMergeExtractsExactStagesWithoutMutatingIndexOrWorkingFile() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), working = try Data(contentsOf: root.appendingPathComponent(path))
        let value = try await repo.externalMergeInputs(path: path)
        for (number, bytes) in [(1, value.base), (2, value.mine), (3, value.theirs)] {
            let object = try XCTUnwrap(value.entry.stages.first { $0.number == number }?.object)
            let actual = try await repo.run(["cat-file", "blob", object]).stdout; XCTAssertEqual(actual, bytes)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
        XCTAssertEqual(value.result, root.appendingPathComponent(path))
    }
}
