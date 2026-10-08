import AppKit
import SwiftUI
import TurtleGitCore

@main struct TemporaryFilesVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.TemporaryFiles.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let temp = TemporaryFileStore(root: root.appendingPathComponent("owned-temp")); try temp.prepare()
        let cache = temp.root.appendingPathComponent("TurtleGit-Gravatar"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let image = cache.appendingPathComponent("cached-author"); try Data("cached".utf8).write(to: image)
        let viewer = temp.root.appendingPathComponent("preview"); try Data("patch".utf8).write(to: viewer)
        let log = ActionLogStore(storageURL: root.appendingPathComponent("private/logfile.txt")); try log.append(repository: root, output: "preserved", cancelled: false)
        prefs.set(["keep history"], forKey: "Clone.URLHistory")
        let model = SavedDataSettingsModel(store: log, preferences: prefs, temporaryFiles: temp, showFile: { _ in true })
        var answer: ((Bool) -> Void)?, requests = 0
        model.confirmTemporaryClear = { requests += 1; answer = $0 }
        model.clearTemporaryFiles(); model.clearTemporaryFiles()
        precondition(requests == 1 && model.confirmingTemporaryClear && FileManager.default.fileExists(atPath: image.path))
        let firstAnswer = answer; answer?(false); precondition(!model.confirmingTemporaryClear && model.canClearTemporaryFiles && FileManager.default.fileExists(atPath: viewer.path))
        model.clearTemporaryFiles(); precondition(requests == 2); firstAnswer?(true)
        precondition(model.confirmingTemporaryClear && FileManager.default.fileExists(atPath: image.path)); answer?(true)
        precondition(!model.confirmingTemporaryClear && !model.canClearTemporaryFiles && model.error == nil)
        precondition(!FileManager.default.fileExists(atPath: image.path) && !FileManager.default.fileExists(atPath: viewer.path))
        let sentinel = temp.root.appendingPathComponent("late"); try Data("keep duplicate".utf8).write(to: sentinel)
        answer?(true); precondition(FileManager.default.fileExists(atPath: sentinel.path), "Duplicate answer must not delete newly created files")
        model.resetTemporaryAvailability(); precondition(model.canClearTemporaryFiles)
        precondition(log.exists && prefs.stringArray(forKey: "Clone.URLHistory") == ["keep history"])
        let alert = SavedDataSettingsModel.temporaryClearAlert()
        precondition(alert.buttons.map { $0.title } == ["Abort", "Proceed"] && alert.buttons[0].keyEquivalent == "\r")
        precondition(alert.window.defaultButtonCell === alert.buttons[0].cell && alert.informativeText.contains("HTTP cache")); alert.window.close()
        let linked = root.appendingPathComponent("linked-temp"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: temp.root)
        let invalid = SavedDataSettingsModel(store: log, preferences: prefs, temporaryFiles: TemporaryFileStore(root: linked), showFile: { _ in true })
        invalid.confirmTemporaryClear = { $0(true) }; invalid.clearTemporaryFiles()
        precondition(invalid.error != nil && invalid.canClearTemporaryFiles && FileManager.default.fileExists(atPath: sentinel.path))
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Temp QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let preview = try UnifiedDiffPreview.create(Data("exact patch\r\n".utf8)); defer { preview.discard() }
        precondition(preview.directory.deletingLastPathComponent().standardizedFileURL == TurtleGitTemporaryStorage.defaultRoot.standardizedFileURL)
        let bytes = try Data(contentsOf: preview.file); precondition(bytes == Data("exact patch\r\n".utf8))
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(head == after)
        let host = NSHostingView(rootView: SavedDataSettingsPage()); host.frame = NSRect(x: 0, y: 0, width: 760, height: 700); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        print("PASS: native Temp files pending/Abort/Proceed/duplicate guards, real nested avatar/preview removal, Abort default alert, symlink rejection, preserved log/history and managed exact-byte preview; hidden host, no main app")
    }
}
