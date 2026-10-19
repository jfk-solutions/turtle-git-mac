// SPDX-License-Identifier: GPL-2.0-or-later
// macOS adaptation of contrib/diff-scripts/diff-ppt.js. PowerPoint exports
// captured inputs; Core compares descriptors without an Office/PDF dependency.
import Foundation

public enum PresentationComparisonFailure: LocalizedError, Sendable {
    case absent, format, budget, manifest
    public var errorDescription: String? {
        switch self {
        case .absent: return "Presentation comparison requires two existing presentation files."
        case .format: return "Presentation comparison supports .ppt, .pptx and .pptm files."
        case .budget: return "The presentation exceeds the comparison limit (512 slides per side or 64 MiB of slide metadata)."
        case .manifest: return "The exported presentation slide metadata is invalid or incomplete."
        }
    }
}
public struct PresentationComparisonPreview: Sendable {
    public let directory: URL
    public let base: URL
    public let destination: URL
    public let basePDF: URL
    public let destinationPDF: URL
    public let baseManifest: URL
    public let destinationManifest: URL
    public static func prepare(_ document: FileComparisonDocument, in root: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        guard !document.base.isDeleted, !document.destination.isDeleted else { throw PresentationComparisonFailure.absent }
        for content in [document.base, document.destination] {
            guard ["ppt", "pptx", "pptm"].contains((content.path as NSString).pathExtension.lowercased()), !content.path.utf8.contains(0) else { throw PresentationComparisonFailure.format }
        }
        let manager = FileManager.default
        let directory = root.appendingPathComponent("TurtleGitPresentationDiff-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func copy(_ content: ComparisonFileContent, side: String) throws -> URL {
                try cancellation.check()
                let folder = directory.appendingPathComponent(side, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent((content.path as NSString).lastPathComponent)
                try content.bytes.write(to: file, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
                try cancellation.check(); return file
            }
            let base = try copy(document.base, side: "base"), destination = try copy(document.destination, side: "new")
            try cancellation.check()
            return Self(directory: directory, base: base, destination: destination,
                        basePDF: directory.appendingPathComponent("base.pdf"), destinationPDF: directory.appendingPathComponent("new.pdf"),
                        baseManifest: directory.appendingPathComponent("base.json"), destinationManifest: directory.appendingPathComponent("new.json"))
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}
public struct PresentationSlide: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let stableID: String?
    public let text: String
    public let notes: String
    public let visualFingerprint: String?
    public init(pageIndex: Int, stableID: String? = nil, text: String, notes: String, visualFingerprint: String? = nil) {
        self.pageIndex = pageIndex; self.stableID = stableID; self.text = text; self.notes = notes; self.visualFingerprint = visualFingerprint
    }
}
public struct PresentationSlideManifest: Codable, Sendable {
    public let version: Int
    public let slides: [PresentationSlide]
    public init(slides: [PresentationSlide]) { version = 1; self.slides = slides }
    public func validate(cancellation: OperationCancellation) throws {
        try cancellation.check()
        guard version == 1 else { throw PresentationComparisonFailure.manifest }
        guard slides.count <= 512 else { throw PresentationComparisonFailure.budget }
        var bytes = 0, ids = Set<Data>()
        for (index, slide) in slides.enumerated() {
            try cancellation.check()
            guard slide.pageIndex == index else { throw PresentationComparisonFailure.manifest }
            if let id = slide.stableID {
                guard !id.isEmpty, id.utf8.count <= 256, !id.utf8.contains(0), ids.insert(Data(id.utf8)).inserted else { throw PresentationComparisonFailure.manifest }
            }
            if let fingerprint = slide.visualFingerprint {
                guard !fingerprint.isEmpty, fingerprint.utf8.count <= 256 else { throw PresentationComparisonFailure.manifest }
            }
            bytes += slide.text.utf8.count + slide.notes.utf8.count
            guard bytes <= 64 * 1024 * 1024 else { throw PresentationComparisonFailure.budget }
        }
    }
    public static func read(from url: URL, cancellation: OperationCancellation) throws -> Self {
        try cancellation.check()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= 128 * 1024 * 1024 else { throw PresentationComparisonFailure.budget }
        let data = try Data(contentsOf: url)
        try cancellation.check()
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(cancellation: cancellation); return result
    }
    public func write(to url: URL, cancellation: OperationCancellation) throws {
        try validate(cancellation: cancellation)
        let data = try JSONEncoder().encode(self)
        guard data.count <= 128 * 1024 * 1024 else { throw PresentationComparisonFailure.budget }
        try cancellation.check(); try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try cancellation.check()
    }
}
public struct PresentationComparisonManifest: Sendable {
    public let base: PresentationSlideManifest
    public let destination: PresentationSlideManifest
    public init(base: PresentationSlideManifest, destination: PresentationSlideManifest) { self.base = base; self.destination = destination }
}
public enum PresentationSlideChange: String, Codable, Sendable { case added, deleted, modified, unchanged }
public struct PresentationSlideComparison: Sendable {
    public let base: PresentationSlide?
    public let destination: PresentationSlide?
    public let change: PresentationSlideChange
    public let isMoved: Bool
}
public struct PresentationComparisonReport: Sendable {
    public let rows: [PresentationSlideComparison]
    /// At most 512² comparisons. Unique identity wins over visual similarity;
    /// exact-content matching then anchors additions/deletions before positional
    /// pairing of the remaining slides. No heuristic discards an input slide.
    public init(base: [PresentationSlide], destination: [PresentationSlide], cancellation: OperationCancellation) throws {
        try PresentationSlideManifest(slides: base).validate(cancellation: cancellation)
        try PresentationSlideManifest(slides: destination).validate(cancellation: cancellation)
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func equal(_ a: PresentationSlide, _ b: PresentationSlide) -> Bool {
            same(a.text,b.text) && same(a.notes,b.notes) && a.visualFingerprint.map { Data($0.utf8) } == b.visualFingerprint.map { Data($0.utf8) }
        }
        var pairs = [Int: Int](), used = Set<Int>()
        let ids = Dictionary(uniqueKeysWithValues: base.enumerated().compactMap { i,s in s.stableID.map { (Data($0.utf8),i) } })
        for (j, slide) in destination.enumerated() {
            try cancellation.check()
            if let id = slide.stableID, let i = ids[Data(id.utf8)] { pairs[j] = i; used.insert(i) }
        }
        for (j, slide) in destination.enumerated() where pairs[j] == nil {
            try cancellation.check()
            if let i = base.indices.first(where: { i in
                guard !used.contains(i) else { return false }
                if let a = base[i].visualFingerprint, let b = slide.visualFingerprint { return same(a,b) }
                return equal(base[i],slide)
            }) { pairs[j] = i; used.insert(i) }
        }
        let remainingBase = base.indices.filter { !used.contains($0) }
        let remainingNew = destination.indices.filter { pairs[$0] == nil }
        for (i,j) in zip(remainingBase,remainingNew) {
            // Different explicit slide IDs are evidence of deletion/insertion,
            // not enough evidence to label unrelated slides Modified.
            guard base[i].stableID == nil || destination[j].stableID == nil else { continue }
            pairs[j] = i; used.insert(i)
        }
        // Longest increasing subsequence distinguishes moves from index shifts
        // caused only by inserted/deleted slides. Quadratic bound is explicit.
        let order = destination.indices.compactMap { j in pairs[j].map { (j,$0) } }
        var lengths = Array(repeating: 1, count: order.count), previous = Array(repeating: -1, count: order.count)
        for j in order.indices {
            try cancellation.check()
            for i in 0..<j where order[i].1 < order[j].1 && lengths[i] + 1 > lengths[j] { lengths[j] = lengths[i] + 1; previous[j] = i }
        }
        var stationary = Set<Int>()
        if var index = lengths.indices.max(by: { lengths[$0] < lengths[$1] }) {
            while index >= 0 { stationary.insert(order[index].0); index = previous[index] }
        }
        var result = [PresentationSlideComparison](), emittedDeleted = Set<Int>()
        for j in destination.indices {
            try cancellation.check()
            if let i = pairs[j] {
                for d in base.indices where d < i && !used.contains(d) && emittedDeleted.insert(d).inserted {
                    result.append(.init(base:base[d],destination:nil,change:.deleted,isMoved:false))
                }
                result.append(.init(base:base[i],destination:destination[j],change:equal(base[i],destination[j]) ? .unchanged : .modified,isMoved:!stationary.contains(j)))
            } else { result.append(.init(base:nil,destination:destination[j],change:.added,isMoved:false)) }
        }
        for d in base.indices where !used.contains(d) && !emittedDeleted.contains(d) { result.append(.init(base:base[d],destination:nil,change:.deleted,isMoved:false)) }
        try cancellation.check(); rows = result
    }
}
