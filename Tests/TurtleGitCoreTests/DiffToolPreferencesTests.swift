// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class DiffToolPreferencesTests: XCTestCase {
    private func program(_ name: String, enabled: Bool = true) -> DiffToolProgram {
        var result = DiffToolProgram(); result.enabled = enabled; result.applicationPath = "/Applications/" + name + ".app"; return result
    }
    private func association(_ pattern: String, _ name: String, enabled: Bool = true) -> DiffToolAssociation {
        var result = DiffToolAssociation(); result.pattern = pattern; result.program = program(name, enabled: enabled); return result
    }
    func testExecutableProgramSelectionAssociationsPersistenceAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("diff tool 雪"), link = root.appendingPathComponent("tool-link")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        var tool = DiffToolProgram(); tool.enabled = true; tool.applicationPath = file.path
        XCTAssertFalse(tool.valid)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        XCTAssertTrue(tool.valid); XCTAssertFalse(tool.isApplicationBundle)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        tool.applicationPath = link.path; XCTAssertTrue(tool.valid)
        var settings = MergeToolPreferences(); settings.program = tool; settings.blockWhileMerging = true; settings.trustExitCode = true
        XCTAssertTrue(settings.supportsTrustedExit)
        var association = DiffToolAssociation(); association.pattern = ".txt"; association.program = tool
        settings.associations = [association]
        let suite = "TurtleGit.CLIToolTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try settings.save(to: defaults)
        let loaded = MergeToolPreferences.load(from: defaults)
        XCTAssertEqual(loaded, settings); XCTAssertEqual(try loaded.selected(path: "a.txt"), tool)
        XCTAssertNil(try loaded.selected(path: "a.txt", alternate: true))
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(tool.valid)
        XCTAssertThrowsError(try loaded.selected(path: "a.txt"))
    }
    func testExecutableLaunchKeepsLiteralArgumentsWorkingDirectoryAndExitStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool"), log = root.appendingPathComponent("arguments")
        let source = #"""
        #!/bin/sh
        printf '%s\000' "$PWD" "$@" > "$1"
        exit 17
        """#
        try Data(source.utf8).write(to: script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let literal = "a ' quote ; $(touch forbidden) %mine 雪"
        let execution = try await ExternalToolExecution.start(executable: script, arguments: [log.path, literal], directory: root)
        let status = try await execution.completion.value
        XCTAssertEqual(status, 17)
        let arguments = try Data(contentsOf: log).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(Array(arguments.dropFirst()), [log.path, literal])
        // macOS may spell the same directory /var or /private/var. Compare the
        // actual directory identity, while retaining byte-exact argument checks.
        let actual = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(arguments.first))
        let expected = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(actual[.systemNumber] as? NSNumber, expected[.systemNumber] as? NSNumber)
        XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        do { _ = try await ExternalToolExecution.start(executable: root.appendingPathComponent("missing"), arguments: [], directory: root); XCTFail("Missing executable launched") } catch {}
    }
    func testExecutableCancellationReapsOwnedProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tool"), marker = root.appendingPathComponent("started")
        let source = #"""
        #!/bin/sh
        /bin/sleep 30 &
        child=$!
        trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' INT TERM
        printf '%s %s' "$$" "$child" > "$1.tmp"
        /bin/mv "$1.tmp" "$1"
        wait "$child"
        """#
        try Data(source.utf8).write(to: script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let token = OperationCancellation()
        let execution = try await ExternalToolExecution.start(executable: script, arguments: [marker.path], directory: root, cancellation: token)
        defer { execution.cancel() }
        for _ in 0..<300 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let pids = try String(contentsOf: marker).split(separator: " ").compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)
        token.cancel()
        do { _ = try await execution.completion.value; XCTFail("Cancelled tool accepted") } catch is OperationCancellationFailure {}
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 })
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
