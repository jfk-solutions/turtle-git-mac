import XCTest
@testable import TurtleGitCore

final class UnifiedDiffSearchTests:XCTestCase {
    func testExactUnicodeSpellingsAreNotNormalized() {
        let text="café cafe\u{301} CAFÉ"
        XCTAssertEqual(UnifiedDiffSearch.find("cafe\u{301}",in:text,from:0),NSRange(location:5,length:5))
        XCTAssertEqual(UnifiedDiffSearch.find("café",in:text,from:5),NSRange(location:11,length:4))
        XCTAssertNil(UnifiedDiffSearch.find("café",in:"cafe\u{301}",from:0,matchCase:true))
        XCTAssertNil(UnifiedDiffSearch.find("cafe",in:"café",from:0))
    }
    func testPinnedUnicodeFoldExpansionsAndSourceBoundaries() {
        XCTAssertEqual(UnifiedDiffSearch.find("STRASSE",in:"Straße",from:0),NSRange(location:0,length:6))
        XCTAssertEqual(UnifiedDiffSearch.find("ß",in:"ss",from:0),NSRange(location:0,length:2))
        XCTAssertNil(UnifiedDiffSearch.find("s",in:"ß",from:0))
        XCTAssertEqual(UnifiedDiffSearch.find("SS",in:"ßß",from:2,backwards:true),NSRange(location:1,length:1))
        XCTAssertEqual(UnifiedDiffSearch.find("ffi",in:"xﬃx",from:0),NSRange(location:1,length:1))
        XCTAssertNil(UnifiedDiffSearch.find("fi",in:"ﬃ",from:0))
        XCTAssertEqual(UnifiedDiffSearch.find("i\u{307}",in:"İ",from:0),NSRange(location:0,length:1))
        XCTAssertNil(UnifiedDiffSearch.find("i",in:"İı",from:0))
        XCTAssertEqual(UnifiedDiffSearch.find("σ",in:"Σς",from:1),NSRange(location:1,length:1))
    }
    func testCaseSensitiveSearchUsesExactScalarSequence() {
        XCTAssertNil(UnifiedDiffSearch.find("SS",in:"ß",from:0,matchCase:true))
        XCTAssertNil(UnifiedDiffSearch.find("needle",in:"NEEDLE",from:0,matchCase:true))
        XCTAssertEqual(UnifiedDiffSearch.find("NEEDLE",in:"needle NEEDLE",from:0,matchCase:true),NSRange(location:7,length:6))
    }
    func testUTF16CursorAndNoWrap() {
        let text="🦎 hit\r\n雪 hit"
        XCTAssertEqual(UnifiedDiffSearch.find("hit",in:text,from:0),NSRange(location:3,length:3))
        XCTAssertEqual(UnifiedDiffSearch.find("hit",in:text,from:6),NSRange(location:10,length:3))
        XCTAssertNil(UnifiedDiffSearch.find("hit",in:text,from:13))
        XCTAssertNil(UnifiedDiffSearch.find("hit",in:text,from:0,backwards:true))
        XCTAssertEqual(UnifiedDiffSearch.find("hit",in:text,from:13,backwards:true),NSRange(location:10,length:3))
        XCTAssertEqual(UnifiedDiffSearch.find("🦎",in:text,from:0),NSRange(location:0,length:2))
        XCTAssertNil(UnifiedDiffSearch.find("🦎",in:text,from:1))
        XCTAssertNil(UnifiedDiffSearch.find("🦎",in:text,from:1,backwards:true))
    }
    func testOverlapsLiteralPunctuationAndNull() {
        XCTAssertEqual(UnifiedDiffSearch.find("aba",in:"ababa",from:5,backwards:true),NSRange(location:2,length:3))
        XCTAssertEqual(UnifiedDiffSearch.find(".*",in:"a.*b",from:0),NSRange(location:1,length:2))
        XCTAssertEqual(UnifiedDiffSearch.find("\0b",in:"a\0b",from:0),NSRange(location:1,length:2))
        XCTAssertNil(UnifiedDiffSearch.find("",in:"abc",from:0))
        XCTAssertNil(UnifiedDiffSearch.find("abc",in:"",from:0))
    }
    func testCursorClampingAndCrossLineSelection() {
        XCTAssertEqual(UnifiedDiffSearch.find("a",in:"abc",from:-10),NSRange(location:0,length:1))
        XCTAssertEqual(UnifiedDiffSearch.find("bc",in:"abc",from:Int.max,backwards:true),NSRange(location:1,length:2))
        XCTAssertEqual(UnifiedDiffSearch.find("a\r\nb",in:"a\r\nb",from:0),NSRange(location:0,length:4))
    }
    func testLongRepeatedPrefixAndExpandingFold() {
        let text=String(repeating:"a",count:50000)+"ß"
        let query=String(repeating:"a",count:1500)+"SS"
        XCTAssertEqual(UnifiedDiffSearch.find(query,in:text,from:0),NSRange(location:48500,length:1501))
    }
    func testMatcherAgainstIndependentWholeScalarOracle() {
        func folded(_ text:String,_ exact:Bool)->[UInt32] {
            text.unicodeScalars.flatMap {exact ? [$0.value]:UnifiedDiffCaseFold.mappings[$0.value] ?? [$0.value]}
        }
        func oracle(_ query:String,_ text:String,_ cursor:Int,_ backwards:Bool,_ exact:Bool)->NSRange? {
            let scalars=Array(text.unicodeScalars),needle=folded(query,exact)
            guard !needle.isEmpty else{return nil}
            var positions=[0]
            for scalar in scalars {positions.append(positions.last!+(scalar.value>0xFFFF ? 2:1))}
            var candidates=[NSRange]()
            for start in scalars.indices {
                for end in (start+1)...scalars.count {
                    if backwards ? positions[end]>cursor:positions[start]<cursor {continue}
                    let piece=String(String.UnicodeScalarView(scalars[start..<end]))
                    if folded(piece,exact)==needle {candidates.append(NSRange(location:positions[start],length:positions[end]-positions[start]))}
                }
            }
            return backwards ? candidates.last:candidates.first
        }
        let atoms=["a","A","s","ß","İ","Σ","ς","🦎","é","e\u{301}"]
        let texts=atoms+atoms.map{$0+"s"}+["ßSSß","aAa","ababa","é e\u{301}","🦎ß🦎"]
        let queries=atoms+["ss","SS","sss","σ","i\u{307}","é","e\u{301}","aba"]
        for text in texts {
            for query in queries {
                for cursor in 0...text.utf16.count {
                    for backwards in [false,true] {
                        for exact in [false,true] {
                            XCTAssertEqual(UnifiedDiffSearch.find(query,in:text,from:cursor,backwards:backwards,matchCase:exact),oracle(query,text,cursor,backwards,exact),"\(text.debugDescription), \(query.debugDescription), \(cursor), back=\(backwards), exact=\(exact)")
                        }
                    }
                }
            }
        }
    }
}
