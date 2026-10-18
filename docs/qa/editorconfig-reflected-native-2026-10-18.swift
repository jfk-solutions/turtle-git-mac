// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Actual parser/editor targets and sheet/drain ownership, with private files.
enum EditorConfigReflectedVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reflected EditorConfig timeout at \(line)")
    }
    final class ScopeProvider: RepositoryBookmarkProvider, @unchecked Sendable {
        private let lock = NSLock(); private var begins = 0, ends = 0
        var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (begins, ends) }
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
        func startAccessing(_ url: URL) -> Bool { lock.lock(); begins += 1; lock.unlock(); return true }
        func stopAccessing(_ url: URL) { lock.lock(); ends += 1; lock.unlock() }
    }
    final class HeldParser: @unchecked Sendable {
        private let lock = NSLock(); private var entered = false
        private let semaphore = DispatchSemaphore(value: 0)
        var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func run() -> MergeEditorConfigProperties {
            lock.lock(); entered = true; lock.unlock()
            _ = semaphore.wait(timeout: .now() + 30)
            return .init(properties: ["tab_width": "99"])
        }
        func release() { semaphore.signal() }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let parser = try EditorConfigRuntime.executable(bundle: SubversionMergeDiff.applicationBundle())
        let suite = "TurtleGit.EditorConfig.Reflected." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "TurtleGitMerge.EnableEditorConfig"); prefs.set(false, forKey: "TurtleGitMerge.Backup")
        var pairs: [FileComparisonWindowController] = [], merges: [TextConflictWindowController] = []
        var heldChoice: CheckedContinuation<URL?, Never>?, heldParser: HeldParser?
        defer { prefs.removePersistentDomain(forName: suite) }
        let text = "keep  \nend" // trailing spaces and missing final newline must survive Save.
        func folder(_ name: String, width: Int) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(("root=true\n[*]\ntab_width=\(width)\nindent_style=space\ncharset=utf-16le\nend_of_line=crlf\ntrim_trailing_whitespace=true\ninsert_final_newline=true\n").utf8).write(to: directory.appendingPathComponent(".editorconfig"))
            return directory
        }
        func read() -> MergeEditorConfigRead {
            let value = MergeEditorConfigRead(); value.folderAccess.requireScope = false
            value.resolve = { try EditorConfigRuntime.resolve(file: $0, executable: parser, cancellation: $1) }
            return value
        }
        func ready(_ owner: FileComparisonWindowController) -> Bool { owner.model.document != nil && !owner.model.mergeToolHasPendingWork && !owner.model.filtering }
        func ready(_ owner: TextConflictWindowController) -> Bool { owner.model.document != nil && !owner.model.mergeToolHasPendingWork && owner.model.nativeEditorReady }
        func pair(_ directory: URL, flags: [String] = []) throws -> FileComparisonWindowController {
            let base = directory.appendingPathComponent("base.txt"), mine = directory.appendingPathComponent("mine.txt")
            try Data(text.utf8).write(to: base); try Data(text.utf8).write(to: mine)
            let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs, deferInitialLoad: true)
            pairs.append(owner); owner.model.makeEditorConfigRead = read
            let invocation = try MergeToolInvocation.parse(arguments: ["--merge-tool", "--base", base.path, "--mine", mine.path] + flags, currentDirectory: root.path)!
            try owner.model.configureMergeTool(invocation)
            owner.window!.alphaValue = 0; owner.window!.orderFront(nil); owner.model.beginTransferredDocument()
            return owner
        }
        func merge(_ directories: [URL], flags: [String] = []) throws -> TextConflictWindowController {
            let files = zip(directories, ["base.txt", "theirs.txt", "mine.txt", "result.txt"]).map { $0.0.appendingPathComponent($0.1) }
            for file in files { try Data(text.utf8).write(to: file) }
            let working = try WorkingTextMerge(base: files[0], theirs: files[1], mine: files[2], merged: files[3])
            let owner = TextConflictWindowController(repository: GitRepository(root: root, executable: git), access: nil, path: files[3].path, workingMerge: working, preferences: prefs, deferInitialLoad: true)
            merges.append(owner); owner.model.makeEditorConfigRead = read
            owner.model.commentProfileURL = root.appendingPathComponent("private-ignorecomments.txt")
            owner.model.regexDefaults = prefs; owner.model.saveFolderAccess.requireScope = false
            let invocation = try MergeToolInvocation.parse(arguments: ["--merge-tool", "--base", files[0].path, "--theirs", files[1].path, "--mine", files[2].path, "--merged", files[3].path] + flags, currentDirectory: root.path)!
            try owner.model.configureMergeTool(invocation)
            owner.window!.alphaValue = 0; owner.window!.orderFront(nil); owner.model.beginTransferredDocument()
            return owner
        }
        func clean() async throws {
            heldChoice?.resume(returning: nil); heldChoice = nil; heldParser?.release()
            pairs.forEach { $0.close() }; merges.forEach { $0.close() }
            try await wait { pairs.allSatisfy { !$0.model.mergeToolHasPendingWork } && merges.allSatisfy { !$0.model.mergeToolHasPendingWork } && MergeRegexOperations.activeRequests == 0 }
        }
        do {
            let actual = try folder("actual", width: 2), reflected = try folder("reflected [literal]", width: 4)
            try Data("root=true\n[base.txt]\ntab_width=3\n[mine.txt]\ntab_width=5\n[theirs.txt]\ntab_width=7\n[result.txt]\ntab_width=8\n".utf8).write(to: reflected.appendingPathComponent(".editorconfig"))
            let names = ["base", "theirs", "mine", "result"].map { reflected.appendingPathComponent($0 + ".txt") }
            let reflectedFlags = ["--basereflectedname", names[0].path, "--theirsreflectedname", names[1].path, "--minereflectedname", names[2].path, "--mergedreflectedname", names[3].path]
            let comparison = try pair(actual, flags: ["--basereflectedname", names[0].path, "--minereflectedname", names[2].path])
            try await wait { ready(comparison) }
            comparison.model.setEditorConfig(true, base: true); comparison.model.setEditorConfig(true, base: false)
            try await wait { ready(comparison) }
            try require(comparison.model.tabWidth(base: true) == 3 && comparison.model.tabWidth(base: false) == 5, "Two-file panes resolved temporary input rather than reflected missing leaves")
            comparison.model.switchSides(); try await wait { ready(comparison) && comparison.model.mergeToolReflectedName(base: true) == names[2].path }
            try require(comparison.model.tabWidth(base: true) == 5 && comparison.model.tabWidth(base: false) == 3, "Switch Sides did not carry reflected EditorConfig targets")
            let other = try folder("save-as", width: 9), output = other.appendingPathComponent("saved.txt")
            comparison.model.chooseExportLocation = { _, _, _ in output }; comparison.model.saveAs(base: false)
            try await wait { ready(comparison) && comparison.model.savedPaneURL(base: false) != nil }
            try require(comparison.model.tabWidth(base: false) == 3 && (try Data(contentsOf: output)) == Data(text.utf8), "SaveFileTo lost reflected priority or applied unused save properties")
            comparison.close(); try await wait { !comparison.model.mergeToolHasPendingWork }

            let ordinary = try pair(try folder("ordinary", width: 2))
            try await wait { ready(ordinary) }; ordinary.model.setEditorConfig(true, base: false)
            try await wait { ready(ordinary) }; try require(ordinary.model.tabWidth(base: false) == 2, "Ordinary actual-file configuration missing")
            let ordinaryOutput = other.appendingPathComponent("ordinary-saved.txt")
            ordinary.model.chooseExportLocation = { _, _, _ in ordinaryOutput }; ordinary.model.saveAs(base: false)
            try await wait { ready(ordinary) && ordinary.model.savedPaneURL(base: false) != nil }
            try require(ordinary.model.tabWidth(base: false) == 9, "Unreflected SaveFileTo kept stale input configuration")
            ordinary.close(); try await wait { !ordinary.model.mergeToolHasPendingWork }

            // Four reads share one owner. Hold its authorization and prove that
            // other panes queue instead of presenting competing sheets or skipping.
            let scoped = try merge([actual, actual, actual, actual], flags: reflectedFlags)
            try await wait { ready(scoped) }
            let provider = ScopeProvider(); var choices = 0, selectedParents: [String] = []
            scoped.model.makeEditorConfigRead = {
                let value = read(); value.folderAccess.requireScope = true
                value.folderAccess.makeLease = { RepositoryAccessLease(url: $0, provider: provider) }
                value.folderAccess.chooseFolder = { _, parent in
                    choices += 1; selectedParents.append(parent.path)
                    return await withCheckedContinuation { heldChoice = $0 }
                }
                value.resolve = { file, token in try EditorConfigRuntime.resolve(file: file, executable: parser, cancellation: token) }
                return value
            }
            let scopedGroup = UUID()
            for pane in ["Base", "Theirs", "Mine", "Merged · \(scoped.model.resultPath)"] { scoped.model.setEditorConfig(true, pane: pane, readGroup: scopedGroup) }
            try await wait { heldChoice != nil }
            try require(choices == 1 && selectedParents == [reflected.path] && scoped.model.editorConfigLoading.count == 4 && scoped.model.mergeToolHasPendingWork, "Parallel panes did not retain one owned authorization interval")
            heldChoice?.resume(returning: reflected); heldChoice = nil
            try await wait { ready(scoped) }
            let resultPane = "Merged · \(scoped.model.resultPath)"
            try require(scoped.model.tabWidths["Base"] == 3 && scoped.model.tabWidths["Theirs"] == 7 && scoped.model.tabWidths["Mine"] == 5 && scoped.model.tabWidths[resultPane] == 8, "Four-pane reflected configuration targets were collapsed")
            try require(choices == 1 && provider.counts.0 == 1 && provider.counts.1 == 0, "Granted folder scope was not reused/retained by the editor")
            scoped.close(); try await wait { !scoped.model.mergeToolHasPendingWork && provider.counts.1 == 1 }

            let cancelled = try merge([actual, actual, actual, actual], flags: reflectedFlags)
            try await wait { ready(cancelled) }; var deniedChoices = 0
            cancelled.model.makeEditorConfigRead = {
                let value = read(); value.folderAccess.requireScope = true
                value.folderAccess.chooseFolder = { _, _ in deniedChoices += 1; return nil }
                value.resolve = { _, _ in throw Failure(description: "Denied reflected path launched parser") }
                return value
            }
            let cancelledGroup = UUID()
            for pane in ["Base", "Theirs", "Mine", "Merged · \(cancelled.model.resultPath)"] { cancelled.model.setEditorConfig(true, pane: pane, readGroup: cancelledGroup) }
            try await wait { ready(cancelled) }
            try require(deniedChoices == 1 && !cancelled.model.editorConfigLoaded.values.contains(true), "Cancelled folder prompt repeated for every queued pane")
            cancelled.model.setEditorConfig(true, pane: "Mine"); try await wait { ready(cancelled) }
            try require(deniedChoices == 2, "Later explicit EditorConfig retry was permanently suppressed")
            cancelled.close(); try await wait { !cancelled.model.mergeToolHasPendingWork }

            let dirs = try [10, 11, 12, 13].enumerated().map { try folder("pane-\($0.offset)", width: $0.element) }
            let separate = try merge(dirs)
            try await wait { ready(separate) }
            for pane in ["Base", "Theirs", "Mine", "Merged · \(separate.model.resultPath)"] { separate.model.setEditorConfig(true, pane: pane) }
            try await wait { ready(separate) }
            try require(separate.model.tabWidths["Base"] == 10 && separate.model.tabWidths["Theirs"] == 11 && separate.model.tabWidths["Mine"] == 12 && separate.model.tabWidths["Merged · \(separate.model.resultPath)"] == 13, "Four actual input/output directories did not remain independent")
            let rebound = try folder("rebound-mine", width: 15).appendingPathComponent("mine.txt")
            separate.model.sourceExporter.present = { _, _, reply in reply(.OK) }; separate.model.sourceExporter.selectedURL = { _ in rebound }
            separate.model.sourceExporter.saveFolderAccess.requireScope = false
            separate.model.exportSource(mine: true)
            try await wait { ready(separate) && !separate.model.sourceExporter.hasPendingWork && separate.model.sourceTargetURL(mine: true) != nil }
            try require(separate.model.tabWidths["Mine"] == 15 && (try separate.model.editorConfigURL(pane: "Mine")).path == rebound.path, "Rebound source retained old EditorConfig target")
            let oldResultPane = "Merged · \(separate.model.resultPath)", savedResult = try folder("new-result", width: 17).appendingPathComponent("saved.txt")
            separate.model.chooseStandaloneOutput = { _, _ in savedResult }
            var saved: Bool?; separate.model.save(markResolved: false, chooseNewOutput: true) { saved = $0 }
            try await wait { saved != nil && ready(separate) }
            let newResultPane = "Merged · \(separate.model.resultPath)"
            try require(saved == true && newResultPane != oldResultPane && separate.model.editorConfigEnabled[newResultPane] == true && separate.model.editorConfigEnabled[oldResultPane] == nil && separate.model.tabWidths[newResultPane] == 17, "Result Save As lost pane toggle or reused stale output configuration")
            try require((try Data(contentsOf: savedResult)) == Data(text.utf8), "EditorConfig charset/ending/trim/final-newline unexpectedly rewrote saved result")
            separate.model.load(); try await wait { ready(separate) }
            try require(separate.model.tabWidths["Mine"] == 15 && separate.model.tabWidths[newResultPane] == 17, "Reload forgot rebound/result targets")
            separate.close(); try await wait { !separate.model.mergeToolHasPendingWork }

            let retiring = try merge(dirs), gate = HeldParser(); heldParser = gate
            try await wait { ready(retiring) }
            retiring.model.makeEditorConfigRead = { let value = read(); value.resolve = { _, _ in gate.run() }; return value }
            for pane in ["Base", "Theirs", "Mine", "Merged · \(retiring.model.resultPath)"] { retiring.model.setEditorConfig(true, pane: pane) }
            try await wait { gate.started }
            retiring.close()
            try require(retiring.model.mergeToolHasPendingWork && MergeRegexOperations.activeRequests > 0, "Retirement dropped held/queued read lifetime")
            gate.release(); heldParser = nil
            try await wait { !retiring.model.mergeToolHasPendingWork && MergeRegexOperations.activeRequests == 0 }
            try require(!retiring.model.tabWidths.values.contains(99), "Retired read recreated pane settings")
            for file in [actual.appendingPathComponent("base.txt"), actual.appendingPathComponent("mine.txt")] { try require((try Data(contentsOf: file)) == Data(text.utf8), "EditorConfig changed an input") }
            for file in names { try require(!FileManager.default.fileExists(atPath: file.path), "EditorConfig created a reflected metadata leaf") }
            for (directory, name) in zip(dirs, ["base.txt", "theirs.txt", "mine.txt", "result.txt"]) { try require((try Data(contentsOf: directory.appendingPathComponent(name))) == Data(text.utf8), "Settings/Save As modified an original source/output") }
            try await clean()
            print("PASS: reflected/actual EditorConfig paths, Switch Sides, missing reflected leaves, independent four-pane/rebound/result targets, Save As session migration, real parser, unused save properties, serialized authorization/scope reuse and retired queue drain")
        } catch { try? await clean(); throw error }
    }
}
