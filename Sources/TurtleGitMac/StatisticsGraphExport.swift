import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TurtleGitCore

/// PDF replaces the upstream Windows enhanced-metafile export. Raster formats
/// retain their original encodings; extensions never disguise another format.
enum StatisticsGraphFormat: String, CaseIterable {
    case pdf, png, jpeg, bmp, gif
    var title: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var contentType: UTType {
        switch self { case .pdf: return .pdf; case .png: return .png; case .jpeg: return .jpeg; case .bmp: return .bmp; case .gif: return .gif }
    }
}

enum StatisticsGraphExportFailure: LocalizedError {
    case unavailable, invalidSize, rendering, encoding
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Select a graph before saving statistics."
        case .invalidSize: return "The graph is too large to export at this size."
        case .rendering: return "The statistics graph could not be rendered."
        case .encoding: return "The statistics graph could not be encoded in the selected format."
        }
    }
}

@MainActor enum StatisticsGraphExport {
    static func data(graph: LogStatisticsGraph, metric: LogStatisticsMetric, style: LogStatisticsStyle, size: CGSize, dark: Bool, format: StatisticsGraphFormat) throws -> Data {
        guard metric != .statistics else { throw StatisticsGraphExportFailure.unavailable }
        guard validSize(size) else { throw StatisticsGraphExportFailure.invalidSize }
        let chart = StatisticsChart(graph: graph, style: style, byAuthor: metric.byAuthor, exporting: true)
        // Scroll containers are not ImageRenderer drawing primitives. Measure the
        // shared pie content intrinsically, including wrapped legends and every
        // date group; preserve the current viewport dimensions for other styles.
        let content: AnyView
        if style == .pie { content = AnyView(chart.frame(width: size.width).fixedSize(horizontal: false, vertical: true).frame(minHeight: size.height)) }
        else { content = AnyView(chart.frame(width: size.width, height: size.height)) }
        let renderer = ImageRenderer(content: content
            .background(dark ? Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1)) : .white)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: style == .pie ? nil : size.height)
        renderer.scale = 1; renderer.isOpaque = true
        var canvasSize = CGSize.zero
        renderer.render { measured, _ in canvasSize = measured }
        guard validSize(canvasSize) else { throw StatisticsGraphExportFailure.invalidSize }
        let output = NSMutableData()
        if format == .pdf {
            var box = CGRect(origin: .zero, size: canvasSize)
            guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: metric.title, kCGPDFContextCreator: "TurtleGit for Mac"] as CFDictionary) else { throw StatisticsGraphExportFailure.rendering }
            var rendered = false
            renderer.render { _, draw in
                context.beginPDFPage(nil); draw(context); context.endPDFPage(); rendered = true
            }
            context.closePDF()
            guard rendered else { throw StatisticsGraphExportFailure.rendering }
        } else {
            guard let image = renderer.cgImage else { throw StatisticsGraphExportFailure.rendering }
            guard let destination = CGImageDestinationCreateWithData(output, format.contentType.identifier as CFString, 1, nil) else { throw StatisticsGraphExportFailure.encoding }
            CGImageDestinationAddImage(destination, image, format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
            guard CGImageDestinationFinalize(destination) else { throw StatisticsGraphExportFailure.encoding }
        }
        return output as Data
    }
    private static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1 && size.width <= 16384 && size.height <= 16384 && size.width * size.height <= 32_000_000
    }
}

@MainActor final class StatisticsGraphSavePanel: NSObject {
    let panel = NSSavePanel()
    private let formats = NSPopUpButton(frame: NSRect(x: 72, y: 0, width: 160, height: 26))
    var format: StatisticsGraphFormat { StatisticsGraphFormat.allCases[formats.indexOfSelectedItem] }
    override init() {
        super.init()
        panel.title = "Save Graph As"; panel.nameFieldStringValue = "statistics.pdf"; panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]; panel.allowsOtherFileTypes = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 26))
        let label = NSTextField(labelWithString: "Format:"); label.frame = NSRect(x: 0, y: 4, width: 66, height: 18)
        formats.addItems(withTitles: StatisticsGraphFormat.allCases.map(\.title)); formats.target = self; formats.action = #selector(changeFormat)
        accessory.addSubview(label); accessory.addSubview(formats); panel.accessoryView = accessory
    }
    @objc func changeFormat() {
        panel.allowedContentTypes = [format.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "statistics" : base) + "." + format.fileExtension
    }
}
