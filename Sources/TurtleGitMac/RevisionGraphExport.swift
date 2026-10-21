// SaveGraphAs, SVG and Graphviz adapted from pinned TortoiseGit.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers
import TurtleGitCore

extension RevisionGraphFormat {
    var title: String { self == .graphviz ? "Graphviz" : rawValue.uppercased() }
    var contentType: UTType {
        switch self { case .svg: return .svg; case .graphviz: return UTType(filenameExtension: "gv", conformingTo: .plainText)!; case .png: return .png; case .jpeg: return .jpeg; case .bmp: return .bmp; case .gif: return .gif; case .pdf: return .pdf; case .wmf, .emf: return UTType(filenameExtension: rawValue, conformingTo: .image) ?? .data }
    }
    var vector: Bool { self == .svg || self == .graphviz || self == .pdf || self == .wmf || self == .emf }
}

enum RevisionGraphExportFailure: LocalizedError {
    case unavailable, size, rendering, encoding, finalDestination
    var errorDescription: String? {
        switch self { case .finalDestination: return "Confirm the final export filename in the Save panel before saving."; case .unavailable: return "Load a revision graph before saving it."; case .size: return "The graph is too large to export at this zoom. Choose a smaller zoom or a vector format."; case .rendering: return "The revision graph could not be rendered."; case .encoding: return "The revision graph could not be encoded in the selected format." }
    }
}

@MainActor enum RevisionGraphExport {
    struct Snapshot {
        let vector: GraphVectorScene
        let raster: GraphVectorScene
        let graphviz: Data
        @MainActor func data(format: RevisionGraphFormat, cancellation: OperationCancellation? = nil) throws -> Data {
            try cancellation?.check()
            switch format {
            case .graphviz: return graphviz
            case .svg: return try MacGraphVectorRenderer.svg(vector)
            case .wmf, .emf: return try MacGraphVectorRenderer.emf(vector, cancellation: cancellation)
            case .pdf: return try MacGraphVectorRenderer.pdf(vector, title: "Revision Graph")
            default:
                let dimensions = raster.size
                guard dimensions.width <= 16384, dimensions.height <= 16384, dimensions.width * dimensions.height <= 32_000_000 else { throw RevisionGraphExportFailure.size }
                return try MacGraphVectorRenderer.raster(raster, type: format.contentType)
            }
        }
    }
    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func fontName(_ font: NSFont) -> String {
        let family = font.familyName ?? "Helvetica"
        // AppKit's private .AppleSystemUIFont name is not a portable SVG/DOT font.
        return family.hasPrefix(".") ? "Helvetica" : family
    }
    static func number(_ value: CGFloat) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
    static func color(_ value: NSColor) -> String {
        let rgb = value.usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func size(canvas: RevisionGraphCanvas, viewport: CGSize, format: RevisionGraphFormat) throws -> CGSize {
        guard !canvas.model.busy, !canvas.model.closed, !canvas.model.confirmingQuit, NSApp.modalWindow==nil, let graph = canvas.model.geometry, !canvas.model.nodes.isEmpty else { throw RevisionGraphExportFailure.unavailable }
        let zoom = format.vector ? CGFloat(1) : canvas.model.zoom
        let result = CGSize(width: ceil(graph.size.width * zoom + 20), height: ceil(graph.size.height * zoom + 20))
        return format.vector ? CGSize(width: max(result.width, viewport.width), height: max(result.height, viewport.height)) : result
    }
    static func data(canvas: RevisionGraphCanvas, viewport: CGSize, format: RevisionGraphFormat, appearance: NSAppearance) throws -> Data {
        try snapshot(canvas: canvas, viewport: viewport, appearance: appearance).data(format: format)
    }
    static func snapshot(canvas: RevisionGraphCanvas, viewport: CGSize, appearance: NSAppearance) throws -> Snapshot {
        let vectorSize = try size(canvas: canvas, viewport: viewport, format: .svg)
        let rasterSize = try size(canvas: canvas, viewport: viewport, format: .png)
        guard [vectorSize, rasterSize].allSatisfy({$0.width.isFinite && $0.height.isFinite && $0.width >= 1 && $0.height >= 1}) else { throw RevisionGraphExportFailure.size }
        var result: Snapshot?
        appearance.performAsCurrentDrawingAppearance {
            result = Snapshot(vector: RevisionGraphVectorScene.make(model: canvas.model, size: vectorSize, zoom: 1),
                raster: RevisionGraphVectorScene.make(model: canvas.model, size: rasterSize, zoom: canvas.model.zoom),
                graphviz: Data(graphviz(canvas: canvas).utf8))
        }
        guard let result else { throw RevisionGraphExportFailure.rendering }; return result
    }
    private static func graphviz(canvas: RevisionGraphCanvas) -> String {
        let model = canvas.model
        let fontName = fontName(model.font).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var parts = ["digraph G {", "graph [rankdir=BT];", "node [style=\"filled, rounded\", shape=box, fontname=\"\(fontName)\", fontsize=\(number(model.font.pointSize)), height=0.26, penwidth=0];"]
        // Full hashes avoid the upstream abbreviated-ID collision while preserving
        // parent-to-child edges, BT orientation and colored reference-table rows.
        for edge in model.geometry!.edges { parts.append("g\(edge.targetHash) -> g\(edge.sourceHash);") }
        for node in model.nodes {
            parts.append("g\(node.hash) [color=transparent, label=<<table border=\"0\" cellborder=\"0\" cellpadding=\"5\">")
            for (index, label) in model.lines(node).enumerated() {
                let background = RevisionGraphPalette.background(label.1, pointer: label.2, preferences: model.preferences)
                parts.append("<tr><td port=\"f\(index)\" bgcolor=\"\(color(background))\"><font color=\"\(color(RevisionGraphPalette.foreground(background)))\">\(xml(label.0))</font></td></tr>")
            }
            parts.append("</table>>];")
        }
        parts.append("}"); return parts.joined(separator: "\n")
    }
}

@MainActor final class RevisionGraphSavePanel: NSObject, NSOpenSavePanelDelegate {
    let panel=NSSavePanel()
    /// Keep the established native popup seam; these are source file filters,
    /// not encoder overrides. The final filename always chooses the encoder.
    let formats=NSPopUpButton(frame:CGRect(x:72,y:0,width:200,height:26))
    var filter:RevisionGraphExportFilter {RevisionGraphExportFilter.allCases[max(0,formats.indexOfSelectedItem)]}
    var format:RevisionGraphFormat {
        (try? RevisionGraphExportDestination(url:URL(fileURLWithPath:"/"+panel.nameFieldStringValue),filter:filter).format) ?? .svg
    }
    override init() {
        super.init();panel.title="Save Graph As";panel.nameFieldStringValue="Revision Graph.svg"
        panel.delegate=self;panel.allowsOtherFileTypes=true;panel.canCreateDirectories=true
        let accessory=NSView(frame:CGRect(x:0,y:0,width:272,height:26)),label=NSTextField(labelWithString:"Format:")
        label.frame=CGRect(x:0,y:4,width:66,height:18)
        formats.addItems(withTitles:["Pictures","Graphs","All Files"]);formats.target=self;formats.action=#selector(changeFormat)
        accessory.addSubview(label);accessory.addSubview(formats);panel.accessoryView=accessory;changeFormat()
    }
    @objc func changeFormat() {
        switch filter {
        case .pictures:panel.allowedContentTypes=[.svg,RevisionGraphFormat.wmf.contentType,RevisionGraphFormat.emf.contentType,.jpeg,.png,.bmp,.gif,.pdf]
        case .graphs:panel.allowedContentTypes=[RevisionGraphFormat.graphviz.contentType,UTType(filenameExtension:"dot",conformingTo:.plainText)!]
        case .allFiles:panel.allowedContentTypes=[]
        }
        // Source adds defaults only when accepting an extensionless filename.
        // Selecting another filter must not destroy a custom or known suffix.
    }
    func normalizedFilename(_ filename:String)throws->String {try RevisionGraphExportDestination.normalizedFilename(filename,filter:filter)}
    func panel(_ sender:Any,userEnteredFilename filename:String,confirmed okFlag:Bool)->String? {
        guard okFlag else{return filename}
        // Returning the final leaf here precedes AppKit's overwrite question
        // and security-scoped acceptance. Validation presents unsupported errors.
        return (try? normalizedFilename(filename)) ?? filename
    }
    func panel(_ sender:Any,validate url:URL)throws { _ = try destination(for:url) }
    func destination(for acceptedURL:URL)throws->RevisionGraphExportDestination {
        let result=try RevisionGraphExportDestination(url:acceptedURL,filter:filter)
        guard result.url.path.utf8.elementsEqual(acceptedURL.path.utf8) else{throw RevisionGraphExportFailure.finalDestination}
        return result
    }
    func retire() {panel.delegate=nil;formats.target=nil;formats.action=nil}
}
