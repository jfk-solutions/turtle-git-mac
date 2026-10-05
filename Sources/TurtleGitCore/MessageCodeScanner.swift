// Adapted from TortoiseGit CommitDlg.cpp::GetAutocompletionList/ScanFile.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit. GPL-2.0-or-later.
import Foundation
import Darwin

public struct MessageCompletionCatalog: Sendable {
    public enum Kind: Sendable { case file, code, snippet }
    private var values: [[UInt16]: Kind] = [:]
    public init(snippets: MessageSnippets = MessageSnippets(), paths: [String] = [], removeExtensions: Bool = false) {
        for key in snippets.keys { insert(Array(key.utf16), kind: .snippet) }
        for path in paths { addFilename(path, removeExtensions: removeExtensions) }
    }
    public var candidates: [String] { values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF16.self) } }
    public func kind(for key: String) -> Kind? { values[Array(key.utf16)] }
    public func kind(forUnits units: [UInt16]) -> Kind? { values[units] }
    mutating func insert(_ key: [UInt16], kind: Kind) { if values[key] == nil { values[key] = kind } }
    mutating func addFilename(_ path: String, removeExtensions: Bool) {
        for name in MessageCompletion.fileCandidates(paths: [path], removeExtensions: removeExtensions) { insert(Array(name.utf16), kind: .file) }
    }
}

public actor MessageCodeScanner {
    public static let shared = MessageCodeScanner()
    public struct Source: Sendable, Equatable {
        public let path: String
        public let state: FileState
        public init(path: String, state: FileState) { self.path = path; self.state = state }
    }
    public struct Options: Sendable, Equatable {
        public var maximumBytes = 300000
        public var timeoutSeconds: UInt32 = 5
        public var parseUnversioned = false
        public var removeExtensions = false
        public var useUTF8 = false
        public var legacyEncoding = String.Encoding.windowsCP1252
        public init() {}
    }
    public struct Result: Sendable {
        public let catalog: MessageCompletionCatalog
        public let timedOut: Bool
        public let visitedRows: Int
    }
    // The source uses a static map keyed only by extension. The shared actor
    // serializes that process-lifetime cache; invalid patterns are never cached.
    private var cachedPatterns: [[UInt16]: String] = [:]
    private let nowMilliseconds: @Sendable () -> UInt64
    public init(nowMilliseconds: @escaping @Sendable () -> UInt64 = { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }) {
        self.nowMilliseconds = nowMilliseconds
    }
    public func scan(root: URL, sources: [Source], snippets: MessageSnippets = MessageSnippets(), userDefinitions: URL,
                     options: Options = Options(), executable: URL? = nil) throws -> Result {
        try Task.checkCancellation()
        var definitions = MessageCodeDefinitions()
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("TurtleGitMac_TurtleGitCore.bundle")) } ?? Bundle.module
        #else
        let bundle = Bundle(for: CodeScannerResourceBundle.self)
        #endif
        for url in [bundle.url(forResource: "autolist", withExtension: "txt", subdirectory: "Completion"), userDefinitions].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url), let text = MessageSnippetLoader.decode(data) { definitions.overlay(text) }
        }
        var catalog = MessageCompletionCatalog(snippets: snippets), visited = 0
        let started = nowMilliseconds(), budget = UInt64(options.timeoutSeconds) * 1000
        for source in sources {
            try Task.checkCancellation()
            if nowMilliseconds() &- started > budget { return Result(catalog: catalog, timedOut: true, visitedRows: visited) }
            visited += 1
            catalog.addFilename(source.path, removeExtensions: options.removeExtensions)
            if source.state == .ignored || source.state == .untracked && !options.parseUnversioned { continue }
            let name = (source.path as NSString).lastPathComponent
            let ext = name.lastIndex(of: ".").map { String(name[$0...]).lowercased() } ?? ""
            guard let configured = definitions.pattern(for: ext), !configured.isEmpty,
                  let data = readRegularFile(root.appendingPathComponent(source.path), maximumBytes: options.maximumBytes),
                  let decoded = MessageCodeText.decode(data, useUTF8: options.useUTF8, legacyEncoding: options.legacyEncoding),
                  !decoded.units.isEmpty else { continue }
            let key = Array(ext.utf16), pattern = cachedPatterns[key] ?? configured
            do {
                let captures = try MessageCodeSymbols.captureUnits(in: decoded.units, pattern: pattern, executable: executable)
                cachedPatterns[key] = pattern
                for units in captures { catalog.insert(units, kind: .code) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Upstream silently skips scan/regex failures. */ }
        }
        try Task.checkCancellation()
        return Result(catalog: catalog, timedOut: false, visitedRows: visited)
    }
    private func readRegularFile(_ url: URL, maximumBytes: Int) -> Data? {
        // Follow symlinks like CreateFile, but never block on a FIFO/device.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size > 0, metadata.st_size < off_t(Int32.max), maximumBytes >= 0,
              metadata.st_size <= Int64(maximumBytes) else { return nil }
        // Read the measured length like ReadFile, rather than allocating the
        // configured maximum for every small file or consuming appended bytes.
        guard let data = try? handle.read(upToCount: Int(metadata.st_size)), !data.isEmpty else { return nil }
        return data
    }
}
private final class CodeScannerResourceBundle: NSObject {}
