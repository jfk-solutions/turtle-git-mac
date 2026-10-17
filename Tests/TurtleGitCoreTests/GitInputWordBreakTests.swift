// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GitInputWordBreakTests:XCTestCase {
    func testSourceModesAndDefaultDoNotWritePreferences() {
        let suite="TurtleGit.WordBreak."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        XCTAssertTrue(GitInputWordBreak(defaults:defaults).enabled(combo:true));XCTAssertNil(defaults.object(forKey:"UseCustomWordBreak"))
        for (mode,plain,combo) in [(0,false,false),(1,true,false),(2,true,true),(3,true,false),(Int(UInt32.max),true,false)] {
            defaults.set(mode,forKey:"UseCustomWordBreak");let policy=GitInputWordBreak(defaults:defaults)
            XCTAssertEqual(policy.enabled(combo:false),plain);XCTAssertEqual(policy.enabled(combo:true),combo)
        }
    }
    func testCompleteASCIIDelimitersAndURLSchemeExceptions() {
        let punctuation=Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".utf16),spaces:Set<UInt16>=[9,10,11,12,13,32]
        for value in UInt16(0)...127 {XCTAssertEqual(GitInputWordBreak.isDelimiter([value],at:0),punctuation.contains(value)||spaces.contains(value),"ASCII \(value)")}
        let scheme=Array("https://host".utf16)
        XCTAssertFalse(GitInputWordBreak.isDelimiter(scheme,at:5));XCTAssertFalse(GitInputWordBreak.isDelimiter(scheme,at:6));XCTAssertTrue(GitInputWordBreak.isDelimiter(scheme,at:7))
        XCTAssertFalse(GitInputWordBreak.isDelimiter([],at:0));XCTAssertFalse(GitInputWordBreak.isDelimiter(scheme,at:-1));XCTAssertFalse(GitInputWordBreak.isDelimiter(scheme,at:scheme.count))
    }
    func testURLBranchAndPathNavigationStops() {
        let value="https://host.example/a_b-c?q=yes#top",stops=[0,8,13,21,23,25,27,29,33,36]
        for index in 0..<stops.count-1 {XCTAssertEqual(GitInputWordBreak.boundary(value,from:stops[index],forward:true),stops[index+1])}
        for index in 1..<stops.count {XCTAssertEqual(GitInputWordBreak.boundary(value,from:stops[index],forward:false),stops[index-1])}
        XCTAssertEqual(GitInputWordBreak.boundary("feature/fix.issue-42",from:0,forward:true),8)
        XCTAssertEqual(GitInputWordBreak.boundary("feature/fix.issue-42",from:19,forward:false),18)
        XCTAssertEqual(GitInputWordBreak.boundary("/Users/name/my_file.swift",from:12,forward:true),15)
    }
    func testRepeatedPunctuationAndCRTLineEndingRules() {
        for count in 1...12 {
            let text=Array(("a"+String(repeating:"\r",count:count)+"\nb").utf16)
            for index in 1...count {XCTAssertFalse(GitInputWordBreak.isDelimiter(text,at:index))}
            XCTAssertTrue(GitInputWordBreak.isDelimiter(text,at:count+1))
        }
        XCTAssertEqual(GitInputWordBreak.boundary("a...///b",from:1,forward:true),7)
        XCTAssertEqual(GitInputWordBreak.boundary("a...///b",from:7,forward:false),0)
        XCTAssertEqual(GitInputWordBreak.boundary("a\r\r\nb",from:0,forward:true),4)
        XCTAssertTrue(GitInputWordBreak.isDelimiter(Array("a\rb".utf16),at:1))
    }
    func testUnicodeAndComposedCaretSafetyAcrossAllOffsets() {
        for value in ["feature/café/fix","feature/cafe\u{301}/🐢-fix","a/\u{301}b","👩‍💻/🇩🇪/done","a\0b/path"] {
            let native=value as NSString
            for offset in -1...native.length+1 {
                for forward in [false,true] {
                    let result=GitInputWordBreak.boundary(value,from:offset,forward:forward)
                    XCTAssertTrue((0...native.length).contains(result))
                    if result<native.length {XCTAssertEqual(native.rangeOfComposedCharacterSequence(at:result).location,result)}
                }
            }
        }
    }
    func testEmptyAndOutOfRangeMovementAreBounded() {
        for forward in [false,true] {XCTAssertEqual(GitInputWordBreak.boundary("",from:Int.max,forward:forward),0)}
        XCTAssertEqual(GitInputWordBreak.boundary("one/two",from:Int.max,forward:true),7)
        XCTAssertEqual(GitInputWordBreak.boundary("one/two",from:Int.min,forward:false),0)
    }
}
