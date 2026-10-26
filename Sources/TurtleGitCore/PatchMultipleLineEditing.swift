// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Stable identity is independent of native range ordering or primary affinity.
public struct PatchLineEditSelection: Equatable, Sendable {
    public let id:Int
    public let anchor:Int
    public let caret:Int
    public init(id:Int,anchor:Int,caret:Int) {self.id=id;self.anchor=anchor;self.caret=caret}
    public var anchorOffset:Int {anchor}
    public var caretOffset:Int {caret}
    public var range:NSRange {NSRange(location:min(anchor,caret),length:abs(caret-anchor))}
    public var isReversed:Bool {caret<anchor}
}
public struct PatchSelectionClipboard: Equatable, Sendable {
    public let text:String
    public let rectangular:Bool
}
/// TextKit supplies screen-X-based offsets and spaces; Core never substitutes
/// UTF-16 columns for the source editor's measured glyph geometry.
public struct PatchRectanglePasteInsertion: Equatable, Sendable {
    public let offset:Int
    public let prefix:String
    public let text:String
    public init(offset:Int,prefix:String="",text:String) {self.offset=offset;self.prefix=prefix;self.text=text}
}

extension PatchLineEditing {
    private struct Change {
        let offset:Int,removed:Int,inserted:Int
    }
    private static func valid(_ text:String,_ selections:[PatchLineEditSelection],_ primary:Int)->Bool {
        guard !selections.isEmpty,Set(selections.map(\.id)).count==selections.count,
              selections.contains(where:{$0.id==primary}) else {return false}
        let units=Array(text.utf16)
        func boundary(_ offset:Int)->Bool {offset>=0 && offset<=units.count && (offset==units.count || !(0xdc00...0xdfff).contains(units[offset]))}
        for selection in selections {
            guard boundary(selection.anchor),boundary(selection.caret) else {return false}
        }
        let sorted=selections.sorted { $0.range.location == $1.range.location ? $0.range.length<$1.range.length : $0.range.location<$1.range.location }
        for i in sorted.indices.dropFirst() {
            let previous=sorted[i-1].range,current=sorted[i].range
            if NSMaxRange(previous)>current.location || previous.location==current.location && previous.length==0 && current.length==0 {return false}
        }
        return true
    }
    private static func changes(_ plan:PatchLineEditPlan)->[Change] {
        var result:[Change]=[],cursor=0,pending=0
        for segment in plan.segments {
            switch segment {
            case let .inserted(value):pending+=value.utf16.count
            case let .source(range):
                if range.location<cursor {pending+=range.length;continue}
                if range.location>cursor || pending>0 {result.append(.init(offset:cursor,removed:range.location-cursor,inserted:pending))}
                pending=0;cursor=NSMaxRange(range)
            }
        }
        if cursor<plan.originalText.utf16.count || pending>0 {result.append(.init(offset:cursor,removed:plan.originalText.utf16.count-cursor,inserted:pending))}
        return result
    }
    private static func moved(_ selection:PatchLineEditSelection,by changes:[Change])->PatchLineEditSelection {
        var a=selection.anchor,c=selection.caret,delta=0
        for change in changes {
            let start=change.offset+delta,end=start+change.removed
            func deleted(_ value:Int)->Int {value<=start ? value:value<=end ? start:value-change.removed}
            a=deleted(a);c=deleted(c)
            let aStart=a<c,cStart=c<a
            if a>start || a==start && aStart {a+=change.inserted}
            if c>start || c==start && cStart {c+=change.inserted}
            delta+=change.inserted-change.removed
        }
        return .init(id:selection.id,anchor:a,caret:c)
    }
    private static func assembled(original:String,work:Work,selections:[PatchLineEditSelection],primary:Int,
                                  rectangular:Bool,clipboard:PatchSelectionClipboard?=nil,thin:Bool=false)->PatchLineEditPlan {
        let main=selections.first {$0.id==primary}!
        // Removing a whole line can merge thin row carets. Keep the primary
        // receipt when native range normalization coalesces identical ranges.
        var seen=Set<NSRange>()
        let preferred=[main]+selections.filter {$0.id != primary}
        let retained=Set(preferred.filter {seen.insert($0.range).inserted}.map(\.id))
        let normalized=selections.filter {retained.contains($0.id)}
        return .init(originalText:original,resultText:work.text,segments:work.segments,selectionAnchor:main.anchor,
                     selectionCaret:main.caret,clipboardText:clipboard?.text,selections:normalized,primarySelectionID:primary,
                     rectangular:rectangular,clipboardRectangular:clipboard?.rectangular ?? false,rectangleIsThin:thin)
    }
    private static func rectangleResult(_ plan:PatchLineEditPlan,input:[PatchLineEditSelection],primary:Int,
                                        duplicate:Bool,thinBefore:Bool=false,beforeThin:[PatchLineEditSelection]?=nil)->PatchLineEditPlan {
        guard let first=input.first,let main=input.first(where:{$0.id==primary}) else {return plan}
        var corner=PatchLineEditSelection(id:primary,anchor:first.anchor,caret:main.caret)
        if !thinBefore && (duplicate || beforeThin == nil) {corner=moved(corner,by:changes(plan))}
        var anchor=corner.anchor,caret=corner.caret
        if duplicate {
            var last=plan.selections.flatMap {[$0.anchor,$0.caret]}.max() ?? 0
            if input.allSatisfy({$0.range.length==0}) {
                let index=PatchLineIndex(text:plan.resultText)
                if let line=index.lineIndex(atUTF16Offset:last),let range=index.range(forLine:line) {last+=range.length}
            }
            if anchor>caret {anchor=last} else {caret=last}
        } else {
            let ranges=beforeThin ?? plan.selections
            guard let first=ranges.first,let last=ranges.last else {return plan}
            if caret<anchor {anchor=first.anchor;caret=last.caret}
            else {anchor=first.caret;caret=last.anchor}
        }
        return .init(originalText:plan.originalText,resultText:plan.resultText,segments:plan.segments,
                     selectionAnchor:plan.selectionAnchor,selectionCaret:plan.selectionCaret,clipboardText:plan.clipboardText,
                     selections:plan.selections,primarySelectionID:plan.primarySelectionID,rectangular:plan.rectangular,
                     clipboardRectangular:plan.clipboardRectangular,rectangleAnchor:anchor,rectangleCaret:caret,rectangleIsThin:duplicate ? thinBefore:true)
    }
    private static func applying(_ plan:PatchLineEditPlan,to work:inout Work) {
        work.segments=plan.segments.flatMap { segment in
            switch segment {case let .source(range):return work.slice(range);case .inserted:return [segment]}
        }
    }
    /// Source defaults permit rectangular selection, but ordinary typing is
    /// primary-only. Per-range commands are explicit Duplicate/Indent/Tab APIs.
    public static func plan(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,rectangular:Bool,
                            command:PatchLineEditCommand,tabWidth:Int=4,useTabs:Bool=true,lineEnding:String="\n",rectangleIsThin:Bool=false)->PatchLineEditPlan? {
        guard valid(text,selections,primarySelectionID),let main=selections.first(where:{$0.id==primarySelectionID}) else {return nil}
        if command == .cutLines,rectangular {
            return cutSelections(text:text,selections:selections,primarySelectionID:primarySelectionID,rectangular:true,lineEnding:lineEnding,rectangleIsThin:rectangleIsThin)
        }
        if [.copyLines,.cutLines,.deleteLine,.transpose].contains(command) {
            guard let single=plan(text:text,anchor:main.anchor,caret:main.caret,command:command,tabWidth:tabWidth,useTabs:useTabs,lineEnding:lineEnding) else {return nil}
            var work=Work(original:text);applying(single,to:&work)
            var result=selections.map {moved($0,by:changes(single))}
            if command == .cutLines || command == .transpose && single.hasReplacement {
                result=[.init(id:main.id,anchor:single.selectionAnchor,caret:single.selectionCaret)]
            } else if command != .copyLines {
                result=result.map {$0.id==main.id ? .init(id:main.id,anchor:single.selectionAnchor,caret:single.selectionCaret):$0}
            }
            return assembled(original:text,work:work,selections:result,primary:main.id,
                             rectangular:rectangular && command != .cutLines && !(command == .transpose && single.hasReplacement),
                             clipboard:single.clipboardText.map { .init(text:$0,rectangular:false) },thin:rectangleIsThin)
        }
        if let parallel=parallelRows(text:text,selections:selections,primary:primarySelectionID,rectangular:rectangular,
                                     command:command,tabWidth:tabWidth,useTabs:useTabs,lineEnding:lineEnding,thinBefore:rectangleIsThin) {return parallel}
        var work=Work(original:text),result=selections
        let duplicateLines=command == .duplicate && selections.allSatisfy {$0.range.length==0}
        // Source iterates live selection slots, updating later positions after
        // each mutation. Native callers retain stable IDs through that update.
        for selection in selections {
            guard let current=result.first(where:{$0.id==selection.id}) else {return nil}
            if command == .duplicate,!duplicateLines,current.range.length==0 {continue}
            guard let single=plan(text:work.text,anchor:current.anchor,caret:current.caret,command:command,
                                  tabWidth:tabWidth,useTabs:useTabs,lineEnding:lineEnding) else {return nil}
            let edits=changes(single)
            applying(single,to:&work)
            result=result.map { entry in
                if entry.id==current.id {return .init(id:entry.id,anchor:single.selectionAnchor,caret:single.selectionCaret)}
                return moved(entry,by:edits)
            }
        }
        let beforeThin=result
        if rectangular,[.indent,.dedent,.tab,.backTab].contains(command) {
            // Editor::Indent restores rectangular mode then ThinRectangularRange.
            result=result.map {.init(id:$0.id,anchor:$0.caret,caret:$0.caret)}
        }
        let complete=assembled(original:text,work:work,selections:result,primary:primarySelectionID,rectangular:rectangular)
        return rectangular ? rectangleResult(complete,input:selections,primary:primarySelectionID,duplicate:command == .duplicate,thinBefore:rectangleIsThin,beforeThin:beforeThin):complete
    }
    /// Rectangles ordinarily occupy distinct logical rows. Plan each small
    /// row locally and stitch source receipts once, avoiding full-document
    /// indexing/rendering for every selected row of a large patch.
    private static func parallelRows(text:String,selections:[PatchLineEditSelection],primary:Int,rectangular:Bool,
                                     command:PatchLineEditCommand,tabWidth:Int,useTabs:Bool,lineEnding:String,thinBefore:Bool)->PatchLineEditPlan? {
        let index=PatchLineIndex(text:text),shown=text as NSString
        var byLine:[Int:PatchLineEditSelection]=[:]
        for selection in selections {
            guard let line=index.lineIndex(atUTF16Offset:selection.range.location),
                  index.lineIndex(atUTF16Offset:NSMaxRange(selection.range))==line,byLine[line]==nil else {return nil}
            byLine[line]=selection
        }
        let duplicateLines=command == .duplicate && selections.allSatisfy {$0.range.length==0}
        var pieces:[PatchLineEditSegment]=[],updated:[Int:PatchLineEditSelection]=[:],cursor=0,delta=0
        for line in byLine.keys.sorted() {
            let selection=byLine[line]!,range=index.range(forLine:line)!
            pieces.append(.source(NSRange(location:cursor,length:range.location-cursor)))
            if command == .duplicate,!duplicateLines,selection.range.length==0 {
                pieces.append(.source(range));updated[selection.id] = .init(id:selection.id,anchor:selection.anchor+delta,caret:selection.caret+delta)
            } else {
                let local=shown.substring(with:range)
                guard let planned=plan(text:local,anchor:selection.anchor-range.location,caret:selection.caret-range.location,
                                       command:command,tabWidth:tabWidth,useTabs:useTabs,lineEnding:lineEnding) else {return nil}
                for segment in planned.segments {
                    switch segment {
                    case let .source(r):pieces.append(.source(NSRange(location:range.location+r.location,length:r.length)))
                    case .inserted:pieces.append(segment)
                    }
                }
                let anchor=range.location+delta+planned.selectionAnchor,caret=range.location+delta+planned.selectionCaret
                updated[selection.id] = .init(id:selection.id,anchor:anchor,caret:caret)
                delta+=planned.resultText.utf16.count-range.length
            }
            cursor=NSMaxRange(range)
        }
        pieces.append(.source(NSRange(location:cursor,length:index.utf16Length-cursor)))
        var work=Work(original:text);work.segments=pieces
        var result=selections.map {updated[$0.id]!}
        let beforeThin=result
        if rectangular,[.indent,.dedent,.tab,.backTab].contains(command) {
            result=result.map {.init(id:$0.id,anchor:$0.caret,caret:$0.caret)}
        }
        let complete=assembled(original:text,work:work,selections:result,primary:primary,rectangular:rectangular)
        return rectangular ? rectangleResult(complete,input:selections,primary:primary,duplicate:command == .duplicate,thinBefore:thinBefore,beforeThin:beforeThin):complete
    }
    public static func selectionClipboard(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,
                                          rectangular:Bool,lineEnding:String="\n")->PatchSelectionClipboard? {
        guard valid(text,selections,primarySelectionID),["\n","\r","\r\n"].contains(lineEnding),
              selections.contains(where:{$0.range.length>0}) else {return nil}
        let shown=text as NSString,ordered=rectangular ? selections.sorted {$0.range.location<$1.range.location}:selections
        let pieces=ordered.map {shown.substring(with:$0.range)}
        return .init(text:pieces.joined(separator:lineEnding)+(rectangular ? lineEnding:""),rectangular:rectangular)
    }
    public static func cutSelections(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,
                                    rectangular:Bool,lineEnding:String="\n",includeClipboard:Bool=true,rectangleIsThin:Bool=false)->PatchLineEditPlan? {
        guard valid(text,selections,primarySelectionID) else {return nil}
        let clipboard=includeClipboard ? selectionClipboard(text:text,selections:selections,primarySelectionID:primarySelectionID,rectangular:rectangular,lineEnding:lineEnding) : nil
        let targets=rectangular ? selections:selections.filter {$0.id==primarySelectionID}
        let sorted=targets.sorted {$0.range.location<$1.range.location}
        var work=Work(original:text),pieces:[PatchLineEditSegment]=[],cursor=0,edits:[Change]=[]
        for selection in sorted where selection.range.length>0 {
            let r=selection.range
            pieces.append(.source(NSRange(location:cursor,length:r.location-cursor)));cursor=NSMaxRange(r)
            edits.append(.init(offset:r.location,removed:r.length,inserted:0))
        }
        pieces.append(.source(NSRange(location:cursor,length:text.utf16.count-cursor)));work.segments=pieces
        let result=targets.map { entry -> PatchLineEditSelection in
            let next=moved(entry,by:edits);return .init(id:entry.id,anchor:next.range.location,caret:next.range.location)
        }
        let complete=assembled(original:text,work:work,selections:result,primary:primarySelectionID,rectangular:rectangular,clipboard:clipboard)
        return rectangular ? rectangleResult(complete,input:selections,primary:primarySelectionID,duplicate:false,thinBefore:rectangleIsThin):complete
    }
    public static func replacePrimarySelection(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,replacement:String)->PatchLineEditPlan? {
        guard valid(text,selections,primarySelectionID),let main=selections.first(where:{$0.id==primarySelectionID}) else {return nil}
        var work=Work(original:text);work.replace(main.range,with:[.inserted(replacement)])
        let caret=main.range.location+replacement.utf16.count
        return assembled(original:text,work:work,selections:[.init(id:main.id,anchor:caret,caret:caret)],primary:main.id,rectangular:false)
    }
    public static func rectanglePasteRows(_ text:String)->[String] {
        var units=Array(text.utf16)
        while units.last==10 || units.last==13 {units.removeLast()}
        guard !units.isEmpty else {return []}
        var rows:[String]=[],start=0,offset=0
        while offset<units.count {
            if units[offset]==10 || units[offset]==13 {
                rows.append(String(decoding:units[start..<offset],as:UTF16.self))
                if units[offset]==13,offset+1<units.count,units[offset+1]==10 {offset+=1}
                start=offset+1
            }
            offset+=1
        }
        rows.append(String(decoding:units[start...],as:UTF16.self));return rows
    }
    public static func planRectanglePaste(text:String,insertions:[PatchRectanglePasteInsertion],primarySelectionID:Int,caret:Int)->PatchLineEditPlan? {
        let units=Array(text.utf16)
        func boundary(_ offset:Int)->Bool {offset>=0 && offset<=units.count && (offset==units.count || !(0xdc00...0xdfff).contains(units[offset]))}
        guard !insertions.isEmpty,boundary(caret) else {return nil}
        var cursor=0,pieces:[PatchLineEditSegment]=[]
        for insertion in insertions {
            guard insertion.offset>=cursor,boundary(insertion.offset),
                  insertion.prefix.utf16.allSatisfy({[9,10,13,32].contains($0)}),
                  !insertion.text.utf16.contains(where:{$0==10 || $0==13}) else {return nil}
            pieces.append(.source(NSRange(location:cursor,length:insertion.offset-cursor)))
            pieces.append(.inserted(insertion.prefix+insertion.text));cursor=insertion.offset
        }
        pieces.append(.source(NSRange(location:cursor,length:text.utf16.count-cursor)))
        var work=Work(original:text);work.segments=pieces
        return assembled(original:text,work:work,selections:[.init(id:primarySelectionID,anchor:caret,caret:caret)],primary:primarySelectionID,rectangular:false)
    }
    /// Default no-virtual-space rectangular Delete/Backspace: remove selection
    /// rows, or one Unicode scalar on each thin row without consuming its EOL.
    public static func deleteSelections(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,
                                        rectangular:Bool,backwards:Bool,rectangleIsThin:Bool=false)->PatchLineEditPlan? {
        guard valid(text,selections,primarySelectionID) else {return nil}
        if selections.contains(where:{$0.range.length>0}) {
            return cutSelections(text:text,selections:selections,primarySelectionID:primarySelectionID,rectangular:rectangular,includeClipboard:false,rectangleIsThin:rectangleIsThin)
        }
        let index=PatchLineIndex(text:text),units=Array(text.utf16)
        if !rectangular,let main=selections.first(where:{$0.id==primarySelectionID}) {
            var start=main.caret,end=start
            if backwards,start>0 {
                start-=1
                if start>0,units[start]==10 && units[start-1]==13 || (0xdc00...0xdfff).contains(units[start]) {start-=1}
            } else if !backwards,end<units.count {
                end+=1
                if end<units.count,units[end-1]==13 && units[end]==10 || (0xdc00...0xdfff).contains(units[end]) {end+=1}
            }
            return cutSelections(text:text,selections:[.init(id:main.id,anchor:start,caret:end)],primarySelectionID:main.id,rectangular:false,includeClipboard:false)
        }
        let targets=rectangular ? selections:selections.filter {$0.id==primarySelectionID}
        var expanded:[PatchLineEditSelection]=[]
        for entry in targets {
            let line=index.lineIndex(atUTF16Offset:entry.caret)!,range=index.range(forLine:line)!
            var end=NSMaxRange(range)
            if end>range.location,units[end-1]==10 {end-=1;if end>range.location,units[end-1]==13 {end-=1}}
            else if end>range.location,units[end-1]==13 {end-=1}
            var start=entry.caret,finish=start
            if backwards,start>range.location {
                start-=1;if start>range.location,(0xdc00...0xdfff).contains(units[start]) {start-=1}
            } else if !backwards,finish<end {
                finish+=1;if finish<end,(0xdc00...0xdfff).contains(units[finish]) {finish+=1}
            }
            expanded.append(.init(id:entry.id,anchor:start,caret:finish))
        }
        guard let deleted=cutSelections(text:text,selections:expanded,primarySelectionID:primarySelectionID,rectangular:rectangular,includeClipboard:false) else {return nil}
        return rectangleResult(deleted,input:selections,primary:primarySelectionID,duplicate:false,thinBefore:rectangleIsThin)
    }
}
