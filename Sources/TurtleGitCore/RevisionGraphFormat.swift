// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RevisionGraphFormat: String, CaseIterable, Sendable {
    case svg, graphviz, png, jpeg, bmp, gif, pdf
    public var fileExtension: String { self == .graphviz ? "gv" : self == .jpeg ? "jpg" : rawValue }
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "gv", "dot": self = .graphviz
        case "jpg", "jpeg": self = .jpeg
        default: guard let value = Self(rawValue: fileExtension.lowercased()), value != .graphviz else { return nil }; self = value
        }
    }
}

/// RevisionGraphDlg::OnFileSavegraphas defaults only an extensionless name.
/// SaveGraphAs then selects its encoder from the resulting filename.
public enum RevisionGraphExportFilter: String, CaseIterable, Sendable {
    case pictures, graphs, allFiles
}

public enum RevisionGraphExportFailure: LocalizedError, Sendable {
    case destination, metafile
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose a file for the exported revision graph."
        case .metafile: return "WMF and EMF graph export are unavailable on macOS. Choose PDF for a vector image, or SVG for an editable graph."
        }
    }
}

public struct RevisionGraphExportDestination: Sendable {
    public let url: URL
    public let format: RevisionGraphFormat

    public init(url: URL, filter: RevisionGraphExportFilter = .allFiles) throws {
        guard url.isFileURL, !url.hasDirectoryPath else { throw RevisionGraphExportFailure.destination }
        let filename = try Self.normalizedFilename(url.lastPathComponent, filter: filter)
        self.url = filename.utf8.elementsEqual(url.lastPathComponent.utf8) ? url : url.deletingLastPathComponent().appendingPathComponent(filename)
        // normalizedFilename always produces a supported encoder suffix.
        guard let format = Self.filenameFormat(filename) else { throw RevisionGraphExportFailure.destination }
        self.format = format
    }

    public static func normalizedFilename(_ filename: String, filter: RevisionGraphExportFilter = .allFiles) throws -> String {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\0") else {
            throw RevisionGraphExportFailure.destination
        }
        var value = filename
        // The source treats a leading or trailing dot as an extension too;
        // Foundation's pathExtension would classify a dotfile differently.
        if !value.utf8.contains(46) {
            switch filter {
            case .pictures: value += ".svg"
            case .graphs: value += ".gv"
            case .allFiles: break
            }
        }
        let suffix = Self.filenameSuffix(value)?.lowercased()
        if suffix == "wmf" || suffix == "emf" { throw RevisionGraphExportFailure.metafile }
        if Self.filenameFormat(value) == nil { value += ".jpg" }
        return value
    }

    private static func filenameFormat(_ filename: String) -> RevisionGraphFormat? {
        filenameSuffix(filename).flatMap { RevisionGraphFormat(fileExtension: $0) }
    }

    private static func filenameSuffix(_ filename: String) -> String? {
        guard let dot = filename.utf8.lastIndex(of: 46) else { return nil }
        return String(decoding: filename.utf8[filename.utf8.index(after: dot)...], as: UTF8.self)
    }
}
