import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class FileComparisonNativeWindow: NSWindow {
    weak var model: FileComparisonWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "f" { model?.find(.showFindInterface); return true }
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            model?.find(flags.contains(.shift) ? .previousMatch : .nextMatch); return true
        }
        if event.keyCode == 96 { model?.load(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class FileComparisonWindowController: NSWindowController, NSWindowDelegate {
    let model: FileComparisonWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        model = FileComparisonWindowModel(repository: repository, access: access, snapshot: snapshot, path: path)
        let window = FileComparisonNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(path) – TurtleGitMerge"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 440)
        window.contentViewController = NSHostingController(rootView: FileComparisonDialog(model: model))
        super.init(window: window); window.model = model; window.delegate = self
        window.setFrameAutosaveName("TurtleGit.TwoFileDiff"); window.center()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class FileComparisonWindowModel: ObservableObject {
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    let snapshot: RevisionComparisonSnapshot
    let path: String
    @Published var document: FileComparisonDocument?
    @Published var alignment: FileComparisonAlignment?
    @Published var busy = false
    @Published var confirmingQuit = false
    @Published var error: String?
    @Published var difference = -1
    @Published var showLineNumbers = MergeEditorPreferences.load().showLineNumbers
    private var scrolls: [Bool: NSScrollView] = [:]
    private var synchronizing = false
    init(repository: GitRepository, access: RepositoryAccessLease?, snapshot: RevisionComparisonSnapshot, path: String) {
        self.repository = repository; self.access = access; self.snapshot = snapshot; self.path = path
    }
    func load() {
        guard !busy, !confirmingQuit else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let value = try await repository.comparisonFile(snapshot, path: path)
                document = value
                alignment = value.base.text.flatMap { base in value.destination.text.map { FileComparisonAlignment(base: base, destination: $0) } }
                difference = -1
            } catch { self.error = error.localizedDescription }
        }
    }
    func register(_ scroll: NSScrollView, base: Bool) { scrolls[base] = scroll }
    func scrolled(_ source: NSScrollView) {
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for target in scrolls.values where target !== source {
            var point = target.contentView.bounds.origin; point.y = source.contentView.bounds.origin.y
            target.contentView.scroll(to: target.contentView.constrainBoundsRect(NSRect(origin: point, size: target.contentView.bounds.size)).origin)
            target.reflectScrolledClipView(target.contentView)
        }
    }
    func navigate(_ step: Int) {
        guard let alignment, !alignment.differences.isEmpty else { return }
        difference = min(alignment.differences.count - 1, max(0, difference + step))
        let row = alignment.differences[difference].lowerBound
        for scroll in scrolls.values {
            guard let text = scroll.documentView as? NSTextView else { continue }
            let lines = text.string.components(separatedBy: "\n")
            let offset = lines.prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
            text.setSelectedRange(NSRange(location: min(offset, (text.string as NSString).length), length: 0))
            text.scrollRangeToVisible(text.selectedRange())
        }
    }
    func find(_ action: NSTextFinder.Action) {
        let text = scrolls.values.compactMap { $0.documentView as? NSTextView }.first { $0.window?.firstResponder === $0 }
            ?? (scrolls[false]?.documentView as? NSTextView)
        let item = NSMenuItem(); item.tag = action.rawValue; text?.performTextFinderAction(item)
    }
}
private struct FileComparisonDialog: View {
    @ObservedObject var model: FileComparisonWindowModel
    private func pane(base: Bool) -> some View {
        let content = base ? model.document?.base : model.document?.destination
        return VStack(alignment: .leading, spacing: 5) {
            Text(base ? "Base" : "Theirs").font(.headline)
            Text((content?.path ?? model.path) + " : " + (content?.revision.label ?? (base ? model.snapshot.from.label : model.snapshot.to.label))).font(.system(.caption, design: .monospaced)).lineLimit(1).help(content?.revision.label ?? "")
            if let alignment = model.alignment {
                FileComparisonEditor(model: model, cells: alignment.rows.map { base ? $0.base : $0.destination }, base: base)
            } else if let content {
                if let text = content.text { FileComparisonEditor(model: model, cells: FileComparisonAlignment(base: text, destination: text).rows.map(\.base), base: base) }
                else if let image = NSImage(data: content.bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ScrollView { Text("Binary or unsupported text encoding · \(content.bytes.count) bytes\n\n" + content.bytes.prefix(4096).enumerated().map { ($0.offset % 16 == 0 ? "\n" : " ") + String(format: "%02X", $0.element) }.joined()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
            } else { Color(nsColor: .textBackgroundColor) }
            Text("\(content?.mode ?? "Absent") · \(content?.bytes.count ?? 0) bytes").font(.caption).foregroundStyle(.secondary)
        }.padding(8).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.load() } label: { CommandLabel(title: "Reload", icon: .mergeReload) }
                Button { model.navigate(-1) } label: { CommandLabel(title: "Previous difference", icon: .mergePreviousConflict) }.disabled(model.difference <= 0)
                Button { model.navigate(1) } label: { CommandLabel(title: "Next difference", icon: .mergeNextConflict) }.disabled(model.alignment?.differences.isEmpty != false || model.difference >= (model.alignment?.differences.count ?? 0) - 1)
                Button { model.find(.showFindInterface) } label: { CommandLabel(title: "Find", icon: .mergeFind) }.disabled(model.alignment == nil)
                Spacer(); Toggle("Line numbers", isOn: $model.showLineNumbers).toggleStyle(.checkbox)
            }.padding(10).disabled(model.busy || model.confirmingQuit)
            Divider()
            HSplitView { pane(base: true); pane(base: false) }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.alignment.map { "\($0.differences.count) difference(s)" } ?? "").font(.caption)
                Spacer(); Text("Read-only comparison").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mergeEditorPreferencesChanged)) { _ in model.showLineNumbers = MergeEditorPreferences.load().showLineNumbers }
        .alert("Comparison failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
private struct FileComparisonEditor: NSViewRepresentable {
    @ObservedObject var model: FileComparisonWindowModel
    let cells: [MergeSourceCell]
    let base: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(); view.isEditable = false; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false; view.textContainer?.containerSize = view.maxSize
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.setAccessibilityLabel(base ? "Base file" : "Destination file")
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.findBarPosition = .belowContent
        scroll.hasVerticalRuler = true; scroll.verticalRulerView = MergeLineRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        model.register(scroll, base: base)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(MergeEditorPreferences.load().tabWidth) * (" " as NSString).size(withAttributes: [.font: view.font!]).width
        let value = NSMutableAttributedString(string: "")
        for cell in cells {
            value.append(NSAttributedString(string: cell.displayText + "\n", attributes: [.font: view.font!, .foregroundColor: NSColor.labelColor, .backgroundColor: MergePalette.color(cell.state), .paragraphStyle: paragraph]))
        }
        if !view.string.utf8.elementsEqual(value.string.utf8) { view.textStorage?.setAttributedString(value) }
        else { value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in view.textStorage?.setAttributes(attributes, range: range) } }
        scroll.rulersVisible = model.showLineNumbers
        (scroll.verticalRulerView as? MergeLineRuler)?.sourceNumbers = cells.map(\.lineNumber)
        scroll.verticalRulerView?.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject {
        let model: FileComparisonWindowModel
        weak var scroll: NSScrollView?
        init(model: FileComparisonWindowModel) { self.model = model }
        @objc func scrolled(_ notification: Notification) { if let scroll { model.scrolled(scroll) } }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
