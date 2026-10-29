// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Logical CharLeft/CharRight targets from Scintilla PositionMove, adapted to
/// native composed-character boundaries. Selection collapse and rectangle rules
/// belong to the command consumer; this operation never edits source packets.
public enum PatchCharacterNavigation {
    public static func position(text:String,caret:Int,backwards:Bool)->Int? {
        guard PatchBoundaryNavigation.position(text:text,caret:caret,boundary:.documentStart) != nil else{return nil}
        let source=text as NSString
        if backwards {
            guard caret>0 else{return 0}
            if caret>=2,source.character(at:caret-2)==13,source.character(at:caret-1)==10 {return caret-2}
            return source.rangeOfComposedCharacterSequence(at:caret-1).location
        }
        guard caret<source.length else{return source.length}
        if caret+1<source.length,source.character(at:caret)==13,source.character(at:caret+1)==10 {return caret+2}
        return NSMaxRange(source.rangeOfComposedCharacterSequence(at:caret))
    }
}
