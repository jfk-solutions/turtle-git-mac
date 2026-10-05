import AppKit

/// Native counterpart of TortoiseUDiff MainWindow.cpp ID_FILE_PRINT.
/// An independent attributed snapshot keeps pagination/selection out of the editor.
@MainActor final class PatchPrintSession: NSObject {
    private let text: NSTextView
    private let operation: NSPrintOperation
    private let completion: () -> Void
    init(snapshot: NSAttributedString, selection: NSRange, title: String, completion: @escaping () -> Void) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        let width = max(1, info.paperSize.width - info.leftMargin - info.rightMargin)
        text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        text.isEditable = false; text.isSelectable = false
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.minSize = NSSize(width: width, height: 1)
        text.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = .zero
        operation = NSPrintOperation(view: text, printInfo: info)
        operation.jobTitle = title
        // The delegate resets the main-actor viewer state after the sheet/operation.
        operation.canSpawnSeparateThread = false
        self.completion = completion
        super.init()
        let options = PatchPrintOptions(snapshot: snapshot, selection: selection, text: text)
        operation.printPanel.addAccessoryController(options)
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
    }
    func run(for window: NSWindow) {
        operation.runModal(for: window, delegate: self, didRun: #selector(finished(_:success:contextInfo:)), contextInfo: nil)
    }
    @objc private func finished(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { completion() }
}

@MainActor private final class PatchPrintOptions: NSViewController, NSPrintPanelAccessorizing {
    private let snapshot: NSAttributedString
    private let selection: NSRange
    private let text: NSTextView
    @objc dynamic var selectionOnly: Bool {
        willSet { willChangeValue(forKey: "localizedSummaryItems") }
        didSet { updateDocument(); didChangeValue(forKey: "localizedSummaryItems") }
    }
    init(snapshot: NSAttributedString, selection: NSRange, text: NSTextView) {
        self.snapshot = NSAttributedString(attributedString: snapshot)
        self.selection = NSIntersectionRange(selection, NSRange(location: 0, length: snapshot.length))
        self.text = text
        selectionOnly = self.selection.length > 0
        super.init(nibName: nil, bundle: nil)
        title = "Unified Diff"
        updateDocument()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        let checkbox = NSButton(checkboxWithTitle: "Print selected text only", target: self, action: #selector(changeSelection(_:)))
        checkbox.frame = NSRect(x: 12, y: 16, width: 255, height: 22)
        checkbox.state = selectionOnly ? .on : .off; checkbox.isEnabled = selection.length > 0
        view.addSubview(checkbox); self.view = view
    }
    @objc private func changeSelection(_ sender: NSButton) { selectionOnly = sender.state == .on }
    private func updateDocument() {
        text.textStorage?.setAttributedString(selectionOnly ? snapshot.attributedSubstring(from: selection) : snapshot)
        text.sizeToFit()
    }
    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Content", .itemDescription: selectionOnly ? "Selected text" : "Whole diff"]]
    }
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["selectionOnly"] }
}
