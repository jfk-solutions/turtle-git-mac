// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptations of diff-dll.js and diff-nb.js from the pinned upstream.
import Foundation

/// Output names for owned comparison inputs are independent of Git paths.
/// An absent historical side has no blob identity: give it an explicit empty
/// input name rather than borrowing the other side's OID.
public enum ComparisonPreviewInputName {
    static func absent(_ content:ComparisonFileContent)->Bool {
        content.mode==nil && content.objectID==nil && content.bytes.isEmpty && !content.isDeleted
    }
    private static func safeExtension(_ value:String)->Bool {
        (1...16).contains(value.utf8.count) && value.utf8.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)}
    }
    public static func leaf(for content:ComparisonFileContent,other:ComparisonFileContent,side:String,fallbackExtension:String)throws->String {
        guard !side.isEmpty,side.utf8.count<=32,side.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45}),fallbackExtension.isEmpty || safeExtension(fallbackExtension) else {throw RevisionComparisonFailure.selection}
        if !content.path.utf8.contains(0) {
            let name=HistoricalGitPath.filename(content.path) ?? ""
            if ["",".",".."].contains(name) {return side+(fallbackExtension.isEmpty ? "":"."+fallbackExtension)}
            return try HistoricalFileDeliveryName.leaf(for:content)
        }
        // Validate the key even for an empty side before deriving its suffix.
        _ = try RepositoryBrowserGitPath(key:content.path)
        if absent(content) {
            let candidates=[HistoricalGitPath.fileExtension(other.path),HistoricalGitPath.fileExtension(content.path),fallbackExtension]
            let ext=candidates.first(where:safeExtension) ?? ""
            return side+"-absent"+(ext.isEmpty ? "":"."+ext)
        }
        return try HistoricalFileDeliveryName.leaf(for:content)
    }
}

public struct BinaryComparisonReport: Sendable {
    public let identical: Bool
    public let text: String
    public init(_ document: FileComparisonDocument, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        let a = document.base, b = document.destination
        let sameSize = a.bytes.count == b.bytes.count
        var same = sameSize && a.isDeleted == b.isDeleted
        if same {
            for offset in stride(from: 0, to: a.bytes.count, by: 1_048_576) {
                try cancellation?.check()
                let end = min(a.bytes.count, offset + 1_048_576)
                if a.bytes[a.bytes.startIndex + offset..<a.bytes.startIndex + end] != b.bytes[b.bytes.startIndex + offset..<b.bytes.startIndex + end] { same = false; break }
            }
        }
        let av = BinaryFileVersion.read(a.bytes), bv = BinaryFileVersion.read(b.bytes)
        func caption(_ content:ComparisonFileContent)->String {content.path.utf8.contains(0) ? RepositoryBrowserGitPath.display(key:content.path):content.path}
        var common: [String] = [], old: [String] = ["Base", "  File: " + caption(a)], new: [String] = ["New", "  File: " + caption(b)]
        if sameSize { common.append("File sizes: \(b.bytes.count) bytes") }
        else { old.append("  Size: \(a.bytes.count) bytes"); new.append("  Size: \(b.bytes.count) bytes") }
        if !same && sameSize { common.append("File content differs!") }
        if a.isDeleted { old.append("  File absent") }; if b.isDeleted { new.append("  File absent") }
        if av == nil && bv == nil { common.append("No version information available.") }
        else if av == bv { common.append("Version: " + (bv ?? "")) }
        else { old.append("  Version: " + (av ?? "Unavailable")); new.append("  Version: " + (bv ?? "Unavailable")) }
        identical = same && av == bv
        text = identical ? (["Files are identical", ""] + common).joined(separator: "\n") :
            (["Files differ!", ""] + old + [""] + new + [""] + common).joined(separator: "\n")
        try cancellation?.check()
    }
}

/// Bounded metadata reads; a malformed/unknown executable remains a comparable
/// binary and simply has no available version. Nothing is loaded or executed.
public enum BinaryFileVersion {
    public static func read(_ data: Data) -> String? {
        let reader = Reader(data)
        if reader.number(0, 2) == 0x5a4d { return pe(reader) }
        return mach(reader, at: 0, size: data.count)
    }
    private struct Reader {
        let data: Data
        init(_ data: Data) { self.data = data }
        func number(_ at: Int, _ length: Int, big: Bool = false) -> UInt64? {
            guard at >= 0, at <= data.count, length <= data.count - at else { return nil }
            var value: UInt64 = 0
            for index in 0..<length { value |= UInt64(data[data.startIndex + at + index]) << ((big ? length - index - 1 : index) * 8) }
            return value
        }
        func integer(_ at: Int, _ length: Int = 4, big: Bool = false) -> Int? {
            guard let value = number(at, length, big: big), value <= UInt64(Int.max) else { return nil }; return Int(value)
        }
    }
    private static func pe(_ r: Reader) -> String? {
        guard let header = r.integer(0x3c), r.number(header, 4) == 0x4550,
              let sections = r.integer(header + 6, 2), sections <= 96,
              let optionalSize = r.integer(header + 20, 2) else { return nil }
        let optional = header + 24, magic = r.number(optional, 2)
        guard magic == 0x10b || magic == 0x20b else { return nil }
        let directories = optional + (magic == 0x10b ? 96 : 112)
        guard directories + 24 <= optional + optionalSize, (r.integer(directories - 4) ?? 0) >= 3,
              let resourceRVA = r.integer(directories + 16), let resourceSize = r.integer(directories + 20), resourceSize >= 16 else { return nil }
        func map(_ rva: Int, length: Int) -> Int? {
            for index in 0..<sections {
                let section = optional + optionalSize + index * 40
                guard let address = r.integer(section + 12), let size = r.integer(section + 16), let raw = r.integer(section + 20), rva >= address else { continue }
                let delta = rva - address
                if delta <= size, length <= size - delta, raw <= r.data.count, delta <= r.data.count - raw, length <= r.data.count - raw - delta { return raw + delta }
            }
            return nil
        }
        guard let root = map(resourceRVA, length: resourceSize) else { return nil }
        func entry(_ relative: Int, id: Int? = nil) -> Int? {
            guard relative >= 0, relative <= resourceSize - 16,
                  let names = r.integer(root + relative + 12, 2), let ids = r.integer(root + relative + 14, 2), names + ids <= 4096,
                  (names + ids) * 8 <= resourceSize - relative - 16 else { return nil }
            for index in 0..<(names + ids) {
                let at = root + relative + 16 + index * 8
                guard let key = r.integer(at), let target = r.integer(at + 4) else { return nil }
                if id == nil || key == id { return target }
            }
            return nil
        }
        guard let type = entry(0, id: 16), type & 0x80000000 != 0,
              let name = entry(type & 0x7fffffff), name & 0x80000000 != 0,
              let language = entry(name & 0x7fffffff), language & 0x80000000 == 0,
              language <= resourceSize - 16, let valueRVA = r.integer(root + language), let valueSize = r.integer(root + language + 4),
              valueSize >= 6, valueSize <= 1_048_576, let value = map(valueRVA, length: valueSize),
              let length = r.integer(value, 2), length <= valueSize, length >= 6, (r.integer(value + 2, 2) ?? 0) >= 52 else { return nil }
        var cursor = 6, key: [UInt16] = []
        while cursor + 2 <= length, key.count < 32 {
            guard let character = r.number(value + cursor, 2) else { return nil }; cursor += 2
            if character == 0 { break }; key.append(UInt16(character))
        }
        guard String(decoding: key, as: UTF16.self) == "VS_VERSION_INFO" else { return nil }
        cursor = (cursor + 3) & ~3
        guard cursor + 52 <= length, r.number(value + cursor, 4) == 0xfeef04bd,
              let high = r.number(value + cursor + 8, 4), let low = r.number(value + cursor + 12, 4) else { return nil }
        return "\(high >> 16).\(high & 0xffff).\(low >> 16).\(low & 0xffff)"
    }
    private static func mach(_ r: Reader, at: Int, size: Int, allowFat: Bool = true) -> String? {
        guard at >= 0, size >= 28, at <= r.data.count, size <= r.data.count - at, let magic = r.number(at, 4) else { return nil }
        if allowFat, [UInt64(0xbebafeca),0xbfbafeca,0xcafebabe,0xcafebabf].contains(magic) {
            let big = magic == 0xbebafeca || magic == 0xbfbafeca, wide = magic == 0xbfbafeca || magic == 0xcafebabf
            guard let count = r.integer(at + 4, big: big), count > 0, count <= 64, 8 + count * (wide ? 32 : 20) <= size else { return nil }
            var versions: [String] = []
            for index in 0..<count {
                let entry = at + 8 + index * (wide ? 32 : 20)
                guard let cpu = r.integer(entry, big: big), let offset = r.integer(entry + 8, wide ? 8 : 4, big: big),
                      let amount = r.integer(entry + (wide ? 16 : 12), wide ? 8 : 4, big: big), offset <= size, amount <= size - offset,
                      let version = mach(r, at: at + offset, size: amount, allowFat: false) else { return nil }
                let architecture = cpu == 0x100000c ? "arm64" : cpu == 0x1000007 ? "x86_64" : String(format: "cpu-%x", cpu)
                versions.append(architecture + ": " + version)
            }
            return versions.joined(separator: "; ")
        }
        guard [UInt64(0xfeedface),0xfeedfacf,0xcefaedfe,0xcffaedfe].contains(magic) else { return nil }
        let big = magic == 0xcefaedfe || magic == 0xcffaedfe, wide = magic == 0xfeedfacf || magic == 0xcffaedfe
        let header = wide ? 32 : 28
        guard let count = r.integer(at + 16, big: big), count <= 4096, let commandSize = r.integer(at + 20, big: big), commandSize <= size - header else { return nil }
        var position = at + header
        for _ in 0..<count {
            guard position + 8 <= at + header + commandSize, let command = r.integer(position, big: big), let length = r.integer(position + 4, big: big), length >= 8, length <= at + header + commandSize - position else { return nil }
            if command == 0xd {
                guard length >= 24, let version = r.number(position + 16, 4, big: big) else { return nil }
                return "\(version >> 16).\((version >> 8) & 255).\(version & 255)"
            }
            position += length
        }
        return nil
    }
}

public enum NotebookComparisonPreparationFailure: LocalizedError {
    case absent
    public var errorDescription: String? { "Notebook comparison requires two existing notebook files." }
}
public struct NotebookComparisonPreview: Sendable {
    public let directory: URL
    public let notebook: URL
    public let base: URL
    public let destination: URL
    public static func source(base: String, destination: String) throws -> String {
        func literal(_ path: String) throws -> String {
            guard !path.contains("\0") else { throw DiffToolFailure.arguments }
            var value = "\""
            for character in path.unicodeScalars {
                switch character.value {
                case 34: value += "\\\""
                case 92: value += "\\\\"
                case 0..<32,127: value += String(format:"\\:%04x",character.value)
                case 128...0xffff: value += String(format:"\\:%04x",character.value)
                case 0x10000...0x10ffff: value += String(format:"\\|%06x",character.value)
                default: value.unicodeScalars.append(character)
                }
            }
            return value + "\""
        }
        return try """
        Notebook[{
        Cell[BoxData[ButtonBox["Compare Notebooks",
        ButtonFrame->"DialogBox", Active->True, ButtonEvaluator->Automatic,
        ButtonFunction:>(Needs["AuthorTools`"];
        NotebookPut[Symbol["NotebookDiff"][\(literal(base)),\(literal(destination))]])]], NotebookDefault]
        }, Saveable->False, Editable->False, Selectable->False,
        WindowToolbars->{}, WindowFrame->ModelessDialog, WindowElements->{},
        WindowFrameElements->CloseBox, WindowTitle->"Diff", ShowCellBracket->False, WindowSize->{Fit,Fit}]
        """
    }
    public static func prepare(_ document: FileComparisonDocument, in root: URL, cancellation: OperationCancellation? = nil) throws -> Self {
        try cancellation?.check()
        guard !document.base.isDeleted, !document.destination.isDeleted else { throw NotebookComparisonPreparationFailure.absent }
        let directory = root.appendingPathComponent("TurtleGitNotebookDiff-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            func target(_ content: ComparisonFileContent, side: String) throws -> URL {
                let folder = directory.appendingPathComponent(side, isDirectory: true)
                try manager.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let other=side=="base" ? document.destination:document.base
                let name=try ComparisonPreviewInputName.leaf(for:content,other:other,side:side,fallbackExtension:"nb")
                return folder.appendingPathComponent(name)
            }
            let base = try target(document.base, side:"base"), destination = try target(document.destination, side:"new"), notebook = directory.appendingPathComponent("Compare.nb")
            try document.base.bytes.write(to: base, options: .withoutOverwriting); try cancellation?.check()
            try document.destination.bytes.write(to: destination, options: .withoutOverwriting); try cancellation?.check()
            try Data(source(base: base.path, destination: destination.path).utf8).write(to: notebook, options: .withoutOverwriting)
            for file in [base,destination,notebook] { try manager.setAttributes([.posixPermissions:0o444], ofItemAtPath:file.path) }
            try cancellation?.check(); return Self(directory:directory, notebook:notebook, base:base, destination:destination)
        } catch { try? manager.removeItem(at:directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}
