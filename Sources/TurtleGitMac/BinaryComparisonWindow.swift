// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

enum NotebookComparisonFailure: LocalizedError {
    case application
    var errorDescription: String? { "No application can open the generated Mathematica notebook. Install Mathematica or choose another diff tool for .nb files in Settings." }
}
@MainActor final class BinaryComparisonWindowController: NSWindowController, NSWindowDelegate {
    let report: BinaryComparisonReport
    var onClosed: () -> Void = {}
    private var closed = false
    init(report: BinaryComparisonReport) {
        self.report = report
        let window = NSWindow(contentRect: .init(x:0,y:0,width:620,height:350),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "File Comparison – " + (report.identical ? "Identical" : "Differs") + " – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = .init(width:420,height:240)
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView: BinaryComparisonDialog(report:report,close:{ [weak self] in self?.close() }))
        window.center()
    }
    func windowWillClose(_ notification: Notification) { guard !closed else { return }; closed = true; onClosed() }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
}
private struct BinaryComparisonDialog: View {
    let report: BinaryComparisonReport
    let close: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top,spacing:16) {
                Image(systemName:report.identical ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size:32)).foregroundStyle(report.identical ? Color.blue : .yellow).accessibilityHidden(true)
                ScrollView { Text(report.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.accessibilityLabel("Binary file comparison result")
            }
            HStack { Spacer(); Button("OK",action:close).keyboardShortcut(.defaultAction) }
        }.padding(20).onExitCommand(perform:close)
    }
}
