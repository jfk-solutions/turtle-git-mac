// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum PatchLineEditCommand: String, CaseIterable, Sendable {
    case copyLines, cutLines, deleteLine, duplicate, transpose, indent, dedent, tab, backTab
}
public enum PatchLineEditSegment: Equatable, Sendable {
    case source(NSRange)
    case inserted(String)
}
/// A source-bound transaction. Source segments retain opaque backing bytes;
/// replacementText alone must not be used to regenerate a moved byte packet.
public struct PatchLineEditPlan: Sendable {
    public let originalText: String
    public var sourceText: String { originalText }
    public let resultText: String
    public let segments: [PatchLineEditSegment]
    public let selectionAnchor: Int
    public let selectionCaret: Int
    public let clipboardText: String?
    public var selectionRange: NSRange { NSRange(location: min(selectionAnchor, selectionCaret), length: abs(selectionAnchor-selectionCaret)) }
    public var replacementRange: NSRange { NSRange(location: 0, length: originalText.utf16.count) }
    public var replacementText: String { resultText }
    public var changesText: Bool { !GitReferenceName.equal(originalText, resultText) }
    public var hasReplacement: Bool { segments != [.source(replacementRange)] }
}

public enum PatchLineEditing {
    /// Ordinary stream selections, in displayed UTF-16 coordinates. Inserted
    /// endings default to the source editor's non-Windows LF platform policy.
    public static func plan(text: String, anchor: Int, caret: Int, command: PatchLineEditCommand,
                            tabWidth: Int = 4, useTabs: Bool = true, lineEnding: String = "\n") -> PatchLineEditPlan? {
        guard (1...1000).contains(tabWidth), ["\n", "\r", "\r\n"].contains(lineEnding),
              UnifiedDiffByteSpan.substring(text, from: anchor, to: anchor) != nil,
              UnifiedDiffByteSpan.substring(text, from: caret, to: caret) != nil else { return nil }
        var work = Work(original: text), a = anchor, c = caret
        var clipboard: String?
        let index = PatchLineIndex(text: text), low = min(a,c), high = max(a,c)
        let first = index.lineIndex(atUTF16Offset: low)!, last = index.lineIndex(atUTF16Offset: high)!
        let line = index.lineIndex(atUTF16Offset: c)!
        func deleted(_ p: Int, _ range: NSRange) -> Int { p <= range.location ? p : max(range.location, p-range.length) }
        switch command {
        case .copyLines, .cutLines:
            let range = NSRange(location: index.lineStarts[first], length: NSMaxRange(index.range(forLine:last)!)-index.lineStarts[first])
            clipboard = work.substring(range)
            if command == .cutLines { work.replace(range, with: []); a=range.location;c=a }
        case .deleteLine:
            let range=index.range(forLine:line)!
            work.replace(range, with: []);a=deleted(a,range);c=deleted(c,range)
        case .duplicate:
            if low != high {
                work.replace(NSRange(location:high,length:0), with:[.source(NSRange(location:low,length:high-low))])
            } else {
                let content=work.contentRange(line:line), count=lineEnding.utf16.count+content.length
                work.replace(NSRange(location:NSMaxRange(content),length:0),with:[.inserted(lineEnding),.source(content)])
                if c > NSMaxRange(content) { c += count;a=c }
            }
        case .transpose:
            if line>0 {
                let previous=work.contentRange(line:line-1), current=work.contentRange(line:line)
                let ending=NSRange(location:NSMaxRange(previous),length:current.location-NSMaxRange(previous))
                work.replace(NSRange(location:previous.location,length:NSMaxRange(current)-previous.location),with:[.source(current),.source(ending),.source(previous)])
                c=previous.location+current.length+ending.length;a=c
            }
        case .indent, .dedent, .tab, .backTab:
            let forward=command == .indent || command == .tab
            let lineIndent=command == .indent || command == .dedent
            if first != last || lineIndent {
                var bottom=last
                // Explicit macOS menu actions include the current line at
                // column zero; Tab/BackTab retain the source multiline rule.
                if first != last, high==index.lineStarts[last] { bottom-=1 }
                if bottom>=first {
                    // One forward pass over the selected source, rather than
                    // rebuilding/reindexing the document after each line.
                    let units=Array(text.utf16),shown=text as NSString
                    var pieces:[PatchLineEditSegment]=[],cursor=0
                    for n in first...bottom {
                        let range=index.range(forLine:n)!
                        var end=NSMaxRange(range)
                        if end>range.location,units[end-1]==10 {end-=1;if end>range.location,units[end-1]==13 {end-=1}}
                        else if end>range.location,units[end-1]==13 {end-=1}
                        var position=range.location,columns=0
                        while position<end {
                            if units[position]==32 {columns+=1}
                            else if units[position]==9 {columns+=tabWidth-columns%tabWidth}
                            else {break}
                            position+=1
                        }
                        if forward && end==range.location {continue}
                        let whitespace=NSRange(location:range.location,length:position-range.location)
                        let value=indentation(max(0,columns+(forward ? tabWidth : -tabWidth)),tab:tabWidth,useTabs:useTabs)
                        if GitReferenceName.equal(shown.substring(with:whitespace),value) {continue}
                        pieces.append(.source(NSRange(location:cursor,length:range.location-cursor)))
                        if !value.isEmpty {pieces.append(.inserted(value))}
                        cursor=position
                    }
                    if !pieces.isEmpty || cursor>0 {
                        pieces.append(.source(NSRange(location:cursor,length:index.utf16Length-cursor)))
                        work.segments=pieces
                    }
                }
                let next=PatchLineIndex(text:work.text), start=next.lineStarts[first]
                let end=bottom+1<next.lineCount ? next.lineStarts[bottom+1] : next.utf16Length
                a=anchor<caret ? start:end;c=anchor<caret ? end:start
            } else {
                if forward,low != high {
                    let range=NSRange(location:low,length:high-low);work.replace(range,with:[]);a=low;c=low
                }
                let indent=work.indentation(line:line,tab:tabWidth), content=work.contentRange(line:line)
                let column=work.column(from:content.location,to:c,tab:tabWidth)
                if column<=indent.columns {
                    let columns=forward ? indent.columns+tabWidth-indent.columns%tabWidth : max(0,indent.columns-tabWidth)
                    let value=indentation(columns,tab:tabWidth,useTabs:useTabs)
                    work.replace(indent.range,with:[.inserted(value)]);c=indent.range.location+value.utf16.count;a=c
                } else if forward {
                    let value=useTabs ? "\t" : String(repeating:" ",count:tabWidth-column%tabWidth)
                    work.replace(NSRange(location:c,length:0),with:[.inserted(value)]);c+=value.utf16.count;a=c
                } else {
                    let goal=max(0,((column-1)/tabWidth)*tabWidth)
                    c=work.offset(atColumn:goal,line:line,tab:tabWidth);a=c
                }
            }
        }
        return PatchLineEditPlan(originalText:text,resultText:work.text,segments:work.segments,selectionAnchor:a,selectionCaret:c,clipboardText:clipboard)
    }
    private static func indentation(_ columns:Int,tab:Int,useTabs:Bool)->String {
        useTabs ? String(repeating:"\t",count:columns/tab)+String(repeating:" ",count:columns%tab) : String(repeating:" ",count:columns)
    }
    private struct Work {
        let original:NSString
        var segments:[PatchLineEditSegment]
        init(original:String) { self.original=original as NSString;segments=[.source(NSRange(location:0,length:original.utf16.count))] }
        func rendered(_ segment:PatchLineEditSegment)->String {
            switch segment {case let .source(r): return original.substring(with:r);case let .inserted(s):return s}
        }
        var text:String { segments.map(rendered).joined() }
        func substring(_ r:NSRange)->String { (text as NSString).substring(with:r) }
        func slice(_ range:NSRange)->[PatchLineEditSegment] {
            var result:[PatchLineEditSegment]=[],offset=0
            for segment in segments {
                let value=rendered(segment),end=offset+value.utf16.count
                let low=max(offset,range.location),high=min(end,NSMaxRange(range))
                if low<high {
                    switch segment {
                    case let .source(r):result.append(.source(NSRange(location:r.location+low-offset,length:high-low)))
                    case .inserted:result.append(.inserted((value as NSString).substring(with:NSRange(location:low-offset,length:high-low))))
                    }
                }
                offset=end
            }
            return result
        }
        mutating func replace(_ range:NSRange,with pieces:[PatchLineEditSegment]) {
            if range.length==0,pieces.isEmpty {return}
            // New literals equal to the selected source are no mutation. Retain
            // provenance rather than canonicalizing already-correct whitespace.
            if GitReferenceName.equal(pieces.map(rendered).joined(),substring(range)),pieces.allSatisfy({if case .inserted=$0{return true};return false}) {return}
            segments=slice(NSRange(location:0,length:range.location))+pieces+slice(NSRange(location:NSMaxRange(range),length:text.utf16.count-NSMaxRange(range)))
        }
        func contentRange(line:Int)->NSRange {
            let range=PatchLineIndex(text:text).range(forLine:line)!,units=Array(text.utf16)
            var end=NSMaxRange(range)
            if end>range.location,units[end-1]==10 {end-=1;if end>range.location,units[end-1]==13 {end-=1}}
            else if end>range.location,units[end-1]==13 {end-=1}
            return NSRange(location:range.location,length:end-range.location)
        }
        func indentation(line:Int,tab:Int)->(range:NSRange,columns:Int) {
            let r=contentRange(line:line),s=substring(r);var count=0,column=0
            for u in s.utf16 {if u==32 {column+=1} else if u==9 {column+=tab-column%tab} else {break};count+=1}
            return (NSRange(location:r.location,length:count),column)
        }
        func column(from:Int,to:Int,tab:Int)->Int {
            var column=0
            for scalar in substring(NSRange(location:from,length:to-from)).unicodeScalars {column += scalar.value==9 ? tab-column%tab:1}
            return column
        }
        func offset(atColumn goal:Int,line:Int,tab:Int)->Int {
            let range=contentRange(line:line);var offset=range.location,column=0
            for scalar in substring(range).unicodeScalars {
                let next=column+(scalar.value==9 ? tab-column%tab:1)
                if next>goal {break};column=next;offset+=scalar.utf16.count
            }
            return offset
        }
    }
}
