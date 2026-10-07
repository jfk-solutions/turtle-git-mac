import AppKit
import Foundation
import TurtleGitCore
import ImageIO
import PDFKit

@main struct StatisticsNativeVerification {
    @MainActor static func wait(_ model: StatisticsWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy, "Statistics timed out")
    }
    @MainActor static func verifyExport(_ controller: StatisticsWindowController, root: URL) throws {
        let model = controller.model
        let choice = StatisticsGraphSavePanel()
        let popup = choice.panel.accessoryView!.subviews.compactMap { $0 as? NSPopUpButton }.first!
        for (index, format) in StatisticsGraphFormat.allCases.enumerated() {
            popup.selectItem(at: index); choice.changeFormat()
            precondition(choice.format == format && choice.panel.allowedContentTypes == [format.contentType])
            precondition((choice.panel.nameFieldStringValue as NSString).pathExtension == format.fileExtension)
        }
        model.selectMetric(.statistics); precondition(!model.canExportGraph)
        let refused = root.appendingPathComponent("summary.png")
        do { try controller.exportGraph(to: refused, format: .png); preconditionFailure("Summary exported") }
        catch StatisticsGraphExportFailure.unavailable { }
        precondition(!FileManager.default.fileExists(atPath: refused.path))
        model.selectMetric(.commitsByDate); precondition(model.canExportGraph)
        model.graphSize = CGSize(width: 640, height: 360)
        for dark in [false, true] {
            controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for style in LogStatisticsStyle.allCases {
                model.style = style
                for format in StatisticsGraphFormat.allCases {
                    let file = root.appendingPathComponent("graph-\(dark ? "dark" : "light")-\(style.rawValue).\(format.fileExtension)")
                    try controller.exportGraph(to: file, format: format)
                    let data = try Data(contentsOf: file)
                    if format == .pdf {
                        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { preconditionFailure("Invalid PDF") }
                        precondition(document.pageCount == 1 && page.bounds(for: .mediaBox).width == 640)
                        precondition(document.string?.contains("Statistics QA") == true, "PDF lost graph labels")
                    } else {
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { preconditionFailure("Invalid raster") }
                        precondition(CGImageSourceGetType(source) as String? == format.contentType.identifier && image.width == 640 && image.height >= 360)
                        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                        let colorful = bytes.withUnsafeMutableBytes { buffer -> Int in
                            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                            let pixels = buffer.bindMemory(to: UInt8.self)
                            return stride(from: 0, to: pixels.count, by: 4).filter { max(pixels[$0], pixels[$0+1], pixels[$0+2]) - min(pixels[$0], pixels[$0+1], pixels[$0+2]) > 30 }.count
                        }
                        precondition(colorful > 50, "Raster lost graph colors")
                    }
                    if let path = ProcessInfo.processInfo.environment["TURTLEGIT_STATISTICS_EXPORT_QA_DIR"] {
                        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try data.write(to: directory.appendingPathComponent(file.lastPathComponent))
                    }
                }
            }
        }
        for metric in LogStatisticsMetric.allCases where metric != .statistics {
            model.selectMetric(metric); precondition(!model.busy && model.graph != nil)
            model.style = .bar
            let file = root.appendingPathComponent("labels-\(metric.rawValue).pdf")
            try controller.exportGraph(to: file, format: .pdf)
            let document = PDFDocument(url: file)!
            let rendered = document.string!.filter { !$0.isWhitespace }
            for label in [metric.title, model.graph!.xAxisLabel, model.graph!.yAxisLabel] {
                precondition(rendered.contains(label.filter { !$0.isWhitespace }), "PDF lost graph title/axis label: " + label)
            }
            if let path = ProcessInfo.processInfo.environment["TURTLEGIT_STATISTICS_EXPORT_QA_DIR"] {
                try Data(contentsOf: file).write(to: URL(fileURLWithPath: path).appendingPathComponent(file.lastPathComponent))
            }
        }
        model.selectMetric(.commitsByDate)
        let sample = [
            LogEntry(hash: "a", author: "Ada", date: "2024-01-01T12:00:00Z", subject: "", committerDate: "2024-01-01T12:00:00Z"),
            LogEntry(hash: "b", author: "Linus", date: "2024-01-03T12:00:00Z", subject: "", committerDate: "2024-01-03T12:00:00Z"),
            LogEntry(hash: "c", author: "Ada", date: "2024-01-04T12:00:00Z", subject: "", committerDate: "2024-01-04T12:00:00Z")
        ]
        let summary = try LogStatistics.analyze(sample)
        let multiple = try LogStatisticsGraph.make(summary, metric: .commitsByDate, authorsShown: 2)
        for style in LogStatisticsStyle.allCases {
            let data = try StatisticsGraphExport.data(graph: multiple, metric: .commitsByDate, style: style, size: CGSize(width: 640, height: 360), dark: false, format: .pdf)
            let document = PDFDocument(data: data)!
            for label in multiple.categoryLabels + multiple.seriesLabels { precondition(document.string?.contains(label) == true, "Export lost a date group/author") }
            if style == .pie { precondition(document.page(at: 0)!.bounds(for: .mediaBox).height > 720) }
            if let path = ProcessInfo.processInfo.environment["TURTLEGIT_STATISTICS_EXPORT_QA_DIR"] {
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("multi-date-\(style.rawValue).pdf"))
            }
        }
        let authors = try LogStatisticsGraph.make(summary, metric: .commitsByAuthor, authorsShown: 2)
        for style in [LogStatisticsStyle.bar, .pie] {
            let data = try StatisticsGraphExport.data(graph: authors, metric: .commitsByAuthor, style: style, size: CGSize(width: 640, height: 360), dark: true, format: .pdf)
            let document = PDFDocument(data: data)!
            precondition(document.string!.contains("Ada") && document.string!.contains("Linus"))
        }
        let empty = try LogStatisticsGraph.make(LogStatistics.analyze([]), metric: .commitsByDate, authorsShown: 1)
        let emptyData = try StatisticsGraphExport.data(graph: empty, metric: .commitsByDate, style: .bar, size: CGSize(width: 640, height: 360), dark: false, format: .pdf)
        precondition(PDFDocument(data: emptyData)?.string?.contains("No graph data available.") == true)
        // Invalid canvas and unavailable graphs must fail before writing output.
        do { _ = try StatisticsGraphExport.data(graph: model.graph!, metric: .commitsByDate, style: .bar, size: CGSize(width: CGFloat.infinity, height: 360), dark: false, format: .png); preconditionFailure("Invalid size accepted") }
        catch StatisticsGraphExportFailure.invalidSize { }
        let unwritable = root.appendingPathComponent("missing/graph.png")
        do { try controller.exportGraph(to: unwritable, format: .png); preconditionFailure("Write failure swallowed") } catch { }
        model.busy = true; precondition(!model.canExportGraph); model.busy = false
        print("Statistics export: five actual encodings × five styles × light/dark decoded; PDF labels, raster colors, multi-author/date-group/empty content, all metric titles/axis labels, summary/busy refusal and write failure passed")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Statistics QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        try Data("one\nthree\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "change")
        let entries = try await repo.history()
        let paths = [".git/index", ".git/config", ".git/HEAD", "file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Statistics.QA." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let controller = StatisticsWindowController(repository: repo, access: nil, entries: entries, defaults: isolated)
        defer { controller.close() }
        let model = controller.model
        precondition(model.metric == .statistics && model.options == LogStatisticsOptions() && model.summary?.totalCommits == 2)
        model.selectMetric(.commitsByDate); precondition(model.graph?.points.reduce(0) { $0 + $1.value } == 2)
        model.selectMetric(.linesIncluding); try await wait(model)
        precondition(model.error == nil && model.summary?.changesCalculated == true && model.summary?.totalChanges.files == 2)
        precondition(model.graph?.points.reduce(0) { $0 + $1.value } == 4)
        model.selectMetric(.commitsByDate)
        for style in LogStatisticsStyle.allCases { model.style = style; controller.window?.contentView?.layoutSubtreeIfNeeded(); await Task.yield() }
        try verifyExport(controller, root: root)
        model.selectMetric(.authorship); precondition(model.graph?.points.map(\.value) == [100])
        model.options.useCommitterNames = true; model.options.caseSensitive = false; model.rebuild(resetAuthors: true)
        model.style = .pie
        var closed = false; controller.onClosed = { closed = true }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        precondition(controller.window!.performKeyEquivalent(with: escape) && closed)
        let restored = StatisticsWindowModel(repository: repo, access: nil, entries: entries, defaults: isolated)
        precondition(restored.metric == .authorship && restored.style == .pie && restored.options.useCommitterNames && !restored.options.caseSensitive)
        restored.start(); restored.cancel(); try await wait(restored)
        precondition(restored.error != nil && restored.summary?.changesCalculated == false)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native Statistics: defaults, snapshot graphs, actual lazy diff totals, automatic calculation, preference restoration, cancellation and unchanged repository passed")
    }
}
