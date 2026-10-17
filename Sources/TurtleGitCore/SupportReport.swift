// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import CryptoKit

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
    public let bundleIdentifier: String?
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
        let process: String, exception: String, bundleIdentifier: String?
        if suffix == "ips" {
            // Apple IPS has a metadata JSON line followed by a crash-data JSON object.
            // Also accept a standalone crash-data object exported from a viewer.
            let body: [String: Any]
            var metadata: [String: Any] = [:]
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { body = object }
            else {
                guard let newline = bytes.firstIndex(of: 10),
                      let header = try? JSONSerialization.jsonObject(with: bytes[..<newline]) as? [String: Any],
                      let object = try? JSONSerialization.jsonObject(with: bytes[bytes.index(after: newline)...]) as? [String: Any] else { throw SupportReportFailure.format }
                body = object; metadata = header
            }
            guard let name = body["procName"] as? String, !name.isEmpty,
                  body["exception"] is [String: Any] || body["termination"] is [String: Any] else { throw SupportReportFailure.format }
            process = label(name)
            bundleIdentifier = (body["bundleInfo"] as? [String:Any])?["CFBundleIdentifier"] as? String ?? metadata["bundleID"] as? String
            let value = body["exception"] as? [String: Any] ?? [:]
            exception = label([value["type"] as? String, value["signal"] as? String].compactMap { $0 }.joined(separator: " / "))
        } else if suffix == "crash" {
            let lines = text.components(separatedBy: .newlines)
            func field(_ prefix: String) -> String? { lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) } }
            guard let name = field("Process:"), !name.isEmpty, let value = field("Exception Type:") ?? field("Termination Reason:"), !value.isEmpty else { throw SupportReportFailure.format }
            process = label(name); exception = label(value); bundleIdentifier = field("Identifier:")
        } else { throw SupportReportFailure.format }
        return .init(fileName: label(fileName), process: process, exception: exception, bundleIdentifier: bundleIdentifier, text: text)
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

/// A content identity, without persisting a report body or its filesystem path.
public struct SupportCrashIncident: Sendable {
    public let id: String
    public let date: Date
    public let report: SupportCrashReport
    public init(report: SupportCrashReport, date: Date) {
        self.report = report; self.date = date
        id = SHA256.hash(data: Data(report.text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SupportCrashDiscovery {
    public static let maximumCandidates = 32
    /// Only bounded, recent reports for this exact app identity are read. A
    /// denied/missing diagnostic directory is left to the manual file chooser.
    public static func latest(in directory: URL, process: String, bundleIdentifier: String,
                              excluding handled: Set<String>, now: Date = Date(),
                              cancellation: OperationCancellation? = nil) throws -> SupportCrashIncident? {
        try cancellation?.check()
        guard directory.isFileURL, !process.isEmpty, !bundleIdentifier.isEmpty,
              try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var candidates: [(URL,Date)] = []
        for file in files {
            try cancellation?.check()
            let name = file.lastPathComponent
            guard ["ips","crash"].contains(file.pathExtension.lowercased()),
                  [process + "-",process + "_",process + "."].contains(where: { name.hasPrefix($0) }),
                  let info = try? file.resourceValues(forKeys: keys), info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size > 0, size <= SupportCrashReport.maximumBytes,
                  let date = info.contentModificationDate, date >= now.addingTimeInterval(-30 * 24 * 3600), date <= now.addingTimeInterval(300) else { continue }
            candidates.append((file,date))
        }
        candidates.sort { $0.1 == $1.1 ? $0.0.lastPathComponent.utf8.lexicographicallyPrecedes($1.0.lastPathComponent.utf8) : $0.1 > $1.1 }
        for (file,date) in candidates.prefix(maximumCandidates) {
            try cancellation?.check()
            guard let report = try? SupportCrashReport.read(file,cancellation:cancellation),
                  report.bundleIdentifier?.utf8.elementsEqual(bundleIdentifier.utf8) == true else { continue }
            let reportedProcess = report.process.components(separatedBy: " [").first ?? report.process
            guard reportedProcess.utf8.elementsEqual(process.utf8) else { continue }
            let incident = SupportCrashIncident(report:report,date:date)
            if !handled.contains(incident.id) { try cancellation?.check(); return incident }
        }
        try cancellation?.check(); return nil
    }
}

public enum SupportCrashRecoveryPreferences {
    public static let enabledKey = "TurtleGit.Support.CheckCrashReportsAtLaunch"
    private static let handledKey = "TurtleGit.Support.HandledCrashReports"
    public static func enabled(in defaults: UserDefaults) -> Bool { defaults.object(forKey:enabledKey) == nil || defaults.bool(forKey:enabledKey) }
    public static func handled(in defaults: UserDefaults) -> Set<String> {
        Set((defaults.stringArray(forKey:handledKey) ?? []).suffix(64).filter { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
    }
    public static func acknowledge(_ incident: SupportCrashIncident, in defaults: UserDefaults) {
        let valid = handled(in:defaults)
        var values = (defaults.stringArray(forKey:handledKey) ?? []).filter { valid.contains($0) && $0 != incident.id }
        values.append(incident.id); defaults.set(Array(values.suffix(64)),forKey:handledKey)
    }
}
