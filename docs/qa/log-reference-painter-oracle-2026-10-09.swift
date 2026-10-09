import AppKit
import Foundation
import TurtleGitCore

@main struct ReferencePainterOracle {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        checkDrawing()
        let rows = try JSONDecoder().decode([[Int]].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let result = rows.map { row -> [Int] in
            let rect = CGRect(x: row[0], y: row[1], width: row[2]-row[0], height: row[3]-row[1])
            let rounded = LogReferenceDrawing.geometry(rect, tracking: true, pointed: false)
            func bounds(_ value: CGRect) -> [Int] { [Int(value.minX), Int(value.minY), Int(value.maxX), Int(value.maxY)] }
            let tag = LogReferenceDrawing.geometry(CGRect(x: rect.minX, y: rect.minY, width: rect.width+8, height: rect.height), tracking: false, pointed: true)
            return bounds(rounded.shadow!) + bounds(rounded.interior)
                + LogReferenceDrawing.mix(Array(row[4...6]), toward: row[7], amount: row[8])
                + tag.tip.flatMap { [Int($0.x), Int($0.y)] }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }
    @MainActor static func checkDrawing() {
        let color = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.35, green: 0.45, blue: 0.2, alpha: 1) : NSColor(srgbRed: 0.9, green: 0.7, blue: 0.1, alpha: 1)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                for (tracking, pointed) in [(false, false), (true, false), (false, true)] {
                    var label = HistoryReferenceLabel(reference: RevisionReference(name: pointed ? "refs/tags/label" : "refs/heads/label", kind: pointed ? .annotatedTag : .localBranch))
                    label.hasTracking = tracking
                    let style = LogReferenceStyle(label, color: color)
                    let font = NSFont.systemFont(ofSize: 13)
                    let text = NSMutableAttributedString(string: "    label    ", attributes: [.font: font, .foregroundColor: NSColor.black, .backgroundColor: color, .logReference: style])
                    if pointed { text.addAttribute(.kern, value: 8, range: NSRange(location: text.length-1, length: 1)) }
                    let cell = LogReferenceTextCell(textCell: ""); cell.attributedStringValue = text
                    let field = NSTextField(labelWithString: ""); field.cell = cell
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                    context.cgContext.clear(CGRect(x: 0, y: 0, width: 300, height: 30))
                    cell.drawInterior(withFrame: CGRect(x: 0, y: 0, width: 300, height: 30), in: field)
                    precondition(cell.badgeFrames.count == 1)
                    let frame = cell.badgeFrames[0], expected = color.usingColorSpace(.sRGB)!
                    let interior = bitmap.colorAt(x: 3, y: 15)!.usingColorSpace(.sRGB)!
                    precondition(interior.alphaComponent > 0.99)
                    for (got, wanted) in zip([interior.redComponent, interior.greenComponent, interior.blueComponent], [expected.redComponent, expected.greenComponent, expected.blueComponent]) { precondition(abs(got-wanted) < 0.025) }
                    if tracking { precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0) }
                    else { precondition(bitmap.colorAt(x: 0, y: 15)!.alphaComponent > 0.99) }
                    if pointed {
                        let shape = LogReferenceDrawing.geometry(frame.rect, tracking: false, pointed: true)
                        let x = Int(shape.body.maxX) + 4
                        precondition(bitmap.colorAt(x: x, y: 15)!.alphaComponent > 0.99)
                        precondition(bitmap.colorAt(x: x, y: 1)!.alphaComponent == 0)
                    }
                }
            }
        }
        // No image is exported: these are numerical, in-memory renderer checks.
    }
}
