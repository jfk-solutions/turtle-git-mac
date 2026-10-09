// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of TortoiseGit SerialPatch.cpp; see NOTICE.
import Foundation

public enum SerialPatchFailure: LocalizedError {
    case file(URL), body(URL)
    public var errorDescription: String? {
        switch self {
        case .file(let file): return "Could not open/parse " + file.path
        case .body(let file): return "Could not parse the mail body in " + file.path
        }
    }
}

/// Source headers and original bytes of one format-patch file. Subject folding
/// preserves the source's continuation whitespace, without decoding RFC 2047.
public struct SerialPatch: Equatable, Sendable {
    public let file: URL
    public let bytes: Data
    public let author: String
    public let date: String
    public let subject: String
    public let inlineBody: Data?

    public init(file: URL) throws {
        guard file.isFileURL, !file.path.contains("\0"),
              let values = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size > 0, size < Int(Int32.max),
              let data = try? Data(contentsOf: file),
              !data.isEmpty, data.count < Int(Int32.max) else { throw SerialPatchFailure.file(file) }
        try self.init(file: file, bytes: data)
    }

    public init(file: URL, bytes: Data) throws {
        guard file.isFileURL, !file.path.contains("\0"), !bytes.isEmpty,
              bytes.count < Int(Int32.max) else { throw SerialPatchFailure.file(file) }
        self.file = file.standardizedFileURL; self.bytes = bytes
        let separators = [Data([10, 10]), Data([13, 10, 13, 10])]
        let separator = separators.compactMap { bytes.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let headerBytes = separator.map { bytes[..<$0.lowerBound] } ?? bytes[...]
        inlineBody = separator.map { Data(bytes[$0.upperBound...]) }
        var parsedAuthor = "", parsedDate = "", parsedSubject = "", continuingSubject = false
        var cursor = headerBytes.startIndex
        while cursor < headerBytes.endIndex {
            let newline = headerBytes[cursor...].firstIndex(of: 10) ?? headerBytes.endIndex
            var end = newline
            while end > cursor && headerBytes[headerBytes.index(before: end)] == 13 { end = headerBytes.index(before: end) }
            let line = headerBytes[cursor..<end]
            cursor = newline < headerBytes.endIndex ? headerBytes.index(after: newline) : headerBytes.endIndex
            if continuingSubject && (line.first == 32 || line.first == 9) {
                parsedSubject += String(decoding: line, as: UTF8.self); continue
            }
            continuingSubject = false
            for (header, target) in [("From: ", 0), ("Date: ", 1), ("Subject: ", 2)] {
                let prefix = Data(header.utf8)
                guard line.starts(with: prefix) else { continue }
                let value = String(decoding: line.dropFirst(prefix.count), as: UTF8.self)
                switch target {
                case 0: parsedAuthor = value
                case 1: parsedDate = value
                default: parsedSubject = value; continuingSubject = true
                }
                break
            }
        }
        author = parsedAuthor; date = parsedDate; subject = parsedSubject
    }
}
