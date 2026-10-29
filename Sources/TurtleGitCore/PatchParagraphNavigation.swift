// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Pinned Scintilla Document.cxx::IsWhiteLine/ParaUp/ParaDown (1970–2011),
/// TortoiseGit7338078f8ddd924b8cddee35f512f2286072136d. Paragraphs are blocks
/// of logical lines separated only by space/tab-only lines. Unicode paragraph
/// separators and other whitespace are ordinary source text in this editor.
/// This computes a UTF-16 position only: no byte buffer, selection or Undo state
/// is mutated. The native owner applies selection extension and view scrolling.
public enum PatchParagraphNavigation {
    public static func position(text:String,caret:Int,backwards:Bool)->Int? {
        let source=text as NSString,length=source.length
        guard caret>=0,caret<=length,
              !(caret>0 && caret<length && source.character(at:caret-1)==13 && source.character(at:caret)==10),
              caret==length || source.rangeOfComposedCharacterSequence(at:caret).location==caret else{return nil}
        let index=PatchLineIndex(text:text)
        guard var line=index.lineIndex(atUTF16Offset:caret) else{return nil}
        func start(_ row:Int)->Int {index.lineStarts[row]}
        func end(_ row:Int)->Int {
            var end=row+1<index.lineCount ? start(row+1):length
            if end>start(row),source.character(at:end-1)==10 {
                end-=1
                if end>start(row),source.character(at:end-1)==13 {end-=1}
            } else if end>start(row),source.character(at:end-1)==13 {end-=1}
            return end
        }
        func white(_ row:Int)->Bool {
            let first=start(row),last=end(row)
            for offset in first..<last {
                let unit=source.character(at:offset)
                if unit != 32 && unit != 9 {return false}
            }
            return true
        }
        if backwards {
            if caret==start(line) {line-=1}
            while line>=0 && white(line) {line-=1}
            while line>=0 && !white(line) {line-=1}
            return start(line+1)
        }
        while line<index.lineCount && !white(line) {line+=1}
        while line<index.lineCount && white(line) {line+=1}
        return line<index.lineCount ? start(line):end(index.lineCount-1)
    }
}
