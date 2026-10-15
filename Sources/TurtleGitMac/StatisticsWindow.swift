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
    var canInteract: Bool { !retired && !busy && !hasSheet }
    var showsGraphControls: Bool { metric != .statistics }
    var canExportGraph: Bool { canInteract && metric != .statistics && graph != nil }
    func supports(_ style: LogStatisticsStyle) -> Bool { !metric.byAuthor || ![.line, .stackedLine].contains(style) }
    func selectStyle(_ style: LogStatisticsStyle) { guard canInteract, supports(style) else { return }; self.style = style }
    func setOptions(_ options: LogStatisticsOptions) { guard canInteract else { return }; self.options = options; rebuild(resetAuthors: true) }
    func setAuthorLimit(_ value: Double) { guard canInteract, value.isFinite else { return }; authorsShown = max(1, value); rebuild() }
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
        if metric == .authorship && changes != nil { return summary.authorshipPercent.values.filter { $0.rounded(.toNearestOrAwayFromZero) > 0 }.count }
        return summary.commitsByAuthor.count
    }
    func start() { if metric.needsChanges { calculate() } }
    func selectMetric(_ metric: LogStatisticsMetric) {
        guard canInteract else { return }; self.metric = metric
        if metric.byAuthor { style = .bar } else if metric == .statistics || metric == .commitsByDate { style = .line }
        rebuild(resetAuthors: true); if metric.needsChanges && changes == nil { calculate() }
    }
    func rebuild(resetAuthors: Bool = false) {
        guard !retired else { return }
        do {
            summary = try LogStatistics.analyze(entries, options: options, changes: changes)
            if resetAuthors { authorsShown = Double(min(250, max(1, availableAuthorCount))) }
            authorsShown = min(authorsShown, Double(min(250, max(1, availableAuthorCount))))
            if metric == .statistics || metric.needsChanges && changes == nil { graph = nil }
            else { graph = try LogStatisticsGraph.make(summary!, metric: metric, authorsShown: Int(authorsShown), alphabetical: !options.sortByCommitCount) }
            error = nil
        } catch { self.error = error.localizedDescription; graph = nil }
    }
    func calculate() {
        guard canInteract, changes == nil else { return }; busy = true; completed = 0; error = nil
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
        retired = true; generation = UUID(); cancel(); becameIdle = {}; close = {}
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
    let model: StatisticsWindowModel
    var onClosed: () -> Void = {}
    private(set) var savePanel: StatisticsGraphSavePanel?
    private var exportError: NSAlert?
    private var closing = false
    private var closed = false
    var presentSavePanel: (NSSavePanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, window, completion in panel.beginSheetModal(for: window, completionHandler: completion) }
    var canSaveGraph: Bool { !closed && model.canExportGraph && window?.attachedSheet == nil }
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [LogEntry], defaults: UserDefaults = .standard) {
        model = StatisticsWindowModel(repository: repository, access: access, entries: entries, defaults: defaults)
        let window = StatisticsNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Statistics", preferences: defaults); window.contentMinSize = NSSize(width: 720, height: 530); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatisticsDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.becameIdle = { [weak self] in if self?.closing == true { self?.window?.performClose(nil) } }
        window.escape = { [weak model] in model?.close() }

        DialogGeometry.attach(window, identifier: "StatisticsDialog", legacyName: "StatisticsDialog")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func saveGraphAs() {
        guard canSaveGraph, savePanel == nil, let window else { return }
        let choice = StatisticsGraphSavePanel(); savePanel = choice; model.hasSheet = true
        presentSavePanel(choice.panel, window) { [weak self, choice, weak window] response in
            guard let self, !self.closed, self.savePanel === choice, let window else { return }
            self.savePanel = nil; self.model.hasSheet = false
            guard response == .OK, let url = choice.panel.url else { return }
            do { try self.exportGraph(to: url, format: choice.format) }
            catch {
                let alert = NSAlert(error: error); self.exportError = alert; self.model.hasSheet = true
                alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
                    guard let self, !self.closed, self.exportError === alert else { return }
                    self.exportError = nil; self.model.hasSheet = false
                }
            }
        }
    }
    func exportGraph(to url: URL, format: StatisticsGraphFormat) throws {
        guard canSaveGraph, let graph = model.graph else { throw StatisticsGraphExportFailure.unavailable }
        let dark = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let data = try StatisticsGraphExport.data(graph: graph, metric: model.metric, style: model.style, size: model.graphSize, dark: dark, format: format)
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.hasSheet, sender.attachedSheet == nil else { return false }
        if model.busy { closing = true; model.cancel(); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true
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
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Graph type:"); Spacer(); Picker("Graph type", selection: Binding(get: { model.metric }, set: { model.selectMetric($0) })) { ForEach(LogStatisticsMetric.allCases, id: \.rawValue) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 360).disabled(!model.canInteract) }
            GroupBox {
                if model.metric == .statistics, let summary = model.summary { StatisticsSummary(summary: summary, calculate: model.calculate).disabled(!model.canInteract).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                else if let graph = model.graph { StatisticsChart(graph: graph, style: model.style, byAuthor: model.metric.byAuthor).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GeometryReader { proxy in Color.clear.onAppear { model.graphSize = proxy.size }.onChange(of: proxy.size) { model.graphSize = $0 } }) }
                else { VStack {
                    Text(model.busy ? "Gathering statistics…" : "No graph data available.")
                    if model.metric.needsChanges && !model.busy { Button("Calculate", action: model.calculate).disabled(!model.canInteract) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Toggle("Authors case sensitive", isOn: option(\.caseSensitive))
                    Toggle("Use committer names", isOn: option(\.useCommitterNames))
                    Toggle("Use commit dates", isOn: option(\.useCommitDates))
                    if model.showsGraphControls { Toggle("Sort by commit count", isOn: option(\.sortByCommitCount)) }
                }.disabled(!model.canInteract)
                Spacer()
                if model.showsGraphControls { HStack {
                    ForEach([LogStatisticsStyle.pie, .stackedLine, .line, .stackedBar, .bar], id: \.rawValue) { style in
                        Button { model.selectStyle(style) } label: { Image(nsImage: styleIcon(style).image() ?? NSImage()).frame(width: 18, height: 18) }.accessibilityLabel(styleTitle(style)).disabled(!model.canInteract || !model.supports(style)).help(styleTitle(style)).tint(model.style == style ? .accentColor : nil)
                    }
                } }
            }
            HStack {
                if model.showsGraphControls { Text("# authors shown individually:")
                Slider(value: Binding(get: { model.authorsShown }, set: { model.setAuthorLimit($0) }), in: 1...Double(max(2, min(250, model.availableAuthorCount))), step: 1).frame(maxWidth: 220).disabled(!model.canInteract || model.availableAuthorCount < 2)
                Text("\(Int(model.authorsShown))").monospacedDigit() }
                if model.busy { ProgressView(value: Double(model.completed), total: Double(max(1, model.entries.count))).frame(width: 100); Button("Cancel") { model.cancel() } }
                Spacer(); Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(12)
    }
    private func option(_ key: WritableKeyPath<LogStatisticsOptions, Bool>) -> Binding<Bool> {
        Binding(get: { model.options[keyPath: key] }, set: { value in var options = model.options; options[keyPath: key] = value; model.setOptions(options) })
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
        Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 12) {
            value("Number of \(summary.unit.rawValue)s:", summary.displayedIntervalCount)
            value("Number of authors:", summary.commitsByAuthor.count)
            value("Total commits analyzed:", summary.totalCommits)
            GridRow { Text("Total file changes:"); if summary.changesCalculated { Text("\(summary.totalChanges.files)") } else { Button("Calculate", action: calculate) } }
            if summary.changesCalculated {
                value("Total changed lines not including added/deleted files:", summary.totalChanges.linesWithoutNewDeletedFiles)
                value("Total changed lines including added/deleted files:", summary.totalChanges.linesIncludingNewDeletedFiles)
            }
            GridRow { Text(""); Text(""); Text("Average"); Text("Min"); Text("Max") }
            GridRow { Text("Commits each \(summary.unit.rawValue):"); Text(""); Text("\(summary.averageCommits)"); Text("\(summary.minimumCommits)"); Text("\(summary.maximumCommits)") }
            if let first = summary.authorsByActivity.first { activity("Most active author:", first) }
            if let last = summary.authorsByActivity.last { activity("Least active author:", last) }
        }.padding(10)
    }
    private func value(_ label: String, _ count: Int) -> some View { GridRow { Text(label); Text("\(count)") } }
    private func activity(_ label: String, _ author: String) -> some View { let values = summary.activity(for: author); return GridRow { Text(label); Text(author); Text("\(values.average)"); Text("\(values.minimum)"); Text("\(values.maximum)") } }
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
