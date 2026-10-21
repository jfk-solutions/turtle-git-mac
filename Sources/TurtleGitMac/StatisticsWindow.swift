import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StatisticsWindowModel: ObservableObject {
    static var activeOperations = 0
    private(set) var pendingOperations=0
    var hasPendingWork:Bool {pendingOperations>0}
    @Published var confirmingQuit=false {didSet {if oldValue != confirmingQuit {formRevision=UUID();generation=UUID();if confirmingQuit {cancel();retireIntents()}}}}
    var retireIntents:()->Void={}
    var presentationAvailable:()->Bool={NSApp.modalWindow==nil}
    let repository: GitRepository
    let entries: [LogEntry]
    private let access: RepositoryAccessLease?
    private let defaults: UserDefaults
    private var changes: [String: LogStatisticsChanges]?
    private var cancellation: OperationCancellation?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private(set) var retired = false
    @Published var hasSheet = false {didSet {if oldValue != hasSheet {formRevision=UUID()}}}
    @Published var exporting = false {didSet {if oldValue != exporting {formRevision=UUID()}}}
    @Published private(set) var formRevision = UUID()
    var becameIdle: () -> Void = {}
    @Published var options = LogStatisticsOptions()
    @Published var metric = LogStatisticsMetric.statistics
    @Published var style = LogStatisticsStyle.line
    @Published var authorsShown = 1.0
    @Published var summary: LogStatisticsSummary?
    @Published var graph: LogStatisticsGraph?
    @Published var busy = false {didSet {if oldValue != busy {formRevision=UUID()}}}
    @Published var completed = 0
    @Published var error: String?
    var close: () -> Void = {}
    var graphSize = CGSize(width: 860, height: 400)
    var canInteract: Bool { !retired && !busy && !hasSheet && !exporting && !confirmingQuit && presentationAvailable() }
    var canCancelCalculation:Bool {!retired && busy && !hasSheet && !exporting && !confirmingQuit && cancellation?.isCancelled==false && presentationAvailable()}
    func cancel(context:UUID) {guard context==formRevision,canCancelCalculation else{return};cancel();formRevision=UUID()}
    func close(context:UUID) {guard context==formRevision,!retired,!confirmingQuit,!hasSheet,!exporting,presentationAvailable() else{return};close()}
    var showsGraphControls: Bool { metric != .statistics }
    var canExportGraph: Bool { canInteract && metric != .statistics && graph != nil }
    func supports(_ style: LogStatisticsStyle) -> Bool { !metric.byAuthor || ![.line, .stackedLine].contains(style) }
    func selectStyle(_ style: LogStatisticsStyle, context: UUID? = nil) { guard accepts(context), supports(style) else { return }; self.style = style; formRevision = UUID() }
    func setOptions(_ options: LogStatisticsOptions, context: UUID? = nil) { guard accepts(context) else { return }; self.options = options; rebuild(resetAuthors: true) }
    func setAuthorLimit(_ value: Double, context: UUID? = nil) {
        guard accepts(context), value.isFinite else { return }
        authorsShown = min(Double(max(1, min(250, availableAuthorCount))), max(1, value.rounded(.towardZero))); rebuild()
    }
    func accepts(_ context: UUID?) -> Bool { canInteract && (context == nil || context == formRevision) }
    var authorSliderHint: String { summary?.authorSliderHint(limit: Int(authorsShown), metric: metric) ?? "" }
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], defaults: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.entries = entries; self.defaults = defaults
        options.caseSensitive = defaults.object(forKey: "StatAuthorsCaseSensitive") == nil || defaults.bool(forKey: "StatAuthorsCaseSensitive")
        options.sortByCommitCount = defaults.object(forKey: "StatSortByCommitCount") == nil || defaults.bool(forKey: "StatSortByCommitCount")
        options.useCommitterNames = defaults.bool(forKey: "StatCommiterNames")
        options.useCommitDates = defaults.object(forKey: "StatCommitDates") == nil || defaults.bool(forKey: "StatCommitDates")
        let page = defaults.integer(forKey: "LastViewedStatsPage")
        metric = LogStatisticsMetric(rawValue: page / 10) ?? .statistics
        style = LogStatisticsStyle(rawValue: page % 10) ?? (metric.byAuthor ? .bar : .line)
        if !supports(style) { style = .bar }
        rebuild(resetAuthors: true)
    }
    var availableAuthorCount: Int {
        guard let summary else { return 0 }
        return summary.rankedAuthors(for: metric).count
    }
    func start() { if metric.needsChanges { calculate() } }
    func selectMetric(_ metric: LogStatisticsMetric, context: UUID? = nil) {
        guard accepts(context) else { return }; self.metric = metric
        if metric.byAuthor { style = .bar } else if metric == .statistics || metric == .commitsByDate { style = .line }
        rebuild(resetAuthors: true); if metric.needsChanges && changes == nil { calculate() }
    }
    func rebuild(resetAuthors: Bool = false) {
        guard !retired else { return }
        formRevision = UUID()
        do {
            summary = try LogStatistics.analyze(entries, options: options, changes: changes)
            if resetAuthors { authorsShown = Double(min(250, max(1, availableAuthorCount))) }
            authorsShown = min(authorsShown, Double(min(250, max(1, availableAuthorCount))))
            if metric == .statistics || metric.needsChanges && changes == nil { graph = nil }
            else { graph = try LogStatisticsGraph.make(summary!, metric: metric, authorsShown: Int(authorsShown), alphabetical: !options.sortByCommitCount) }
            error = nil
        } catch { self.error = error.localizedDescription; graph = nil }
    }
    func calculate(context: UUID? = nil) {
        guard accepts(context), changes == nil else { return }; formRevision = UUID(); busy = true; completed = 0; error = nil
        let token = OperationCancellation(), request = UUID()
        cancellation = token; generation = request; Self.activeOperations += 1;pendingOperations += 1
        let capturedRepository=repository.capturingDiffBackend(preferences:defaults)
        worker = Task { [self, access] in
            defer {
                Self.activeOperations -= 1;pendingOperations -= 1
                if cancellation === token {
                    busy = false; cancellation = nil; worker = nil
                    if !retired { becameIdle() }
                }
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (stream, continuation) = AsyncStream<Int>.makeStream()
                let operation = Task { [capturedRepository, entries] in
                    defer { continuation.finish() }
                    return try await capturedRepository.logStatisticsChanges(entries, cancellation: token) { done, _ in continuation.yield(done) }
                }
                for await done in stream {
                    if !retired,!confirmingQuit,request == generation,!token.isCancelled {completed=done}
                }
                let result = try await operation.value
                try token.check()
                guard !retired,!confirmingQuit,request == generation else {return}
                changes = result; rebuild(resetAuthors: true)
            } catch {
                if !retired,!confirmingQuit,request == generation,!token.isCancelled {self.error=error.localizedDescription}
            }
        }
    }
    func cancel() { cancellation?.cancel() }
    func retire() {
        guard !retired else { return }
        retired = true; formRevision = UUID(); generation = UUID(); cancel(); retireIntents(); becameIdle = {}; close = {};presentationAvailable={false}
    }
    func savePreferences() {
        guard !retired else { return }
        defaults.set(options.caseSensitive, forKey: "StatAuthorsCaseSensitive"); defaults.set(options.sortByCommitCount, forKey: "StatSortByCommitCount")
        defaults.set(options.useCommitterNames, forKey: "StatCommiterNames"); defaults.set(options.useCommitDates, forKey: "StatCommitDates")
        defaults.set(metric.rawValue * 10 + style.rawValue, forKey: "LastViewedStatsPage")
    }
}

private final class StatisticsNativeWindow: NSWindow {
    var escape: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1b}" { escape(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class StatisticsWindowController: NSWindowController, NSWindowDelegate {
    static var activeExports = 0
    let model: StatisticsWindowModel
    var onClosed: () -> Void = {}
    private(set) var savePanel: StatisticsGraphSavePanel?
    private var exportError: NSAlert?
    private var closing = false
    private var closed = false
    private var exportRequest: UUID?
    private var pendingExports=0
    private var pendingSettlements=0
    private var exportCancellation:OperationCancellation?
    private var releaseTask:Task<Void,Never>?
    private var retiredSheets:[NSWindow]=[]
    private var saveAnswered=false
    var writeGraph:@Sendable (Data,URL,OperationCancellation) async throws->Void = {data,url,token in
        try await StatisticsGraphExport.write(data:data,to:url,cancellation:token)
    }
    var presentSavePanel:(NSSavePanel,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void = {panel,owner,reply in panel.beginSheetModal(for:owner,completionHandler:reply)}
    var presentExportError:(NSAlert,NSWindow,@escaping(NSApplication.ModalResponse)->Void)->Void = {alert,owner,reply in alert.beginSheetModal(for:owner,completionHandler:reply)}
    var selectedSaveURL:(NSSavePanel)->URL? = {$0.url}
    var hasPendingWork:Bool {model.hasPendingWork || pendingExports>0 || pendingSettlements>0 || savePanel != nil || exportError != nil || retiredSheets.contains{$0.sheetParent != nil} || window?.attachedSheet != nil}
    var canReuse:Bool {!closed && !closing && !model.retired}
    var canSaveGraph:Bool {canReuse && model.canExportGraph && NSApp.modalWindow==nil && window?.attachedSheet==nil}
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], defaults: UserDefaults = .standard) {
        model = StatisticsWindowModel(repository: repository, access: access, entries: entries, defaults: defaults)
        let window = StatisticsNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Statistics", preferences: defaults); window.contentMinSize = NSSize(width: 780, height: 550); window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StatisticsDialog(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(host); window.contentView = content
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor), host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor), host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 780), content.heightAnchor.constraint(greaterThanOrEqualToConstant: 550)
        ])
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.becameIdle = { [weak self] in if self?.closing == true { self?.window?.performClose(nil) } }
        model.presentationAvailable = {[weak self] in self?.canReuse==true && self?.window?.attachedSheet==nil && NSApp.modalWindow==nil}
        model.retireIntents = {[weak self] in self?.exportCancellation?.cancel()}
        window.escape = {[weak self] in
            guard let self,self.canReuse,!self.model.confirmingQuit,NSApp.modalWindow==nil else{return}
            self.window?.performClose(nil)
        }

        DialogGeometry.attach(window, identifier: "StatisticsDialog", legacyName: "StatisticsDialog")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private struct ExportSnapshot {
        let graph: LogStatisticsGraph
        let metric: LogStatisticsMetric
        let style: LogStatisticsStyle
        let size: CGSize
        let dark: Bool
        let revision: UUID
        @MainActor func data(format: StatisticsGraphFormat) throws -> Data {
            try StatisticsGraphExport.data(graph: graph, metric: metric, style: style, size: size, dark: dark, format: format)
        }
    }
    private func snapshot() throws -> ExportSnapshot {
        guard canSaveGraph, let graph = model.graph else { throw StatisticsGraphExportFailure.unavailable }
        return ExportSnapshot(graph: graph, metric: model.metric, style: model.style, size: model.graphSize,
                              dark: window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                              revision: model.formRevision)
    }
    func saveGraphAs() {
        guard canSaveGraph,savePanel==nil,let window,let captured=try? snapshot() else{return}
        let request=UUID(),choice=StatisticsGraphSavePanel(),token=OperationCancellation()
        choice.panel.alphaValue=window.alphaValue;choice.panel.appearance=window.appearance
        exportRequest=request;exportCancellation=token;saveAnswered=false;savePanel=choice;model.hasSheet=true
        let expected=model.formRevision
        presentSavePanel(choice.panel,window) {[weak self,choice] response in
            guard let self,!self.closed,self.exportRequest==request,self.savePanel===choice,!self.saveAnswered else{return}
            self.saveAnswered=true;self.pendingSettlements += 1
            // Freeze every output choice while the accepted panel still owns its
            // final URL. Never derive a sibling destination after authorization.
            let destination:Result<StatisticsGraphExportDestination,Error>?
            if response == .OK,let url=self.selectedSaveURL(choice.panel) {destination=Result {try choice.destination(for:url)}}
            else {destination=nil}
            let live=self.model.formRevision==expected && !self.model.confirmingQuit && !token.isCancelled
            let writer=self.writeGraph
            choice.panel.sheetParent?.endSheet(choice.panel,returnCode:response);choice.panel.orderOut(nil)
            Task { @MainActor [self,choice] in
                defer {self.pendingSettlements -= 1;self.resumeClosing()}
                await self.waitForSheet(choice.panel)
                guard !self.closed,self.exportRequest==request,self.savePanel===choice else{return}
                self.savePanel=nil;choice.retire();self.model.hasSheet=false
                guard live,!self.model.confirmingQuit,!token.isCancelled,let destination else {self.finishExport(request);return}
                do {
                    let target=try destination.get()
                    self.model.exporting=true;self.pendingExports += 1;Self.activeExports += 1
                    let writeEpoch=self.model.formRevision
                    defer {
                        Self.activeExports -= 1;self.pendingExports -= 1;self.model.exporting=false;self.finishExport(request)
                    }
                    try token.check()
                    let data=try captured.data(format:target.format)
                    try token.check()
                    guard !self.closed,!self.model.confirmingQuit,self.model.formRevision==writeEpoch else{return}
                    try await writer(data,target.url,token)
                } catch {
                    guard !self.closed,!self.model.confirmingQuit,!token.isCancelled else {self.finishExport(request);return}
                    self.finishExport(request);self.showExportError(error,window:window)
                }
            }
        }
    }
    private func resumeClosing() {
        if !closed,closing,!hasPendingWork {window?.performClose(nil)}
    }
    private func finishExport(_ request:UUID) {
        guard exportRequest==request else{return}
        exportRequest=nil;exportCancellation=nil
        if !closed,closing,!hasPendingWork {window?.performClose(nil)}
    }
    private func waitForSheet(_ sheet:NSWindow) async {
        while sheet.sheetParent != nil || window?.attachedSheet === sheet {try? await Task.sleep(nanoseconds:10_000_000)}
    }
    private func showExportError(_ error:Error,window:NSWindow) {
        guard !closed,!model.confirmingQuit,exportError==nil else{return}
        let alert=NSAlert(error:error);exportError=alert;model.hasSheet=true
        alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
        var answered=false
        presentExportError(alert,window) {[weak self,weak alert] _ in
            guard let self,let alert,!self.closed,self.exportError===alert,!answered else{return}
            answered=true
            alert.window.sheetParent?.endSheet(alert.window);alert.window.orderOut(nil)
            self.pendingSettlements += 1
            Task { @MainActor [self,alert] in
                defer {self.pendingSettlements -= 1;self.resumeClosing()}
                await self.waitForSheet(alert.window)
                guard self.exportError===alert else{return}
                self.exportError=nil;self.model.hasSheet=false
                if !self.closed,self.closing {window.performClose(nil)}
            }
        }
    }
    /// This synchronous compatibility entry point receives an already granted
    /// exact output URL. Interactive exports use the cancellation-aware writer.
    func exportGraph(to url:URL,format:StatisticsGraphFormat) throws {
        let captured=try snapshot(),data=try captured.data(format:format)
        let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        if GitRuntime.isAppStoreBuild && !scoped {throw RepositoryAccessFailure.securityScopeUnavailable}
        try data.write(to:url,options:.atomic)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        guard !closed,!model.confirmingQuit,NSApp.modalWindow==nil,!model.hasSheet,sender.attachedSheet==nil else{return false}
        if model.hasPendingWork || pendingExports>0 {closing=true;model.cancel();exportCancellation?.cancel();return false}
        return true
    }
    func windowWillClose(_ notification:Notification) {
        guard !closed else{return}
        closed=true;closing=true;exportRequest=nil;exportCancellation?.cancel()
        model.savePreferences();model.retire()
        if let choice=savePanel {
            choice.retire();retiredSheets.append(choice.panel)
            choice.panel.sheetParent?.endSheet(choice.panel,returnCode:.cancel);choice.panel.orderOut(nil)
        }
        if let alert=exportError {
            retiredSheets.append(alert.window);alert.window.sheetParent?.endSheet(alert.window,returnCode:.cancel);alert.window.orderOut(nil)
        }
        savePanel=nil;exportError=nil;model.hasSheet=false
        guard hasPendingWork else{finishClose();return}
        releaseTask=Task { @MainActor [self] in
            while hasPendingWork {try? await Task.sleep(nanoseconds:10_000_000)}
            finishClose()
        }
    }
    private func finishClose() {
        releaseTask=nil;retiredSheets=[];exportCancellation=nil
        let callback=onClosed;onClosed={};callback()
    }

}

private struct StatisticsDialog: View {
    @ObservedObject var model: StatisticsWindowModel
    var body: some View {
        let context = model.formRevision
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Graph type:"); Spacer(); Picker("Graph type", selection: Binding(get: { model.metric }, set: { model.selectMetric($0, context: context) })) { ForEach(LogStatisticsMetric.allCases, id: \.rawValue) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 360).disabled(!model.canInteract) }
            GroupBox {
                if model.metric == .statistics, let summary = model.summary { StatisticsSummary(summary: summary, calculate: { model.calculate(context: context) }).disabled(!model.canInteract).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                else if let graph = model.graph { StatisticsChart(graph: graph, style: model.style, byAuthor: model.metric.byAuthor).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GeometryReader { proxy in Color.clear.onAppear { model.graphSize = proxy.size }.onChange(of: proxy.size) { model.graphSize = $0 } }) }
                else { VStack {
                    Text(model.busy ? "Gathering statistics…" : "No graph data available.")
                    if model.metric.needsChanges && !model.busy { Button("Calculate") { model.calculate(context: context) }.disabled(!model.canInteract) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Toggle("Authors case sensitive", isOn: option(\.caseSensitive, context: context))
                    Toggle("Use committer names", isOn: option(\.useCommitterNames, context: context))
                    Toggle("Use commit dates", isOn: option(\.useCommitDates, context: context))
                    if model.showsGraphControls { Toggle("Sort by commit count", isOn: option(\.sortByCommitCount, context: context)) }
                }.disabled(!model.canInteract)
                Spacer()
                if model.showsGraphControls { HStack {
                    ForEach([LogStatisticsStyle.pie, .stackedLine, .line, .stackedBar, .bar], id: \.rawValue) { style in
                        Button { model.selectStyle(style, context: context) } label: { Image(nsImage: styleIcon(style).image() ?? NSImage()).frame(width: 18, height: 18) }.accessibilityLabel(styleTitle(style)).disabled(!model.canInteract || !model.supports(style)).help(styleHelp(style)).background(model.style == style ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityValue(model.style == style ? "Selected" : "")
                    }
                } }
            }
            HStack {
                if model.showsGraphControls { Text("# authors shown individually:")
                Slider(value: Binding(get: { model.authorsShown }, set: { model.setAuthorLimit($0, context: context) }), in: 1...Double(max(2, min(250, model.availableAuthorCount))), step: 1).frame(maxWidth: 220).disabled(!model.canInteract || model.availableAuthorCount < 2)
                    .accessibilityLabel("Authors shown individually").accessibilityValue(model.authorSliderHint).help(model.authorSliderHint)
                Text("\(Int(model.authorsShown))").monospacedDigit() }
                if model.exporting { ProgressView().controlSize(.small); Text("Saving graph…") }
                if model.busy { ProgressView(value: Double(model.completed), total: Double(max(1, model.entries.count))).frame(width: 100); Button("Cancel") {model.cancel(context:context)}.disabled(!model.canCancelCalculation) }
                Spacer(); Button("OK") {model.close(context:context)}.keyboardShortcut(.defaultAction).disabled(model.confirmingQuit || model.hasSheet || model.exporting)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(12)
    }
    private func option(_ key: WritableKeyPath<LogStatisticsOptions, Bool>, context: UUID) -> Binding<Bool> {
        Binding(get: { model.options[keyPath: key] }, set: { value in var options = model.options; options[keyPath: key] = value; model.setOptions(options, context: context) })
    }
    private func styleIcon(_ style: LogStatisticsStyle) -> MenuIcon {
        switch style { case .pie: return .graphPie; case .line: return .graphLine; case .stackedLine: return .graphStackedLine; case .bar: return .graphBar; case .stackedBar: return .graphStackedBar }
    }
    private func styleHelp(_ style:LogStatisticsStyle)->String {
        switch style {case .pie:return "Pie Graph";case .line:return "Line Graph";case .stackedLine:return "Stacked Line Graph";case .bar:return "Bar Graph";case .stackedBar:return "Stacked Bar Graph"}
    }
    private func styleTitle(_ style: LogStatisticsStyle) -> String {
        switch style { case .pie: return "Pie"; case .line: return "Line"; case .stackedLine: return "Stacked line"; case .bar: return "Bar"; case .stackedBar: return "Stacked bar" }
    }
}

private struct StatisticsSummary: View {
    let summary: LogStatisticsSummary
    var calculate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 9) {
                value("Number of \(summary.unit.rawValue)s:", summary.displayedIntervalCount)
                value("Number of authors:", summary.commitsByAuthor.count)
                value("Total commits analyzed:", summary.totalCommits)
                HStack {
                    Text("Total file changes:"); Spacer()
                    if summary.changesCalculated { Text("\(summary.totalChanges.files)").monospacedDigit().textSelection(.enabled) }
                    else { Button("Calculate", action: calculate) }
                }
                if summary.changesCalculated {
                    value("Total changed lines not including added/deleted files:", summary.totalChanges.linesWithoutNewDeletedFiles)
                    value("Total changed lines including added/deleted files:", summary.totalChanges.linesIncludingNewDeletedFiles)
                }
            }
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow { Color.clear.frame(height: 1).gridCellUnsizedAxes(.vertical); Text("").frame(width: 160); Text("Average"); Text("Min"); Text("Max") }
                GridRow { Text("Commits each \(summary.unit.rawValue):").frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading); Text(""); Text("\(summary.averageCommits)"); Text("\(summary.minimumCommits)"); Text("\(summary.maximumCommits)") }
                activity("Most active author:", summary.authorsByActivity.first)
                activity("Least active author:", summary.authorsByActivity.last)
            }.frame(maxWidth: .infinity).monospacedDigit().textSelection(.enabled)
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func value(_ label: String, _ count: Int) -> some View {
        HStack { Text(label); Spacer(); Text("\(count)").monospacedDigit().textSelection(.enabled) }
    }
    private func activity(_ label: String, _ author: LogStatisticsAuthor?) -> some View {
        let values = author.map { summary.activity(for: $0) } ?? (average: 0, minimum: 0, maximum: 0)
        return GridRow { Text(label).frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading); Text(author?.name ?? "").lineLimit(1).truncationMode(.middle).frame(width: 160, alignment: .leading).help(author?.name ?? ""); Text("\(values.average)"); Text("\(values.minimum)"); Text("\(values.maximum)") }
    }
}

private extension LogStatisticsColor {
    var chartColor: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1) }
}
/// Native text metrics replace GDI font measurements while retaining its
/// minimum size, fit-to-height and penultimate-dots/last-group policy.
struct StatisticsLegendLayout {
    let fontSize: CGFloat
    let rowHeight: CGFloat
    let width: CGFloat
    let groups: [Int?]
    init(graph: LogStatisticsGraph, height: CGFloat) {
        let initial = max(7, height / 80)
        let initialFont = NSFont.systemFont(ofSize: initial)
        let initialHeight = max(1, ceil(initialFont.ascender - initialFont.descender + initialFont.leading))
        let available = max(0, height - 20)
        fontSize = max(7, min(initial, initial * available / CGFloat(max(1, graph.legendLabels.count)) / initialHeight))
        let font = NSFont.systemFont(ofSize: fontSize)
        rowHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        groups = graph.legendGroupIndices(capacity: max(1, Int(available / rowHeight) - 1))
        width = ceil(graph.legendLabels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 50
    }
}
