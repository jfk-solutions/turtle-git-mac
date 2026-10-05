import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class CompletionChoicesModel: ObservableObject {
    @Published var candidates: [String] = []
    @Published var selected = 0
    @Published var width: CGFloat = 420
}

@MainActor final class CommitCompletionPopup {
    private let state = CompletionChoicesModel()
    var accept: (String) -> Void = { _ in }
    private let popover = NSPopover()
    var isShown: Bool { popover.isShown }
    init() { popover.behavior = .semitransient; popover.animates = false }
    func show(_ values: [String], in editor: NSTextView) {
        guard editor.window != nil else { return }
        let prior = state.candidates.indices.contains(state.selected) ? state.candidates[state.selected] : nil
        state.candidates = values; state.selected = prior.flatMap { value in values.firstIndex { $0.utf16.elementsEqual(value.utf16) } } ?? 0
        let textWidth = values.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width }.max() ?? 0
        state.width = min(600, max(160, ceil(textWidth + 36)))
        let size = NSSize(width: state.width, height: min(220, CGFloat(values.count) * 26 + 8))
        if popover.contentViewController == nil { popover.contentViewController = NSHostingController(rootView: CompletionChoices(model: state) { [weak self] index in self?.state.selected = index; self?.choose() }) }
        popover.contentSize = size
        guard let layout = editor.layoutManager, let container = editor.textContainer, !editor.string.isEmpty else { return }
        layout.ensureLayout(for: container)
        let length = (editor.string as NSString).length, position = editor.selectedRange().location
        let glyph = layout.glyphIndexForCharacter(at: min(position, length - 1))
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = editor.textContainerOrigin
        let caret = NSRect(x: (position == length ? bounds.maxX : bounds.minX) + origin.x, y: line.minY + origin.y, width: 1, height: line.height)
        if !popover.isShown { popover.show(relativeTo: caret, of: editor, preferredEdge: .maxY) }
    }
    func move(_ delta: Int) { state.selected = min(max(0, state.selected + delta), max(0, state.candidates.count - 1)) }
    func choose() {
        guard state.candidates.indices.contains(state.selected) else { return }
        let value = state.candidates[state.selected]; close(); accept(value)
    }
    func close() { popover.close() }
}

private struct CompletionChoices: View {
    @ObservedObject var model: CompletionChoicesModel
    let choose: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.candidates.indices, id: \.self) { index in
                        Button {
                            choose(index)
                        } label: {
                            HStack(spacing: 6) {
                                if let icon = MenuIcon.completionFile.image() { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                Text(verbatim: model.candidates[index]).lineLimit(1).truncationMode(.middle).help(model.candidates[index])
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 6).frame(height: 26)
                                .background(model.selected == index ? Color.accentColor.opacity(0.22) : Color.clear)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Complete " + model.candidates[index]).id(index)
                    }
                }.padding(.vertical, 4)
            }.onChange(of: model.selected) { proxy.scrollTo($0) }
        }.frame(width: model.width)
    }
}
