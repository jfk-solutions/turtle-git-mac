import Foundation
import MachO
import TurtleGitCore

@main struct BuiltGraphLayoutReceiver {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1])) else { throw NSError(domain: "GraphLayoutQA", code: 1) }
        let executable = try RevisionGraphLayoutRuntime.executable(bundle: bundle)
        let loaded = (0..<_dyld_image_count()).compactMap { index -> URL? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
        }
        let expectedCore = bundle.bundleURL.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/TurtleGitCore").resolvingSymlinksInPath()
        precondition(loaded.contains(expectedCore), "Receiver must load the app's embedded Core framework")
        let nodes = [RevisionGraphNode(hash: "merge", parents: ["left", "right", "root"]),
                     RevisionGraphNode(hash: "left", parents: ["root"]),
                     RevisionGraphNode(hash: "right", parents: ["root"]), RevisionGraphNode(hash: "root")]
        let sizes = [CGSize(width: 220, height: 70), CGSize(width: 120, height: 40), CGSize(width: 180, height: 55), CGSize(width: 100, height: 40)]
        let geometry = try RevisionGraphLayoutRuntime.layout(nodes: nodes, sizes: sizes, executable: executable)
        precondition(geometry.nodes.map(\.hash) == nodes.map(\.hash))
        precondition(geometry.edges.count == 5)
        let rects = Dictionary(uniqueKeysWithValues: geometry.nodes.map { ($0.hash, $0.rect) })
        for edge in geometry.edges {
            let a = rects[edge.sourceHash]!, b = rects[edge.targetHash]!
            precondition(b.midY > a.midY)
            precondition(!a.contains(edge.points.first!) && !b.contains(edge.points.last!))
            precondition(edge.points.count == edge.bends.count + 2)
        }
        let cancellation = OperationCancellation(); cancellation.cancel()
        do {
            _ = try RevisionGraphLayoutRuntime.layout(nodes: nodes, sizes: sizes, executable: executable, cancellation: cancellation)
            throw NSError(domain: "GraphLayoutQA", code: 2)
        } catch { precondition(error.localizedDescription == "Operation cancelled.") }
        print("PASS: " + CommandLine.arguments[2] + " built Core, bundled helper lookup, OGDF geometry, clipping and pre-cancelled request")
    }
}
