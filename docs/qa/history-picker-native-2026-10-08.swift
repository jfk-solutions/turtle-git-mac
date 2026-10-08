import AppKit
import SwiftUI
import TurtleGitCore

@main struct HistoryPickerVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let result = table(in: child) { return result } }
        return nil
    }
    @MainActor static func verify(_ history: any MessageHistory, expected: [String]) async throws {
        let model = MessageHistoryPickerModel(history: history)
        let host = NSHostingView(rootView: CommitMessageHistoryDialog(model: model) { _ in })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await settle(host)
        let list = table(in: host)!
        precondition(list.numberOfRows == expected.count && window.firstResponder === list)
        list.selectRowIndexes([1], byExtendingSelection: false); try await settle(host)
        precondition(model.selection == [1] && list.selectedRowIndexes == [1])
        precondition(Array(model.selectedMessage.utf16) == Array(expected[1].utf16))
        model.selection = [0, 2]; try await settle(host)
        precondition(list.selectedRowIndexes == [0, 2])
        precondition(Array(model.selectedMessage.utf16) == Array((expected[0] + "\n\n" + expected[2]).utf16))
        model.deleteRow(0); try await settle(host)
        precondition(list.numberOfRows == 2 && list.selectedRowIndexes == [0])
        precondition(Array(model.selectedMessage.utf16) == Array(expected[1].utf16))
        model.deleteRow(99); precondition(model.entries.count == 2)
        model.deleteRow(1); try await settle(host); precondition(list.selectedRowIndexes == [0])
        model.deleteRow(0); try await settle(host)
        precondition(list.numberOfRows == 0 && model.selection.isEmpty && model.selectedMessage.isEmpty && history.entries.isEmpty)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.HistoryPicker.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let merge = MergeMessageHistory(defaults: prefs)
        for text in ["tail\nbody", "é", "e\u{301}"] { merge.add(text) }
        precondition(merge.entries.count == 3)
        try await verify(merge, expected: merge.entries)
        let commit = CommitMessageHistory(repositoryIdentity: "fixture", defaults: prefs)
        for text in ["third\nbody", "second", "first"] { commit.add(text) }
        try await verify(commit, expected: commit.entries)
        DialogGeometry.install(preferences: prefs)
        let store = WindowGeometryStore(preferences: prefs)
        let first = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; first.minSize = .init(width: 400, height: 260)
        DialogGeometry.attach(first, identifier: "HistoryDlg")
        first.setFrame(.init(x: 40, y: 90, width: 780, height: 420), display: false); first.close()
        precondition(store.load("HistoryDlg")?.width == 780)
        let next = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        next.isReleasedWhenClosed = false; next.minSize = .init(width: 400, height: 260)
        DialogGeometry.attach(next, identifier: "HistoryDlg")
        if !NSScreen.screens.isEmpty { precondition(next.frame.width == min(780, next.screen!.visibleFrame.width)) }
        next.close(); SavedDataStore(preferences: prefs).clear(.dialogGeometry); precondition(store.load("HistoryDlg") == nil)
        print("PASS: real hidden Merge and Commit history tables retain separate Unicode rows, initial focus, one/multiple selection and exact source-order joined messages, persisted single-row deletion and next-row selection through empty, invalid-index guard; shared HistoryDlg geometry close/reopen and reset; no main app or synthetic input")
    }
}
