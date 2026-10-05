#!/usr/bin/env python3
"""Verify native print snapshots and PDF pagination without opening the app/print UI."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / 'Sources/TurtleGitCore/UnifiedDiffPrintMargins.swift').read_text() + (root / 'Sources/TurtleGitMac/PatchPrinting.swift').read_text().replace('import TurtleGitCore\n', '')
driver = r'''
import PDFKit

extension PatchPrintSession {
    func savePDF(_ url: URL) -> PDFDocument {
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        precondition(operation.run(), "PDF print operation failed")
        return PDFDocument(url: url)!
    }
    func chooseWholeDiff() {
        let options = operation.printPanel.accessoryControllers.first as! PatchPrintOptions
        options.selectionOnly = false
    }
    var printText: String { text.string }
}

@MainActor func verify() {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let contents = "FIRST_MARKER\n" + (0..<300).map { "+ line \($0)\tPDF pagination test" }.joined(separator: "\n") + "\nLAST_MARKER\n"
    let snapshot = NSMutableAttributedString(string: contents, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.black])
    let original = NSAttributedString(attributedString: snapshot)
    let selection = (contents as NSString).range(of: "+ line 150\tPDF pagination test")
    let session = try! PatchPrintSession(snapshot: snapshot, selection: selection, title: "Print QA") { }
    // Changing the editor's source after invoking Print cannot change its snapshot.
    snapshot.mutableString.setString("MUTATED_EDITOR")
    precondition(session.printText == original.attributedSubstring(from: selection).string)
    let selected = session.savePDF(folder.appendingPathComponent("selection.pdf"))
    precondition(selected.pageCount == 1)
    let selectionText = selected.string ?? ""
    precondition(selectionText.contains("line 150") && !selectionText.contains("FIRST_MARKER") && !selectionText.contains("LAST_MARKER"))
    session.chooseWholeDiff()
    precondition(session.printText == contents)
    let wholeSession = try! PatchPrintSession(snapshot: original, selection: selection, title: "Whole diff") { }
    wholeSession.chooseWholeDiff()
    let whole = wholeSession.savePDF(folder.appendingPathComponent("whole.pdf"))
    precondition(whole.pageCount > 1, "Long diff should paginate")
    let wholeText = whole.string ?? ""
    precondition(wholeText.contains("FIRST_MARKER") && wholeText.contains("LAST_MARKER") && !wholeText.contains("MUTATED_EDITOR"))
    var margins = UnifiedDiffPrintMargins(); margins.top = 240; margins.bottom = 240
    let inset = try! PatchPrintSession(snapshot: original, selection: NSRange(location: 0, length: 0), title: "Margin QA", margins: margins) { }
    let insetPDF = inset.savePDF(folder.appendingPathComponent("margins.pdf"))
    precondition(insetPDF.pageCount > whole.pageCount, "Larger saved margins must reduce the printable height")
    precondition(insetPDF.string?.contains("FIRST_MARKER") == true && insetPDF.string?.contains("LAST_MARKER") == true)
    var invalid = margins; invalid.left = 10000
    do {
        _ = try PatchPrintSession(snapshot: original, selection: NSRange(location: 0, length: 0), title: "Invalid", margins: invalid) { }
        preconditionFailure("Impossible printable area must fail before showing a sheet")
    } catch { }
    print("Margin PDF: \(insetPDF.pageCount) pages; valid margins affect pagination; impossible area rejected.")
    let unselected = try! PatchPrintSession(snapshot: original, selection: NSRange(location: 0, length: 0), title: "All") { }
    precondition(unselected.printText == contents)
    print("Print snapshots: selected PDF 1 page; whole PDF \(whole.pageCount) pages; first/last text and isolated immutable source verified.")
}
verify()
'''
with tempfile.TemporaryDirectory(prefix='turtlegit-print-qa-') as directory:
    folder = pathlib.Path(directory)
    swift = folder / 'main.swift'
    swift.write_text(source + driver)
    binary = folder / 'print-qa'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(swift), '-framework', 'AppKit', '-framework', 'PDFKit', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True, timeout=60)
