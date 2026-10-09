import Foundation
@testable import TurtleGitCore
struct ProjectionFixture: Decodable {
    struct Row: Decodable { let hash: String; let parents: [String]; let refs: [String]; let head: Bool }
    struct Expected: Decodable { let visible: Bool; let collapsed: Bool; let forced: Bool; let lanes: [Int]; let column: Int }
    let name: String; let mode: String; let mask: Int; let firstParent: Bool; let overrides: [String:String]; let rows: [Row]; let expected: [Expected]
}
@main struct ProjectionVerification {
    static func main() throws {
        let fixtures=try JSONDecoder().decode([ProjectionFixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var snapshots=0
        for fixture in fixtures {
            let entries=fixture.rows.map { row -> LogEntry in
                var e=LogEntry(hash:row.hash,author:"",date:"",subject:row.hash,parents:row.parents)
                e.isHead=row.head;e.references=row.refs.map { RevisionReference(name:$0) };return e
            }
            var options=HistoryWalkOptions();options.graphMode=fixture.mode == "all" ? .all : fixture.mode == "compressed" ? .compressed : .labeled;options.firstParent=fixture.firstParent
            let overrides=fixture.overrides.mapValues { $0 == "collapse" ? HistoryRollupChoice.collapse : .expand }
            let result=CommitGraph.project(entries,walk:options,references:HistoryReferenceVisibility(rawValue:fixture.mask),rollupStates:overrides)
            let visible=zip(fixture.rows,fixture.expected).filter { $0.1.visible }
            precondition(result.entries.map(\.hash)==visible.map { $0.0.hash },"Visibility mismatch \(fixture.name): \(result.entries.map(\.hash)) vs \(visible.map { $0.0.hash })")
            for (i,pair) in visible.enumerated() {
                let expected=pair.1,graph=result.graph[i]
                precondition(graph.lanes.map(\.rawValue)==expected.lanes && graph.column==expected.column,"Hidden-row lane mismatch \(fixture.name) \(pair.0.hash)")
                precondition(graph.collapsed==expected.collapsed,"Paint rollup mismatch \(fixture.name)")
                precondition(result.entries[i].parents==pair.0.parents,"Actual parents changed \(fixture.name)")
            }
            for (row,expected) in zip(fixture.rows,fixture.expected) {
                precondition(result.rollups[row.hash]?.collapsed==expected.collapsed && result.rollups[row.hash]?.forced==expected.forced,"Rollup mismatch \(fixture.name) \(row.hash)")
                snapshots += 1
            }
        }
        print("PASS: \(fixtures.count) complete/ compressed/labeled/label-mask/forced/first-parent projections; \(snapshots) visibility/rollup/forced snapshots and visible full-walk lane states match compiled pinned C++ filter/rollup/Lanes/updateLanes bodies; actual parents unchanged")
    }
}
