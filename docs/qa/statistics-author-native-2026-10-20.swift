import AppKit
import Foundation
import ImageIO
import PDFKit
import TurtleGitCore

private actor StatisticsAuthorWriteGate {
    var data: Data?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func write(_ data: Data, to url: URL,cancellation:OperationCancellation) async throws {
        self.data = data
        if !released { await withCheckedContinuation { continuation = $0 } }
        try cancellation.check()
        try await StatisticsGraphExport.write(data:data,to:url,cancellation:cancellation)
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}

@main struct StatisticsAuthorNativeVerification {
    static let composed = "\u{00e9}lodie"
    static let decomposed = "e\u{0301}lodie"
    @MainActor static func require(_ value: Bool, _ message: String, line: Int = #line) throws {
        if !value { throw NSError(domain: "Statistics author identity: \(message)", code: line) }
    }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NSError(domain: "Statistics author native timeout", code: line)
    }
    static func bytes(_ strings: [String]) -> [Data] { strings.map { Data($0.utf8) } }
    @MainActor static func verifyColors(_ image: CGImage, graph: LogStatisticsGraph, context: String, thinLines: Bool) throws {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { storage in
            let canvas = CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        if thinLines {
            // A one-point stroke may have no opaque interior at its fractional
            // device row. Independently invert source-over-white: pixel =
            // white + alpha*(specified source-white). Classify only tight RGB
            // rays at substantial coverage, never an arbitrary color tolerance.
            // Each pixel can witness exactly one palette entry.
            let rays = graph.colors.map { color in
                [Double(color.red) - 255, Double(color.green) - 255, Double(color.blue) - 255]
            }
            var counts = [Int](repeating: 0, count: rays.count)
            for y in 0..<image.height { for x in 0..<(image.width * 7 / 8) {
                let offset = (y * image.width + x) * 4
                let pixel = (0..<3).map { Double(data[offset + $0]) - 255 }
                var matches: [Int] = []
                for (index, ray) in rays.enumerated() {
                    let norm = ray.reduce(0) { $0 + $1 * $1 }
                    guard norm > 0 else { continue }
                    let alpha = zip(pixel, ray).reduce(0.0) { $0 + $1.0 * $1.1 } / norm
                    guard alpha >= 0.25, alpha <= 1.01 else { continue }
                    let residual = zip(pixel, ray).map { abs($0.0 - alpha * $0.1) }.max() ?? .infinity
                    if residual <= 3 { matches.append(index) }
                }
                if matches.count == 1 { counts[matches[0]] += 1 }
            } }
            for (index, count) in counts.enumerated() {
                try require(count > 8, "\(context) lost distinct antialiased palette ray \(index): \(count) plot pixels")
            }
            return
        }
        for (index, color) in graph.colors.enumerated() {
            var count = 0, closestDistance = Int.max, nearCount = 0
            var closestPixel: [UInt8] = []
            // This fixed 960x500 fixture places its legend beyond x=862.
            // Keep the plot through x=839, including the fourth author bar
            // at x=645...843, while excluding the entire legend and swatches.
            for y in 0..<image.height { for x in 0..<(image.width * 7 / 8) {
                let offset = (y * image.width + x) * 4
                let dr = abs(Int(data[offset]) - Int(color.red)), dg = abs(Int(data[offset + 1]) - Int(color.green)), db = abs(Int(data[offset + 2]) - Int(color.blue))
                if dr <= 3 && dg <= 3 && db <= 3 { count += 1 }
                if max(dr, dg, db) <= 32 { nearCount += 1 }
                if dr + dg + db < closestDistance { closestDistance = dr + dg + db; closestPixel = Array(data[offset..<(offset + 4)]) }
            } }
            if count <= 8 { print("COLOR DIAGNOSTIC \(context) index=\(index) source=\(color) exact=\(count) tolerance32=\(nearCount) closestRGBADistance=\(closestDistance) closest=\(closestPixel)") }
            try require(count > 8, "\(context) lost plot color \(index): \(count) pixels")
        }
    }
    @MainActor static func render(_ graph: LogStatisticsGraph, root: URL) throws {
        let labels = graph.metric.byAuthor ? graph.categoryLabels : graph.seriesLabels
        try require(bytes(labels).filter { $0 == Data("Others (2)".utf8) }.count == 2, "actual and synthetic Others captions not both present")
        try require(Set(bytes(labels)).count == 3 && labels.count == 4, "canonical names or duplicate captions changed")
        let original = bytes(labels)
        for point in graph.points {
            let index = graph.metric.byAuthor ? point.category : point.series
            try require(Data(graph.tooltip(for: point).utf8).range(of: original[index]) != nil, "tooltip changed raw author bytes")
        }
        for style in LogStatisticsStyle.allCases where !graph.metric.byAuthor || ![.line, .stackedLine].contains(style) {
            let chart = StatisticsChart(graph: graph, style: style, byAuthor: graph.metric.byAuthor)
            try require(Set(chart.groupKeys).count == 4, "Charts scale merged raw author identities")
            for point in graph.points {
                let index = graph.metric.byAuthor ? point.category : point.series
                try require(chart.groupKey(for: point) == chart.groupKeys[index], "mark and scale identities differ")
            }
            for format in [StatisticsGraphFormat.png, .pdf] {
                let data = try StatisticsGraphExport.data(graph: graph, metric: graph.metric, style: style, size: CGSize(width: 960, height: 500), dark: false, format: format)
                let file = root.appendingPathComponent("authors-\(graph.metric.rawValue)-\(style.rawValue).\(format.fileExtension)")
                try data.write(to: file)
                if let path = ProcessInfo.processInfo.environment["TURTLEGIT_STATISTICS_AUTHOR_ARTIFACTS"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent(file.lastPathComponent))
                }
                try require(try Data(contentsOf: file) == data, "export byte roundtrip changed")
                let image: CGImage
                if format == .png {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StatisticsGraphExportFailure.encoding }
                    image = decoded
                } else {
                    guard let document = PDFDocument(data: data), document.pageCount == 1, let page = document.page(at: 0), let decoded = page.thumbnail(of: CGSize(width: 960, height: 500), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw StatisticsGraphExportFailure.rendering }
                    image = decoded
                }
                try verifyColors(image, graph: graph, context: "\(graph.metric) \(style) \(format)", thinLines: style == .line)
                try require(bytes(graph.metric.byAuthor ? graph.categoryLabels : graph.seriesLabels) == original, "export mutated graph labels")
            }
        }
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Statistics Author QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        let authors = [composed, decomposed, "Others (2)", "Case", "case", "Tail"]
        let committers = [composed, composed, decomposed, decomposed, "Commit", "commit"]
        for index in 0..<12 {
            let day = index < 6 ? "01" : "03"
            try Data("line \(index)\n".utf8).write(to: root.appendingPathComponent("file"))
            try await repo.stage(["file"])
            _ = try await repo.run(["commit", "-m", "author fixture \(index)"], environmentOverrides: [
                "GIT_AUTHOR_NAME": authors[index % 6], "GIT_AUTHOR_EMAIL": "author@example.invalid",
                "GIT_COMMITTER_NAME": committers[index % 6], "GIT_COMMITTER_EMAIL": "committer@example.invalid",
                "GIT_AUTHOR_DATE": "2024-01-\(day)T12:00:00Z", "GIT_COMMITTER_DATE": "2024-01-\(day)T13:00:00Z"])
        }
        let entries = try await repo.history()
        try require(entries.count == 12, "private Git history missing commits")
        try require(Set(bytes(entries.map(\.author))).contains(Data(decomposed.utf8)), "Git history normalized decomposed author")
        let tracked = [".git/HEAD", ".git/index", ".git/config", ".git/refs/heads/main", "file"]
        let before = try tracked.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let entryBytes = entries.map { Data(($0.hash + "\0" + $0.author + "\0" + $0.committer).utf8) }
        let suite = "TurtleGit.Statistics.Author.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = StatisticsWindowController(repository: repo, access: nil, entries: entries, defaults: defaults)
        owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); owner.window?.orderFront(nil)
        defer { owner.close() }
        let model = owner.model
        model.calculate()
        try await wait { !model.busy }
        try require(model.error == nil && model.summary?.changesCalculated == true, "actual Calculate failed: \(model.error ?? "")")
        for useCommitter in [false, true] { for sensitive in [true, false] {
            var options = model.options; options.useCommitterNames = useCommitter; options.caseSensitive = sensitive
            model.setOptions(options)
            var expected: [Data: Int] = [:]
            for entry in entries {
                let raw = useCommitter ? entry.committer : entry.author
                expected[Data((sensitive ? raw : raw.lowercased()).utf8), default: 0] += 1
            }
            for metric in LogStatisticsMetric.allCases {
                model.selectMetric(metric)
                guard let summary = model.summary else { throw StatisticsGraphExportFailure.unavailable }
                let actual = Dictionary(uniqueKeysWithValues: summary.commitsByAuthor.map { (Data($0.key.name.utf8), $0.value) })
                try require(actual == expected, "\(metric) author/committer=\(useCommitter) case=\(sensitive) raw counts changed")
                try require(summary.totalCommits == 12 && summary.changesCalculated, "Calculate result lost on option/metric change")
                if metric != .statistics {
                    guard let graph = model.graph else { throw StatisticsGraphExportFailure.unavailable }
                    try require(Set(graph.includedAuthors.map { Data($0.name.utf8) }) == Set(expected.keys), "metric lost identity rows/series")
                    let expectedTotal: Int
                    switch metric {
                    case .linesIncluding: expectedTotal = summary.totalChanges.linesIncludingNewDeletedFiles
                    case .linesExcluding: expectedTotal = summary.totalChanges.linesWithoutNewDeletedFiles
                    case .authorship: expectedTotal = summary.authorshipPercent.values.reduce(0) { $0 + Int($1.rounded()) }
                    default: expectedTotal = 12
                    }
                    try require(graph.points.reduce(0) { $0 + $1.value } == expectedTotal, "\(metric) totals changed")
                }
            }
        } }
        // Distinct counts keep every line visibly separate; the real Others (2)
        // caption intentionally equals the aggregate of two omitted authors.
        var sample: [LogEntry] = []
        for day in ["01", "03"] { for (author, count) in [(composed, 7), (decomposed, 6), ("Others (2)", 5), ("Tail", 2), ("Tiny", 1)] {
            for index in 0..<count { sample.append(LogEntry(hash: "\(day)-\(sample.count)-\(index)", author: author, date: "2024-01-\(day)T12:00:00Z", subject: "", committerDate: "2024-01-\(day)T12:00:00Z")) }
        } }
        let summary = try LogStatistics.analyze(sample)
        for metric in [LogStatisticsMetric.commitsByDate, .commitsByAuthor] {
            let graph = try LogStatisticsGraph.make(summary, metric: metric, authorsShown: 3)
            try require(graph.includedAuthors.count == 3 && graph.skippedAuthors.count == 2, "aggregate fixture ranking changed")
            try render(graph, root: root)
        }
        let saving = StatisticsWindowController(repository: repo, access: nil, entries: sample, defaults: defaults)
        saving.window?.alphaValue = 0; saving.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); saving.window?.orderFront(nil)
        defer { saving.close() }
        saving.model.selectMetric(.commitsByDate); saving.model.setAuthorLimit(3); saving.model.selectStyle(.bar)
        saving.model.graphSize = CGSize(width: 960, height: 500)
        let snapshot = bytes(saving.model.graph!.seriesLabels)
        let target = root.appendingPathComponent("captured-author-graph.pdf")
        let sentinel=Data("existing statistics graph".utf8);try sentinel.write(to:target)
        var reply: ((NSApplication.ModalResponse) -> Void)?
        saving.presentSavePanel = { _, _, completion in reply = completion }
        saving.selectedSaveURL = { _ in target }
        let gate = StatisticsAuthorWriteGate()
        saving.writeGraph = {data,url,token in try await gate.write(data,to:url,cancellation:token)}
        do {
            saving.saveGraphAs(); reply?(.OK)
            for _ in 0..<3000 { if await gate.data != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let frozenData = await gate.data
            try require(frozenData != nil && saving.model.exporting, "owned snapshot writer did not start")
            var altered = saving.model.options; altered.caseSensitive = false
            saving.model.setOptions(altered)
            try require(bytes(saving.model.graph!.seriesLabels) == snapshot, "pending export accepted new identity controls")
            saving.close(); await gate.finish()
            try await wait { StatisticsWindowController.activeExports == 0 }
            try require(try Data(contentsOf:target)==sentinel,"Cancelled snapshot export overwrote the previous target")
            try require(frozenData.flatMap {PDFDocument(data:$0)}?.pageCount==1,"Owned captured snapshot PDF invalid")
        } catch {
            await gate.finish()
            saving.close()
            // Preserve the original assertion while still releasing the owned
            // writer and bounding cleanup; run_receiver reaps a stuck process.
            for _ in 0..<3000 {
                if StatisticsWindowController.activeExports == 0 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            throw error
        }
        try require(try tracked.map { try Data(contentsOf: root.appendingPathComponent($0)) } == before, "statistics mutated Git/worktree bytes")
        try require(entries.map { Data(($0.hash + "\0" + $0.author + "\0" + $0.committer).utf8) } == entryBytes, "statistics mutated accepted Log snapshot")
        owner.close()
        try await wait { StatisticsWindowModel.activeOperations == 0 && StatisticsWindowController.activeExports == 0 }
        try require(model.retired && saving.model.retired, "owned statistics windows did not retire")
        print("PASS: Statistics exact author identities, actual Git Calculate/options/all metrics, duplicate Others captions, distinct plot colors in PNG/PDF all supported styles, captured export bytes and owned cleanup")
    }
}
