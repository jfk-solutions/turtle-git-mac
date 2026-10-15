import XCTest
@testable import TurtleGitCore

final class MergeInlineComparisonTests: XCTestCase {
    func testPinnedSourceParserAndRepeatedTokenTies() throws {
        struct Sample: Decodable {
            let base: String, destination: String, word: Bool
            let common: [[Int]], modified: [[Int]], tokens: [[Int]]
        }
        guard let path = ProcessInfo.processInfo.environment["TURTLEGIT_INLINE_SOURCE_EXPECTED"] else {
            throw XCTSkip("Run scripts/test-inline-source.py for the independently compiled pinned-source corpus")
        }
        XCTAssertTrue(SubversionInlineDiff.available, "Bundled inline runtime must load")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(samples.count, 1800)
        for sample in samples {
            let units = [Array(sample.base.utf16), Array(sample.destination.utf16)]
            let lengths = sample.word ? sample.tokens : units.map { $0.map { _ in 1 } }
            let offsets = lengths.map { side -> [Int] in
                var values = [0]; for n in side { values.append(values.last! + n) }; return values
            }
            let tokens = units.enumerated().map { side, text in
                lengths[side].indices.map { Array(text[offsets[side][$0]..<offsets[side][$0 + 1]]) }
            }
            let segments = try XCTUnwrap(SubversionInlineDiff.segments(base: tokens[0], destination: tokens[1], word: sample.word))
            let raw = segments.map { [$0.base.lowerBound, $0.base.count, $0.destination.lowerBound, $0.destination.count] }
            XCTAssertEqual(zip(segments, raw).filter { $0.0.common }.map { $0.1 }, sample.common, sample.base + " → " + sample.destination)
            XCTAssertEqual(zip(segments, raw).filter { !$0.0.common }.map { $0.1 }, sample.modified, sample.base + " → " + sample.destination)
            let common = sample.common.reduce(0) { $0 + $1[1] }
            let changed = sample.modified.reduce(0) { $0 + $1[1] + $1[3] }
            let visible = !sample.modified.isEmpty && common * 2 > changed + 2 * sample.modified.count
            let actual = MergeInlineComparison(base: sample.base, destination: sample.destination, word: sample.word)
            XCTAssertEqual(actual != nil, visible)
            guard let actual else { continue }
            func positions(_ side: Int) -> [NSRange] {
                sample.modified.map { item in
                    let start = item[side * 2], end = start + item[side * 2 + 1]
                    return NSRange(location: offsets[side][start], length: offsets[side][end] - offsets[side][start])
                }
            }
            XCTAssertEqual(actual.basePositions, positions(0)); XCTAssertEqual(actual.destinationPositions, positions(1))
            XCTAssertEqual(actual.base, positions(0).filter { $0.length > 0 })
            XCTAssertEqual(actual.destination, positions(1).filter { $0.length > 0 })
            XCTAssertEqual(actual.baseMissing, sample.modified.filter { $0[1] < $0[3] }.map { offsets[0][$0[0]] })
            XCTAssertEqual(actual.destinationMissing, sample.modified.filter { $0[3] < $0[1] }.map { offsets[1][$0[2]] })
        }
    }
    func testConcurrentComparisonsKeepIndependentPoolsAndContexts() {
        let errors = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 160) { index in
            let prefix = "🐢 keep \(index) shared ", a = prefix + "old tail constant", b = prefix + "new tail constant"
            let expected = NSRange(location: prefix.utf16.count, length: 3)
            let actual = MergeInlineComparison(base: a, destination: b, word: true)
            if actual?.base != [expected] || actual?.destination != [expected] {
                errors.lock(); failures += 1; errors.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
    }
    func testNavigationVisitsStartsEndsAndZeroWidthChunksWithoutWrapping() throws {
        let diff = try XCTUnwrap(MergeInlineComparison(base: "keep shared ending", destination: "keep new shared ending", word: true))
        XCTAssertEqual(diff.basePositions, [NSRange(location: 5, length: 0)])
        XCTAssertEqual(diff.destinationPositions, [NSRange(location: 5, length: 4)])
        XCTAssertEqual(diff.navigationOffset(from: 0, base: true, forward: true), 5)
        XCTAssertNil(diff.navigationOffset(from: 5, base: true, forward: true))
        XCTAssertEqual(diff.navigationOffset(from: 6, base: true, forward: false), 5)
        XCTAssertEqual(diff.navigationOffset(from: 5, base: false, forward: true), 9)
        XCTAssertEqual(diff.navigationOffset(from: 8, base: false, forward: false), 5)
        XCTAssertNil(diff.navigationOffset(from: 9, base: false, forward: true))
        XCTAssertNil(diff.navigationOffset(from: 5, base: false, forward: false))
    }
    func testPresentationUsesCurrentLineLimitAndSourceRowGates() throws {
        let short = MergeSourceCell(text: "keep shared ending\r\n", lineNumber: 1, state: .conflicted)
        let long = MergeSourceCell(text: "keep new shared ending\r\n", lineNumber: 1, state: .conflicted)
        XCTAssertNotNil(MergeInlinePresentation.comparison(cell: short, other: long, left: true, word: true, maximumLength: 18))
        XCTAssertNil(MergeInlinePresentation.comparison(cell: long, other: short, left: false, word: true, maximumLength: 18))
        for state in [MergeSourceState.normal, .filtered, .empty] {
            let cell = MergeSourceCell(text: short.text, lineNumber: 1, state: state)
            XCTAssertNil(MergeInlinePresentation.comparison(cell: cell, other: long, left: true, word: false, maximumLength: 100))
        }
        let suite = "TurtleGit.InlineTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MergeInlinePresentation.defaultEnabled(from: defaults))
        MergeInlinePresentation.saveEnabled(false, to: defaults)
        XCTAssertFalse(MergeInlinePresentation.defaultEnabled(from: defaults))
    }
    func testCharacterAndWordModesUseExactUTF16Ranges() throws {
        let a = "let count = 10; // keep this shared text", b = "let count = 20; // keep this shared text"
        let chars = try XCTUnwrap(MergeInlineComparison(base: a, destination: b))
        XCTAssertEqual(chars.base, [NSRange(location: 12, length: 1)])
        XCTAssertEqual(chars.destination, chars.base)
        let words = try XCTUnwrap(MergeInlineComparison(base: a, destination: b, word: true))
        XCTAssertEqual(words.base, [NSRange(location: 12, length: 2)])
        XCTAssertEqual(words.destination, words.base)
        XCTAssertTrue(words.baseMissing.isEmpty); XCTAssertTrue(words.destinationMissing.isEmpty)
        let unicode = try XCTUnwrap(MergeInlineComparison(base: "🐢 shared café tail text", destination: "🐢 shared cafe\u{301} tail text", word: true))
        XCTAssertEqual(("🐢 shared café tail text" as NSString).substring(with: unicode.base[0]), "café")
        XCTAssertEqual(("🐢 shared cafe\u{301} tail text" as NSString).substring(with: unicode.destination[0]), "cafe\u{301}")
    }
    func testWhitespacePunctuationAndMissingTextMarkers() throws {
        let whitespace = try XCTUnwrap(MergeInlineComparison(base: "same\t  value; keep all this", destination: "same value; keep all this", word: true))
        XCTAssertEqual(whitespace.base, [NSRange(location: 4, length: 3)])
        XCTAssertEqual(whitespace.destination, [NSRange(location: 4, length: 1)])
        let punctuation = try XCTUnwrap(MergeInlineComparison(base: "same.name and shared words", destination: "same_name and shared words", word: true))
        XCTAssertEqual(punctuation.base, [NSRange(location: 4, length: 1)])
        let insertion = try XCTUnwrap(MergeInlineComparison(base: "keep shared ending", destination: "keep new shared ending", word: true))
        XCTAssertTrue(insertion.base.isEmpty)
        XCTAssertEqual(insertion.baseMissing, [5])
        XCTAssertEqual(insertion.destination, [NSRange(location: 5, length: 4)])
        let reverse = try XCTUnwrap(MergeInlineComparison(base: "keep new shared ending", destination: "keep shared ending", word: true))
        XCTAssertEqual(reverse.destinationMissing, insertion.baseMissing)
        XCTAssertEqual(reverse.base, insertion.destination)
    }
    func testSimilarityGateEmptyEqualAndLengthLimit() throws {
        XCTAssertNil(MergeInlineComparison(base: "old", destination: "new"))
        XCTAssertNil(MergeInlineComparison(base: "child next", destination: "child last", word: true))
        XCTAssertNil(MergeInlineComparison(base: "", destination: "added"))
        XCTAssertNil(MergeInlineComparison(base: "same", destination: "same"))
        let a = String(repeating: "a", count: 2999) + "x", b = String(repeating: "a", count: 2999) + "y"
        XCTAssertNotNil(MergeInlineComparison(base: a, destination: b))
        XCTAssertNotNil(MergeInlineComparison(base: a + "z", destination: b))
        XCTAssertNotNil(MergeInlineComparison(base: a, destination: b + "z"))
        XCTAssertNil(MergeInlineComparison(base: a + "z", destination: b + "z"))
        XCTAssertNil(MergeInlineComparison(base: "🐢 keep", destination: "🐢 kept", maximumLength: 6))
    }
}
