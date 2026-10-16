import XCTest
@testable import TurtleGitCore

final class MergeMovedBlockTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testPinnedSourceOracle() throws {
        let url=root.appendingPathComponent("build/qa/moved-block-source-expected.json")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Run scripts/test-moved-block-source.py to prepare the pinned source corpus.") }
        struct Case: Decodable { let base:[String],mine:[String],segments:[[Int]],whitespace:Int,ended:Bool,links:[[Int]] }
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:url))
        XCTAssertGreaterThan(cases.count,1000)
        for (index,value) in cases.enumerated() {
            func lines(_ values:[String]) -> [String] { values.enumerated().map { $0.element + ($0.offset < values.count - 1 || value.ended ? "\n" : "") } }
            let plan=SubversionDiffPlan(segments:value.segments.map { .init(kind:.modified,base:$0[0]..<($0[0]+$0[1]),mine:$0[2]..<($0[2]+$0[3]),theirs:0..<0) },base:lines(value.base),mine:lines(value.mine),theirs:nil)
            let blocks=try MergeMovedBlock.detect(plan:plan,whitespace:MergeWhitespaceComparison(rawValue:value.whitespace)!)
            let links=blocks.flatMap { block in block.base.enumerated().map { [$0.element,block.mine.lowerBound+$0.offset] } }
            XCTAssertEqual(links,value.links,"Pinned moved-block case \(index)")
        }
    }
    func testRealEngineReorderAndPresentationDoNotChangeAlignment() throws {
        let config=SubversionMergeConfiguration(executable:root.appendingPathComponent("build/merge-diff-runtime/MergeDiff/merge-diff"),runtimeRoot:root.appendingPathComponent("build/git-runtime/Git"))
        let base="head\nunique moved 🐢\nrepeated\nstay1\nstay2\nstay3\ntail\n",mine="head\nstay1\nstay2\nstay3\nunique moved 🐢\nrepeated\ntail\n"
        let plan=try config.plan(base:base,mine:mine)
        let off=try SubversionComparisonPresentation(plan:plan),on=try SubversionComparisonPresentation(plan:plan,detectMovedBlocks:true)
        XCTAssertEqual(on.movedBlocks,[.init(base:1..<3,mine:4..<6)])
        XCTAssertTrue(off.movedBlocks.isEmpty)
        XCTAssertEqual(on.alignment.rows.map { $0.base.text },off.alignment.rows.map { $0.base.text })
        XCTAssertEqual(on.alignment.rows.map { $0.destination.text },off.alignment.rows.map { $0.destination.text })
        XCTAssertEqual(on.alignment.differences,off.alignment.differences)
    }
    func testAmbiguousRepeatedLinesDoNotSeedAndCancellationRefusesWork() throws {
        let plan=SubversionDiffPlan(segments:[.init(kind:.modified,base:0..<2,mine:0..<2,theirs:0..<0)],base:["a\n","a\n","tail\n"],mine:["a\n","a\n","tail\n"],theirs:nil)
        XCTAssertTrue(try MergeMovedBlock.detect(plan:plan).isEmpty)
        let cancellation=OperationCancellation();cancellation.cancel()
        XCTAssertThrowsError(try MergeMovedBlock.detect(plan:plan,cancellation:cancellation))
        let invalid=SubversionDiffPlan(segments:[.init(kind:.modified,base:0..<8,mine:0..<2,theirs:0..<0)],base:plan.base,mine:plan.mine,theirs:nil)
        XCTAssertThrowsError(try MergeMovedBlock.detect(plan:invalid))
    }
    func testSourceDefaultAndPrivatePersistence() throws {
        let suite="TurtleGit.Moved."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        XCTAssertTrue(MergeMovedBlock.enabled(defaults:defaults));defaults.set(false,forKey:"TurtleGitMerge.ViewMovedBlocks")
        XCTAssertFalse(MergeMovedBlock.enabled(defaults:defaults))
    }
}
