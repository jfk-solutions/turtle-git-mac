// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum PatchBoundary:String,CaseIterable,Sendable {
    case previousWord,nextWord,smartLineStart,lineEnd,documentStart,documentEnd
}

/// Logical navigation from pinned Scintilla Document::NextWordStart,
/// VCHomePosition and LineEndPosition. Coordinates are native UTF-16 offsets;
/// document bytes remain owned by the edit buffer and are never regenerated.
public enum PatchBoundaryNavigation {
    public static func position(text:String,caret:Int,boundary:PatchBoundary)->Int? {
        let source=text as NSString,length=source.length
        guard caret>=0,caret<=length,
              !(caret>0 && caret<length && source.character(at:caret-1)==13 && source.character(at:caret)==10),
              caret==length || source.rangeOfComposedCharacterSequence(at:caret).location==caret else{return nil}
        switch boundary {
        case .documentStart:return 0
        case .documentEnd:return length
        case .previousWord,.nextWord:
            let left=boundary == .previousWord
            var at=caret
            // Read only the traversed context. In particular, repeated local
            // navigation does not allocate a scalar/position array for the file.
            if left {
                while at>0 {
                    let previous=scalarBefore(source,at)
                    guard classification(previous.value)==0 else{break}
                    at=previous.start
                }
                if at>0 {
                    let kind=classification(scalarBefore(source,at).value)
                    while at>0 {
                        let previous=scalarBefore(source,at)
                        guard classification(previous.value)==kind else{break}
                        at=previous.start
                    }
                }
            } else if at<length {
                let kind=classification(scalarAfter(source,at).value)
                while at<length {
                    let next=scalarAfter(source,at)
                    guard classification(next.value)==kind else{break}
                    at=next.end
                }
                while at<length {
                    let next=scalarAfter(source,at)
                    guard classification(next.value)==0 else{break}
                    at=next.end
                }
            }
            return safeEndpoint(source,at,left:left)
        case .smartLineStart,.lineEnd:
            var start=caret,end=caret
            while start>0 {
                let unit=source.character(at:start-1)
                if unit==13 || unit==10 {break}
                start-=1
            }
            while end<length {
                let unit=source.character(at:end)
                if unit==13 || unit==10 {break}
                end+=1
            }
            if boundary == .lineEnd {return end}
            var first=start
            while first<end {
                let unit=source.character(at:first)
                if unit != 32 && unit != 9 {break}
                first+=1
            }
            let firstEndpoint=safeEndpoint(source,first,left:false)
            return caret==firstEndpoint ? start:firstEndpoint
        }
    }
    private static func classification(_ scalar:UInt32)->Int {
        let ranges=UnifiedDiffCaseMapping.wordClasses
        var low=0,high=ranges.count
        while low+1<high {
            let middle=(low+high)/2
            if ranges[middle].0<=scalar {low=middle}else{high=middle}
        }
        return ranges[low].1
    }
    private static func scalarAfter(_ text:NSString,_ offset:Int)->(value:UInt32,end:Int) {
        let first=text.character(at:offset)
        if first>=0xd800 && first<=0xdbff,offset+1<text.length {
            let second=text.character(at:offset+1)
            if second>=0xdc00 && second<=0xdfff {
                return (0x10000+(UInt32(first)-0xd800)*0x400+UInt32(second)-0xdc00,offset+2)
            }
        }
        return (UInt32(first),offset+1)
    }
    private static func scalarBefore(_ text:NSString,_ offset:Int)->(value:UInt32,start:Int) {
        let last=text.character(at:offset-1)
        if last>=0xdc00 && last<=0xdfff,offset>=2 {
            let first=text.character(at:offset-2)
            if first>=0xd800 && first<=0xdbff {
                return (0x10000+(UInt32(first)-0xd800)*0x400+UInt32(last)-0xdc00,offset-2)
            }
        }
        return (UInt32(last),offset-1)
    }
    private static func safeEndpoint(_ source:NSString,_ position:Int,left:Bool)->Int {
        var result=position
        if result>0 && result<source.length && source.character(at:result-1)==13 && source.character(at:result)==10 {
            result+=left ? -1:1
        }
        if result<source.length {
            let composed=source.rangeOfComposedCharacterSequence(at:result)
            if composed.location != result {result=left ? composed.location:NSMaxRange(composed)}
        }
        return result
    }
}
