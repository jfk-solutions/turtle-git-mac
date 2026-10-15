// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Darwin
import TurtleGitCore

@main struct ExternalDocumentsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Provider: RepositoryBookmarkProvider {
        let allowed: Bool
        private let lock = NSLock()
        private var count = 0
        init(_ allowed: Bool = true) { self.allowed = allowed }
        var live: Int { lock.lock(); defer { lock.unlock() }; return count }
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
        func startAccessing(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; if allowed { count += 1 }; return allowed }
        func stopAccessing(_ url: URL) { lock.lock(); count -= 1; lock.unlock() }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "External document operation did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            ExternalToolProcesses.cancelAll()
            for _ in 0..<1000 { if ExternalToolProcesses.activeRequests == 0 && ExternalDocumentApplication.activeRequests == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            fputs("External documents failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func verify() async throws {
        try require(ExternalToolProcesses.activeRequests == 0, "Receiver began with unrelated tool executions")
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = root.appendingPathComponent("space 雪 'quote' $literal %title.patch")
        let bytes = Data([0xff,0,13,10]) + Data("private patch\n".utf8); try bytes.write(to: file)
        let suite = "TurtleGit.ExternalDocuments.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); UnifiedDiffPreviewFiles.discardAll(); ExternalToolProcesses.cancelAll() }
        let title = "revision \"雪\" %1 $(literal)\nnext line"
        var value = UnifiedDiffViewerPreferences(enabled: true, applicationPath: "/Applications/Private Viewer.app", arguments: #"--title "%title" --file=%1 '$HOME'"#)
        value.save(to: prefs)
        let provider = Provider()
        var received = false, preview: URL?
        let opened = try await UnifiedDiffApplication.openExternal(bytes, alternate: false, preferences: prefs, title: title, provider: provider, requiresScopes: true, launch: { application, documents, configuration in
            try require(application.path == value.applicationPath && documents.isEmpty && configuration.createsNewApplicationInstance, "Argument launch lost application/mode")
            let arguments = configuration.arguments
            try require(arguments.count == 4 && arguments[0] == "--title" && arguments[1] == title && arguments[3] == "$HOME", "Title was retokenized or shell-expanded")
            preview = URL(fileURLWithPath: String(arguments[2].dropFirst("--file=".count)))
            try require(try Data(contentsOf: preview!) == bytes, "Viewer preview changed original bytes")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "App launch lost Quit ownership")
            received = true
        })
        try require(opened && received && provider.live == 0 && ExternalDocumentApplication.activeRequests == 0, "App argument launch did not release scopes")
        try require(preview != nil && FileManager.default.fileExists(atPath: preview!.path), "Successful detached viewer lost preview")
        // Default stored settings still use native document URLs, with no argv override.
        value.arguments = ""; value.save(to: prefs); received = false
        _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: false, preferences: prefs, title: title, provider: provider, requiresScopes: true, launch: { _, documents, configuration in
            try require(documents.count == 1 && configuration.arguments.isEmpty && !configuration.createsNewApplicationInstance, "Legacy native document-open behavior changed")
            try require(try Data(contentsOf: documents[0]) == bytes, "Native document bytes changed"); received = true
        })
        try require(received && provider.live == 0, "Native document launch leaked grant")
        value.enabled = false; value.save(to: prefs); received = false
        let builtin = try await UnifiedDiffApplication.openExternal(bytes, alternate: false, preferences: prefs, launch: { _,_,_ in received = true })
        try require(!builtin && !received, "Disabled viewer launched without Shift")
        _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: true, preferences: prefs, launch: { _,_,_ in received = true })
        try require(received, "Shift did not restore disabled configured viewer")
        // Launch failure cleans only that request's original-byte preview.
        var failedPreview: URL?
        do {
            _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: true, preferences: prefs, launch: { _, documents, _ in failedPreview = documents.first; throw Failure(description: "injected launch failure") })
            throw Failure(description: "Expected app launch failure")
        } catch { try require(failedPreview != nil && !FileManager.default.fileExists(atPath: failedPreview!.path), "Failed viewer leaked preview") }
        do {
            _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: true, preferences: prefs, provider: Provider(false), requiresScopes: true, launch: { _,_,_ in throw Failure(description: "Unscoped tool launched") })
            throw Failure(description: "Missing program scope was accepted")
        } catch ExternalDocumentApplication.Failure.programPermission {
            try require(ExternalDocumentApplication.Failure.programPermission.localizedDescription.contains("Browse in Settings"), "Program permission recovery points to repository selection")
        }
        let cancelled = OperationCancellation(); cancelled.cancel()
        do {
            _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: true, preferences: prefs, cancellation: cancelled, launch: { _,_,_ in throw Failure(description: "Cancelled tool launched") })
            throw Failure(description: "Cancelled viewer was accepted")
        } catch is OperationCancellationFailure {}
        // A suspended native launch retains caller file permission until completion.
        var leaf: RepositoryAccessLease? = RepositoryAccessLease(url: file, provider: provider)
        weak var weakLeaf = leaf
        var resume: CheckedContinuation<Void,Never>?, started = false
        var program = value.program; program.arguments = "%1"
        let task = Task { try await ExternalDocumentApplication.open(file: file, program: program, arguments: [file.path], nativeDocumentOpen: true, permissions: [leaf!], provider: provider, requiresScopes: true, launch: { _,_,_ in started = true; await withCheckedContinuation { resume = $0 } }) }
        defer { resume?.resume(); resume = nil }
        try await wait { started }
        leaf = nil; try require(weakLeaf != nil && provider.live == 2, "Suspended native launch dropped file/program grant")
        resume?.resume(); resume = nil; try await task.value
        try require(weakLeaf == nil && provider.live == 0, "Completed native launch retained grants")
        // Actual executable argv and child settlement are checked without launching a user app.
        let tool = root.appendingPathComponent("viewer 雪")
        let script = """
        #!/bin/sh
        printf '%s\\0' "$@" > "$0.argv"
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s\\n' "$$" "$task_child" > "$0.pids"
        while [ ! -f "$0.release" ]; do /bin/sleep 0.05; done
        kill "$task_child" 2>/dev/null
        wait "$task_child" 2>/dev/null
        exit 0
        """
        try script.write(to: tool, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        value = UnifiedDiffViewerPreferences(enabled: true, applicationPath: tool.path, arguments: #"--title "%title" %1"#); value.save(to: prefs)
        _ = try await UnifiedDiffApplication.openExternal(bytes, alternate: false, preferences: prefs, title: title, provider: provider, requiresScopes: true)
        let argvFile = URL(fileURLWithPath: tool.path + ".argv"), pidFile = URL(fileURLWithPath: tool.path + ".pids")
        try await wait { FileManager.default.fileExists(atPath: pidFile.path) }
        let arguments = try Data(contentsOf: argvFile).split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        try require(arguments.count == 3 && arguments[0] == "--title" && arguments[1] == title, "Actual CLI argv changed title")
        try require(try Data(contentsOf: URL(fileURLWithPath: arguments[2])) == bytes && ExternalToolProcesses.activeRequests == 1 && provider.live == 1, "CLI launch dropped preview/scope/process ownership")
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Live executable lost Quit guard")
        ExternalToolProcesses.cancelAll(); try await wait { ExternalToolProcesses.activeRequests == 0 }
        try require(pids.count == 2 && pids.allSatisfy { kill($0,0) != 0 } && provider.live == 0, "Owned executable/descendant or scopes leaked")
        // Alternative Editor invokes one literal filename and guards its queued launch.
        let editor = root.appendingPathComponent("editor")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$0.argv\"\n".write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        AlternativeEditorPreferences(custom: true, applicationPath: editor.path).save(to: prefs)
        var queuedEditorOwned = false
        let editorFailure = await withCheckedContinuation { reply in
            AlternativeEditor.open(file, preferences: prefs) { reply.resume(returning: $0) }
            queuedEditorOwned = AlternativeEditor.activeRequests > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel
        }
        try require(queuedEditorOwned && editorFailure == nil, "Alternative executable failed: " + (editorFailure ?? ""))
        try await wait { ExternalToolProcesses.activeRequests == 0 && AlternativeEditor.activeRequests == 0 }
        let editorArguments = try Data(contentsOf: URL(fileURLWithPath: editor.path + ".argv")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        try require(editorArguments == [file.path] && Data(contentsOf: file) == bytes, "Alternative editor split/evaluated filename or changed bytes")
        // The actual settings form displays its owning template in a native field.
        let host = NSHostingController(rootView: UnifiedDiffViewerSettings(preferences: prefs))
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 680,height: 460), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = host; defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(host.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == value.arguments } }
        try require(ExternalDocumentApplication.activeRequests == 0 && UnifiedDiffApplication.activeRequests == 0, "Launch accounting did not settle")
        print("PASS: External document templates/native URL defaults, Shift, raw bytes, launch failure/cancellation, scoped app/CLI lifetime, actual argv/descendant reaping, Alternative Editor and owning Settings field")
    }
}
