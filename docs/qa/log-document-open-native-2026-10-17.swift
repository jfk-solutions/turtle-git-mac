import AppKit
import TurtleGitCore

@main struct LogDocumentOpenVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timeout: " + message)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Log document Open failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), root = base.appendingPathComponent("repository"), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default; try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git, askpass: nil)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Log Open QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "file 雪.txt", bytes = Data("historical\n".utf8), file = root.appendingPathComponent(path)
        try bytes.write(to: file); _ = try await repo.run(["add", "--", path]); _ = try await repo.run(["commit", "-m", "historical"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let app = base.appendingPathComponent("Reader.app"), other = base.appendingPathComponent("Other.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true); try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let suite = "TurtleGit.LogOpen.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "EnableLogCache"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        var owners: [LogWindowController] = [], previews: [URL] = []
        defer { owners.forEach { $0.close() }; previews.forEach { HistoricalPreviewFiles.discard($0) } }
        func owner(working: Bool = false) async throws -> LogWindowController {
            prefs.set(working, forKey: "LogIncludeWorkingTreeChanges")
            let value = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false, historyFileCache: HistoryFileCache(root: base.appendingPathComponent("private-cache")))
            owners.append(value)
            try await wait("Log loaded") { !value.model.busy && !value.model.entries.isEmpty }
            value.model.select([working ? "" : value.model.entries.first { !$0.hash.isEmpty }!.hash])
            try await wait("Log files") { value.model.files.count == 1 }
            value.model.selectedFiles = [value.model.files[0].id]
            return value
        }
        func open(_ value: LogWindowController, _ action: HistoricalOpenAction = .open) { value.model.openHistoricalFile([value.model.files[0].id], action: action) }
        func settled(_ value: LogWindowController) async throws { try await wait("Open settled") { value.documentOpen == nil && !value.model.busy && LogWindowModel.activeFileOpenReads == 0 } }
        // Real historical read -> deferred owner -> native document-open packet.
        let first = try await owner(); var launches = 0
        first.configureDocumentOpen = { operation in
            operation.defaultApplication = { _ in app }
            operation.launch = { application, documents, configuration in
                launches += 1; try require(application == app && documents.count == 1 && configuration.arguments.isEmpty && !configuration.createsNewApplicationInstance, "Default Open arguments changed")
                previews += documents; try require(try Data(contentsOf: documents[0]) == bytes, "Historical bytes changed")
                let mode = try fm.attributesOfItem(atPath: documents[0].path)[.posixPermissions] as! NSNumber
                try require(mode.intValue & 0o222 == 0, "Historical preview is writable")
            }
        }
        open(first); try await wait("Default launch") { launches == 1 }; try await settled(first); first.close()
        let cancelled = try await owner(); var choices = 0
        cancelled.configureDocumentOpen = { operation in
            operation.chooseApplication = { _ in choices += 1; return nil }
            operation.launch = { _, _, _ in throw Failure(message: "Cancelled panel launched") }
        }
        open(cancelled, .openWith); try await wait("Cancel choice") { choices == 1 }; try await settled(cancelled)
        try require(cancelled.model.error == nil, "Cancel produced error"); cancelled.close()
        let stale = try await owner(); var choiceReply: CheckedContinuation<URL?, Never>?, staleLaunches = 0
        stale.configureDocumentOpen = { operation in
            operation.chooseApplication = { _ in await withCheckedContinuation { choiceReply = $0 } }
            operation.launch = { _, _, _ in staleLaunches += 1 }
        }
        open(stale, .openWith); try await wait("Pending choice") { choiceReply != nil }
        open(stale, .openWith); try require(LogDocumentOpenSession.activeRequests == 1, "Duplicate Open started")
        stale.model.selectedFiles = []; choiceReply!.resume(returning: app); choiceReply = nil
        try await settled(stale); try require(staleLaunches == 0, "Stale Open With launched"); stale.close()
        // Preview preparation retains ownership after forced closure and discards
        // an input that has never reached the launch adapter.
        let preparation = try await owner(); var prepareReply: CheckedContinuation<Void, Never>?, abandoned: URL?
        preparation.configureDocumentOpen = { operation in
            operation.preparePreview = { content, token in
                let preview = try HistoricalFilePreview.create(content); abandoned = preview.file
                await withCheckedContinuation { prepareReply = $0 }; return preview
            }
            operation.launch = { _, _, _ in throw Failure(message: "Retired preparation launched") }
        }
        open(preparation); try await wait("Preparation gate") { prepareReply != nil }
        try require(preparation.windowShouldClose(preparation.window!), "Native Close blocked preparation retirement"); preparation.close()
        try require(LogDocumentOpenSession.activeRequests == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Preparation lost Quit lifetime")
        prepareReply!.resume(); prepareReply = nil; try await wait("Preparation drained") { LogDocumentOpenSession.activeRequests == 0 }
        try require(!fm.fileExists(atPath: abandoned!.path), "Undispatched preview survived retirement")
        let pending = try await owner(); var launchReply: CheckedContinuation<Void, Error>?, accepted: URL?
        pending.configureDocumentOpen = { operation in
            operation.defaultApplication = { _ in app }
            operation.launch = { _, documents, _ in accepted = documents[0]; previews += documents; try await withCheckedThrowingContinuation { launchReply = $0 } }
        }
        open(pending); try await wait("Pending launch") { launchReply != nil }
        pending.model.error = "Keep current error"
        try require(pending.windowShouldClose(pending.window!), "Native Close blocked pending launch retirement"); pending.close()
        try require(LogDocumentOpenSession.activeRequests == 1 && ExternalDocumentApplication.activeRequests == 1 && fm.fileExists(atPath: accepted!.path) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Accepted launch lost preview/Quit lifetime")
        launchReply!.resume(throwing: Failure(message: "Uncertain delivery")); launchReply = nil
        try await wait("Launch drained") { LogDocumentOpenSession.activeRequests == 0 && ExternalDocumentApplication.activeRequests == 0 }
        try require(pending.model.error == "Keep current error" && fm.fileExists(atPath: accepted!.path), "Late error published or accepted preview deleted")
        AlternativeEditorPreferences(custom: true, applicationPath: app.path).save(to: prefs)
        let editor = try await owner(); var editorReply: CheckedContinuation<Void, Never>?, editorLaunches = 0
        editor.configureDocumentOpen = { operation in
            operation.preparePreview = { content, _ in let preview = try HistoricalFilePreview.create(content); previews.append(preview.file); await withCheckedContinuation { editorReply = $0 }; return preview }
            operation.launch = { application, documents, configuration in editorLaunches += 1; try require(application == app && documents.count == 1 && configuration.arguments.isEmpty, "Editor settings/arguments were not captured") }
        }
        open(editor, .alternativeEditor); try await wait("Editor preparation") { editorReply != nil }
        AlternativeEditorPreferences(custom: true, applicationPath: other.path).save(to: prefs)
        editorReply!.resume(); editorReply = nil; try await settled(editor)
        try require(editorLaunches == 1, "Captured editor did not launch"); editor.close()
        let missing = try await owner(); var missingPreview: URL?
        missing.configureDocumentOpen = { operation in
            operation.defaultApplication = { _ in nil }
            operation.preparePreview = { content, _ in let preview = try HistoricalFilePreview.create(content); missingPreview = preview.file; return preview }
        }
        open(missing); try await wait("Missing handler error") { missing.model.error != nil }; try await settled(missing)
        try require(!fm.fileExists(atPath: missingPreview!.path), "Missing-handler preview leaked"); missing.close()
        let disk = Data("working tree\n".utf8); try disk.write(to: file)
        let working = try await owner(working: true); var workingLaunches = 0
        working.configureDocumentOpen = { operation in
            operation.defaultApplication = { _ in app }
            operation.launch = { _, documents, _ in workingLaunches += 1; try require(documents == [file] && (try Data(contentsOf: documents[0])) == disk, "Working Open substituted historical/temp data") }
        }
        open(working); try await wait("Working launch") { workingLaunches == 1 }; try await settled(working); working.close()
        try require(try await repo.run(["rev-parse", "HEAD"]).stdout == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Open changed Git state")
        try require(LogDocumentOpenSession.activeRequests == 0 && LogWindowModel.activeFileOpenReads == 0 && AlternativeEditor.activeRequests == 0 && ExternalDocumentApplication.activeRequests == 0, "Open owners leaked")
        print("PASS: Log document Open family: current/default/working, cancelled/stale Open With, settings capture, read-only previews, retirement, uncertain delivery and Quit")
    }
}
