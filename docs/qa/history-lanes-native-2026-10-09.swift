import Foundation
struct LaneFixture: Decodable {
    struct Row: Decodable { let hash: String; let parents: [String]; let boundary: Bool }
    let name: String; let firstParent: Bool; let rows: [Row]; let expected: [[Int]]; let active: [Int]
}
@main struct LaneVerification {
    static func main() throws {
        let fixtures = try JSONDecoder().decode([LaneFixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var count = 0
        for fixture in fixtures {
            var machine = HistoryLanes()
            for (i,row) in fixture.rows.enumerated() {
                let actual = machine.consume(hash:row.hash,parents:row.parents,boundary:row.boundary,firstParent:fixture.firstParent).map(\.rawValue)
                precondition(actual == fixture.expected[i],"Lane mismatch \(fixture.name) row \(i): \(actual) vs \(fixture.expected[i])")
                precondition(machine.activeLane == fixture.active[i],"Active lane mismatch \(fixture.name) row \(i)")
                count += 1
            }
        }
        print("PASS: \(fixtures.count) deterministic linear/diamond/octopus/disconnected/criss-cross/first-parent/boundary/random DAG fixtures, \(count) exact lane-type and active-column snapshots against compiled pinned C++ Lanes/updateLanes")
    }
}
