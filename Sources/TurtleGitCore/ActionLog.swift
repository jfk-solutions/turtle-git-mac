// Ports LogFile.cpp and ProgressDlg.cpp (GPL-2.0-or-later; see NOTICE).
import Foundation
import Darwin

/// Local, private history of the displayed progress log, independent of Git results.
public struct ActionLogStore: Sendable {
    public let storageURL: URL
    public init(storageURL: URL = RepositoryAccessStore.defaultStorageURL.deletingLastPathComponent().appendingPathComponent("logfile.txt")) { self.storageURL = storageURL }
    public static func maximumLines(preferences: UserDefaults) -> UInt32 {
        guard let value = preferences.object(forKey: "MaxLinesInLogfile") as? NSNumber else { return 4000 }
        return UInt32(clamping: value.int64Value)
    }
    public var exists: Bool { FileManager.default.fileExists(atPath: storageURL.path) }
    public func read() throws -> String { try String(contentsOf: storageURL, encoding: .utf8) }
    public func clear() throws {
        guard exists else { return }
        try locked { if exists { try FileManager.default.removeItem(at: storageURL) } }
    }
    public func append(repository: URL, output: String, cancelled: Bool, maximumLines: UInt32 = 4000,
                       date: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) throws {
        guard maximumLines > 0 else { return }
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .short; formatter.timeStyle = .none; let day = formatter.string(from: date)
        formatter.dateStyle = .none; formatter.timeStyle = .medium
        var incoming = ["", day + " - " + formatter.string(from: date) + " - " + repository.path]
        incoming += Self.lines(output)
        if cancelled { incoming.append("User cancelled") }
        try locked {
            let old = exists ? Self.lines(try read()) : []
            let keep = max(Int(maximumLines), incoming.count) - incoming.count
            let text = (Array(old.suffix(keep)) + incoming).joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        }
    }
    /// CString termination and CR, LF, CRLF splitting; no phantom final empty line.
    public static func lines(_ text: String) -> [String] {
        let bytes = Array(text.utf8.prefix { $0 != 0 }); var result: [String] = []; var start = 0; var index = 0
        while index < bytes.count {
            if bytes[index] == 10 || bytes[index] == 13 {
                result.append(String(decoding: bytes[start..<index], as: UTF8.self))
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count { result.append(String(decoding: bytes[start...], as: UTF8.self)) }
        return result
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let folder = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(storageURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var attempts = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), attempts < 10 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            attempts += 1; Thread.sleep(forTimeInterval: 0.2)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
