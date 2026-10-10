import XCTest
import Darwin
@testable import TurtleGitCore

final class RevisionGraphLayoutTests: XCTestCase {
    var executable: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("build/graph-layout-runtime/GraphLayout/graph-layout")
    }
    func testRealGraphUsesMeasuredSizesAndPreservesEveryEdge() async throws {
        let (root, repo, _) = try await RevisionGraphTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = RevisionGraphOptions(); options.showBranchingsAndMerges = true
        let graph = try await repo.revisionGraph(options: options)
        let sizes = graph.nodes.enumerated().map { CGSize(width: 80 + $0.offset * 20, height: 30 + $0.element.references.count * 15) }
        let layout = try RevisionGraphLayoutRuntime.layout(nodes: graph.nodes, sizes: sizes, executable: executable)
        XCTAssertEqual(layout.nodes.map(\.hash), graph.nodes.map(\.hash))
        XCTAssertEqual(layout.edges.count, graph.nodes.reduce(0) { $0 + $1.parents.count })
        for (index, geometry) in layout.nodes.enumerated() {
            XCTAssertEqual(geometry.rect.size, sizes[index])
            XCTAssertGreaterThanOrEqual(geometry.rect.minX, 0); XCTAssertGreaterThanOrEqual(geometry.rect.minY, 0)
            for other in layout.nodes.prefix(index) {
                XCTAssertFalse(geometry.rect.insetBy(dx: 0.001, dy: 0.001).intersects(other.rect.insetBy(dx: 0.001, dy: 0.001)))
            }
        }
        let rectangles = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.hash, $0.rect) })
        for edge in layout.edges {
            let source = rectangles[edge.sourceHash]!, target = rectangles[edge.targetHash]!
            XCTAssertGreaterThan(target.midY, source.midY)
            XCTAssertEqual(edge.points.count, edge.bends.count + 2)
            XCTAssertFalse(source.contains(edge.points.first!)); XCTAssertFalse(target.contains(edge.points.last!))
            XCTAssertTrue(edge.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        XCTAssertEqual(layout.size.width, layout.nodes.map { $0.rect.maxX }.max())
        XCTAssertEqual(layout.size.height, layout.nodes.map { $0.rect.maxY }.max())
    }
    func testEmptyInvalidInputAndMissingEngine() throws {
        let empty = try RevisionGraphLayoutRuntime.layout(nodes: [], sizes: [], executable: URL(fileURLWithPath: "/missing/graph-layout"))
        XCTAssertEqual(empty.size, .zero)
        let node = RevisionGraphNode(hash: "a")
        for sizes in [[], [CGSize(width: 0, height: 40)], [CGSize(width: CGFloat.infinity, height: 40)]] {
            XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: [node], sizes: sizes, executable: executable))
        }
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: [node, node], sizes: [CGSize(width: 10, height: 10), CGSize(width: 10, height: 10)], executable: executable))
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: [RevisionGraphNode(hash: "a", parents: ["missing"])], sizes: [CGSize(width: 10, height: 10)], executable: executable))
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: [node], sizes: [CGSize(width: 10, height: 10)], executable: URL(fileURLWithPath: "/missing/graph-layout"))) {
            guard case RevisionGraphLayoutFailure.runtimeMissing = $0 else { return XCTFail("Unexpected missing-runtime error: \($0)") }
        }
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: [], sizes: [], cancellation: token))
    }
    func testCyclesFailInActualEngine() throws {
        let nodes = [RevisionGraphNode(hash: "a", parents: ["b"]), RevisionGraphNode(hash: "b", parents: ["a"])]
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.layout(nodes: nodes, sizes: [CGSize(width: 50, height: 40), CGSize(width: 50, height: 40)], executable: executable)) {
            guard case RevisionGraphLayoutFailure.failed(let detail) = $0 else { return XCTFail("Unexpected engine error: \($0)") }
            XCTAssertTrue(detail.contains("cycle"))
        }
    }
    func testMalformedGeometryCannotReachRenderer() throws {
        let nodes = [RevisionGraphNode(hash: "a", parents: ["b"]), RevisionGraphNode(hash: "b")]
        let sizes = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 20)]
        for text in ["", "TGGRAPH1 1 1\n20 20\n20 80\n0\n", "TGGRAPH1 2 1\n20 20\n20 80\n",
                     "TGGRAPH1 2 1\n20 nan\n20 80\n0\n", "TGGRAPH1 2 1\n-20 20\n20 80\n0\n",
                     "TGGRAPH1 2 1\n20 20\n20 80\n1 20\n", "TGGRAPH1 2 1\n20 20\n20 80\n-1\n",
                     "TGGRAPH1 2 1\n20 20\n20 80\n0\nextra\n"] {
            XCTAssertThrowsError(try RevisionGraphLayoutRuntime.parse(Data(text.utf8), nodes: nodes, sizes: sizes, edges: [(0, 1)]))
        }
        XCTAssertThrowsError(try RevisionGraphLayoutRuntime.parse(Data([0xff]), nodes: nodes, sizes: sizes, edges: [(0, 1)]))
    }
    func testBorderClippingMatchesSourceHorizontalVerticalAndFallback() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40), center = CGPoint(x: 50, y: 20)
        XCTAssertEqual(RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: CGPoint(x: 50, y: 100)), CGPoint(x: 50, y: 40.5))
        XCTAssertEqual(RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: CGPoint(x: 50, y: -100)), CGPoint(x: 50, y: -0.5))
        XCTAssertEqual(RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: CGPoint(x: 500, y: 20)), CGPoint(x: 100.5, y: 20))
        XCTAssertEqual(RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: CGPoint(x: -500, y: 20)), CGPoint(x: -0.5, y: 20))
        let next = CGPoint(x: 60, y: 21)
        XCTAssertEqual(RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: next), next, "Source fallback returns the neighboring point")
        let diagonal = RevisionGraphLayout.cutPoint(rect: rect, center: center, toward: CGPoint(x: 200, y: 200))
        XCTAssertEqual(diagonal.y, 40.5); XCTAssertEqual(diagonal.x, 50 + 20.5 / 180 * 150, accuracy: 0.00001)
    }
    func testCancelReapsOwnedWorkerAndRemovesPrivateInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-graph-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("wait.py"), marker = root.appendingPathComponent("marker.json")
        let encodedPath = String(data: try JSONSerialization.data(withJSONObject: marker.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        let program = "#!/usr/bin/python3\nimport os,sys,json,time\nmarker = " + encodedPath + "\nwith open(marker+'.tmp', 'w') as f:\n json.dump({'pid':os.getpid(),'input':sys.argv[1],'mode':os.stat(sys.argv[1]).st_mode & 0o777,'directory_mode':os.stat(os.path.dirname(sys.argv[1])).st_mode & 0o777},f)\nos.replace(marker+'.tmp', marker)\ntime.sleep(30)\n"
        try Data(program.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let token = OperationCancellation(); defer { token.cancel() }
        let worker = Task.detached {
            try RevisionGraphLayoutRuntime.layout(nodes: [RevisionGraphNode(hash: "a")], sizes: [CGSize(width: 40, height: 20)], executable: helper, cancellation: token)
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard FileManager.default.fileExists(atPath: marker.path) else {
            token.cancel()
            do { _ = try await worker.value; XCTFail("Owned worker did not start") }
            catch { XCTFail("Owned worker did not start: \(error)") }
            return
        }
        let data = try Data(contentsOf: marker), details = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pid = try XCTUnwrap(details["pid"] as? Int), input = try XCTUnwrap(details["input"] as? String)
        XCTAssertEqual(details["mode"] as? Int, 0o600); XCTAssertEqual(details["directory_mode"] as? Int, 0o700)
        XCTAssertEqual(Darwin.kill(pid_t(pid), 0), 0)
        token.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled layout must not publish") } catch { XCTAssertTrue(error is OperationCancellationFailure) }
        XCTAssertEqual(Darwin.kill(pid_t(pid), 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: input).deletingLastPathComponent().path))
    }
}
