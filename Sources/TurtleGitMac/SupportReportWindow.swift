// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore
import Darwin

@MainActor final class SupportReportService {
    static let shared = SupportReportService()
    static private(set) var activeScans = 0
    private(set) var controller: SupportReportWindowController?
    private(set) var recoveryNotice: SupportCrashRecoveryWindowController?
    private let preferences: UserDefaults, directory: URL
    private let processName: String, bundleIdentifier: String
    private var checked = false, retired = false
    private var presentations=0
    var hasOwnedUtilityWindow:Bool {!retired && (presentations>0 || controller?.utilityOwnerActive==true || recoveryNotice?.utilityOwnerActive==true)}
    func presentExistingUtility()->Bool {
        guard hasOwnedUtilityWindow else{return false}
        // A synchronous presentation/factory already owns its window handoff.
        // A reentrant reopen retains that handoff instead of presenting twice.
        guard presentations==0 else{return true}
        presentations += 1;defer{presentations -= 1}
        // Reopen retains the accepted factory/presentation; it never starts a
        // diagnostic scan, imports another incident or constructs a new owner.
        if let controller,controller.utilityOwnerActive {
            if controller.window?.isMiniaturized==true {controller.window?.deminiaturize(nil)}
            presentReport(controller)
        } else if let recoveryNotice,recoveryNotice.utilityOwnerActive {
            if recoveryNotice.window?.isMiniaturized==true {recoveryNotice.window?.deminiaturize(nil)}
            presentNotice(recoveryNotice)
        }
        return true
    }
    var createReport:(String,UserDefaults)->SupportReportWindowController = {SupportReportWindowController(systemInformation:$0,preferences:$1)}
    var createNotice:(SupportCrashIncident)->SupportCrashRecoveryWindowController = {SupportCrashRecoveryWindowController(incident:$0)}
    private var token: OperationCancellation?
    var discover: @Sendable (URL, String, String, Set<String>, OperationCancellation) async throws -> SupportCrashIncident? = { directory,process,bundle,handled,token in
        try await Task.detached { try SupportCrashDiscovery.latest(in:directory,process:process,bundleIdentifier:bundle,excluding:handled,cancellation:token) }.value
    }
    var presentNotice: (SupportCrashRecoveryWindowController) -> Void = { $0.showWindow(nil); $0.window?.orderFront(nil) }
    var presentReport: (SupportReportWindowController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    init(preferences: UserDefaults = .standard, reportsDirectory: URL? = nil, processName: String? = nil, bundleIdentifier: String? = nil) {
        self.preferences = preferences
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString:$0) } ?? NSHomeDirectory()
        directory = reportsDirectory ?? URL(fileURLWithPath:home).appendingPathComponent("Library/Logs/DiagnosticReports",isDirectory:true)
        self.processName = processName ?? Bundle.main.executableURL?.lastPathComponent ?? ""
        self.bundleIdentifier = bundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
    }
    @discardableResult func show(recovered report: SupportCrashReport? = nil) -> Bool {
        guard !retired else { return false }
        presentations += 1;defer{presentations -= 1}
        if let controller, !controller.model.retired {
            if let report, !controller.model.installRecoveredReport(report) { presentReport(controller); return false }
            presentReport(controller); return true
        }
        let bundle = Bundle.main
        let info = ApplicationAboutInformation(application: bundle.bundleURL, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let owner = createReport(info.versionText + "\nmacOS: " + ProcessInfo.processInfo.operatingSystemVersionString,preferences)
        controller = owner
        owner.onClosed = { [weak self, weak owner] in if self?.controller === owner { self?.controller = nil } }
        if let report { _ = owner.model.installRecoveredReport(report) }
        presentReport(owner); return true
    }
    func checkForPreviousCrash() {
        guard !retired, !checked else { return }; checked = true
        guard SupportCrashRecoveryPreferences.enabled(in:preferences), !processName.isEmpty, !bundleIdentifier.isEmpty else { return }
        let token = OperationCancellation(), discover = discover, directory = directory, process = processName, bundle = bundleIdentifier
        let handled = SupportCrashRecoveryPreferences.handled(in:preferences)
        self.token = token; Self.activeScans += 1
        Task { [weak self] in
            defer { Self.activeScans -= 1; if self?.token === token { self?.token = nil } }
            do {
                let incident = try await discover(directory,process,bundle,handled,token)
                guard let self, !self.retired, !token.isCancelled, self.token === token,
                      SupportCrashRecoveryPreferences.enabled(in:self.preferences), let incident,
                      !SupportCrashRecoveryPreferences.handled(in:self.preferences).contains(incident.id) else { return }
                self.showRecoveryNotice(incident)
            } catch { /* Unavailable or denied diagnostics retain the ordinary manual import route. */ }
        }
    }
    private func showRecoveryNotice(_ incident:SupportCrashIncident) {
        guard !retired else{return}
        presentations += 1;defer{presentations -= 1}
        let notice=createNotice(incident);recoveryNotice=notice
        notice.onReview = { [weak self,weak notice] in
            guard let self,let notice,!self.retired,self.recoveryNotice === notice,self.show(recovered:incident.report) else{return false}
            SupportCrashRecoveryPreferences.acknowledge(incident,in:self.preferences);return true
        }
        notice.onDismiss = { [weak self,weak notice] in
            guard let self,let notice,!self.retired,self.recoveryNotice === notice else{return}
            SupportCrashRecoveryPreferences.acknowledge(incident,in:self.preferences)
        }
        notice.onClosed = { [weak self,weak notice] in if self?.recoveryNotice === notice {self?.recoveryNotice=nil} }
        presentNotice(notice)
    }
    func retire() {
        guard !retired else { return }; retired = true; token?.cancel()
        recoveryNotice?.onDismiss = {}; recoveryNotice?.onReview = { false }; recoveryNotice?.close(); recoveryNotice = nil
        controller?.close(); controller = nil
    }
}

@MainActor final class SupportCrashRecoveryModel: ObservableObject {
    let incident: SupportCrashIncident
    @Published var notice: String?
    init(incident:SupportCrashIncident) { self.incident = incident }
}
@MainActor final class SupportCrashRecoveryWindowController: NSWindowController, NSWindowDelegate {
    let model: SupportCrashRecoveryModel
    var onReview: () -> Bool = { false }
    var onDismiss: () -> Void = {}
    var onClosed: () -> Void = {}
    private var handled = false,closed=false
    var utilityOwnerActive:Bool {!closed && window != nil}
    init(incident: SupportCrashIncident) {
        model = SupportCrashRecoveryModel(incident:incident)
        let window = NSWindow(contentRect:.init(x:0,y:0,width:540,height:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Crash Report – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self;TurtleGitHelp.attach(window,topic:.reportProblem)
        let host = NSHostingController(rootView:SupportCrashRecoveryDialog(owner:self)); host.sizingOptions = []
        window.contentViewController = host; window.setContentSize(.init(width:540,height:320)); window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func review() {
        guard !handled else { return }
        guard onReview() else { model.notice = "Finish the current problem-report operation, then try again."; return }
        handled = true; close()
    }
    func dismiss() { guard !handled else { return }; handled = true; onDismiss(); close() }
    func windowWillClose(_ notification:Notification) {guard !closed else{return};closed=true;if !handled {handled=true;onDismiss()};let callback=onClosed;onClosed={};callback()}
}
private struct SupportCrashRecoveryDialog: View {
    private weak var owner: SupportCrashRecoveryWindowController?
    @ObservedObject private var state: SupportCrashRecoveryModel
    init(owner:SupportCrashRecoveryWindowController) { self.owner = owner; state = owner.model }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("TurtleGit stopped unexpectedly",systemImage:"exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text("An Apple crash report is available. You can review it and describe what happened before choosing what to share.")
            Text(state.incident.report.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(state.incident.report.fileName)
            Text("The report stays local. It is excluded from the problem report until you select Include.").font(.caption)
            SupportReportFeedbackBand(messages:state.notice.map{[$0]} ?? [],active:false,isError:state.notice != nil,identifier:"support-recovery-feedback")
            Spacer(minLength:0)
            HStack { Button("Help") {TurtleGitHelp.show(.reportProblem)}.accessibilityIdentifier("support-recovery-help");Spacer(); Button("Dismiss") { owner?.dismiss() }.keyboardShortcut(.cancelAction); Button("Review Report…") { owner?.review() }.keyboardShortcut(.defaultAction) }
        }.padding(16)
    }
}

@MainActor final class SupportReportWindowModel: ObservableObject {
    static private(set) var activeReads = 0
    static private(set) var activeWrites = 0
    @Published var draft = SupportReportDraft() {
        didSet { if oldValue.includeCrashReport != draft.includeCrashReport || oldValue.replaceHomePath != draft.replaceHomePath { revision = UUID() }; rebuild() }
    }
    @Published private(set) var checkCrashReportsAtLaunch: Bool
    private let recoveryPreferences: UserDefaults
    @Published private(set) var report: SupportCrashReport?
    @Published private(set) var preview = ""
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var reading = false { didSet { revision = UUID() } }
    @Published private(set) var readCancelling=false
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
    struct ReadContext:Equatable {let owner:ObjectIdentifier;let request:UUID}
    var readContext:ReadContext {.init(owner:ObjectIdentifier(self),request:request)}
    var canCancelRead:Bool {!retired && reading && !readCancelling && readToken?.isCancelled==false}
    func cancelRead(context:ReadContext) {
        guard canCancelRead,context==readContext else{return}
        readCancelling=true;readToken?.cancel()
    }
    var feedbackMessages:[String] {
        var messages=[String]()
        if reading {messages.append(readCancelling ? NSLocalizedString("Cancelling crash-report import…",comment:""):NSLocalizedString("Loading Apple crash report…",comment:""))}
        if writing {messages.append(NSLocalizedString("Saving problem report…",comment:""))}
        if picking {messages.append(NSLocalizedString("Choosing a file…",comment:""))}
        if let error {messages.append(error)}
        if let notice {messages.append(notice)}
        return messages
    }
    var canEdit: Bool { !retired && !reading && !writing && !picking }
    init(systemInformation: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path, preferences: UserDefaults = .standard) {
        self.systemInformation = systemInformation; self.home = home; recoveryPreferences = preferences
        checkCrashReportsAtLaunch = SupportCrashRecoveryPreferences.enabled(in:preferences); rebuild()
    }
    func setCrashChecking(_ enabled: Bool, context: Context) {
        guard accepts(context) else { return }; checkCrashReportsAtLaunch = enabled; revision = UUID()
        recoveryPreferences.set(enabled,forKey:SupportCrashRecoveryPreferences.enabledKey)
    }
    @discardableResult func installRecoveredReport(_ report: SupportCrashReport) -> Bool {
        guard canEdit else { return false }
        self.report = report; draft.includeCrashReport = false; notice = "Recovered Apple crash report. Review it before including it."; revision = UUID(); rebuild(); return true
    }
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
        request = id; readToken = token; readCancelling=false;reading = true; error = nil; notice = nil; Self.activeReads += 1
        Task {
            defer {
                Self.activeReads -= 1;withExtendedLifetime(lease) {}
                if request==id {
                    reading=false;readToken=nil;readCancelling=false
                    if !retired,token.isCancelled {notice=NSLocalizedString("Crash-report import cancelled.",comment:"")}
                }
            }
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
    var utilityOwnerActive:Bool {!closed && !model.retired && window != nil}
    init(systemInformation: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path, preferences: UserDefaults = .standard) {
        model = SupportReportWindowModel(systemInformation: systemInformation, home: home, preferences:preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 840, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Report a Problem – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self;TurtleGitHelp.attach(window,topic:.reportProblem)
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
        let context = model.context,readContext=model.readContext
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing:12) {
                Label("Report a Problem",systemImage:"exclamationmark.bubble.fill").font(.title2).foregroundStyle(.orange).fixedSize()
                SupportReportFeedbackBand(messages:model.feedbackMessages,active:model.reading || model.writing,isError:model.error != nil,identifier:"support-report-feedback",cancelEnabled:model.canCancelRead,cancelVisible:model.reading,cancel:{model.cancelRead(context:readContext)})
            }.frame(height:24)
            Text("Describe what happened. You can select an Apple crash report to include in the report below.")
            Text("What happened / steps to reproduce:")
            TextEditor(text: model.field(\.details, context: context)).accessibilityLabel("Problem description").accessibilityIdentifier("support-report-description").font(.body).frame(height: 100).border(Color.secondary.opacity(0.3)).disabled(!model.canEdit)
            HStack {
                Button("Choose Crash Report…") { owner?.importReport(context: context) }.disabled(!model.canEdit)
                Text(model.report.map{$0.fileName+" — "+$0.process} ?? " ").lineLimit(1).truncationMode(.middle).help(model.report?.fileName ?? "").frame(maxWidth:.infinity,alignment:.leading)
                Button("Remove") {model.removeReport(context:context)}.disabled(!model.canEdit || model.report==nil).opacity(model.report==nil ? 0:1).accessibilityHidden(model.report==nil)
            }.frame(height:28).accessibilityIdentifier("support-report-import-controls")
            Toggle("Check for crash reports at launch", isOn: Binding(get:{ model.checkCrashReportsAtLaunch },set:{ model.setCrashChecking($0,context:context) })).disabled(!model.canEdit)
            Toggle("Include the selected crash report", isOn: model.field(\.includeCrashReport, context: context)).disabled(!model.canEdit || model.report == nil)
            Toggle("Replace my home folder path with <HOME>", isOn: model.field(\.replaceHomePath, context: context)).disabled(!model.canEdit)
            Text("Review the exact report below before sharing. Other private details may remain. Copy and Save keep the report local; the issue form opens separately.").font(.caption).foregroundStyle(.secondary)
            SupportReportPreview(text: model.preview).frame(minHeight: 180, maxHeight: .infinity)
            HStack {
                Button("Copy Report") { owner?.copyReport(context: context) }.disabled(!model.canEdit || model.preview.isEmpty)
                Button("Save Report…") { owner?.exportReport(context: context) }.disabled(!model.canEdit || model.preview.isEmpty)
                Button("Open Issue Form") { owner?.issueForm(context: context) }.disabled(!model.canEdit)
                Button("Help") {TurtleGitHelp.show(.reportProblem)}.accessibilityIdentifier("support-report-help")
                Spacer(); Button("Close") { owner?.close() }.keyboardShortcut(.cancelAction).disabled(model.writing || model.picking)
            }
        }.padding(20)
    }
}
private struct SupportReportFeedbackBand:View {
    let messages:[String],active:Bool,isError:Bool,identifier:String
    var cancelEnabled=false,cancelVisible=false
    var cancel:(()->Void)?=nil
    @State private var showingDetails=false
    var body:some View {
        let details=messages.joined(separator:"\n"),summary=messages.flatMap{$0.components(separatedBy:.newlines)}.filter{!$0.isEmpty}.joined(separator:" · ")
        HStack(spacing:6) {
            ProgressView().controlSize(.small).frame(width:18,height:18).opacity(active ? 1:0).accessibilityHidden(!active).allowsHitTesting(false)
            Button {showingDetails=true} label: {
                HStack(spacing:4) {
                    Text(summary.isEmpty ? " ":summary).font(.caption).lineLimit(1).truncationMode(.tail)
                    Image(systemName:"chevron.down").font(.caption2).opacity(details.isEmpty ? 0:1)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.buttonStyle(.plain).foregroundStyle(isError ? Color.red:Color.secondary)
                .disabled(details.isEmpty).opacity(details.isEmpty ? 0:1).accessibilityHidden(details.isEmpty)
                .accessibilityLabel("Problem report status").accessibilityValue(details).help(details)
                .popover(isPresented:$showingDetails) {
                    ScrollView {Text(details).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12)}.frame(width:480,height:180)
                }
            if let cancel {
                Button("Cancel reading",action:cancel).controlSize(.small).disabled(!cancelEnabled).opacity(cancelVisible ? 1:0).accessibilityHidden(!cancelVisible)
            }
        }.frame(maxWidth:.infinity,minHeight:24,maxHeight:24).accessibilityIdentifier(identifier)
    }
}
private struct SupportReportPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular); view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = .init(width: 8, height: 8); view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Exact problem report");view.identifier = .init("support-report-preview-text")
        let scroll = NSScrollView();scroll.identifier = .init("support-report-preview"); scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }; if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
    }
}
