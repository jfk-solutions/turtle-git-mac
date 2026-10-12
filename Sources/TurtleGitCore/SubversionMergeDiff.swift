// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum SubversionDiffKind: String, Sendable { case common, modified, latest, same, conflict }
public struct SubversionDiffSegment: Sendable, Equatable {
    public let kind: SubversionDiffKind
    public let base: Range<Int>
    public let mine: Range<Int>
    public let theirs: Range<Int>
}
public struct SubversionDiffPlan: Sendable {
    public let segments: [SubversionDiffSegment]
    public let base: [String]
    public let mine: [String]
    public let theirs: [String]?
    /// Original line arrays are retained separately from filtered engine keys.
    /// Consumers must use these originals for display, transfers and result text.
    public var hasConflicts: Bool { segments.contains { $0.kind == .conflict } }
}
public enum SubversionMergeDiffFailure: LocalizedError {
    case runtimeMissing, invalidOutput, failed(String), timedOut
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled Subversion merge engine is missing. Rebuild TurtleGit with its merge runtime."
        case .invalidOutput: return "The merge engine returned an invalid source mapping."
        case .failed(let detail): return "The Subversion merge engine failed. " + detail
        case .timedOut: return "The merge engine took too long to compare these files."
        }
    }
}
public enum SubversionMergeDiff {
    private final class FrameworkAnchor: NSObject {}
    /// The app resolves its own sealed bundle. Standalone native receivers may
    /// load Core from Xcode's product directory and use its companion app.
    public static func applicationBundle() -> Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        let framework = Bundle(for: FrameworkAnchor.self)
        let companion = framework.bundleURL.deletingLastPathComponent().appendingPathComponent("TurtleGitMac.app")
        return Bundle(url: companion) ?? .main
    }
    public static func executable(bundle: Bundle = .main) throws -> URL {
        let resolved = bundle === Bundle.main ? applicationBundle() : bundle
        let path = resolved.bundleURL.appendingPathComponent("Contents/Helpers/MergeDiff/merge-diff")
        guard FileManager.default.isExecutableFile(atPath: path.path) else { throw SubversionMergeDiffFailure.runtimeMissing }
        return path
    }
    public static func runtimeRoot(bundle: Bundle = .main) throws -> URL {
        let resolved = bundle === Bundle.main ? applicationBundle() : bundle
        let path = resolved.bundleURL.appendingPathComponent("Contents/Helpers/Git")
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent("libexec/git-svn-runtime").path) else { throw SubversionMergeDiffFailure.runtimeMissing }
        return path
    }
    /// Call off the UI thread. The bounded helper uses the pinned Subversion
    /// diff2/diff3 APIs. Canonical hex framing makes each of the nine source line
    /// endings one engine token and keeps byte/EOL distinctions explicit.
    public static func plan(base: String, mine: String, theirs: String? = nil, filter: MergeRegexFilter? = nil,
                            executable: URL? = nil, runtimeRoot: URL? = nil, regexExecutable: URL? = nil,
                            cancellation: OperationCancellation? = nil) throws -> SubversionDiffPlan {
        let token = cancellation ?? OperationCancellation(); try token.check()
        let helper = try executable ?? Self.executable(), runtime = try runtimeRoot ?? Self.runtimeRoot()
        guard helper.isFileURL, runtime.isFileURL, !helper.path.contains("\0"), !runtime.path.contains("\0") else { throw SubversionMergeDiffFailure.runtimeMissing }
        let sources = [base, mine] + (theirs.map { [$0] } ?? [])
        let lines = sources.map(MergeRegexFilters.lines)
        let all = lines.flatMap { $0 }
        let transformed: [String]
        if let filter {
            let content = all.map(MergeLineEndings.droppingFinalEnding)
            let replacements = try MergeRegexFilters.transformed(content, filter: filter, executable: regexExecutable, cancellation: token)
            transformed = zip(all, replacements).map { original, replaced in
                let endingOffset = (MergeLineEndings.droppingFinalEnding(original) as NSString).length
                return replaced + (original as NSString).substring(from: endingOffset)
            }
        } else { transformed = all }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMergeDiff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let hex = Array("0123456789abcdef".utf8)
        var offset = 0, files: [URL] = []
        for (index, source) in lines.enumerated() {
            try token.check()
            var bytes = Data()
            for line in transformed[offset..<offset + source.count] {
                for byte in line.utf8 { bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 15)]) }
                bytes.append(10)
                guard bytes.count <= 32 * 1024 * 1024 else { throw SubversionMergeDiffFailure.failed("Comparison input is too large.") }
            }
            offset += source.count
            let file = directory.appendingPathComponent(String(index)); try bytes.write(to: file); files.append(file)
        }
        let output: Data
        do { output = try BundledTextHelper.capture(executable: helper, arguments: [runtime.path, String(sources.count)] + files.map(\.path), cancellation: token) }
        catch BundledTextHelperFailure.timedOut { throw SubversionMergeDiffFailure.timedOut }
        catch BundledTextHelperFailure.failed(let detail) { throw SubversionMergeDiffFailure.failed(detail) }
        try token.check()
        guard let text = String(data: output, encoding: .utf8) else { throw SubversionMergeDiffFailure.invalidOutput }
        let records = text.split(separator: "\n")
        guard records.first == "svn-diff\t1\t\(sources.count)" else { throw SubversionMergeDiffFailure.invalidOutput }
        let counts = lines.map(\.count) + (sources.count == 2 ? [0] : [])
        var ends = [0, 0, 0], segments: [SubversionDiffSegment] = []
        for record in records.dropFirst() {
            let fields = record.split(separator: "\t")
            guard fields.count == 7, let kind = SubversionDiffKind(rawValue: String(fields[0])) else { throw SubversionMergeDiffFailure.invalidOutput }
            let values = fields.dropFirst().compactMap { Int($0) }
            guard values.count == 6 else { throw SubversionMergeDiffFailure.invalidOutput }
            var ranges: [Range<Int>] = []
            for index in 0..<3 {
                let start = values[index * 2], count = values[index * 2 + 1]
                guard start == ends[index], count >= 0, start >= 0, start <= counts[index], count <= counts[index] - start else { throw SubversionMergeDiffFailure.invalidOutput }
                ranges.append(start..<start + count); ends[index] = start + count
            }
            guard ranges.contains(where: { !$0.isEmpty }), sources.count == 3 || [.common, .modified].contains(kind) else { throw SubversionMergeDiffFailure.invalidOutput }
            if kind == .common { guard ranges[0].count == ranges[1].count && (sources.count == 2 || ranges[1].count == ranges[2].count) else { throw SubversionMergeDiffFailure.invalidOutput } }
            if sources.count == 3 {
                guard kind != .modified || ranges[0].count == ranges[2].count,
                      kind != .latest || ranges[0].count == ranges[1].count,
                      kind != .same || ranges[1].count == ranges[2].count else { throw SubversionMergeDiffFailure.invalidOutput }
            }
            segments.append(.init(kind: kind, base: ranges[0], mine: ranges[1], theirs: ranges[2]))
        }
        guard ends == counts else { throw SubversionMergeDiffFailure.invalidOutput }
        return .init(segments: segments, base: lines[0], mine: lines[1], theirs: lines.count == 3 ? lines[2] : nil)
    }
}
