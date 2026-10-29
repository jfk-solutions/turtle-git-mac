// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum PatchSelectionEditCommand:String,CaseIterable,Sendable {
    case lowerCase,upperCase,deleteWordLeft,deleteWordRight,deleteLineLeft,deleteLineRight
}
/// Source Scintilla Editor::ChangeCaseOfSelection/DelWordOrLine. Plans retain
/// unchanged source fragments; display strings never regenerate opaque bytes.
public enum PatchSelectionEditing {
    private struct Edit {let range:NSRange;let text:String}
    public static func plan(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,rectangular:Bool,
                            command:PatchSelectionEditCommand,rectangleAnchor:Int?=nil,rectangleCaret:Int?=nil,
                            rectangleIsThin:Bool=false,rectangleRowsExplicit:Bool=false)->PatchLineEditPlan? {
        let source=text as NSString,length=source.length
        func valid(_ p:Int)->Bool {
            p>=0 && p<=length && !(p>0 && p<length && source.character(at:p-1)==13 && source.character(at:p)==10) &&
            (p==length || source.rangeOfComposedCharacterSequence(at:p).location==p)
        }
        guard !selections.isEmpty,Set(selections.map(\.id)).count==selections.count,
              let primary=selections.first(where:{$0.id==primarySelectionID}),
              selections.allSatisfy({valid($0.anchor) && valid($0.caret)}),
              rectangleAnchor.map(valid) ?? true,rectangleCaret.map(valid) ?? true else{return nil}
        let ordered=selections.sorted{$0.range.location<$1.range.location}
        for pair in zip(ordered,ordered.dropFirst()) where NSMaxRange(pair.0.range)>pair.1.range.location {return nil}
        let converting=command == .lowerCase || command == .upperCase
        var edits:[Edit]=[]
        if converting {
            let mapping=command == .lowerCase ? UnifiedDiffCaseMapping.lower:UnifiedDiffCaseMapping.upper
            for row in ordered {
                var offset=row.range.location
                for scalar in source.substring(with:row.range).unicodeScalars {
                    let n=scalar.utf16.count
                    if let mapped=mapping[scalar.value] {
                        var replacement=String.UnicodeScalarView()
                        for value in mapped {guard let value=Unicode.Scalar(value) else{return nil};replacement.append(value)}
                        edits.append(Edit(range:NSRange(location:offset,length:n),text:String(replacement)))
                    }
                    offset+=n
                }
            }
        } else {
            let caret=primary.caret,left=command == .deleteWordLeft || command == .deleteLineLeft
            let target:Int
            if command == .deleteLineLeft || command == .deleteLineRight {
                let index=PatchLineIndex(text:text)
                guard let row=index.lineIndex(atUTF16Offset:caret),let full=index.range(forLine:row) else{return nil}
                if left {target=full.location}
                else {
                    var end=NSMaxRange(full)
                    if end>full.location,source.character(at:end-1)==10 {end-=1;if end>full.location,source.character(at:end-1)==13 {end-=1}}
                    else if end>full.location,source.character(at:end-1)==13 {end-=1}
                    target=max(caret,end)
                }
            } else {
                target=wordTarget(text:text,caret:caret,left:left)
            }
            edits=[Edit(range:NSRange(location:min(caret,target),length:abs(caret-target)),text:"")]
        }
        edits=edits.filter{$0.range.length>0 || !$0.text.isEmpty}
        // All changes use original coordinates. Assemble retained source and
        // changed literals in one forward pass rather than reslicing a growing
        // document once for every converted scalar.
        var segments:[PatchLineEditSegment]=[],rendered:[String]=[]
        segments.reserveCapacity(edits.count*2+1);rendered.reserveCapacity(edits.count*2+1)
        var cursor=0,ends:[Int]=[],deltas=[0]
        ends.reserveCapacity(edits.count);deltas.reserveCapacity(edits.count+1)
        for edit in edits {
            if cursor<edit.range.location {
                let span=NSRange(location:cursor,length:edit.range.location-cursor)
                segments.append(.source(span));rendered.append(source.substring(with:span))
            }
            if !edit.text.isEmpty {segments.append(.inserted(edit.text));rendered.append(edit.text)}
            cursor=NSMaxRange(edit.range);ends.append(cursor)
            deltas.append(deltas.last!+edit.text.utf16.count-edit.range.length)
        }
        if cursor<length {
            let span=NSRange(location:cursor,length:length-cursor)
            segments.append(.source(span));rendered.append(source.substring(with:span))
        }
        if edits.isEmpty {segments=[.source(NSRange(location:0,length:length))]}
        let result=rendered.joined()
        func moved(_ p:Int)->Int {
            // Upper-bound search counts edits already completed before p. A
            // point within a removed fragment clamps to that fragment's start.
            var low=0,high=ends.count
            while low<high {let mid=(low+high)/2;if ends[mid]<=p {low=mid+1}else{high=mid}}
            if low<edits.count,p>=edits[low].range.location {return edits[low].range.location+deltas[low]}
            return p+deltas[low]
        }
        let rows:[PatchLineEditSelection]
        if converting {
            rows=selections.map{.init(id:$0.id,anchor:moved($0.anchor),caret:moved($0.caret))}
        } else {
            let right=command == .deleteWordRight || command == .deleteLineRight
            rows=[.init(id:primary.id,anchor:moved(right ? primary.caret:primary.anchor),caret:moved(primary.caret))]
        }
        guard let selected=rows.first(where:{$0.id==primarySelectionID}) else{return nil}
        return PatchLineEditPlan(originalText:text,resultText:result,segments:segments,
            selectionAnchor:selected.anchor,selectionCaret:selected.caret,clipboardText:nil,selections:rows,
            primarySelectionID:primarySelectionID,rectangular:rectangular,
            rectangleAnchor:rectangleAnchor.map(moved),rectangleCaret:rectangleCaret.map(moved),rectangleIsThin:rectangleIsThin,
            rectangleRowsExplicit:rectangular)
    }
    private static func classification(_ cp:UInt32)->Int {
        let ranges=UnifiedDiffCaseMapping.wordClasses
        var low=0,high=ranges.count
        while low+1<high {let mid=(low+high)/2;if ranges[mid].0<=cp {low=mid}else{high=mid}}
        return ranges[low].1
    }
    private static func wordTarget(text:String,caret:Int,left:Bool)->Int {
        let scalars=Array(text.unicodeScalars)
        var positions=[0];positions.reserveCapacity(scalars.count+1)
        for scalar in scalars {positions.append(positions.last!+scalar.utf16.count)}
        var at=positions.firstIndex(of:caret)!
        if left {
            while at>0 && classification(scalars[at-1].value)==0 {at-=1}
            if at>0 {let kind=classification(scalars[at-1].value);while at>0 && classification(scalars[at-1].value)==kind {at-=1}}
        } else if at<scalars.count {
            let kind=classification(scalars[at].value)
            while at<scalars.count && classification(scalars[at].value)==kind {at+=1}
            while at<scalars.count && classification(scalars[at].value)==0 {at+=1}
        }
        var result=positions[at];let source=text as NSString
        // Native text cannot leave half a composed sequence or CRLF behind.
        if result>0 && result<source.length && source.character(at:result-1)==13 && source.character(at:result)==10 {result+=left ? -1:1}
        if result<source.length {let part=source.rangeOfComposedCharacterSequence(at:result);if part.location != result {result=left ? part.location:NSMaxRange(part)}}
        return result
    }
}
