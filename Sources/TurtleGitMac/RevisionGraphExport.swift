// SaveGraphAs, SVG and Graphviz adapted from pinned TortoiseGit.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers
import TurtleGitCore

enum RevisionGraphFormat: String, CaseIterable {
    case svg, graphviz, png, jpeg, bmp, gif, pdf
    var title: String { self == .graphviz ? "Graphviz" : rawValue.uppercased() }
    var fileExtension: String { self == .graphviz ? "gv" : self == .jpeg ? "jpg" : rawValue }
    var contentType: UTType {
        switch self { case .svg: return .svg; case .graphviz: return UTType(filenameExtension: "gv", conformingTo: .plainText)!; case .png: return .png; case .jpeg: return .jpeg; case .bmp: return .bmp; case .gif: return .gif; case .pdf: return .pdf }
    }
    var vector: Bool { self == .svg || self == .graphviz || self == .pdf }
}

enum RevisionGraphExportFailure: LocalizedError {
    case unavailable, size, rendering, encoding
    var errorDescription: String? {
        switch self { case .unavailable: return "Load a revision graph before saving it."; case .size: return "The graph is too large to export at this zoom. Choose a smaller zoom or a vector format."; case .rendering: return "The revision graph could not be rendered."; case .encoding: return "The revision graph could not be encoded in the selected format." }
    }
}

@MainActor enum RevisionGraphExport {
    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static var fontName: String {
        let family = RevisionGraphWindowModel.font.familyName ?? "Helvetica"
        // AppKit's private .AppleSystemUIFont name is not a portable SVG/DOT font.
        return family.hasPrefix(".") ? "Helvetica" : family
    }
    static func number(_ value: CGFloat) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    static func color(_ value: NSColor) -> String {
        let rgb = value.usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func size(canvas: RevisionGraphCanvas, viewport: CGSize, format: RevisionGraphFormat) throws -> CGSize {
        guard !canvas.model.busy, !canvas.model.closed, let graph = canvas.model.geometry, !canvas.model.nodes.isEmpty else { throw RevisionGraphExportFailure.unavailable }
        let zoom = format.vector ? CGFloat(1) : canvas.model.zoom
        let result = CGSize(width: ceil(graph.size.width * zoom + 20), height: ceil(graph.size.height * zoom + 20))
        return format.vector ? CGSize(width: max(result.width, viewport.width), height: max(result.height, viewport.height)) : result
    }
    static func data(canvas: RevisionGraphCanvas, viewport: CGSize, format: RevisionGraphFormat, appearance: NSAppearance) throws -> Data {
        let dimensions = try size(canvas: canvas, viewport: viewport, format: format)
        guard dimensions.width.isFinite, dimensions.height.isFinite, dimensions.width >= 1, dimensions.height >= 1 else { throw RevisionGraphExportFailure.size }
        var result: Data?
        var failure: Error?
        appearance.performAsCurrentDrawingAppearance {
            do {
            switch format {
            case .svg: result = Data(svg(canvas: canvas, size: dimensions).utf8)
            case .graphviz: result = Data(graphviz(canvas: canvas).utf8)
            default:
                let output = NSMutableData(), zoom = format.vector ? CGFloat(1) : canvas.model.zoom
                let context: CGContext
                if format == .pdf {
                    var box = CGRect(origin: .zero, size: dimensions)
                    guard let consumer = CGDataConsumer(data: output), let pdf = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Revision Graph", kCGPDFContextCreator: "TurtleGit for Mac"] as CFDictionary) else { throw RevisionGraphExportFailure.rendering }
                    context = pdf; context.beginPDFPage(nil)
                } else {
                    guard dimensions.width <= 16384, dimensions.height <= 16384, dimensions.width * dimensions.height <= 32_000_000 else { throw RevisionGraphExportFailure.size }
                    guard let bitmap = CGContext(data: nil, width: Int(dimensions.width), height: Int(dimensions.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RevisionGraphExportFailure.rendering }
                    context = bitmap
                }
                context.translateBy(x: 0, y: dimensions.height); context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                NSColor.textBackgroundColor.setFill(); CGRect(origin: .zero, size: dimensions).fill()
                context.translateBy(x: 10, y: 10); context.scaleBy(x: zoom, y: zoom)
                canvas.drawGraph(text: true, renderingZoom: zoom)
                NSGraphicsContext.restoreGraphicsState()
                if format == .pdf { context.endPDFPage(); context.closePDF() }
                else {
                    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, format.contentType.identifier as CFString, 1, nil) else { throw RevisionGraphExportFailure.encoding }
                    CGImageDestinationAddImage(destination, image, format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
                    guard CGImageDestinationFinalize(destination) else { throw RevisionGraphExportFailure.encoding }
                }
                result = output as Data
            }
            } catch { failure = error }
        }
        if let failure { throw failure }
        guard let result else { throw RevisionGraphExportFailure.rendering }; return result
    }
    private static func svg(canvas: RevisionGraphCanvas, size: CGSize) -> String {
        let model = canvas.model, graph = model.geometry!
        var parts = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(size.width))\" height=\"\(number(size.height))\" viewBox=\"0 0 \(number(size.width)) \(number(size.height))\">", "<rect width=\"100%\" height=\"100%\" fill=\"\(color(.textBackgroundColor))\"/>", "<g transform=\"translate(10 10)\">"]
        for edge in graph.edges {
            let points = model.arrowsTowardMerges ? Array(edge.points.reversed()) : edge.points
            let coordinates = points.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: " ")
            parts.append("<polyline points=\"\(coordinates)\" fill=\"none\" stroke=\"\(color(.labelColor))\" stroke-width=\"2\"/>")
            if points.count >= 2, let end = points.last {
                let before = points[points.count - 2], angle = atan2(end.y - before.y, end.x - before.x)
                let a = CGPoint(x: end.x - 8 * cos(angle - .pi/8), y: end.y - 8 * sin(angle - .pi/8)), b = CGPoint(x: end.x - 8 * cos(angle + .pi/8), y: end.y - 8 * sin(angle + .pi/8))
                parts.append("<polyline points=\"\(number(a.x)),\(number(a.y)) \(number(end.x)),\(number(end.y)) \(number(b.x)),\(number(b.y))\" fill=\"none\" stroke=\"\(color(.labelColor))\" stroke-width=\"2\"/>")
            }
        }
        let nodes = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.hash, $0) })
        for (index, geometry) in graph.nodes.enumerated() {
            guard let node = nodes[geometry.hash] else { continue }
            let rect = geometry.rect, labels = model.lines(node), height = rect.height / CGFloat(labels.count)
            let shape = "x=\"\(number(rect.minX))\" y=\"\(number(rect.minY))\" width=\"\(number(rect.width))\" height=\"\(number(rect.height))\" rx=\"6\""
            parts.append("<defs><clipPath id=\"node\(index)\"><rect \(shape)/></clipPath></defs><g clip-path=\"url(#node\(index))\">")
            for (line, label) in labels.enumerated() {
                let background = RevisionGraphPalette.background(label.1, pointer: label.0 == "super-project-pointer", preferences: model.preferences)
                let y = rect.minY + CGFloat(line) * height
                parts.append("<rect x=\"\(number(rect.minX))\" y=\"\(number(y))\" width=\"\(number(rect.width))\" height=\"\(number(height))\" fill=\"\(color(background))\"/>")
                parts.append("<text x=\"\(number(rect.minX + 20))\" y=\"\(number(y + 5 + 12))\" font-family=\"\(xml(fontName))\" font-size=\"12\" fill=\"\(color(RevisionGraphPalette.foreground(background)))\">\(xml(label.0))</text>")
            }
            parts.append("</g>")
            if let selection = model.selection.firstIndex(of: node.hash) {
                let stroke = selection == 0 ? color(.selectedControlColor) : "#880015"
                parts.append("<rect \(shape) fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"4\"/>")
            }
        }
        parts.append("</g></svg>"); return parts.joined(separator: "\n")
    }
    private static func graphviz(canvas: RevisionGraphCanvas) -> String {
        let model = canvas.model
        var parts = ["digraph G {", "graph [rankdir=BT];", "node [style=\"filled, rounded\", shape=box, fontname=\"\(fontName)\", fontsize=12, height=0.26, penwidth=0];"]
        // Full hashes avoid the upstream abbreviated-ID collision while preserving
        // parent-to-child edges, BT orientation and colored reference-table rows.
        for edge in model.geometry!.edges { parts.append("g\(edge.targetHash) -> g\(edge.sourceHash);") }
        for node in model.nodes {
            parts.append("g\(node.hash) [color=transparent, label=<<table border=\"0\" cellborder=\"0\" cellpadding=\"5\">")
            for (index, label) in model.lines(node).enumerated() {
                let background = RevisionGraphPalette.background(label.1, pointer: label.0 == "super-project-pointer", preferences: model.preferences)
                parts.append("<tr><td port=\"f\(index)\" bgcolor=\"\(color(background))\"><font color=\"\(color(RevisionGraphPalette.foreground(background)))\">\(xml(label.0))</font></td></tr>")
            }
            parts.append("</table>>];")
        }
        parts.append("}"); return parts.joined(separator: "\n")
    }
}

@MainActor final class RevisionGraphSavePanel: NSObject {
    let panel = NSSavePanel()
    let formats = NSPopUpButton(frame: CGRect(x: 72, y: 0, width: 160, height: 26))
    var format: RevisionGraphFormat { RevisionGraphFormat.allCases[formats.indexOfSelectedItem] }
    override init() {
        super.init(); panel.title = "Save Graph As"; panel.nameFieldStringValue = "Revision Graph.svg"
        panel.allowedContentTypes = [.svg]; panel.allowsOtherFileTypes = false; panel.canCreateDirectories = true
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 232, height: 26)), label = NSTextField(labelWithString: "Format:")
        label.frame = CGRect(x: 0, y: 4, width: 66, height: 18)
        formats.addItems(withTitles: RevisionGraphFormat.allCases.map(\.title)); formats.target = self; formats.action = #selector(changeFormat)
        accessory.addSubview(label); accessory.addSubview(formats); panel.accessoryView = accessory
    }
    @objc func changeFormat() {
        panel.allowedContentTypes = [format.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (base.isEmpty ? "Revision Graph" : base) + "." + format.fileExtension
    }
}
