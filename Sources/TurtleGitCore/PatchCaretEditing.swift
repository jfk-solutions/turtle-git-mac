// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Adapted from pinned Scintilla Document.cxx:2890–2985 at TortoiseGit
/// 7338078f8ddd924b8cddee35f512f2286072136d (Scintilla attribution in NOTICE).
/// Word-part rules retain ASCII case/digits,
/// punctuation and the default '_' word separator. Offsets are native UTF-16.
/// Native carets never split a composed character or CRLF, even where the byte
/// editor could stop between Unicode scalars. No Unicode normalization occurs.
public enum PatchCaretEditing {
    private enum Kind:Equatable { case lower,upper,digit,punctuation,space,nonASCII,other }
    private static func kind(_ value:UInt32)->Kind {
        switch value {
        case 97...122:return .lower
        case 65...90:return .upper
        case 48...57:return .digit
        case 33...47,58...64,91...96,123...126:return .punctuation
        case 9...13,32:return .space
        case 128...UInt32.max:return .nonASCII
        default:return .other
        }
    }
    private static func insideCRLF(_ text:NSString,_ offset:Int)->Bool {
        offset>0 && offset<text.length && text.character(at:offset-1)==13 && text.character(at:offset)==10
    }
    public static func wordPart(text:String,caret:Int,backwards:Bool)->Int? {
        let shown=text as NSString
        guard caret>=0,caret<=shown.length,!insideCRLF(shown,caret),
              caret==shown.length || caret==shown.rangeOfComposedCharacterSequence(at:caret).location else {return nil}
        let count=shown.length
        func before(_ at:Int)->Int {
            guard at>0 else{return 0}
            let last=shown.character(at:at-1)
            return at>1 && (0xdc00...0xdfff).contains(last) && (0xd800...0xdbff).contains(shown.character(at:at-2)) ? at-2:at-1
        }
        func value(_ at:Int)->UInt32 {
            guard at>=0,at<count else{return 0}
            let first=shown.character(at:at)
            if (0xd800...0xdbff).contains(first),at+1<count {
                let last=shown.character(at:at+1)
                if (0xdc00...0xdfff).contains(last) {return 0x10000+(UInt32(first)-0xd800)*0x400+UInt32(last)-0xdc00}
            }
            return UInt32(first)
        }
        func after(_ at:Int)->Int {min(count,at+(value(at)>0xffff ? 2:1))}
        func category(_ at:Int)->Kind {kind(value(at))}
        var p=caret
        if backwards {
            guard p>0 else{return 0};p=before(p)
            if value(p)==95 {while p>0 && value(p)==95 {p=before(p)}}
            if p>0 {
                let initial=category(p);p=before(p)
                if initial == .lower {
                    while p>0 && category(p) == .lower {p=before(p)}
                    if category(p) != .upper && category(p) != .lower {p=after(p)}
                } else if initial != .other {
                    while p>0 && category(p)==initial {p=before(p)}
                    if category(p) != initial {p=after(p)}
                } else {p=after(p)}
            }
        } else {
            if p<count && value(p)==95 {while p<count && value(p)==95 {p=after(p)}}
            let initial=category(p)
            if initial == .upper {
                if category(after(p)) == .lower {
                    p=after(p);while p<count && category(p) == .lower {p=after(p)}
                } else {while p<count && category(p) == .upper {p=after(p)}}
                if category(p) == .lower && category(before(p)) == .upper {p=before(p)}
            } else if initial != .other {
                while p<count && category(p)==initial {p=after(p)}
            } else if p<count {p=after(p)}
        }
        let target=insideCRLF(shown,p) ? (backwards ? p-1:p+1):p
        guard target<shown.length else{return shown.length}
        let composed=shown.rangeOfComposedCharacterSequence(at:target)
        if target==composed.location {return target}
        return backwards ? composed.location:NSMaxRange(composed)
    }
    /// Ordinary typing replaces the explicit selection, otherwise one complete
    /// native character, without consuming an existing line ending. Newline and
    /// paste use their own insertion paths. The source likewise overstrikes only
    /// InsertCharacter, not Editor::NewLine/Paste; additional typing is disabled.
    public static func overtype(text:String,selections:[PatchLineEditSelection],primarySelectionID:Int,replacement:String)->PatchLineEditPlan? {
        guard !replacement.isEmpty,let selected=selections.first(where:{$0.id==primarySelectionID}) else{return nil}
        let shown=text as NSString,r=selected.range
        guard r.location>=0,NSMaxRange(r)<=shown.length,
              !insideCRLF(shown,r.location),!insideCRLF(shown,NSMaxRange(r)),
              r.location==shown.length || shown.rangeOfComposedCharacterSequence(at:r.location).location==r.location,
              NSMaxRange(r)==shown.length || shown.rangeOfComposedCharacterSequence(at:NSMaxRange(r)).location==NSMaxRange(r) else{return nil}
        var end=NSMaxRange(r)
        if r.length==0,r.location<shown.length,!replacement.contains("\n"),!replacement.contains("\r") {
            let unit=shown.character(at:r.location)
            if unit != 10 && unit != 13 {end=NSMaxRange(shown.rangeOfComposedCharacterSequence(at:r.location))}
        }
        return PatchLineEditing.replacePrimarySelection(text:text,selections:[.init(id:selected.id,anchor:r.location,caret:end)],primarySelectionID:selected.id,replacement:replacement)
    }
}
