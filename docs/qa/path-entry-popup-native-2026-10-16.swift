import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class PathDraft: ObservableObject {
    @Published var text = "choice"
    var submissions = 0
}
private struct PopupFixtureView: View {
    @ObservedObject var draft: PathDraft
    let root: URL
    var body: some View {
        VStack {
            PathEntryField(text: $draft.text, label: "Fixture path", base: root)
            Button("Continue") { draft.submissions += 1 }.keyboardShortcut(.defaultAction)
        }.padding().frame(width: 480, height: 100)
    }
}
@main struct PathEntryPopupVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Popup timeout at \(line)")
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 520, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Task { @MainActor in
            do { try await verify(window); window.close(); fflush(stdout); exit(0) }
            catch { window.close(); fputs("Path popup failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func verify(_ window: NSWindow) async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for name in ["choice one.patch", "choice two.patch"] { try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name)) }
        let draft = PathDraft()
        window.contentView = NSHostingView(rootView: PopupFixtureView(draft: draft, root: root))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var field: PathEntryField.Field?
        try await wait { field = descendants(window.contentView).compactMap { $0 as? PathEntryField.Field }.first; return field != nil && window.isKeyWindow }
        let control = field!, coordinator = control.coordinator!
        for (key, chars, cancel) in [(UInt16(36), "\r", false), (UInt16(53), "\u{1b}", true), (UInt16(48), "\t", false)] {
            draft.text = "choice"
            try await wait { control.stringValue == "choice" }
            window.makeFirstResponder(control)
            guard let editor = control.currentEditor() as? PathEntryField.Editor else { throw Failure(description: "Actual field editor missing") }
            editor.setSelectedRange(NSRange(location: 6, length: 0)); editor.undoManager?.removeAllActions(); editor.breakUndoCoalescing()
            // Load filesystem results without replacing Cocoa's completion-list implementation.
            coordinator.present = { _ in }
            coordinator.request(explicit: true)
            try await wait { coordinator.choices.count == 2 && PathEntryField.Coordinator.activeReads == 0 }
            var phase = 0, selected: String?, failure: String?
            let deadline = Date().addingTimeInterval(8)
            func post(_ code: UInt16, _ text: String) {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) { NSApp.postEvent(event, atStart: false) }
            }
            let timer = Timer(timeInterval: 0.08, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if Date() > deadline { failure = "Actual Cocoa completion list did not settle (phase \(phase)); key=\(window.isKeyWindow), editorKey=\(editor.window?.isKeyWindow == true), windows=\(NSApp.windows.map { String(describing: type(of: $0)) + ":\($0.isVisible):" + descendants($0.contentView).map { String(describing: type(of: $0)) }.joined(separator: ",") })"; window.makeFirstResponder(nil); timer.invalidate(); return }
                    let table = NSApp.windows.filter { $0 !== window && $0.isVisible }.flatMap { descendants($0.contentView) }.compactMap { $0 as? NSTableView }.first { $0.numberOfRows >= 2 }
                    if phase == 0, table != nil { phase = 1; post(125, "\u{f701}") }
                    else if phase == 1, let table, table.selectedRow >= 0 {
                        let row = table.selectedRow
                        guard row < coordinator.choices.count else { failure = "Completion row outside source results"; timer.invalidate(); return }
                        selected = coordinator.choices[row]; phase = 2; post(key, chars)
                    } else if phase == 2, table == nil { phase = 3; timer.invalidate() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            editor.complete(nil)
            try await wait { phase == 3 || failure != nil }
            timer.invalidate()
            if let failure { throw Failure(description: failure) }
            guard let selected else { throw Failure(description: "Completion list never selected a result") }
            let expected = cancel ? "choice" : selected
            try await wait { draft.text == expected && editor.string == expected }
            guard draft.submissions == 0 else { throw Failure(description: "Completion key submitted the dialog") }
            if !cancel {
                editor.breakUndoCoalescing()
                guard editor.undoManager?.canUndo == true else { throw Failure(description: "Popup selection has no Undo") }
                editor.undoManager?.undo(); try await wait { draft.text == "choice" }
                editor.undoManager?.redo(); try await wait { draft.text == selected }
            }
            window.makeFirstResponder(nil)
            try await wait { PathEntryField.Coordinator.activeReads == 0 }
        }
        print("PASS: actual Cocoa completion list handles Down/Return, Down/Escape, Down/Tab without default-button submission, with native Undo/Redo")
    }
}
