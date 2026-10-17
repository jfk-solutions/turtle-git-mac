// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum SupportReportFailure: LocalizedError {
    case file, size, format, details
    public var errorDescription: String? {
        switch self {
        case .file: return "Choose a readable regular Apple .ips or .crash report."
        case .size: return "The crash report exceeds the 4 MiB import limit."
        case .format: return "This file is not a supported UTF-8 Apple crash report."
        case .details: return "Keep the problem description below 64 KiB and remove null characters."
        }
    }
}

/// Original Apple report text stays intact; import metadata is for presentation only.
public struct SupportCrashReport: Sendable {
    public static let maximumBytes = 4 * 1024 * 1024
    public let fileName: String
    public let process: String
    public let exception: String
    public let text: String
    public static func read(_ url: URL, cancellation: OperationCancellation? = nil) throws -> Self {
        try cancellation?.check()
        guard url.isFileURL, ["ips", "crash"].contains(url.pathExtension.lowercased()) else { throw SupportReportFailure.file }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SupportReportFailure.file }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0 else { throw SupportReportFailure.file }
        guard info.st_size <= maximumBytes else { throw SupportReportFailure.size }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try cancellation?.check()
        return try parse(bytes, fileName: url.lastPathComponent)
    }
    public static func parse(_ bytes: Data, fileName: String) throws -> Self {
        guard bytes.count <= maximumBytes else { throw SupportReportFailure.size }
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8), !text.utf8.contains(0) else { throw SupportReportFailure.format }
        let suffix = (fileName as NSString).pathExtension.lowercased()
        func label(_ value: String) -> String { String(value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(256)) }
        let process: String, exception: String
        if suffix == "ips" {
            // Apple IPS has a metadata JSON line followed by a crash-data JSON object.
            // Also accept a standalone crash-data object exported from a viewer.
            let body: [String: Any]
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { body = object }
            else {
                guard let newline = bytes.firstIndex(of: 10),
                      (try? JSONSerialization.jsonObject(with: bytes[..<newline]) as? [String: Any]) != nil,
                      let object = try? JSONSerialization.jsonObject(with: bytes[bytes.index(after: newline)...]) as? [String: Any] else { throw SupportReportFailure.format }
                body = object
            }
            guard let name = body["procName"] as? String, !name.isEmpty,
                  body["exception"] is [String: Any] || body["termination"] is [String: Any] else { throw SupportReportFailure.format }
            process = label(name)
            let value = body["exception"] as? [String: Any] ?? [:]
            exception = label([value["type"] as? String, value["signal"] as? String].compactMap { $0 }.joined(separator: " / "))
        } else if suffix == "crash" {
            let lines = text.components(separatedBy: .newlines)
            func field(_ prefix: String) -> String? { lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) } }
            guard let name = field("Process:"), !name.isEmpty, let value = field("Exception Type:") ?? field("Termination Reason:"), !value.isEmpty else { throw SupportReportFailure.format }
            process = label(name); exception = label(value)
        } else { throw SupportReportFailure.format }
        return .init(fileName: label(fileName), process: process, exception: exception, text: text)
    }
}

public struct SupportReportDraft: Sendable {
    public var details = ""
    public var includeCrashReport = false
    public var replaceHomePath = true
    public init() {}
    public func render(systemInformation: String, report: SupportCrashReport?, home: String) throws -> String {
        guard details.utf8.count <= 64 * 1024, !details.utf8.contains(0) else { throw SupportReportFailure.details }
        var text = "TurtleGit for Mac — Problem Report\n\n" + systemInformation + "\n\nWhat happened / steps to reproduce:\n" + details + "\n"
        if includeCrashReport, let report { text += "\nSelected Apple crash report: " + report.fileName + "\nProcess: " + report.process + "\nException: " + report.exception + "\n\n" + report.text }
        if replaceHomePath, home.hasPrefix("/"), home != "/" {
            text = text.replacingOccurrences(of: home, with: "<HOME>")
            let escaped = home.replacingOccurrences(of: "/", with: "\\/")
            text = text.replacingOccurrences(of: escaped, with: "<HOME>")
        }
        return text
    }
}
