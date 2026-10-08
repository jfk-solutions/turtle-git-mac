import XCTest
@testable import TurtleGitCore

final class GitCliOutputParserTests: XCTestCase {
    private func render(_ input: Data, chunks: [Int]) -> Data {
        let parser = GitCliOutputParser(); var result = Data(), offset = 0, index = 0
        while offset < input.count {
            let count = min(chunks[index % chunks.count], input.count - offset); parser.appendChunk(input.subdata(in: offset..<offset+count))
            let out = parser.processPending(); XCTAssertFalse(out.limited); XCTAssertLessThanOrEqual(out.erasePreviousLineBytes, result.count)
            result.removeLast(out.erasePreviousLineBytes); result.append(out.data); offset += count; index += 1
        }
        return result
    }
    func testPinnedCloneCapturesMatchWholeSingleByteAndIrregularChunks() throws {
        for name in ["clone","clone2"] {
            let input = try Data(contentsOf: Bundle.module.url(forResource:name,withExtension:"txt",subdirectory:"GitOutput")!)
            let expected = try Data(contentsOf: Bundle.module.url(forResource:name+"-final",withExtension:"txt",subdirectory:"GitOutput")!)
            for chunks in [[input.count],[1],[17,1,64,3,1024,2]] { XCTAssertEqual(render(input,chunks:chunks), expected, name) }
        }
    }
    func testLocalOverlayRemoteReplacementAndSplitUnicode() {
        let local = "Pre-commit\n\nHallo\nCR\rLonger\rFinal\nAnotherCR\rMore Override\r\nAfter empty\nNowCRCR\r\rNewline\nEven more\r\nVery last\n"
        let expected = "Pre-commit\n\nHallo\nFinalr\nMore Override\nAfter empty\nNewline\nEven more\nVery last\n"
        let remote = "remote: JETZT        \nremote: 123        \rremote: abcd        \rremote: \nremote: def        \nremote: fertig        \n雪🐢\n"
        let remoteExpected = "remote: JETZT        \nremote: abcd        \nremote: def        \nremote: fertig        \n雪🐢\n"
        for chunks in [[1],[8,5,2,21],[1024]] { XCTAssertEqual(render(Data(local.utf8),chunks:chunks),Data(expected.utf8)); XCTAssertEqual(render(Data(remote.utf8),chunks:chunks),Data(remoteExpected.utf8)) }
    }
    func testLineLimitNulDropResetAndFinalTail() {
        let parser = GitCliOutputParser(); parser.appendChunk(Data(("remote: "+String(repeating:"A",count:10*1024)+"\r").utf8)); let first = parser.processPending()
        XCTAssertEqual(first.data.count,8221); XCTAssertTrue(String(decoding:first.data,as:UTF8.self).hasSuffix("... [line truncated at 8 KiB]"))
        parser.appendChunk(Data("remote: more output\r".utf8)); let replaced = parser.processPending(); XCTAssertEqual(replaced.erasePreviousLineBytes,8221); XCTAssertEqual(replaced.data,Data("remote: more output".utf8))
        parser.activateDropMode(); parser.appendChunk(Data("ignored\n".utf8)); XCTAssertTrue(parser.processPending().data.isEmpty)
        parser.reset(); parser.appendChunk(Data("a\0雪🐢".utf8)); XCTAssertEqual(parser.processPending().data,Data("a\n".utf8)); XCTAssertEqual(parser.finish().data,Data("雪🐢\n".utf8))
    }
    func testManyLinesUsesUpstreamSoftEmissionLimit() {
        let parser = GitCliOutputParser(limit:1024*1024)
        let prefix = "Cloning into 'poc'...\nLooking up 127.0.0.1 ... done.\nremote: def        \n"
        parser.appendChunk(Data((prefix+String(repeating:String(repeating:"A",count:1024)+"\n",count:5000)).utf8))
        let out = parser.processPending(); XCTAssertTrue(out.limited); XCTAssertEqual(out.data.count,1048648)
    }
}
