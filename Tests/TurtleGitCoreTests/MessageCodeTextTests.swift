import XCTest
@testable import TurtleGitCore

final class MessageCodeTextTests: XCTestCase {
    func testBinaryAlignmentAndBOMPrecedence() {
        XCTAssertEqual(MessageCodeText.detect(Data([0xff, 0xfe, 0, 0, 0, 0, 0, 0])), .binary)
        XCTAssertNil(MessageCodeText.decode(Data([0, 0, 0, 0])))
        XCTAssertEqual(MessageCodeText.detect(Data([65, 0, 0, 0, 0, 66, 67, 68])), .utf16LE)
        XCTAssertEqual(MessageCodeText.detect(Data([0xff, 0xfe, 0, 0, 65, 0, 0, 0])), .utf32LE)
        XCTAssertEqual(MessageCodeText.detect(Data([0, 0, 0xfe, 0xff, 0, 0, 0, 65])), .utf32BE)
        XCTAssertEqual(MessageCodeText.detect(Data([0xef, 0xbb, 0xbf])), .utf8BOM)
    }
    func testSmallInputAndUseUTF8() {
        XCTAssertEqual(MessageCodeText.detect(Data()), .ascii)
        XCTAssertNil(MessageCodeText.decode(Data()))
        XCTAssertEqual(MessageCodeText.detect(Data([0])), .ascii)
        XCTAssertEqual(MessageCodeText.detect(Data([65, 0])), .ascii)
        XCTAssertEqual(MessageCodeText.detect(Data("plain".utf8)), .ascii)
        XCTAssertEqual(MessageCodeText.detect(Data("plain".utf8), useUTF8: true), .utf8)
        XCTAssertEqual(MessageCodeText.detect(Data([0xc3]), useUTF8: true), .ascii)
    }
    func testNullThresholdAndByteParity() {
        var bytes = Array(repeating: UInt8(65), count: 50)
        bytes[1] = 0
        XCTAssertEqual(MessageCodeText.detect(Data(bytes)), .ascii)
        bytes[3] = 0
        XCTAssertEqual(MessageCodeText.detect(Data(bytes)), .utf16LE)
        bytes[3] = 65; bytes[4] = 0
        XCTAssertEqual(MessageCodeText.detect(Data(bytes)), .utf16BE)
    }
    func testStructuralUTF8ClassifierQuirks() {
        XCTAssertEqual(MessageCodeText.detect(Data("雪🦎".utf8)), .utf8)
        for bytes: [UInt8] in [[0x80, 65, 65], [0xc0, 0x80, 65], [0xc2, 65, 65], [0xf5, 0x80, 0x80, 0x80], [0xe2, 0x82]] {
            XCTAssertEqual(MessageCodeText.detect(Data(bytes)), .ascii)
        }
        // The source checks continuation structure, not modern Unicode scalar validity.
        XCTAssertEqual(MessageCodeText.detect(Data([0xe0, 0x80, 0x80])), .utf8)
        XCTAssertEqual(MessageCodeText.detect(Data([0xed, 0xa0, 0x80])), .utf8)
    }
    func testUTF16RawUnitsBOMOddTailAndUnpairedSurrogate() {
        XCTAssertEqual(MessageCodeText.decode(Data([0xff, 0xfe, 65, 0, 0xff]))?.units, [0xfeff, 65])
        XCTAssertEqual(MessageCodeText.decode(Data([0xfe, 0xff, 0, 65, 0xff]))?.units, [0xfeff, 65])
        XCTAssertEqual(MessageCodeText.decode(Data([0xff, 0xfe, 0, 0xd8]))?.units, [0xfeff, 0xd800])
        XCTAssertEqual(MessageCodeText.decode(Data([65, 0, 66, 0]))?.units, [65, 66])
    }
    func testUTF32LengthQuirkAndInvalidValues() {
        let little = Data([0xff, 0xfe, 0, 0, 0x8e, 0xf9, 1, 0, 65, 0, 0, 0])
        let big = Data([0, 0, 0xfe, 0xff, 0, 1, 0xf9, 0x8e, 0, 0, 0, 65])
        XCTAssertEqual(MessageCodeText.decode(little)?.units, [0xfeff, 0xd83e, 0xdd8e])
        XCTAssertEqual(MessageCodeText.decode(big)?.units, [0xfeff, 0xd83e, 0xdd8e])
        XCTAssertEqual(MessageCodeText.decode(Data([0xff, 0xfe, 0, 0, 0, 0, 0x11, 0, 99]))?.units, [0xfeff, 0xfffd])
        XCTAssertEqual(MessageCodeText.decode(Data([0xff, 0xfe, 0, 0, 0x8e, 0xf9, 1, 0]))?.units, [0xfeff, 0xd83e])
    }
    func testUTF8BOMAndExplicitLegacyAdaptation() {
        XCTAssertEqual(MessageCodeText.decode(Data([0xef, 0xbb, 0xbf, 65]))?.units, [0xfeff, 65])
        XCTAssertEqual(MessageCodeText.decode(Data([0xe9]))?.units, [0xe9])
        XCTAssertEqual(MessageCodeText.decode(Data([0xe9]), legacyEncoding: .isoLatin1)?.units, [0xe9])
    }
}
