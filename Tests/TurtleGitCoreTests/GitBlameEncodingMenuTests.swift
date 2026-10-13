import XCTest
@testable import TurtleGitCore

final class GitBlameEncodingMenuTests: XCTestCase {
    func testCompleteSourceCatalogResolvesRealCodecs() throws {
        XCTAssertEqual(GitBlameEncodingMenu.groups.map(\.title), ["Arabic", "Baltic", "Celtic", "Cyrillic", "Central European", "Chinese", "Eastern European", "Greek", "Hebrew", "Japanese", "Korean", "North European", "Thai", "Turkish", "Western European", "Vietnamese"])
        let choices = GitBlameEncodingMenu.unicode + GitBlameEncodingMenu.groups.flatMap(\.choices)
        XCTAssertEqual(choices.count, 51)
        XCTAssertEqual(Set(choices.map(\.codePage)).count, 51)
        XCTAssertEqual(GitBlameEncodingMenu.unicode.map(\.codePage), [65001, 1200, 1201])
        for choice in choices {
            let encoding = try XCTUnwrap(choice.encoding, choice.title)
            XCTAssertEqual(encoding.windowsCodePage, choice.codePage)
            if choice.codePage != 1200 && choice.codePage != 1201 {
                XCTAssertEqual(encoding.decodeText(Data("ASCII\n".utf8)), "ASCII\n", choice.title)
                try encoding.validate(Data("ASCII\n".utf8))
            }
        }
        XCTAssertTrue(Set(GitBlameEncodingMenu.additional.map(\.id)).isDisjoint(with: Set(choices.compactMap { $0.encoding?.id })))
        XCTAssertEqual(Set(choices.compactMap { $0.encoding?.id } + GitBlameEncodingMenu.additional.map(\.id)), Set(GitBlameEncoding.available.map(\.id)))
    }
    func testOEMSupplementalMappingsAndBinaryGuard() throws {
        let arabic = try XCTUnwrap(GitBlameEncoding.available.first { $0.windowsCodePage == 720 })
        let western = try XCTUnwrap(GitBlameEncoding.available.first { $0.windowsCodePage == 858 })
        XCTAssertEqual(arabic.decodeText(Data([0x98, 0x99, 0x9a, 10])), "ءآأ\n")
        XCTAssertEqual(western.decodeText(Data([0x82, 0xd5, 10])), "é€\n")
        for codec in [arabic, western] {
            XCTAssertNotNil(codec.decodeText(Data(0...255)))
            XCTAssertThrowsError(try codec.validate(Data([65, 0, 10])))
            XCTAssertEqual(try codec.legacyLines(Data([65, 10, 66, 10])), ["A", "B"])
            XCTAssertEqual(try codec.legacyLines(Data()), [])
        }
    }
    func testSupplementalCodecsAnnotateHistoricalBytesWithoutMutatingIndex() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (page, bytes, lines) in [(UInt32(720), Data([0x98,0x99,0x9a,10,65,10]), ["ءآأ", "A"]), (858, Data([0x82,0xd5,10,66]), ["é€", "B"])] {
            let path = "OEM \(page).txt", file = root.appendingPathComponent(path)
            try bytes.write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "OEM \(page)")
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout
            let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            try Data("working replacement\n".utf8).write(to: file)
            var options = GitBlameOptions(); options.encoding = try XCTUnwrap(GitBlameEncoding.available.first { $0.windowsCodePage == page })
            let result = try await repo.blame(path: path, options: options)
            XCTAssertEqual(result.contents, bytes); XCTAssertEqual(result.lines.map(\.source), lines)
            XCTAssertEqual(result.encoding.decodeText(result.contents)?.components(separatedBy: "\n").first, lines.first)
            let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
            XCTAssertEqual(afterHead, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            XCTAssertEqual(try Data(contentsOf: file), Data("working replacement\n".utf8))
        }
    }
}
