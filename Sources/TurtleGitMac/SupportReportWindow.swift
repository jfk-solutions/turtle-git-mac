// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

@MainActor final class SupportReportService {
    static let shared = SupportReportService()
    private var controller: SupportReportWindowController?
    func show() {
        if let controller, !controller.model.retired { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        let bundle = Bundle.main
        let info = ApplicationAboutInformation(application: bundle.bundleURL, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let owner = SupportReportWindowController(systemInformation: info.versionText + "\nmacOS: " + ProcessInfo.processInfo.operatingSystemVersionString)
        controller = owner
        owner.onClosed = { [weak self, weak owner] in if self?.controller === owner { self?.controller = nil } }
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class SupportReportWindowModel: ObservableObject {
    static private(set) var activeReads = 0
    static private(set) var activeWrites = 0
    @Published var draft = SupportReportDraft() {
        didSet { if oldValue.includeCrashReport != draft.includeCrashReport || oldValue.replaceHomePath != draft.replaceHomePath { revision = UUID() }; rebuild() }
    }
    @Published private(set) var report: SupportCrashReport?
    @Published private(set) var preview = ""
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var reading = false { didSet { revision = UUID() } }
    @Published private(set) var writing = false { didSet { revision = UUID() } }
    @Published var picking = false { didSet { revision = UUID() } }
    @Published private var revision = UUID()
    private(set) var retired = false
    private var readToken: OperationCancellation?
    private var request = UUID()
    private let systemInformation: String, home: String
    var readFile: (URL, OperationCancellation) async throws -> SupportCrashReport = { url, token in try await Task.detached { try SupportCrashReport.read(url, cancellation: token) }.value }
    var writeFile: (Data, URL) async throws -> Void = { data, url in try await Task.detached { try data.write(to: url, options: .atomic) }.value }
    struct Context: Equatable { let owner: ObjectIdentifier; let revision: UUID }
    var context: Context { .init(owner: ObjectIdentifier(self), revision: revision) }
    var canEdit: Bool { !retired && !reading && !writing && !picking }
    init(systemInformation: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.systemInformation = systemInformation; self.home = home; rebuild() }
    func accepts(_ context: Context) -> Bool { canEdit && context == self.context }
    func field<Value>(_ key: WritableKeyPath<SupportReportDraft, Value>, context: Context) -> Binding<Value> {
        Binding(get: { self.draft[keyPath: key] }, set: { if self.accepts(context) { self.draft[keyPath: key] = $0 } })
    }
    private func rebuild() {
        guard !retired else { return }
        do { preview = try draft.render(systemInformation: systemInformation, report: report, home: home); error = nil }
        catch { preview = ""; self.error = error.localizedDescription }
    }
    func removeReport(context: Context) { guard accepts(context) else { return }; report = nil; draft.includeCrashReport = false; revision = UUID(); rebuild() }
    func load(_ url: URL, lease: RepositoryAccessLease?) {
        guard canEdit else { return }
        let token = OperationCancellation(), id = UUID(), read = readFile
        request = id; readToken = token; reading = true; error = nil; notice = nil; Self.activeReads += 1
        Task {
            defer { Self.activeReads -= 1; withExtendedLifetime(lease) {}; if request == id { reading = false; readToken = nil } }
            do {
                if GitRuntime.isAppStoreBuild && lease?.hasSecurityScope != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                let loaded = try await read(url, token); try token.check()
                guard !retired, request == id else { return }
                report = loaded; draft.includeCrashReport = false; revision = UUID(); rebuild()
            } catch { if !retired, request == id, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func save(_ data: Data, to url: URL, lease: RepositoryAccessLease?) {
        guard canEdit else { return }
        let write = writeFile; writing = true; error = nil; notice = nil; Self.activeWrites += 1
        Task {
            defer { Self.activeWrites -= 1; writing = false; withExtendedLifetime(lease) {} }
            do {
                if GitRuntime.isAppStoreBuild && lease?.hasSecurityScope != true { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await write(data, url)
                if !retired { notice = "Report saved." }
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func invalidate() { guard !retired else { return }; retired = true; revision = UUID(); readToken?.cancel() }
}

@MainActor final class SupportReportWindowController: NSWindowController, NSWindowDelegate {
    static private(set) var activePickers = 0
    let model: SupportReportWindowModel
    var onClosed: () -> Void = {}
    var clipboard: NSPasteboard = .general
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var presentOpen: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { $0.beginSheetModal(for: $1, completionHandler: $2) }
    var presentSave: (NSSavePanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { $0.beginSheetModal(for: $1, completionHandler: $2) }
    var panelURL: (NSSavePanel) -> URL? = { $0.url }
    private var panel: NSSavePanel?
    private var picker: UUID?
    private var closed = false
    init(systemInformation: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        model = SupportReportWindowModel(systemInformation: systemInformation, home: home)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 840, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Report a Problem – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let host = NSHostingController(rootView: SupportReportDialog(owner: self, model: model)); host.sizingOptions = []; window.contentViewController = host
        NSLayoutConstraint.activate([host.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 720), host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 650)])
        window.setContentSize(.init(width: 840, height: 740)); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func begin(_ panel: NSSavePanel, context: SupportReportWindowModel.Context) -> UUID? {
        guard model.accepts(context), let window, window.attachedSheet == nil else { return nil }
        let id = UUID(); self.panel = panel; picker = id; model.picking = true; Self.activePickers += 1; return id
    }
    private func finish(_ id: UUID) -> Bool {
        guard picker == id else { return false }; picker = nil; panel = nil; model.picking = false; Self.activePickers -= 1; return !closed && !model.retired
    }
    func importReport(context: SupportReportWindowModel.Context) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Select an Apple crash report"; panel.prompt = "Review Report"
        panel.allowedContentTypes = [UTType(filenameExtension: "ips"), UTType(filenameExtension: "crash")].compactMap { $0 }
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let id = begin(panel, context: context), let window else { return }
        presentOpen(panel, window) { [weak self] response in
            guard let self, self.finish(id), response == .OK, let url = self.panelURL(panel) else { return }
            self.model.load(url, lease: RepositoryAccessLease(url: url))
        }
    }
    func exportReport(context: SupportReportWindowModel.Context) {
        guard model.accepts(context), !model.preview.isEmpty else { return }
        let bytes = Data(model.preview.utf8), panel = NSSavePanel(); panel.title = "Save problem report"; panel.nameFieldStringValue = "TurtleGit-problem-report.txt"; panel.allowedContentTypes = [.plainText]
        guard let id = begin(panel, context: context), let window else { return }
        presentSave(panel, window) { [weak self] response in
            guard let self, self.finish(id), response == .OK, let url = self.panelURL(panel) else { return }
            self.model.save(bytes, to: url, lease: RepositoryAccessLease(url: url))
        }
    }
    func copyReport(context: SupportReportWindowModel.Context) { guard model.accepts(context), !model.preview.isEmpty else { return }; clipboard.clearContents(); clipboard.setString(model.preview, forType: .string) }
    func issueForm(context: SupportReportWindowModel.Context) { guard model.accepts(context) else { return }; openURL(URL(string: "https://github.com/jfk-solutions/turtle-git-mac/issues/new")!) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.writing && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; model.invalidate()
        let owned = panel; if let id = picker { _ = finish(id) }
        if let owned { owned.sheetParent?.endSheet(owned, returnCode: .cancel); owned.orderOut(nil) }
        openURL = { _ in }; let callback = onClosed; onClosed = {}; callback()
    }
}

private struct SupportReportDialog: View {
    weak var owner: SupportReportWindowController?
    @ObservedObject var model: SupportReportWindowModel
    var body: some View {
        let context = model.context
        VStack(alignment: .leading, spacing: 12) {
            Label("Report a Problem", systemImage: "exclamationmark.bubble.fill").font(.title2).foregroundStyle(.orange)
            Text("Describe what happened. You can select an Apple crash report to include in the report below.")
            Text("What happened / steps to reproduce:")
            TextEditor(text: model.field(\.details, context: context)).font(.body).frame(height: 100).border(Color.secondary.opacity(0.3)).disabled(!model.canEdit)
            HStack {
                Button("Choose Crash Report…") { owner?.importReport(context: context) }.disabled(!model.canEdit)
                if let report = model.report { Text(report.fileName + " — " + report.process).lineLimit(1).help(report.fileName); Button("Remove") { model.removeReport(context: context) }.disabled(!model.canEdit) }
                Spacer()
                if model.reading || model.writing { ProgressView().controlSize(.small) }
            }
            Toggle("Include the selected crash report", isOn: model.field(\.includeCrashReport, context: context)).disabled(!model.canEdit || model.report == nil)
            Toggle("Replace my home folder path with <HOME>", isOn: model.field(\.replaceHomePath, context: context)).disabled(!model.canEdit)
            Text("Review the exact report below before sharing. Other private details may remain. Copy and Save keep the report local; the issue form opens separately.").font(.caption).foregroundStyle(.secondary)
            SupportReportPreview(text: model.preview).frame(minHeight: 180, maxHeight: .infinity)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).foregroundStyle(.green) }
            HStack {
                Button("Copy Report") { owner?.copyReport(context: context) }.disabled(!model.canEdit || model.preview.isEmpty)
                Button("Save Report…") { owner?.exportReport(context: context) }.disabled(!model.canEdit || model.preview.isEmpty)
                Button("Open Issue Form") { owner?.issueForm(context: context) }.disabled(!model.canEdit)
                Spacer(); Button("Close") { owner?.close() }.keyboardShortcut(.cancelAction).disabled(model.writing || model.picking)
            }
        }.padding(20)
    }
}
private struct SupportReportPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular); view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = .init(width: 8, height: 8); view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Exact problem report")
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }; if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
    }
}
