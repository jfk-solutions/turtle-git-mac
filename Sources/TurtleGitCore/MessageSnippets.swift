// Adapted from TortoiseGit CommitDlg.cpp::ParseSnippetFile/HandleSnippet.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit. GPL-2.0-or-later.
import Foundation

public struct MessageSnippets: Sendable {
    private var values: [[UInt16]: String] = [:]
    public init() {}
    public var keys: [String] { values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF16.self) } }
    public func expansion(for key: String) -> String? { values[Array(key.utf16)] }
    /// No trimming: only a leading '#' is a comment, and the first '=' separates key/value.
    /// Unknown escapes retain both characters; a dangling backslash is dropped upstream.
    public mutating func overlay(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var line = raw
            if index < lines.count - 1 && line.hasSuffix("\r") { line.removeLast() }
            let units = Array(line.utf16)
            guard units.first != 35, let equals = units.firstIndex(of: 61), equals > 0 else { continue }
            var value: [UInt16] = [], escaped = false
            for unit in units.dropFirst(equals + 1) {
                if escaped {
                    switch unit {
                    case 116: value.append(9)
                    case 110: value.append(10)
                    case 114: value.append(13)
                    case 92: value.append(92)
                    default: value.append(92); value.append(unit)
                    }
                    escaped = false
                } else if unit == 92 { escaped = true }
                else { value.append(unit) }
            }
            values[Array(units[..<equals])] = String(decoding: value, as: UTF16.self)
        }
    }
    public func candidates(files: [String]) -> [String] {
        Set(files.map { Array($0.utf16) } + values.keys).sorted { $0.lexicographicallyPrecedes($1) }
            .map { String(decoding: $0, as: UTF16.self) }
    }
}

/// Reads local definitions away from the editor thread. User definitions override shipped keys.
public actor MessageSnippetLoader {
    public init() {}
    public func load(userURL: URL) -> MessageSnippets {
        var result = MessageSnippets()
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("TurtleGitMac_TurtleGitCore.bundle")) } ?? Bundle.module
        #else
        let bundle = Bundle(for: SnippetResourceBundle.self)
        #endif
        for url in [bundle.url(forResource: "snippet", withExtension: "txt", subdirectory: "Completion"), userURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url), let text = Self.decode(data) else { continue }
            result.overlay(text)
        }
        return result
    }
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xfe, 0xff]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252)
    }
}
private final class SnippetResourceBundle: NSObject {}
