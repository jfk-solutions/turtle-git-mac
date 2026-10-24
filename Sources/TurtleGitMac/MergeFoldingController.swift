import AppKit
import Combine
import TurtleGitCore

/// One controller belongs to a comparison window, rather than to individual
/// text views. All panes consume the same source-to-screen projection.
@MainActor final class MergeFoldingController: ObservableObject {
    @Published private(set) var collapsed: Bool
    @Published private(set) var projection = MergeFoldProjection(folding: MergeFolding(unchanged: []), collapsed: false)
    private(set) var folding = MergeFolding(unchanged: [])
    private let preferences: UserDefaults
    private var unchanged: [Bool] = []
    private var contextLines: Int
    private var retired = false
    private(set) var revision = 0
    var geometryChanged: () -> Void = {}
    var expanded: ([Range<Int>]) -> Void = { _ in }
    var actionsAllowed: () -> Bool = { true }

    init(preferences: UserDefaults = .standard, collapsedOverride: Bool? = nil) {
        self.preferences = preferences
        let settings = MergeFoldingPreferences.load(from: preferences)
        collapsed = collapsedOverride ?? settings.collapsed; contextLines = settings.contextLines
    }

    /// A changed alignment starts a fresh source hide map, as upstream Reload
    /// does. Identical hosting updates preserve manually expanded sections.
    func update(unchanged: [Bool], force: Bool = false) {
        guard !retired else { return }
        let context = MergeFoldingPreferences.load(from: preferences).contextLines
        guard force || self.unchanged != unchanged || context != contextLines else { return }
        self.unchanged = unchanged; contextLines = context
        folding = MergeFolding(unchanged: unchanged, contextLines: context)
        refresh()
    }

    func setCollapsed(_ value: Bool) {
        guard !retired, actionsAllowed(), value != collapsed else { return }
        collapsed = value
        MergeFoldingPreferences(collapsed: value, contextLines: contextLines).saveCollapsed(to: preferences)
        refresh()
    }
    @discardableResult func expand(screenRow: Int) -> Bool {
        guard !retired, actionsAllowed(), collapsed, projection.rows.indices.contains(screenRow),
              case .marker(let range) = projection.rows[screenRow], let expandedRange = folding.expand(marker: range.lowerBound) else { return false }
        refresh(); expanded([expandedRange]); return true
    }
    @discardableResult func reveal(sourceRow: Int) -> Bool {
        reveal(sourceRows: [sourceRow])
    }
    @discardableResult func reveal(sourceRows: [Int]) -> Bool {
        guard !retired, actionsAllowed(), collapsed else { return false }
        let ranges = folding.reveal(rows: sourceRows)
        guard !ranges.isEmpty else { return false }
        refresh(); expanded(ranges); return true
    }
    func install(visibility: [MergeFolding.Visibility]) {
        guard !retired, folding.visibility != visibility else { return }
        folding = MergeFolding(visibility: visibility); refresh()
    }
    func retire() { retired = true; geometryChanged = {}; expanded = { _ in }; actionsAllowed = { false } }
    private func refresh() {
        revision &+= 1
        projection = MergeFoldProjection(folding: folding, collapsed: collapsed)
        geometryChanged()
    }

    /// Creates display rows only; original cells remain owned by the document.
    /// Consumers must map actions through projection before touching source data.
    func displayCells(_ cells: [MergeSourceCell]) -> [MergeSourceCell] {
        guard collapsed, cells.count == folding.visibility.count else { return cells }
        return projection.rows.map { row in
            switch row {
            case .source(let index): return cells[index]
            case .marker: return MergeSourceCell(text: "{...}", lineNumber: nil, state: .empty)
            }
        }
    }
}

extension NSAttributedString.Key {
    static let mergeFoldHidden = NSAttributedString.Key("TurtleGit.MergeFoldHidden")
    static let mergeFoldMarker = NSAttributedString.Key("TurtleGit.MergeFoldMarker")
}

/// Keep the complete attributed document and all UTF-16 source coordinates.
/// Hidden paragraphs occupy a subpixel height; markers draw over their original
/// paragraph. No display placeholder can be inserted into edits or clipboard.
@MainActor final class MergeFoldTextLayout {
    weak var controller: MergeFoldingController?
    private var ranges: [NSRange] = []
    private var states: [MergeFolding.Visibility] = []
    private var originals: [(NSRange, [NSAttributedString.Key: Any])] = []
    private var presentation: NSAttributedString?
    private var presentationRevision = -1
    private var presentationFont: NSFont?
    private weak var observedStorage: NSTextStorage?
    private var storageObserver: NSObjectProtocol?
    private var installing = false
    private var inputDepth=0
    private var inputSelection:NSRange?
    private var inputSelectionRevision:Int?
    var suppressesInputReveal:Bool {inputDepth > 0}
    func beginPaneInput(){inputDepth += 1}
    func endPaneInput(selection:NSRange){inputSelection=selection;inputSelectionRevision=controller?.revision;inputDepth=max(0,inputDepth-1)}
    func clearPaneInput(){if inputDepth==0 {inputSelection=nil}}
    func adjacentInputOffset(_ offset:Int,forward:Bool)->Int? {
        guard !ranges.isEmpty,states.count==ranges.count else{return nil}
        var lo=0,hi=ranges.count
        while lo<hi {let mid=(lo+hi)/2;if ranges[mid].location<=offset {lo=mid+1}else{hi=mid}}
        var row=max(0,lo-1)+(forward ? 1:-1)
        while states.indices.contains(row),states[row] != .shown {row += forward ? 1:-1}
        return ranges.indices.contains(row) ? ranges[row].location:nil
    }
    func visibleInputOffset(_ offset:Int,forward:Bool,in view:NSTextView)->Int? {
        guard controller?.collapsed == true,!ranges.isEmpty,states.count==ranges.count else{return min(max(0,offset),view.string.utf16.count)}
        var lo=0,hi=ranges.count
        while lo<hi {let mid=(lo+hi)/2;if ranges[mid].location<=offset {lo=mid+1}else{hi=mid}}
        let row=max(0,lo-1)
        guard states[row] != .shown else{return min(max(0,offset),view.string.utf16.count)}
        var target=row
        while states.indices.contains(target),states[target] != .shown {target += forward ? 1:-1}
        if !states.indices.contains(target) {
            target=row
            while states.indices.contains(target),states[target] != .shown {target += forward ? -1:1}
        }
        guard states.indices.contains(target) else{return nil}
        if target>row {return ranges[target].location}
        let text=view.string as NSString,range=ranges[target]
        var end=min(text.length,NSMaxRange(range))
        while end>range.location,[10,13].contains(Int(text.character(at:end-1))) {end -= 1}
        return end
    }
    deinit { if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) } }

    /// Compare the unfurled source styling, not the live storage: wrapping owns
    /// paragraph padding and folding owns hidden-row attributes in that storage.
    /// A no-op hosting update must leave both owners' settled geometry intact.
    @discardableResult func installPresentation(_ value: NSAttributedString, font: NSFont, in view: NSTextView, controller: MergeFoldingController) -> Bool {
        guard let storage = view.textStorage else { return false }
        if observedStorage !== storage {
            if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) }
            observedStorage = storage; presentation = nil
            storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self, weak storage] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.installing, storage?.editedMask.contains(.editedCharacters) == true else { return }
                    self.presentation = nil
                }
            }
        }
        guard self.controller !== controller || presentationRevision != controller.revision || presentation?.isEqual(to: value) != true || presentationFont != font || !view.string.utf8.elementsEqual(value.string.utf8) else { return false }
        installing = true; defer { installing = false }
        storage.beginEditing()
        prepare(view)
        // Assigning NSTextView.font can rewrite the document's font attributes.
        if view.font != font { view.font = font }
        if !storage.string.utf8.elementsEqual(value.string.utf8) { storage.setAttributedString(value) }
        else {
            value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in storage.setAttributes(attributes, range: range) }
        }
        apply(to: view, controller: controller)
        storage.endEditing()
        presentation = NSAttributedString(attributedString: value)
        presentationRevision = controller.revision; presentationFont = font
        return true
    }
    func prepare(_ view: NSTextView) {
        presentation = nil
        guard let storage = view.textStorage else { return }
        storage.beginEditing(); defer { storage.endEditing() }
        for (range, attributes) in originals where NSMaxRange(range) <= storage.length && range.length > 0 {
            if storage.attribute(.mergeFoldHidden, at: range.location, effectiveRange: nil) != nil || storage.attribute(.mergeFoldMarker, at: range.location, effectiveRange: nil) != nil {
                storage.setAttributes(attributes, range: range)
            }
        }
        originals = []
    }
    func apply(to view: NSTextView, controller: MergeFoldingController) {
        self.controller = controller
        guard let storage = view.textStorage else { return }
        // Observers must see a complete fold map, never restored/half-hidden rows.
        storage.beginEditing(); defer { storage.endEditing() }
        prepare(view)
        ranges = MergeLineEndings.lineRanges(in: view.string)
        states = controller.collapsed && ranges.count == controller.folding.visibility.count ? controller.folding.visibility : Array(repeating: .shown, count: ranges.count)
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.mergeFoldHidden, range: whole)
        storage.removeAttribute(.mergeFoldMarker, range: whole)
        view.setAccessibilityCustomActions(controller.collapsed ? [NSAccessibilityCustomAction(name: "Expand unchanged section", handler: { [weak self, weak view] in
            guard let self, let view else { return false }; return self.expandSelection(in: view)
        })] : [])
        for (row, range) in ranges.enumerated() where states[row] != .shown {
            guard range.length > 0 else { continue }
            storage.enumerateAttributes(in: range) { attributes, run, _ in originals.append((run, attributes)) }
            let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 0
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            if states[row] == .hidden {
                paragraph.minimumLineHeight = 0.01; paragraph.maximumLineHeight = 0.01
                storage.addAttributes([.mergeFoldHidden: true, .font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)], range: range)
            } else {
                let height = view.layoutManager?.defaultLineHeight(for: view.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) ?? 18
                paragraph.minimumLineHeight = height; paragraph.maximumLineHeight = height
                storage.addAttribute(.mergeFoldMarker, value: true, range: range)
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
    func draw(in view: NSTextView, dirtyRect: NSRect) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        for (row, range) in ranges.enumerated() where states[row] == .marker && range.length > 0 {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            var rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.x += view.textContainerOrigin.x; rect.origin.y += view.textContainerOrigin.y
            guard rect.intersects(dirtyRect) else { continue }
            rect.size.width = max(rect.width, view.visibleRect.width)
            NSColor.textBackgroundColor.setFill(); rect.fill()
            let text = "{...}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: view.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attributes)
            let center = view.visibleRect.midX
            NSColor.separatorColor.setFill()
            NSRect(x: view.visibleRect.minX, y: rect.midY, width: max(0, center - size.width / 2 - view.visibleRect.minX - 6), height: 1).fill()
            NSRect(x: center + size.width / 2 + 6, y: rect.midY, width: max(0, view.visibleRect.maxX - center - size.width / 2 - 6), height: 1).fill()
            text.draw(at: NSPoint(x: center - size.width / 2, y: rect.minY), withAttributes: attributes)
        }
        _ = container
    }
    func canExpandSelection(in view: NSTextView) -> Bool {
        guard let controller, controller.collapsed, controller.actionsAllowed(),
              let row = ranges.firstIndex(where: { NSLocationInRange(view.selectedRange().location, $0) }) else { return false }
        return states[row] != .shown
    }
    @discardableResult func expandSelection(in view: NSTextView) -> Bool {
        guard canExpandSelection(in: view) else { return false }
        reveal(selection: view.selectedRange(), in: view, includeMarker: true)
        return true
    }
    func expand(at event: NSEvent, in view: NSTextView) -> Bool {
        guard event.clickCount == 2, let controller, controller.collapsed,
              let layout = view.layoutManager, let container = view.textContainer else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let character = layout.characterIndex(for: location, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let row = ranges.firstIndex(where: { NSLocationInRange(character, $0) }), states[row] == .marker,
              let screen = controller.projection.screenRow(containing: row) else { return false }
        return controller.expand(screenRow: screen)
    }
    func reveal(selection: NSRange, in view: NSTextView? = nil, includeMarker: Bool = false) {
        guard inputDepth==0,!(inputSelection == selection && inputSelectionRevision == controller?.revision),let controller, controller.collapsed, selection.location >= 0, selection.location != NSNotFound, selection.length >= 0 else { return }
        let (end, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow else { return }
        let rows = ranges.enumerated().compactMap { row, range -> Int? in
            range.location <= end && NSMaxRange(range) >= selection.location && (states[row] == .hidden || selection.length > 0 || includeMarker) ? row : nil
        }
        if controller.reveal(sourceRows: rows), let view {
            apply(to: view, controller: controller)
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            view.needsDisplay = true
        }
    }
}

/// A viewport update must not recompute every inline diff or rebuild the styled
/// document. Keep source content/style separate from live wrapping and folding.
@MainActor final class MergeEditorPresentationCache {
    struct Style: Equatable {
        let font: NSFont
        let tabWidth: Int
        let inline: Bool
        let word: Bool
        let maximumInlineLength: Int
        let palette: Int
        let mode: Int
    }
    struct Value {
        let text: NSAttributedString
        let missingOffsets: [Int]
    }
    private struct Cell: Equatable {
        let bytes: Data
        let number: Int?
        let state: MergeSourceState
        init(_ cell: MergeSourceCell) { bytes = Data(cell.text.utf8); number = cell.lineNumber; state = cell.state }
    }
    private struct Key: Equatable {
        let text: Data
        let cells: [Cell]?
        let peers: [Cell]?
        let states: [MergeSourceState]
        let style: Style
    }
    private var key: Key?
    private var saved: Value?
    private(set) var builds = 0
    func value(text: String, cells: [MergeSourceCell]?, peers: [MergeSourceCell]?, states: [MergeSourceState] = [], style: Style, build: () -> Value) -> Value {
        let next = Key(text: Data(text.utf8), cells: cells?.map(Cell.init), peers: peers?.map(Cell.init), states: states, style: style)
        if key == next, let saved { return saved }
        let result = build()
        // Copy the attributed value: a mutable builder must not rewrite a cached
        // presentation while TextKit retains the preceding source generation.
        let value = Value(text: NSAttributedString(attributedString: result.text), missingOffsets: result.missingOffsets)
        key = next; saved = value; builds += 1
        return value
    }
}

@MainActor protocol MergeEditorPresentationProviding { var presentationCache: MergeEditorPresentationCache { get } }

/// All selectors, whether dispatched by a key binding or NSApp.sendAction,
/// share the same source caret and fold ownership. Source separators define word
/// movement; TextKit supplies native grapheme and visual-line geometry.
@MainActor protocol MergePaneInputProviding:AnyObject {var paneInputLayout:MergeFoldTextLayout {get}}
@MainActor class MergePaneInputTextView:NSTextView,MergePaneInputProviding {
    var paneInputLayout:MergeFoldTextLayout {fatalError("A pane owns its fold layout")}
    var paneInputCells:[MergeSourceCell]? {nil}
    var paneInputAllowed:Bool {false}
    var paneInputMutationAllowed:Bool {false}
    var paneInputRevision:Int {0}
    func paneInputBegan() {}
    private struct Receipt {let range:NSRange,anchor:Int,head:Int,revision:Int,foldRevision:Int,length:Int}
    private var inputReceipt:Receipt?
    private var goalX:CGFloat?
    private var cachedWordDocument:(revision:Int,length:Int,aligned:Bool,value:MergePaneInput.WordDocument)?
    private var wordDocument:MergePaneInput.WordDocument? {
        let length=string.utf16.count,aligned=paneInputCells != nil
        if let cached=cachedWordDocument,cached.revision==paneInputRevision,cached.length==length,cached.aligned==aligned {return cached.value}
        guard let value=MergePaneInput.WordDocument(text:string,cells:paneInputCells) else{return nil}
        cachedWordDocument=(paneInputRevision,length,aligned,value);return value
    }
    private var wordSeparators:String {MergeFindOptions.load(from:(self as? MergeFindProviding)?.mergeFindDefaults ?? .standard).wordSeparators}
    private var wordHiddenRows:Set<Int> {
        guard let controller=paneInputLayout.controller,controller.collapsed else{return []}
        return Set(controller.folding.visibility.indices.filter{controller.folding.visibility[$0] != .shown})
    }
    override func didChangeText() {cachedWordDocument=nil;super.didChangeText()}
    override func setSelectedRange(_ charRange:NSRange) {
        clearExternalInput();super.setSelectedRange(charRange)
    }
    override func setSelectedRanges(_ ranges:[NSValue],affinity:NSSelectionAffinity,stillSelecting:Bool) {
        clearExternalInput();super.setSelectedRanges(ranges,affinity:affinity,stillSelecting:stillSelecting)
    }
    private func clearExternalInput() {
        guard !paneInputLayout.suppressesInputReveal else{return}
        inputReceipt=nil;goalX=nil;paneInputLayout.clearPaneInput()
    }
    override func becomeFirstResponder()->Bool {clearExternalInput();return super.becomeFirstResponder()}
    private struct InputLine {
        let rect:NSRect,x:CGFloat,glyphs:NSRange,characters:NSRange
    }
    private func caretLine(_ offset:Int,affinity:NSSelectionAffinity = .downstream)->InputLine? {
        guard let layout=layoutManager,let container=textContainer else{return nil}
        layout.ensureLayout(for:container)
        let text=string as NSString,length=text.length,index=min(max(0,offset),length),origin=textContainerOrigin
        if index==length,layout.extraLineFragmentTextContainer === container {
            let line=layout.extraLineFragmentRect.offsetBy(dx:origin.x,dy:origin.y)
            if line.height>0 {return InputLine(rect:line,x:line.minX,glyphs:NSRange(location:layout.numberOfGlyphs,length:0),characters:NSRange(location:length,length:0))}
        }
        guard length>0,layout.numberOfGlyphs>0 else{return nil}
        var glyph=layout.glyphIndexForCharacter(at:min(index,length-1))
        // A soft-wrap boundary has two caret positions. Keep the selected
        // fragment when goal X lands at its end, without crossing a real EOL.
        if affinity == .upstream,index>0,![10,13].contains(Int(text.character(at:index-1))) {
            let previous=layout.glyphIndexForCharacter(at:index-1)
            var previousGlyphs=NSRange()
            _ = layout.lineFragmentRect(forGlyphAt:previous,effectiveRange:&previousGlyphs)
            let previousCharacters=layout.characterRange(forGlyphRange:previousGlyphs,actualGlyphRange:nil)
            if NSMaxRange(previousCharacters)==index {glyph=previous}
        }
        var glyphs=NSRange()
        let line=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&glyphs).offsetBy(dx:origin.x,dy:origin.y)
        let characters=layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        var x=line.minX+layout.location(forGlyphAt:glyph).x
        if index==NSMaxRange(characters),characters.length>0 {
            // The upstream side of a soft wrap is the trailing insertion point,
            // not the start of its final glyph (which may also be a ligature).
            x=layout.lineFragmentUsedRect(forGlyphAt:glyph,effectiveRange:nil).maxX+origin.x
            let probe=layout.characterIndexForGlyph(at:glyph)
            let count=layout.getLineFragmentInsertionPoints(forCharacterAt:probe,alternatePositions:false,inDisplayOrder:false,positions:nil,characterIndexes:nil)
            if count>0,count<=65_536,count<=characters.length+1 {
                var positions=Array(repeating:CGFloat.zero,count:count),indexes=Array(repeating:0,count:count)
                let actual=layout.getLineFragmentInsertionPoints(forCharacterAt:probe,alternatePositions:false,inDisplayOrder:false,positions:&positions,characterIndexes:&indexes)
                if actual<=count,let insertion=indexes.prefix(actual).firstIndex(of:index) {x=line.minX+positions[insertion]}
            }
        }
        guard line.height>0,line.minY.isFinite,x.isFinite else{return nil}
        return InputLine(rect:line,x:x,glyphs:glyphs,characters:characters)
    }
    private func goalOffset(in line:InputLine,x:CGFloat)->(offset:Int,affinity:NSSelectionAffinity) {
        let text=string as NSString,lower=line.characters.location
        var upper=min(text.length,NSMaxRange(line.characters))
        while upper>lower,[10,13].contains(Int(text.character(at:upper-1))) {upper -= 1}
        let hit=offset(at:NSPoint(x:x,y:line.rect.midY)) ?? lower
        var result=min(max(lower,hit),upper)
        if result>lower,result<upper {result=max(lower,text.rangeOfComposedCharacterSequence(at:result).location)}
        return (result,result==NSMaxRange(line.characters) && line.characters.length>0 ? .upstream:.downstream)
    }
    private func verticalTarget(from head:Int,forward:Bool,x:CGFloat)->(offset:Int,affinity:NSSelectionAffinity)? {
        guard let layout=layoutManager,let current=caretLine(head,affinity:selectionAffinity) else{return nil}
        let candidate:Int
        if textContainer?.widthTracksTextView != true,paneInputCells != nil {
            guard let adjacent=paneInputLayout.adjacentInputOffset(head,forward:forward) else{return nil}
            candidate=adjacent
        } else {
            let glyph=forward ? NSMaxRange(current.glyphs):current.glyphs.location-1
            if glyph==layout.numberOfGlyphs,forward,layout.extraLineFragmentTextContainer === textContainer {candidate=string.utf16.count}
            else {
                guard glyph>=0,glyph<layout.numberOfGlyphs else{return nil}
                candidate=layout.characterIndexForGlyph(at:glyph)
            }
        }
        guard let shown=paneInputLayout.visibleInputOffset(candidate,forward:forward,in:self),let target=caretLine(shown) else{return nil}
        return goalOffset(in:target,x:x)
    }
    private func caretPoint(_ offset:Int)->NSPoint? {
        guard let caret=caretLine(offset,affinity:selectionAffinity) else{return nil}
        return NSPoint(x:caret.x,y:caret.rect.midY)
    }
    private func offset(at point:NSPoint)->Int? {
        guard let layout=layoutManager,let container=textContainer else{return nil}
        layout.ensureLayout(for:container)
        return layout.characterIndex(for:NSPoint(x:point.x-textContainerOrigin.x,y:point.y-textContainerOrigin.y),in:container,fractionOfDistanceBetweenInsertionPoints:nil)
    }
    private func navigate(forward:Bool,modify:Bool=false,vertical:Bool=false,home:Bool=false,page:Bool=false,word:Bool=false,propose:()->Void) {
        if paneInputLayout.suppressesInputReveal {propose();return}
        guard paneInputAllowed,window?.attachedSheet==nil else{return}
        if hasMarkedText() {propose();return}
        paneInputBegan()
        let before=selectedRange(),length=string.utf16.count,foldRevision=paneInputLayout.controller?.revision ?? -1
        let lastCaret=paneInputCells != nil && length>0 && (string as NSString).character(at:length-1)==10 ? length-1:length
        let receipt=inputReceipt.flatMap{$0.range==before && $0.revision==paneInputRevision && $0.foldRevision==foldRevision && $0.length==length ? $0:nil}
        let rawAnchor=modify ? receipt?.anchor ?? (before.length==0 ? before.location:selectionAffinity == .upstream ? NSMaxRange(before):before.location):before.location
        let anchor=paneInputLayout.visibleInputOffset(rawAnchor,forward:!forward,in:self) ?? rawAnchor
        if receipt == nil {goalX=nil}
        let head=receipt?.head ?? (before.length==0 ? before.location:selectionAffinity == .upstream ? before.location:NSMaxRange(before))
        paneInputLayout.beginPaneInput()
        var settled=before
        defer {paneInputLayout.endPaneInput(selection:settled)}
        if !vertical {goalX=nil}
        if vertical,goalX==nil {goalX=caretPoint(head)?.x}
        // Extend from the moving end without relying on TextKit's private
        // selection anchor; word boundaries use the same source geometry.
        if modify {super.setSelectedRange(NSRange(location:head,length:0))}
        var destination:Int
        var destinationAffinity=selectionAffinity
        if home {
            let text=string as NSString,line=text.lineRange(for:NSRange(location:min(head,length),length:0))
            var first=line.location
            while first<NSMaxRange(line),first<length,[9,32].contains(Int(text.character(at:first))) {first += 1}
            destination=head==first ? line.location:first
        } else if page,let point=caretPoint(head) {
            let line=max(1,layoutManager?.defaultLineHeight(for:font ?? .systemFont(ofSize:12)) ?? 18)
            let distance=max(line,floor(visibleRect.height/line)*line)
            destination=offset(at:NSPoint(x:goalX ?? point.x,y:point.y+(forward ? distance:-distance))) ?? head
        } else if vertical {
            if let target=verticalTarget(from:head,forward:forward,x:goalX ?? caretPoint(head)?.x ?? textContainerOrigin.x) {
                destination=target.offset;destinationAffinity=target.affinity
            } else {destination=head}
        } else if word {
            guard let target=wordDocument?.destination(from:head,forward:forward,wordSeparators:wordSeparators,hiddenRows:wordHiddenRows) else{super.setSelectedRange(before);return}
            destination=target
        } else {propose();destination=selectedRange().location}
        destination=min(max(0,destination),lastCaret)
        guard let visible=paneInputLayout.visibleInputOffset(destination,forward:forward,in:self) else {super.setSelectedRange(before);return}
        destination=min(visible,lastCaret)
        if page,let x=goalX,let target=caretLine(destination) {
            let placed=goalOffset(in:target,x:x);destination=min(placed.offset,lastCaret);destinationAffinity=placed.affinity
        }
        settled=modify ? NSRange(location:min(anchor,destination),length:abs(anchor-destination)):NSRange(location:destination,length:0)
        if vertical {super.setSelectedRanges([NSValue(range:settled)],affinity:destinationAffinity,stillSelecting:false)}
        else {super.setSelectedRange(settled)}
        inputReceipt=Receipt(range:settled,anchor:modify ? anchor:destination,head:destination,revision:paneInputRevision,foldRevision:foldRevision,length:length)
        scrollRangeToVisible(NSRange(location:destination,length:0))
    }
    private func deletePane(backward:Bool,word:Bool=false,propose:()->Void) {
        guard paneInputMutationAllowed,window?.attachedSheet==nil else{return}
        if hasMarkedText() {propose();return}
        paneInputBegan();clearExternalInput()
        paneInputLayout.beginPaneInput()
        defer {paneInputLayout.endPaneInput(selection:selectedRange())}
        let cells=paneInputCells,selected=selectedRange()
        let requested:NSRange?
        if word {requested=wordDocument?.deletionRange(selection:selected,backward:backward,wordSeparators:wordSeparators,hiddenRows:wordHiddenRows)}
        else if let cells {requested=MergePaneInput.deletionRange(in:string,cells:cells,selection:selected,backward:backward)}
        else {propose();return}
        guard var range=requested else{return}
        if selected.length==0,let cells {
            guard let start=paneInputLayout.visibleInputOffset(range.location,forward:false,in:self),let end=paneInputLayout.visibleInputOffset(NSMaxRange(range),forward:true,in:self) else{return}
            range=NSRange(location:min(start,end),length:abs(end-start))
            guard let normalized=MergePaneInput.normalizedReplacementRange(in:string,cells:cells,selection:range),normalized.length>0 else{return}
            range=normalized
        }
        // Existing delegates perform one aligned edit and own its Undo receipt.
        insertText("",replacementRange:range)
    }
    override func deleteBackward(_ sender:Any?){deletePane(backward:true){super.deleteBackward(sender)}}
    override func deleteForward(_ sender:Any?){deletePane(backward:false){super.deleteForward(sender)}}
    override func deleteWordBackward(_ sender:Any?){deletePane(backward:true,word:true){super.deleteWordBackward(sender)}}
    override func deleteWordForward(_ sender:Any?){deletePane(backward:false,word:true){super.deleteWordForward(sender)}}
    override func keyDown(with event:NSEvent) {
        let modifiers=event.modifierFlags.intersection([.command,.control,.option,.shift])
        if modifiers == .control,event.keyCode==51 || event.keyCode==117 {
            if event.keyCode==51 {deleteWordBackward(nil)}else{deleteWordForward(nil)};return
        }
        if event.keyCode==115,modifiers.isEmpty || modifiers == .shift {
            if modifiers == .shift {moveToBeginningOfLineAndModifySelection(nil)}else{moveToBeginningOfLine(nil)};return
        }
        super.keyDown(with:event)
    }
    override func moveLeft(_ sender:Any?){navigate(forward:false,modify:false,vertical:false){super.moveLeft(sender)}}
    override func moveLeftAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:false){super.moveLeft(sender)}}
    override func moveRight(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveRight(sender)}}
    override func moveRightAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveRight(sender)}}
    override func moveBackward(_ sender:Any?){navigate(forward:false,modify:false,vertical:false){super.moveBackward(sender)}}
    override func moveBackwardAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:false){super.moveBackward(sender)}}
    override func moveForward(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveForward(sender)}}
    override func moveForwardAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveForward(sender)}}
    override func moveWordLeft(_ sender:Any?){navigate(forward:false,modify:false,vertical:false,word:true){super.moveWordLeft(sender)}}
    override func moveWordLeftAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:false,word:true){super.moveWordLeft(sender)}}
    override func moveWordRight(_ sender:Any?){navigate(forward:true,modify:false,vertical:false,word:true){super.moveWordRight(sender)}}
    override func moveWordRightAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false,word:true){super.moveWordRight(sender)}}
    override func moveWordBackward(_ sender:Any?){navigate(forward:false,modify:false,vertical:false,word:true){super.moveWordBackward(sender)}}
    override func moveWordBackwardAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:false,word:true){super.moveWordBackward(sender)}}
    override func moveWordForward(_ sender:Any?){navigate(forward:true,modify:false,vertical:false,word:true){super.moveWordForward(sender)}}
    override func moveWordForwardAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false,word:true){super.moveWordForward(sender)}}
    override func moveUp(_ sender:Any?){navigate(forward:false,modify:false,vertical:true){super.moveUp(sender)}}
    override func moveUpAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:true){super.moveUp(sender)}}
    override func moveDown(_ sender:Any?){navigate(forward:true,modify:false,vertical:true){super.moveDown(sender)}}
    override func moveDownAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:true){super.moveDown(sender)}}
    override func moveToEndOfLine(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveToEndOfLine(sender)}}
    override func moveToEndOfLineAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveToEndOfLine(sender)}}
    override func moveToRightEndOfLine(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveToRightEndOfLine(sender)}}
    override func moveToRightEndOfLineAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveToRightEndOfLine(sender)}}
    override func moveToEndOfParagraph(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveToEndOfParagraph(sender)}}
    override func moveToEndOfParagraphAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveToEndOfParagraph(sender)}}
    override func moveToBeginningOfDocument(_ sender:Any?){navigate(forward:false,modify:false,vertical:false){super.moveToBeginningOfDocument(sender)}}
    override func moveToBeginningOfDocumentAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:false){super.moveToBeginningOfDocument(sender)}}
    override func moveToEndOfDocument(_ sender:Any?){navigate(forward:true,modify:false,vertical:false){super.moveToEndOfDocument(sender)}}
    override func moveToEndOfDocumentAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:false){super.moveToEndOfDocument(sender)}}
    override func moveToBeginningOfLine(_ sender:Any?){navigate(forward:false,modify:false,home:true){super.moveToBeginningOfLine(sender)}}
    override func moveToBeginningOfLineAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,home:true){super.moveToBeginningOfLine(sender)}}
    override func moveToLeftEndOfLine(_ sender:Any?){navigate(forward:false,modify:false,home:true){super.moveToLeftEndOfLine(sender)}}
    override func moveToLeftEndOfLineAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,home:true){super.moveToLeftEndOfLine(sender)}}
    override func moveToBeginningOfParagraph(_ sender:Any?){navigate(forward:false,modify:false,home:true){super.moveToBeginningOfParagraph(sender)}}
    override func moveToBeginningOfParagraphAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,home:true){super.moveToBeginningOfParagraph(sender)}}
    override func pageUp(_ sender:Any?){navigate(forward:false,modify:false,vertical:true,page:true){super.pageUp(sender)}}
    override func pageUpAndModifySelection(_ sender:Any?){navigate(forward:false,modify:true,vertical:true,page:true){super.pageUp(sender)}}
    override func pageDown(_ sender:Any?){navigate(forward:true,modify:false,vertical:true,page:true){super.pageDown(sender)}}
    override func pageDownAndModifySelection(_ sender:Any?){navigate(forward:true,modify:true,vertical:true,page:true){super.pageDown(sender)}}
}
