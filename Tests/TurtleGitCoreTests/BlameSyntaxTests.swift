import XCTest
import Darwin
@testable import TurtleGitCore

final class BlameSyntaxTests: XCTestCase {
    var helper: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/lexilla-runtime/Lexilla/lexilla") }
    func testPinnedExtensionFamiliesUseRealLexersAndWordLists() throws {
        for (extensionName,lexer,text,style) in [
            ("py","python","def example():\n    return 42\n",5),
            ("cpp","cpp","int value = 42;\n",5),
            ("cs","cpp","class Example {}\n",5),
            ("rc","cpp","BEGIN\nEND\n",5),
            ("idl","cpp","interface Example {};\n",5),
            ("java","cpp","public class Example {}\n",5),
            ("js","cpp","function example() {}\n",5),
            ("pas","pascal","begin\nend.\n",9),
            ("as","cpp","function example() {}\n",5),
            ("html","hypertext","<html><body>example</body></html>\n",1)
        ] {
            let result = try BlameSyntax.highlight(text,filename:"sample." + extensionName,executable:helper)
            XCTAssertEqual(result.lexer,lexer,extensionName)
            XCTAssertTrue(result.ranges.contains { $0.style == style },extensionName)
            XCTAssertEqual(result.ranges.reduce(0) { $0 + $1.range.length },text.utf16.count)
        }
    }
    func testCaseSensitiveUnknownAndNoExtensionSourceRules() throws {
        XCTAssertNil(try BlameSyntax.highlight("int value;",filename:"code.CPP",executable:helper).lexer)
        XCTAssertNil(try BlameSyntax.highlight("let value = 1",filename:"code.swift",executable:helper).lexer)
        let result = try BlameSyntax.highlight("int value;",filename:"README",executable:helper)
        XCTAssertEqual(result.lexer,"cpp")
        XCTAssertFalse(result.ranges.contains { $0.style == 5 }, "Source's no-extension fallback has no keyword lists.")
    }
    func testUnicodeAndMultilineStringsMapByteStylesToExactUTF16Ranges() throws {
        let text = "int value = 3;\nconst char* name = \"雪🦎\";\n/* multiline\n comment */\n"
        let result = try BlameSyntax.highlight(text,filename:"unicode.cpp",executable:helper)
        let source = text as NSString
        XCTAssertTrue(result.ranges.contains { $0.style == 6 && source.substring(with:$0.range).contains("雪🦎") })
        XCTAssertTrue(result.ranges.contains { $0.style == 1 && source.substring(with:$0.range).contains("multiline\n comment") })
        XCTAssertEqual(result.ranges.reduce(0) { $0 + $1.range.length },source.length)
    }
    func testEmbeddedStylesRetainSourceFontAndEOLIntervals() throws {
        let result=try BlameSyntax.highlight("<script language=\"VBScript\">\nDim value\nvalue = \"雪\"\n</script>\n",filename:"embedded.html",executable:helper)
        XCTAssertEqual(result.lexer,"hypertext")
        for interval in [71...77,81...87,41...50,56...65] {
            for number in interval {
                XCTAssertEqual(result.styles[String(number)]?.font,"Lucida Console")
                XCTAssertEqual(result.styles[String(number)]?.eolFilled,true)
            }
        }
        for number in [51,66] { XCTAssertEqual(result.styles[String(number)]?.eolFilled,true);XCTAssertNil(result.styles[String(number)]?.font) }
        XCTAssertEqual(result.styles["77"]?.background,[127,127,255])
        XCTAssertEqual(result.styles["87"]?.background,[207,207,127])
        XCTAssertEqual(result.styles["51"]?.background,[223,223,127])
        XCTAssertEqual(result.styles["66"]?.background,[0,175,95])
        XCTAssertTrue(result.ranges.contains { (71...77).contains($0.style) })
    }
    func testInvalidInputsAndPreCancellationDoNotRunHelper() throws {
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try BlameSyntax.highlight("int x;",filename:"a.cpp",executable:helper,cancellation:token)) { XCTAssertTrue($0 is OperationCancellationFailure) }
        for (text,tabs) in [("int\0x;",4),("int x;",0),("int x;",1001)] {
            XCTAssertThrowsError(try BlameSyntax.highlight(text,filename:"a.cpp",tabSize:tabs,executable:helper))
        }
    }
    func fixture(script: String) throws -> (URL,URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitLexillaTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let executable = directory.appendingPathComponent("lexilla")
        try Data(script.utf8).write(to:executable); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        try FileManager.default.copyItem(at:helper.deletingLastPathComponent().appendingPathComponent("BlameLexers.json"),to:directory.appendingPathComponent("BlameLexers.json"))
        return (directory,executable)
    }
    func testMalformedHelperOutputRefusesSplitUnicodeIncompleteAndOverlappingRanges() throws {
        for output in ["lexilla\t1\nname\tcpp\nrange\t0\t1\t6\nrange\t1\t2\t6\n",
                       "lexilla\t1\nname\tcpp\nrange\t0\t2\t6\n",
                       "lexilla\t1\nname\tcpp\nrange\t0\t3\t6\nrange\t0\t3\t6\n"] {
            let (directory,executable) = try fixture(script:"#!/bin/sh\ncat <<'LEXILLA_OUTPUT'\n" + output + "LEXILLA_OUTPUT\n")
            defer { try? FileManager.default.removeItem(at:directory) }
            XCTAssertThrowsError(try BlameSyntax.highlight("雪",filename:"a.cpp",executable:executable)) { XCTAssertTrue($0 is BlameSyntaxFailure) }
        }
    }
    func testCancellationReapsOwnedHelperAndRemovesPrivateSourceInputs() async throws {
        let (directory,executable) = try fixture(script:"#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nsleep 30 & wait\n")
        defer { try? FileManager.default.removeItem(at:directory) }
        let temporary = try TurtleGitTemporaryStorage.root
        let before = Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter { $0.hasPrefix("TurtleGitLexilla-") })
        let token = OperationCancellation()
        let operation = Task.detached { try BlameSyntax.highlight("int x;",filename:"a.cpp",executable:executable,cancellation:token) }
        var pid:Int32?
        for _ in 0..<1000 {
            pid = (try? String(contentsOfFile:executable.path + ".pid",encoding:.utf8)).flatMap(Int32.init)
            if pid != nil { break }; try await Task.sleep(nanoseconds:5_000_000)
        }
        token.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled helper completed") } catch is OperationCancellationFailure {}
        let owned = try XCTUnwrap(pid); XCTAssertEqual(Darwin.kill(owned,0),-1); XCTAssertEqual(errno,ESRCH)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter { $0.hasPrefix("TurtleGitLexilla-") })
        XCTAssertEqual(before,after)
    }
}
