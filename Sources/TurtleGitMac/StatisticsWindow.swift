import AppKit
import SwiftUI
import Charts
import TurtleGitCore

@MainActor final class StatisticsWindowModel: ObservableObject {
    static var activeOperations = 0
    let repository: GitRepository
    let entries: [LogEntry]
    private let access: RepositoryAccessLease?
    private let defaults: UserDefaults
    private var changes: [String: LogStatisticsChanges]?
    private var cancellation: OperationCancellation?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private(set) var retired = false
    @Published var hasSheet = false
    @Published var exporting = false
    @Published private(set) var formRevision = UUID()
    var becameIdle: () -> Void = {}
    @Published var options = LogStatisticsOptions()
    @Published var metric = LogStatisticsMetric.statistics
    @Published var style = LogStatisticsStyle.line
    @Published var authorsShown = 1.0
    @Published var summary: LogStatisticsSummary?
    @Published var graph: LogStatisticsGraph?
    @Published var busy = false
    @Published var completed = 0
    @Published var error: String?
    var close: () -> Void = {}
    var graphSize = CGSize(width: 860, height: 400)
    var canInteract: Bool { !retired && !busy && !hasSheet && !exporting }
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
        cancellation = token; generation = request; Self.activeOperations += 1
        worker = Task { [self, access] in
            defer {
                Self.activeOperations -= 1
                if request == generation || retired {
                    busy = false; cancellation = nil; worker = nil
                    if !retired { becameIdle() }
                }
                withExtendedLifetime(access) {}
            }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (stream, continuation) = AsyncStream<Int>.makeStream()
                let operation = Task { [repository, entries] in
                    defer { continuation.finish() }
                    return try await repository.logStatisticsChanges(entries, cancellation: token) { done, _ in continuation.yield(done) }
                }
                for await done in stream {
                    if !retired, request == generation, !token.isCancelled { completed = done }
                }
                let result = try await operation.value
                try token.check()
                guard !retired, request == generation else { return }
                changes = result; rebuild(resetAuthors: true)
            } catch {
                if !retired, request == generation { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { cancellation?.cancel() }
    func retire() {
        guard !retired else { return }
        retired = true; formRevision = UUID(); generation = UUID(); cancel(); becameIdle = {}; close = {}
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
    var writeGraph: @Sendable (Data, URL) async throws -> Void = { data, url in
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
        }.value
    }
    var presentSavePanel: (NSSavePanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, window, completion in panel.beginSheetModal(for: window, completionHandler: completion) }
    var selectedSaveURL: (NSSavePanel) -> URL? = { $0.url }
    var canSaveGraph: Bool { !closed && model.canExportGraph && window?.attachedSheet == nil }
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
        window.escape = { [weak model] in model?.close() }

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
        guard canSaveGraph, savePanel == nil, let window, let captured = try? snapshot() else { return }
        let request = UUID(), choice = StatisticsGraphSavePanel()
        exportRequest = request; savePanel = choice; model.hasSheet = true
        presentSavePanel(choice.panel, window) { [weak self, choice, weak window] response in
            guard let self, !self.closed, self.exportRequest == request, self.savePanel === choice, let window else { return }
            self.savePanel = nil; self.model.hasSheet = false; self.exportRequest = nil
            guard response == .OK, let url = self.selectedSaveURL(choice.panel), self.model.formRevision == captured.revision else { return }
            self.model.exporting = true; Self.activeExports += 1
            let writer = self.writeGraph
            Task { [self] in
                defer {
                    Self.activeExports -= 1
                    self.model.exporting = false
                    if !self.closed && self.closing { self.window?.performClose(nil) }
                }
                do {
                    let data = try captured.data(format: choice.format)
                    try await writer(data, url)
                } catch {
                    guard !self.closed else { return }
                    self.showExportError(error, window: window)
                }
            }
        }
    }
    private func showExportError(_ error: Error, window: NSWindow) {
        let alert = NSAlert(error: error); exportError = alert; model.hasSheet = true
        alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
            guard let self, !self.closed, self.exportError === alert else { return }
            self.exportError = nil; self.model.hasSheet = false
            if self.closing { self.window?.performClose(nil) }
        }
    }
    /// Immediate export remains available for callers that already own a URL.
    func exportGraph(to url: URL, format: StatisticsGraphFormat) throws {
        let captured = try snapshot()
        let data = try captured.data(format: format)
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.hasSheet, sender.attachedSheet == nil else { return false }
        if model.busy || model.exporting { closing = true; model.cancel(); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; exportRequest = nil
        model.savePreferences(); model.retire()
        if let sheet = savePanel?.panel { window?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        if let alert = exportError { window?.endSheet(alert.window, returnCode: .cancel); alert.window.orderOut(nil) }
        savePanel = nil; exportError = nil; model.hasSheet = false
        onClosed(); onClosed = {}
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
                        Button { model.selectStyle(style, context: context) } label: { Image(nsImage: styleIcon(style).image() ?? NSImage()).frame(width: 18, height: 18) }.accessibilityLabel(styleTitle(style)).disabled(!model.canInteract || !model.supports(style)).help(styleTitle(style)).background(model.style == style ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
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
                if model.busy { ProgressView(value: Double(model.completed), total: Double(max(1, model.entries.count))).frame(width: 100); Button("Cancel") { model.cancel() } }
                Spacer(); Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
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
    private func activity(_ label: String, _ author: String?) -> some View {
        let values = author.map { summary.activity(for: $0) } ?? (average: 0, minimum: 0, maximum: 0)
        return GridRow { Text(label).frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading); Text(author ?? "").lineLimit(1).truncationMode(.middle).frame(width: 160, alignment: .leading).help(author ?? ""); Text("\(values.average)"); Text("\(values.minimum)"); Text("\(values.maximum)") }
    }
}

private extension LogStatisticsColor {
    var chartColor: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1) }
}
struct StatisticsChart: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverTip = ""
    let graph: LogStatisticsGraph
    let style: LogStatisticsStyle
    let byAuthor: Bool
    var exporting = false
    static func backgroundColor(dark: Bool) -> Color { dark ? Color(.sRGB, red: 32.0 / 255, green: 32.0 / 255, blue: 32.0 / 255, opacity: 1) : .white }
    private var bars: Bool { style == .bar || style == .stackedBar }
    private var labels: [String] { bars ? graph.barLabels : (byAuthor ? [""] : graph.categoryLabels) }
    private func name(_ point: LogStatisticsGraph.Point) -> String { byAuthor ? graph.categoryLabels[point.category] : graph.seriesLabels[point.series] }
    private func center(_ point: LogStatisticsGraph.Point) -> Double { byAuthor ? 0.5 : Double(point.category) + 0.5 }
    var body: some View {
        VStack(spacing: 8) {
            Text(graph.metric.title).font(.headline).multilineTextAlignment(.center).help("Title")
            GeometryReader { geometry in
                HStack(spacing: 10) {
                    plot.frame(maxWidth: .infinity, maxHeight: .infinity)
                    // MyGraph hides the legend below 300 pixels inside its
                    // ten-pixel graph margins on either side.
                    if geometry.size.width > 320 && !graph.legendLabels.isEmpty {
                        StatisticsLegend(graph: graph, height: geometry.size.height)
                    }
                }
            }
        }.background(Self.backgroundColor(dark: colorScheme == .dark))
    }
    @ViewBuilder private var plot: some View {
        let xLabels = labels
        let rectangles = bars ? graph.barLayout(stacked: style == .stackedBar) : []
        if graph.points.isEmpty { Text("No graph data available.") }
        else if style == .pie { StatisticsPies(graph: graph, byAuthor: byAuthor, exporting: exporting) }
        else {
            Chart {
                if bars {
                    ForEach(Array(rectangles.enumerated()), id: \.offset) { _, bar in
                        RectangleMark(xStart: .value("Start", bar.left), xEnd: .value("End", bar.right), yStart: .value("Base", bar.bottom), yEnd: .value("Value", bar.top))
                            .foregroundStyle(by: .value("Author", name(bar.point)))
                    }
                } else {
                    ForEach(Array(graph.points.enumerated()), id: \.offset) { _, point in
                        if style == .line {
                            LineMark(x: .value("Interval", center(point)), y: .value("Value", Double(point.value)))
                                .foregroundStyle(by: .value("Author", name(point))).symbol(.circle).symbolSize(36).lineStyle(StrokeStyle(lineWidth: 1))
                        } else {
                            AreaMark(x: .value("Interval", center(point)), y: .value("Value", Double(point.value)))
                                .foregroundStyle(by: .value("Author", name(point)))
                        }
                    }
                }
                if [.bar, .line].contains(style) {
                    RuleMark(y: .value("Average", Double(graph.averageGuide))).foregroundStyle(Color.primary).lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityLabel(Text(graph.averageTooltip(style: style)))
                }
            }.chartForegroundStyleScale(domain: byAuthor ? graph.categoryLabels : graph.seriesLabels, range: graph.colors.map(\.chartColor))
            .chartLegend(.hidden)
            .chartXAxisLabel(graph.xAxisLabel, position: .bottom, alignment: .center).chartYAxisLabel(graph.yAxisLabel, position: .leading)
            .chartXScale(domain: 0.0...Double(max(1, xLabels.count))).chartYScale(domain: 0.0...Double(graph.yAxisMaximum(style: style)))
            .chartYAxis { AxisMarks(position: .leading, values: graph.yAxisTicks(style: style).map(Double.init)) { value in
                AxisTick(); AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number))") } }
            } }
            .chartXAxis { AxisMarks(values: xLabels.indices.map { Double($0) + 0.5 }) { value in
                AxisTick(); AxisValueLabel { if let number = value.as(Double.self), xLabels.indices.contains(Int(number)) { Text(xLabels[Int(number)]).font(.caption2) } }
            } }
            .chartOverlay { proxy in
                if !exporting {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                            let tip: String
                            switch phase {
                            case .ended: tip = ""
                            case .active(let location): tip = tooltip(location: location, bounds: geometry[proxy.plotAreaFrame], proxy: proxy, rectangles: rectangles)
                            }
                            if hoverTip != tip { hoverTip = tip }
                        }.help(hoverTip)
                    }
                }
            }.padding(10)
        }
    }
    private func tooltip(location: CGPoint, bounds: CGRect, proxy: ChartProxy, rectangles: [LogStatisticsGraph.Bar]) -> String {
        guard bounds.contains(location) else { return "" }
        let x = location.x - bounds.minX, y = location.y - bounds.minY
        if let averageY = proxy.position(forY: Double(graph.averageGuide)), abs(y - averageY) <= 2 {
            return graph.averageTooltip(style: style)
        }
        if bars, let valueX = proxy.value(atX: x, as: Double.self), let valueY = proxy.value(atY: y, as: Double.self) {
            return rectangles.first { $0.contains(x: valueX, y: valueY) }.map { graph.tooltip(for: $0.point) } ?? ""
        }
        if style == .line && labels.count < 40 {
            let hits = graph.points.filter { point in
                guard let px = proxy.position(forX: center(point)), let py = proxy.position(forY: Double(point.value)) else { return false }
                return abs(x - px) <= 3 && abs(y - py) <= 3
            }
            return hits.map { graph.tooltip(for: $0) }.joined(separator: ", ")
        }
        return ""
    }
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

private struct StatisticsLegend: View {
    let graph: LogStatisticsGraph
    let height: CGFloat
    var body: some View {
        let layout = StatisticsLegendLayout(graph: graph, height: height)
        let colors = graph.colors.map(\.chartColor)
        VStack(spacing: 0) {
            ForEach(Array(layout.groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 10) {
                    Text(group.map { graph.legendLabels[$0] } ?? "...").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    if let group {
                        Rectangle().fill(colors[group]).padding(1)
                            .overlay(Rectangle().stroke(Color.primary, lineWidth: 1))
                            .frame(width: 28, height: max(1, layout.rowHeight - 2))
                            .accessibilityHidden(true)
                    }
                }.frame(height: layout.rowHeight)
            }
        }.font(.system(size: layout.fontSize)).padding(5)
            .frame(width: layout.width)
            .overlay(Rectangle().stroke(Color.primary, lineWidth: 1))
            .help("Legend").padding(.trailing, 10)
    }
}

private struct StatisticsPies: View {
    let graph: LogStatisticsGraph
    let byAuthor: Bool
    var exporting = false
    @State private var hoverTips: [Int: String] = [:]
    var body: some View {
        let colors = graph.colors.map(\.chartColor)
        let categories = graph.pieCategories
        GeometryReader { geometry in
            let slot = max(0, min(geometry.size.width / CGFloat(max(1, categories.count)), geometry.size.height - 50))
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(categories, id: \.self) { category in
                        let points = byAuthor ? graph.points : graph.points.filter { $0.category == category }
                        VStack(spacing: 10) {
                            Canvas { context, size in
                                let total = Double(points.reduce(0) { $0 + $1.value }); var angle = Double.pi
                                let center = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) * 0.425
                                for point in points where point.value > 0 && total > 0 {
                                    let next = angle - Double(point.value) / total * 2 * .pi
                                    var path = Path(); path.move(to: center); path.addArc(center: center, radius: radius, startAngle: .radians(angle), endAngle: .radians(next), clockwise: true); path.closeSubpath()
                                    context.fill(path, with: .color(colors[byAuthor ? point.category : point.series])); angle = next
                                }
                            }.frame(width: slot, height: slot).overlay {
                                if !exporting {
                                    GeometryReader { pieGeometry in
                                        Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                                            var tip = ""
                                            if case .active(let location) = phase {
                                                let radius = min(pieGeometry.size.width, pieGeometry.size.height) * 0.425
                                                if radius > 0, let point = graph.piePoint(category: category, x: Double((location.x - pieGeometry.size.width / 2) / radius), y: Double((location.y - pieGeometry.size.height / 2) / radius)) { tip = graph.tooltip(for: point) }
                                            }
                                            if hoverTips[category] != tip { hoverTips[category] = tip }
                                        }.help(hoverTips[category] ?? "")
                                    }
                                }
                            }
                            Text(byAuthor ? "" : graph.categoryLabels[category]).font(.caption2).lineLimit(1).frame(height: 14)
                        }.frame(width: slot)
                    }
                }
                Text(graph.xAxisLabel).font(.caption)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.padding(10)
    }
}
