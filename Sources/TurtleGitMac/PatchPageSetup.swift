import AppKit
import SwiftUI
import TurtleGitCore

struct PatchPageSetup: View {
    let model: PatchWindowModel
    private let unit: UnifiedDiffMarginUnit
    @State private var left: String
    @State private var top: String
    @State private var right: String
    @State private var bottom: String
    init(model: PatchWindowModel) {
        self.model = model
        let unit: UnifiedDiffMarginUnit = Locale.current.usesMetricSystem ? .millimeters : .inches
        self.unit = unit
        let margins = UnifiedDiffPrintMargins.load()
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false; formatter.maximumFractionDigits = unit == .millimeters ? 2 : 3
        func field(_ points: Double) -> String { formatter.string(from: NSNumber(value: points / unit.pointsPerUnit)) ?? "" }
        _left = State(initialValue: field(margins.left)); _top = State(initialValue: field(margins.top))
        _right = State(initialValue: field(margins.right)); _bottom = State(initialValue: field(margins.bottom))
    }
    private var margins: UnifiedDiffPrintMargins? {
        func points(_ field: String) -> Double? {
            Double(field.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")).map { $0 * unit.pointsPerUnit }
        }
        guard let l = points(left), let t = points(top), let r = points(right), let b = points(bottom) else { return nil }
        var margins = UnifiedDiffPrintMargins(); margins.left = l; margins.top = t; margins.right = r; margins.bottom = b
        let paper = NSPrintInfo.shared.paperSize
        return margins.fits(width: paper.width, height: paper.height) ? margins : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Page Setup").font(.headline)
            GroupBox("Margins (\(unit.label))") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow { Text("Left:"); TextField("Left margin", text: $left); Text("Right:"); TextField("Right margin", text: $right) }
                    GridRow { Text("Top:"); TextField("Top margin", text: $top); Text("Bottom:"); TextField("Bottom margin", text: $bottom) }
                }.padding(12)
            }
            Text("Paper size and orientation are selected in the Print dialog. Printer minimum margins also apply.").font(.caption).foregroundStyle(.secondary)
            if margins == nil { Text("Enter nonnegative margins that leave a printable area on the current paper.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { model.showPageSetup = false }.keyboardShortcut(.cancelAction)
                Button("OK") { guard let margins, margins.save() else { return }; model.showPageSetup = false }
                    .keyboardShortcut(.defaultAction).disabled(margins == nil)
            }
        }.padding(20).frame(width: 460)
    }
}
