// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of AutoTextTestDlg.cpp and IDD_AUTOTEXTTESTDLG.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AutotextTesterModel: ObservableObject {
    static let contentLimit = 200 * 1024
    private(set) static var activeRequests = 0
    @Published var content = "" { didSet {
        if content.utf16.count > Self.contentLimit {
            content = String(decoding: Array(content.utf16.prefix(Self.contentLimit)), as: UTF16.self)
        }
    } }
    @Published var pattern = ""
    @Published private(set) var result = ""
    @Published private(set) var timing = ""
    @Published private(set) var busy = false
    private var retired = false
    private var generation = UUID()
    private var cancellation: OperationCancellation?
    let preferences: UserDefaults
    let clipboard: NSPasteboard
    var matcher: (String, String, OperationCancellation) async throws -> [String]
    init(executable: URL? = nil, preferences: UserDefaults = .standard, clipboard: NSPasteboard = .general) {
        self.preferences = preferences; self.clipboard = clipboard
        matcher = { text, pattern, token in
            try await Task.detached {
                try MessageCodeSymbols.captures(in: text, pattern: pattern, executable: executable, cancellation: token)
            }.value
        }
    }
    func scan() {
        guard !retired, !busy else { return }
        result = ""; timing = ""
        guard !content.isEmpty, !pattern.isEmpty else { return }
        // CString conversion in the source stops the content at its first NUL.
        let text = String(content.prefix { $0 != "\0" }), expression = pattern
        let request = UUID(), token = OperationCancellation(), provider = matcher
        generation = request; cancellation = token; busy = true
        Self.activeRequests += 1
        Task {
            let started = DispatchTime.now().uptimeNanoseconds
            defer { Self.activeRequests -= 1; if generation == request { busy = false; cancellation = nil } }
            do {
                let words = try await provider(text, expression, token)
                guard !retired, generation == request, !token.isCancelled else { return }
                result = words.map { $0 + "\r\n" }.joined()
                timing = "Parse time: \((DispatchTime.now().uptimeNanoseconds - started) / 1000) uSecs"
            } catch {
                guard !retired, generation == request, !token.isCancelled else { return }
                result = "Regex is invalid!\r\n" + error.localizedDescription
            }
        }
    }
    func retire() {
        guard !retired else { return }; retired = true; generation = UUID()
        cancellation?.cancel(); cancellation = nil; busy = false
    }
}

@MainActor final class AutotextTesterController: NSWindowController, NSWindowDelegate {
    let model: AutotextTesterModel
    var onClosed: () -> Void = {}
    init(model: AutotextTesterModel? = nil) {
        let model = model ?? AutotextTesterModel(); self.model = model
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:660,height:640), styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "Autotext Tester – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width:660,height:640); window.contentMaxSize = window.contentMinSize
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView:AutotextTesterDialog(model:model,exit:{[weak self] in self?.close()}).frame(width:660,height:640))
        window.setContentSize(NSSize(width:660,height:640)); window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func close() { model.retire(); super.close() }
    func windowWillClose(_ notification:Notification) { model.retire(); let callback = onClosed; onClosed = {}; callback() }
}

private struct AutotextTesterDialog: View {
    @ObservedObject var model: AutotextTesterModel
    let exit: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Enter file content to test for below:")
            AutotextEditor(model:model,output:false).frame(height:255)
            Text("Enter the regex string below:")
            TextField("",text:$model.pattern).accessibilityLabel("Regex string").disabled(model.busy)
            HStack { Button("Scan",action:model.scan).keyboardShortcut(.defaultAction).disabled(model.busy); if model.busy { ProgressView().controlSize(.small) } }
            Text("Found auto words:")
            AutotextEditor(model:model,output:true).frame(minHeight:140,maxHeight:.infinity)
            HStack { Text(model.timing).font(.caption); Spacer(); Button("Exit",action:exit).keyboardShortcut(.cancelAction) }
        }.padding(16)
    }
}

struct AutotextEditor: NSViewRepresentable {
    @ObservedObject var model: AutotextTesterModel
    let output: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model:model) }
    func makeNSView(context:Context) -> NSScrollView {
        let editor = IssueRegexSampleTextView(frame:.zero)
        editor.clipboard = model.clipboard; editor.preferences = model.preferences
        editor.delegate = context.coordinator; editor.isRichText = false; editor.allowsUndo = !output
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = NSFont.monospacedSystemFont(ofSize:12,weight:.regular)
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(output ? "Found auto words" : "File content")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.updating = true; defer { context.coordinator.updating = false }
        let value = output ? model.result : model.content
        if editor.string != value { editor.string = value }
        editor.isEditable = !output && !model.busy; editor.isSelectable = true
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) { (scroll.documentView as? NSTextView)?.delegate = nil }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: AutotextTesterModel
        var updating = false
        init(model:AutotextTesterModel) { self.model = model }
        func textDidChange(_ notification:Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            model.content = editor.string
        }
        func textView(_ textView:NSTextView,shouldChangeTextIn range:NSRange,replacementString:String?) -> Bool {
            (textView.string as NSString).length - range.length + (replacementString?.utf16.count ?? 0) <= AutotextTesterModel.contentLimit
        }
    }
}

@MainActor final class AutotextTesterOwner: ObservableObject {
    private(set) var controller: AutotextTesterController?
    var create: (UserDefaults) -> AutotextTesterController = { AutotextTesterController(model: AutotextTesterModel(preferences: $0)) }
    var present: (AutotextTesterController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    func show(preferences: UserDefaults = .standard) {
        if let controller { present(controller); return }
        let controller = create(preferences); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        present(controller)
    }
    func close() { controller?.model.retire(); controller?.close(); controller = nil }
}
