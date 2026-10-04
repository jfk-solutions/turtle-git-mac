import Foundation

public enum IgnoreScope: Int, CaseIterable, Sendable { case containingFolder, recursively }
public enum IgnoreDestination: Int, CaseIterable, Sendable { case repositoryRoot, containingFolders, exclude }
public enum IgnoreFailure: LocalizedError {
    case selection, outsideWorkingTree, lineBreak, unsupportedFile
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select files or folders to ignore."
        case .outsideWorkingTree: return "Ignore selections must stay in this working tree, outside Git’s administrative directories."
        case .lineBreak: return "Git ignore rules cannot represent filenames containing a line break."
        case .unsupportedFile: return "The ignore destination must be a regular UTF-8 file, not a symbolic link or directory."
        }
    }
}
public struct IgnoreOptions: Sendable {
    public let paths: [String]
    public let mask: Bool
    public var scope: IgnoreScope = .containingFolder
    public var destination: IgnoreDestination = .repositoryRoot
    public init(paths: [String], mask: Bool = false) throws {
        guard !paths.isEmpty else { throw IgnoreFailure.selection }
        do { self.paths = try RemovalRequest(paths: paths, keepLocal: true).paths }
        catch { throw IgnoreFailure.outsideWorkingTree }
        guard !paths.contains(where: { $0.contains("\n") || $0.contains("\r") }) else { throw IgnoreFailure.lineBreak }
        self.mask = mask
    }
    public func pattern(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let extensionName = (name as NSString).pathExtension
        if mask && extensionName.isEmpty { return nil }
        // The leading star is intentional only in extension-mask mode. All path
        // characters remain literal, including macOS names invalid on Windows.
        let item = mask ? "*." + Self.escape(extensionName) : Self.escape(name)
        guard scope == .containingFolder else { return item }
        let parent = (path as NSString).deletingLastPathComponent
        let prefix = destination != .containingFolders && !parent.isEmpty ? Self.escape(parent) + "/" : ""
        return "/" + prefix + item
    }
    private static func escape(_ name: String) -> String {
        name.map { "\\*?[]#! ".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
}

extension GitRepository {
    /// Resolve through Git rather than assuming .git is a directory: linked
    /// worktrees keep info/exclude in the common administrative directory.
    public func ignoreDestinations(_ options: IgnoreOptions) throws -> [URL] {
        try validateIgnoreSelection(options)
        return try ignorePlans(options).map(\.url)
    }
    @discardableResult public func addIgnoreRules(_ options: IgnoreOptions) throws -> [URL] {
        try validateIgnoreSelection(options)
        let plans = try ignorePlans(options)
        // Validate/read every destination before writing any of them. Existing
        // bytes, comments, BOM and line endings survive the append unchanged.
        let prepared = try plans.map { plan -> (URL, Data, Data) in
            let attributes = try? FileManager.default.attributesOfItem(atPath: plan.url.path)
            if let attributes, attributes[.type] as? FileAttributeType != .typeRegular { throw IgnoreFailure.unsupportedFile }
            let original = attributes == nil ? Data() : try Data(contentsOf: plan.url)
            var data = original
            guard let text = String(data: data, encoding: .utf8) else { throw IgnoreFailure.unsupportedFile }
            let eol = data.firstIndex(of: 10).map { index in index > 0 && data[index - 1] == 13 ? "\r\n" : "\n" } ?? "\n"
            var existing = Set(text.components(separatedBy: "\n").map { line -> String in
                var value = line; if value.last == "\r" { value.removeLast() }; if value.first == "\u{feff}" { value.removeFirst() }; return value
            })
            let new = plan.patterns.filter { existing.insert($0).inserted }
            guard !new.isEmpty else { return (plan.url, original, data) }
            if !data.isEmpty && data.last != 10 { data.append(contentsOf: eol.utf8) }
            data.append(contentsOf: (new.joined(separator: eol) + eol).utf8)
            return (plan.url, original, data)
        }
        var changed: [URL] = []
        for (url, original, data) in prepared where original != data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Append only the new suffix to existing files, preserving inode,
            // permissions and all prior bytes like upstream modeNoTruncate.
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                let length = try handle.seekToEnd()
                guard length == original.count, try Data(contentsOf: url) == original else { throw IgnoreFailure.unsupportedFile }
                try handle.write(contentsOf: data.dropFirst(Int(length)))
            } else { try data.write(to: url, options: .withoutOverwriting) }
            changed.append(url)
        }
        return changed
    }
    private func validateIgnoreSelection(_ options: IgnoreOptions) throws {
        guard try !isBare() else { throw IgnoreFailure.selection }
        for path in options.paths {
            let parent = root.appendingPathComponent(path).deletingLastPathComponent()
            guard RepositoryAccessLease.pathIsContained(parent, by: root) else { throw IgnoreFailure.outsideWorkingTree }
            let existing = try CloneOptions.workingDirectory(for: parent)
            var bytes = try run(["-C", existing.path, "rev-parse", "--show-toplevel"]).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL == root else { throw IgnoreFailure.outsideWorkingTree }
        }
    }
    private func ignorePlans(_ options: IgnoreOptions) throws -> [(url: URL, patterns: [String])] {
        var plans: [(url: URL, patterns: [String])] = []
        var exclude: URL?
        if options.destination == .exclude {
            var bytes = try run(["rev-parse", "--git-path", "info/exclude"]).stdout
            if bytes.last == 10 { bytes.removeLast() }
            let path = String(decoding: bytes, as: UTF8.self)
            exclude = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            var commonBytes = try run(["rev-parse", "--git-common-dir"]).stdout
            if commonBytes.last == 10 { commonBytes.removeLast() }
            let commonPath = String(decoding: commonBytes, as: UTF8.self)
            let common = commonPath.hasPrefix("/") ? URL(fileURLWithPath: commonPath, isDirectory: true) : root.appendingPathComponent(commonPath, isDirectory: true)
            guard RepositoryAccessLease.pathIsContained(exclude!.deletingLastPathComponent(), by: common) else { throw IgnoreFailure.outsideWorkingTree }
        }
        for path in options.paths {
            guard let pattern = options.pattern(for: path) else { continue }
            let url: URL
            switch options.destination {
            case .repositoryRoot: url = root.appendingPathComponent(".gitignore")
            case .containingFolders: url = root.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent(".gitignore")
            case .exclude: url = exclude!
            }
            if options.destination != .exclude && !RepositoryAccessLease.pathIsContained(url.deletingLastPathComponent(), by: root) { throw IgnoreFailure.outsideWorkingTree }
            if let position = plans.firstIndex(where: { $0.url == url }) { plans[position].patterns.append(pattern) }
            else { plans.append((url, [pattern])) }
        }
        return plans
    }
}
