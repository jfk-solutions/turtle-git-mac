// Layout configuration and border clipping adapted from TortoiseGit.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RevisionGraphLayoutFailure: LocalizedError {
    case runtimeMissing, invalidGraph, failed(String), invalidOutput
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled Revision Graph layout engine is missing. Rebuild TurtleGit with its GraphLayout runtime."
        case .invalidGraph: return "The revision graph has invalid node sizes or missing parent nodes."
        case .failed(let detail): return "Could not lay out the revision graph. " + detail
        case .invalidOutput: return "The Revision Graph layout engine returned invalid geometry."
        }
    }
}

public struct RevisionGraphNodeGeometry: Sendable {
    public let hash: String
    public let rect: CGRect
}
public struct RevisionGraphEdgeGeometry: Sendable {
    public let sourceHash: String
    public let targetHash: String
    public let bends: [CGPoint]
    /// Center-to-center OGDF polyline clipped to the expanded node borders.
    public let points: [CGPoint]
}
public struct RevisionGraphLayout: Sendable {
    public let nodes: [RevisionGraphNodeGeometry]
    public let edges: [RevisionGraphEdgeGeometry]
    public let size: CGSize

    /// CRevisionGraphWnd::cutPoint checks horizontal borders before vertical
    /// borders. Use the neighboring bend, not a straight line across all bends.
    public static func cutPoint(rect: CGRect, center: CGPoint, toward next: CGPoint, lineWidth: CGFloat = 1) -> CGPoint {
        let border = rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        let dx = next.x - center.x, dy = next.y - center.y
        if dy != 0 {
            let y: CGFloat? = next.y > border.maxY ? border.maxY : (next.y < border.minY ? border.minY : nil)
            if let y {
                let x = center.x + (y - center.y) / dy * dx
                if border.minX <= x && x <= border.maxX { return CGPoint(x: x, y: y) }
            }
        }
        if dx != 0 {
            let x: CGFloat? = next.x > border.maxX ? border.maxX : (next.x < border.minX ? border.minX : nil)
            if let x {
                let y = center.y + (x - center.x) / dx * dy
                if border.minY <= y && y <= border.maxY { return CGPoint(x: x, y: y) }
            }
        }
        return next
    }
}

public enum RevisionGraphLayoutRuntime {
    public static func executable(bundle: Bundle = .main) throws -> URL {
        let file = bundle.bundleURL.appendingPathComponent("Contents/Helpers/GraphLayout/graph-layout")
        guard FileManager.default.isExecutableFile(atPath: file.path) else { throw RevisionGraphLayoutFailure.runtimeMissing }
        return file
    }

    /// Call off the UI thread. The caller owns one cancellation token per layout;
    /// cancellation reaps the owned helper before removing its private inputs.
    public static func layout(nodes: [RevisionGraphNode], sizes: [CGSize], executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> RevisionGraphLayout {
        try Task.checkCancellation(); try cancellation?.check()
        guard sizes.count == nodes.count, nodes.count <= 1_000_000,
              Set(nodes.map(\.hash)).count == nodes.count,
              sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.width <= 1_000_000 && $0.height <= 1_000_000 }) else { throw RevisionGraphLayoutFailure.invalidGraph }
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.hash, $0.offset) })
        var edges: [(Int, Int)] = []
        for (index, node) in nodes.enumerated() {
            try cancellation?.check()
            for parent in node.parents {
                guard let target = indices[parent], target != index else { throw RevisionGraphLayoutFailure.invalidGraph }
                edges.append((index, target))
            }
        }
        guard edges.count <= 10_000_000 else { throw RevisionGraphLayoutFailure.invalidGraph }
        if nodes.isEmpty { return RevisionGraphLayout(nodes: [], edges: [], size: .zero) }
        let helper = try executable ?? Self.executable()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw RevisionGraphLayoutFailure.runtimeMissing }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitGraphLayout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var input = "TGGRAPH1 \(nodes.count) \(edges.count)\n"
        input += sizes.map { "\(Double($0.width)) \(Double($0.height))\n" }.joined()
        input += edges.map { "\($0.0) \($0.1)\n" }.joined()
        let file = directory.appendingPathComponent("input"), outputFile = directory.appendingPathComponent("output"), errorFile = directory.appendingPathComponent("error")
        try Data(input.utf8).write(to: file); try Data().write(to: outputFile); try Data().write(to: errorFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let output = try FileHandle(forWritingTo: outputFile), error = try FileHandle(forWritingTo: errorFile)
        defer { try? output.close(); try? error.close() }
        let token = cancellation ?? OperationCancellation()
        let status = try CancellableGitProcess.run(executable: helper, arguments: [file.path], environment: ProcessInfo.processInfo.environment,
                                                  output: output.fileDescriptor, error: error.fileDescriptor, cancellation: token)
        try Task.checkCancellation(); try token.check()
        guard status == 0 else {
            let details = try FileHandle(forReadingFrom: errorFile)
            defer { try? details.close() }
            throw RevisionGraphLayoutFailure.failed(String(decoding: try details.read(upToCount: 1024) ?? Data(), as: UTF8.self))
        }
        let length = (try FileManager.default.attributesOfItem(atPath: outputFile.path)[.size] as? NSNumber)?.intValue ?? 0
        // A bound derived from this request, not a fixed graph row limit.
        guard length <= 4096 + nodes.count * 128 + edges.count * 256 + nodes.count * edges.count * 64 else { throw RevisionGraphLayoutFailure.invalidOutput }
        return try parse(try Data(contentsOf: outputFile), nodes: nodes, sizes: sizes, edges: edges, cancellation: token)
    }

    static func parse(_ data: Data, nodes: [RevisionGraphNode], sizes: [CGSize], edges: [(Int, Int)], cancellation: OperationCancellation? = nil) throws -> RevisionGraphLayout {
        guard let text = String(data: data, encoding: .utf8) else { throw RevisionGraphLayoutFailure.invalidOutput }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard rows.count == 2 + nodes.count + edges.count, rows.last?.isEmpty == true,
              rows[0] == "TGGRAPH1 \(nodes.count) \(edges.count)" else { throw RevisionGraphLayoutFailure.invalidOutput }
        func values(_ row: Substring) throws -> [CGFloat] {
            let fields = row.split(separator: " ")
            let parsed = fields.compactMap { Double($0) }
            guard parsed.count == fields.count, parsed.allSatisfy(\.isFinite) else { throw RevisionGraphLayoutFailure.invalidOutput }
            return parsed.map { CGFloat($0) }
        }
        var geometry: [RevisionGraphNodeGeometry] = []
        for index in nodes.indices {
            try cancellation?.check()
            let point = try values(rows[index + 1])
            guard point.count == 2 else { throw RevisionGraphLayoutFailure.invalidOutput }
            let rect = CGRect(x: point[0] - sizes[index].width / 2, y: point[1] - sizes[index].height / 2, width: sizes[index].width, height: sizes[index].height)
            guard rect.minX >= 0, rect.minY >= 0 else { throw RevisionGraphLayoutFailure.invalidOutput }
            geometry.append(RevisionGraphNodeGeometry(hash: nodes[index].hash, rect: rect))
        }
        var paths: [RevisionGraphEdgeGeometry] = []
        for (index, edge) in edges.enumerated() {
            try cancellation?.check()
            let fields = rows[1 + nodes.count + index].split(separator: " ")
            guard let first = fields.first, let count = Int(first), count >= 0, count <= nodes.count + 2,
                  fields.count == 1 + 2 * count else { throw RevisionGraphLayoutFailure.invalidOutput }
            let coords = try values(fields.dropFirst().joined(separator: " ")[...])
            let bends = stride(from: 0, to: coords.count, by: 2).map { CGPoint(x: coords[$0], y: coords[$0 + 1]) }
            let source = geometry[edge.0].rect, target = geometry[edge.1].rect
            let a = CGPoint(x: source.midX, y: source.midY), b = CGPoint(x: target.midX, y: target.midY)
            var points = [a] + bends + [b]
            points[0] = RevisionGraphLayout.cutPoint(rect: source, center: a, toward: points[1])
            points[points.count - 1] = RevisionGraphLayout.cutPoint(rect: target, center: b, toward: points[points.count - 2])
            paths.append(RevisionGraphEdgeGeometry(sourceHash: nodes[edge.0].hash, targetHash: nodes[edge.1].hash, bends: bends, points: points))
        }
        return RevisionGraphLayout(nodes: geometry, edges: paths, size: CGSize(width: geometry.map { $0.rect.maxX }.max() ?? 0, height: geometry.map { $0.rect.maxY }.max() ?? 0))
    }
}
