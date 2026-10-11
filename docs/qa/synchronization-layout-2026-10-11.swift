import AppKit
import TurtleGitCore
@testable import TurtleGitMac

// Link against the freshly built Debug app objects with entry point
// _turtlegit_layout_main. Captures actual AppKit/SwiftUI content, not a mockup.
struct SynchronizationLayoutCapture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root)
        _ = try await repository.run(["init", "-b", "main", "--template="])
        for (key, value) in [("user.name", "TurtleGit demo"), ("user.email", "demo@example.invalid"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        let file = root.appendingPathComponent("README.md")
        try Data("TurtleGit sample repository\n".utf8).write(to: file)
        try await repository.stage(["README.md"]); _ = try await repository.commit(message: "Create the sample repository")
        let base = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("TurtleGit sample repository\nReview native synchronization controls\n".utf8).write(to: file)
        try await repository.stage(["README.md"]); _ = try await repository.commit(message: "Review native synchronization controls")
        _ = try await repository.run(["remote", "add", "origin", root.deletingLastPathComponent().appendingPathComponent("sample-server.git").path])
        _ = try await repository.run(["update-ref", "refs/remotes/origin/main", base])
        _ = try await repository.run(["config", "branch.main.remote", "origin"])
        _ = try await repository.run(["config", "branch.main.merge", "refs/heads/main"])
        let refs = try await repository.run(["show-ref"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let suite = "TurtleGit.Sync.Layout." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        DialogGeometry.install(preferences: preferences)
        let owner = SynchronizationWindowController(repository: repository, access: nil, preferences: preferences)
        owner.window!.alphaValue = 1; owner.showWindow(nil); defer { owner.close() }
        for _ in 0..<2000 { if !owner.model.busy && owner.model.outgoing != nil { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(!owner.model.busy && owner.model.outgoing?.commits.count == 1 && owner.model.pushActionTitle == "Push")
        let window = owner.window!
        for (size, suffix) in [(NSSize(width: 1050, height: 660), ""), (NSSize(width: 860, height: 500), "-minimum")] {
            window.setContentSize(size)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance); window.makeFirstResponder(nil)
                let view = window.contentView!; view.layoutSubtreeIfNeeded(); view.needsDisplay = true
                try await Task.sleep(nanoseconds: 250_000_000)
                guard let capture = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { throw NSError(domain: "SynchronizationCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Window capture unavailable"]) }
                let bitmap = NSBitmapImageRep(cgImage: capture)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("git-synchronization-" + name + suffix + ".png"))
                print("CAPTURE: \(name)\(suffix) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }
        let finalRefs = try await repository.run(["show-ref"]).stdout, finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        precondition(refs == finalRefs && index == finalIndex && config == finalConfig)
        owner.close(); precondition(owner.model.closed && !owner.model.busy && !owner.model.transportRunning && !window.isVisible)
        print("PASS: read-only native Sync captures, one owned window, both sizes/themes and closed owner")
    }
}
@_cdecl("turtlegit_layout_main") func bootstrap() -> Int32 {
    Task { @MainActor in
        do { try await SynchronizationLayoutCapture.main(); exit(0) }
        catch { print(error); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
