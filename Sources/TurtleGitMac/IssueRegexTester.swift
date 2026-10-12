// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of BugtraqRegexTestDlg.cpp/.h and IDD_BUGTRAQREGEXTESTER.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class IssueRegexTesterModel: ObservableObject {
    private(set) static var activeRequests = 0
    static let sample = "Sample log message to test the bugtraq: regex strings.\n\nTesting mentions of issues inside a text: Mention single issue #55. Mention issues #77, #78, and #79. Mention more issues #123, #124 and #125 and some more separate ones: Issue #45, issue #46 and issue #47.\n\n\nUpdate issue #101\nFixes issue #202\nFixed issue #123\nResolves issue #88.\nCloses issue #99.\n"
    @Published var message = sample { didSet { if message != oldValue { ranges = []; schedule() } } }
    @Published var check: String { didSet { if check != oldValue { schedule() } } }
    @Published var extract: String { didSet { if extract != oldValue { schedule() } } }
    @Published private(set) var ranges: [NSRange] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private var active = false, retired = false
    private var generation = UUID()
    private var cancellation: OperationCancellation?
    private var task: Task<Void, Never>?
    private var lastValid: (String, String)?
    var matcher: (String, String, String, OperationCancellation) async throws -> IssueRegexMatch
    let preferences: UserDefaults
    let clipboard: NSPasteboard
    init(check: String = "", extract: String = "", executable: URL? = nil, preferences: UserDefaults = .standard, clipboard: NSPasteboard = .general) {
        self.check = check; self.extract = extract; self.preferences = preferences; self.clipboard = clipboard
        matcher = { message, check, extract, cancellation in
            try await Task.detached {
                try IssueRegexRuntime.match(message: message, check: check, extract: extract, executable: executable, cancellation: cancellation)
            }.value
        }
    }
    var canAccept: Bool { active && !retired }
    func activate() { guard !retired else { return }; active = true; schedule() }
    func retire() {
        guard !retired else { return }; retired = true; active = false; generation = UUID()
        cancellation?.cancel(); task?.cancel(); cancellation = nil; task = nil; busy = false
    }
    private func schedule() {
        guard active, !retired else { return }
        cancellation?.cancel(); task?.cancel()
        let request = UUID(), token = OperationCancellation(), provider = matcher, text = message
        let check = check.trimmingCharacters(in: .whitespacesAndNewlines), extract = extract.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = lastValid
        generation = request; cancellation = token; busy = true
        task = Task {
            do { try await Task.sleep(nanoseconds:150_000_000) } catch { return }
            guard live(request, token) else { return }
            Self.activeRequests += 1
            defer { Self.activeRequests -= 1; if generation == request { busy = false; cancellation = nil; task = nil } }
            do {
                // An empty message expression produces no issue runs, but the
                // second field still receives independent ECMAScript validation.
                let result = try await provider(check.isEmpty ? "" : text, check.isEmpty ? "(?:)" : check, extract, token)
                guard live(request, token) else { return }
                ranges = check.isEmpty ? [] : result.ranges; error = nil; lastValid = (check, extract)
            } catch {
                guard live(request, token) else { return }
                self.error = error.localizedDescription
                // Source keeps the last valid expressions when a regex edit is invalid.
                if let prior, !prior.0.isEmpty {
                    do {
                        let result = try await provider(text, prior.0, prior.1, token)
                        guard live(request, token) else { return }; ranges = result.ranges
                    } catch { if live(request, token) { ranges = [] } }
                } else { ranges = [] }
            }
        }
    }
    private func live(_ request: UUID, _ token: OperationCancellation) -> Bool { active && !retired && generation == request && !token.isCancelled }
}

@MainActor final class IssueRegexTesterController: NSWindowController, NSWindowDelegate {
    let model: IssueRegexTesterModel
    var completed: ((String, String)?) -> Void = { _ in }
    private var answered = false
    init(model: IssueRegexTesterModel? = nil) {
        let model = model ?? IssueRegexTesterModel(); self.model = model
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:420),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Bugtraq Regex Tester – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width:560,height:380)
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView:IssueRegexTesterDialog(model:model,accept:{[weak self] in self?.finish(accept:true)},cancel:{[weak self] in self?.finish(accept:false)}))
        DialogGeometry.attach(window,identifier:"BugtraqRegexTester"); window.center(); model.activate()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func finish(accept: Bool) {
        guard !answered, !accept || model.canAccept else { return }; answered = true
        let value = accept ? (model.check.trimmingCharacters(in:.whitespacesAndNewlines),model.extract.trimmingCharacters(in:.whitespacesAndNewlines)) : nil
        model.retire(); completed(value); window?.close()
    }
    func windowWillClose(_ notification:Notification) { if !answered { answered = true; model.retire(); completed(nil) } }
}

private struct IssueRegexTesterDialog: View {
    @ObservedObject var model: IssueRegexTesterModel
    let accept: () -> Void, cancel: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Sample text:")
            IssueRegexSampleEditor(model:model).frame(minHeight:150,maxHeight:.infinity)
            HStack { Text("Message part expression:").frame(width:170,alignment:.leading); TextField("",text:$model.check).accessibilityLabel("Message part expression") }
            HStack { Text("Bug-ID expression:").frame(width:170,alignment:.leading); TextField("",text:$model.extract).accessibilityLabel("Bug-ID expression") }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            Text("Testing expressions does not change repository settings.").font(.caption).foregroundStyle(.secondary)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button("OK",action:accept).keyboardShortcut(.defaultAction); Button("Cancel",action:cancel).keyboardShortcut(.cancelAction) }
        }.padding(16)
    }
}

struct IssueRegexSampleEditor: NSViewRepresentable {
    @ObservedObject var model: IssueRegexTesterModel
    func makeCoordinator()->Coordinator { Coordinator(model:model) }
    func makeNSView(context:Context)->NSScrollView {
        let editor=IssueRegexSampleTextView(frame:.zero)
        editor.clipboard=model.clipboard; editor.preferences=model.preferences; editor.delegate=context.coordinator
        editor.isEditable=true; editor.isSelectable=true; editor.isRichText=false; editor.allowsUndo=true
        editor.isAutomaticQuoteSubstitutionEnabled=false; editor.isAutomaticDashSubstitutionEnabled=false; editor.isAutomaticTextReplacementEnabled=false
        editor.font=MessageEditorFont.resolve(name:model.preferences.string(forKey:"LogFontName") ?? MessageEditorFont.defaultName,size:(model.preferences.object(forKey:"LogFontSize") as? Int) ?? MessageEditorFont.defaultSize)
        editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor; editor.textContainerInset=NSSize(width:10,height:10)
        editor.minSize = .zero; editor.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable=true; editor.isHorizontallyResizable=false; editor.autoresizingMask=[.width]
        editor.textContainer?.widthTracksTextView=true; editor.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Issue regex sample text")
        let scroll=NSScrollView();scroll.documentView=editor;scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;return scroll
    }
    func updateNSView(_ view:NSScrollView,context:Context) {
        guard let editor=view.documentView as? IssueRegexSampleTextView else {return}
        context.coordinator.model=model;context.coordinator.updating=true
        defer{context.coordinator.updating=false}
        if editor.string != model.message {editor.string=model.message}
        let selection=editor.selectedRanges,length=(editor.string as NSString).length
        editor.textStorage?.beginEditing()
        editor.textStorage?.setAttributes([.font:editor.font ?? NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.textColor],range:NSRange(location:0,length:length))
        for range in model.ranges where range.location>=0 && range.location<=length && range.length<=length-range.location {
            editor.textStorage?.addAttributes([.foregroundColor:NSColor.linkColor,.underlineStyle:NSUnderlineStyle.single.rawValue],range:range)
        }
        editor.textStorage?.endEditing();editor.selectedRanges=selection
        editor.typingAttributes=[.font:editor.font ?? NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.textColor]
    }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) {(view.documentView as? NSTextView)?.delegate=nil}
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        var model:IssueRegexTesterModel,updating=false
        init(model:IssueRegexTesterModel){self.model=model}
        func textDidChange(_ notification:Notification){guard !updating,let editor=notification.object as? NSTextView else{return};model.message=editor.string}
    }
}

@MainActor final class IssueRegexSampleTextView:NSTextView {
    var clipboard:NSPasteboard = .general
    var preferences:UserDefaults = .standard
    override func copy(_ sender:Any?){let text=string as NSString,range=selectedRange();guard range.length>0,range.location<=text.length,range.length<=text.length-range.location else{return};clipboard.clearContents();clipboard.setString(text.substring(with:range),forType:.string)}
    override func cut(_ sender:Any?){guard selectedRange().length>0 else{return};copy(sender);insertText("",replacementRange:selectedRange())}
    override func paste(_ sender:Any?){guard let text=clipboard.string(forType:.string) else{return};insertText(text,replacementRange:selectedRange())}
    override func menu(for event:NSEvent)->NSMenu? {sampleMenu()}
    func sampleMenu()->NSMenu {
        let menu=NSMenu();menu.autoenablesItems=false
        let icons=MenuPresentationSettings.applicationContextIcons(defaults:preferences)
        for (title,action,enabled,icon) in [("Cut",#selector(cut(_:)),selectedRange().length>0,NSImage(systemSymbolName:"scissors",accessibilityDescription:nil)),("Copy",#selector(copy(_:)),selectedRange().length>0,MenuIcon.copy.image()),("Paste",#selector(paste(_:)),clipboard.string(forType:.string) != nil,NSImage(systemSymbolName:"doc.on.clipboard",accessibilityDescription:nil)),("Select All",#selector(selectAll(_:)),!string.isEmpty,NSImage(systemSymbolName:"selection.pin.in.out",accessibilityDescription:nil))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.isEnabled=enabled;item.image=icons ? icon:nil;menu.addItem(item)
        }
        return menu
    }
}
