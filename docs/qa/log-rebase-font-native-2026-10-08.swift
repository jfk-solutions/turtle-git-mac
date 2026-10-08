import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class OutputFontMode: ObservableObject { @Published var configured = false }
struct OutputFontPreview: View {
    @ObservedObject var mode: OutputFontMode
    var body: some View { OutputView(text: "Legacy output", usesLogFont: mode.configured) }
}

@main struct LogRebaseFontVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func texts(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { texts(in: $0) }
    }
    @MainActor static func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view); return window
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.LogRebaseFont.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        let rebase = RebaseWindowModel(repository: repo, access: nil, messageDefaults: prefs)
        rebase.fileRecovery = true; rebase.amendMessage = "Rebase draft 雪"; rebase.output = "Rebase progress 雪"; rebase.tab = 1
        let logWindow = host(LogDialog(model: log).defaultAppStorage(prefs))
        let rebaseWindow = host(RebaseDialog(model: rebase).defaultAppStorage(prefs))
        let mode = OutputFontMode()
        let legacy = host(OutputFontPreview(mode: mode).defaultAppStorage(prefs))
        defer { logWindow.close(); rebaseWindow.close(); legacy.close(); log.invalidate() }
        try await settle(logWindow.contentView!); try await settle(rebaseWindow.contentView!); try await settle(legacy.contentView!)
        let message = texts(in: logWindow.contentView!).first { $0.string == log.message }!
        let amend = texts(in: rebaseWindow.contentView!).first { $0.string == rebase.amendMessage }!
        let unchanged = texts(in: legacy.contentView!).first { $0.string == "Legacy output" }!
        precondition(message.font?.pointSize == 9 && amend.font?.pointSize == 9 && unchanged.font?.pointSize == 12)
        message.setSelectedRange(.init(location: 0, length: 8)); amend.setSelectedRange(.init(location: 0, length: 6))
        prefs.set("Monaco", forKey: "LogFontName"); prefs.set(18, forKey: "LogFontSize")
        try await settle(logWindow.contentView!); try await settle(rebaseWindow.contentView!); try await settle(legacy.contentView!)
        precondition(message.font?.familyName == "Monaco" && message.font?.pointSize == 18)
        precondition(amend.font?.familyName == "Monaco" && amend.font?.pointSize == 18 && amend.string == "Rebase draft 雪")
        precondition(message.selectedRange() == .init(location: 0, length: 8) && amend.selectedRange() == .init(location: 0, length: 6))
        precondition(unchanged.font?.pointSize == 12 && unchanged.string == "Legacy output")
        mode.configured = true; try await settle(legacy.contentView!); precondition(unchanged.font?.pointSize == 18)
        mode.configured = false; try await settle(legacy.contentView!); precondition(unchanged.font?.pointSize == 12)
        rebase.tab = 2; try await settle(rebaseWindow.contentView!)
        let progress = texts(in: rebaseWindow.contentView!).first { $0.string == rebase.output }!
        precondition(progress.font?.familyName == "Monaco" && progress.font?.pointSize == 18 && !progress.isEditable)
        prefs.set(22, forKey: "LogFontSize"); try await settle(rebaseWindow.contentView!)
        precondition(progress.font?.pointSize == 22 && progress.string == "Rebase progress 雪")
        precondition(!message.isEditable && rebase.amendMessage == "Rebase draft 雪")
        print("PASS: actual hidden Log message pane and Rebase amend/progress views use shared source default and live configured fonts; draft/selection retained, read-only outputs and legacy output font preserved; no main app or rebase operation")
    }
}
