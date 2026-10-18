// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum GitCredentialFailure: LocalizedError {
    case changed, readOnly
    public var errorDescription: String? {
        switch self {
        case .changed: return "Credential configuration changed outside this dialog. Refresh before saving."
        case .readOnly: return "A credential configuration is read-only. Authorize a writable configuration folder or keep Advanced configuration."
        }
    }
}

public struct GitCredentialEntry: Equatable, Sendable {
    public let scope: String
    public let origin: String
    public let key: String
    public let value: String
    public let hasValue: Bool
    public var file: URL? {
        guard origin.hasPrefix("file:"), String(origin.dropFirst(5)).hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: String(origin.dropFirst(5)))
    }
    public var subsection: String? {
        guard key.hasPrefix("credential."), let last = key.lastIndex(of: ".") else { return nil }
        let start = key.index(key.startIndex, offsetBy: 11)
        return last < start ? "" : String(key[start..<last])
    }
    public var field: String { String(key.split(separator: ".").last ?? "") }
}
public struct GitCredentialGroup: Identifiable, Equatable, Sendable {
    public let scope: String, origin: String, url: String
    public let entries: [GitCredentialEntry]
    public var id: String { scope + "\0" + origin + "\0" + url }
    public var file: URL? { entries.first?.file }
    public var helpers: [String] { entries.filter { $0.field == "helper" }.map(\.value) }
    public var username: String { entries.last { $0.field == "username" }?.value ?? "" }
    public var useHTTPPath: Bool {
        guard let entry = entries.last(where: { $0.field == "usehttppath" }) else { return false }
        if !entry.hasValue { return true }
        let value = entry.value.lowercased()
        return ["true", "yes", "on"].contains(value) || (Int(value).map { $0 != 0 } ?? false)
    }
}
public struct GitCredentialSnapshot: Equatable, Sendable {
    public let entries: [GitCredentialEntry]
    public var groups: [GitCredentialGroup] {
        var result: [GitCredentialGroup] = []
        for entry in entries {
            guard let url = entry.subsection else { continue }
            if let index = result.firstIndex(where: { $0.scope == entry.scope && $0.origin == entry.origin && $0.url == url }) {
                let old = result[index]
                result[index] = .init(scope: old.scope, origin: old.origin, url: old.url, entries: old.entries + [entry])
            } else { result.append(.init(scope: entry.scope, origin: entry.origin, url: url, entries: [entry])) }
        }
        return result.sorted { ($0.scope + ":" + $0.url + ":" + $0.origin) < ($1.scope + ":" + $1.url + ":" + $1.origin) }
    }
    public static func parse(_ data: Data, root: URL) throws -> Self {
        guard data.isEmpty || data.last == 0 else { throw GitConfigurationFailure.output }
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if !records.isEmpty { records.removeLast() }
        guard records.count % 3 == 0 else { throw GitConfigurationFailure.output }
        var entries: [GitCredentialEntry] = []
        for offset in stride(from: 0, to: records.count, by: 3) {
            guard let scope = String(data: Data(records[offset]), encoding: .utf8),
                  var origin = String(data: Data(records[offset + 1]), encoding: .utf8),
                  let record = String(data: Data(records[offset + 2]), encoding: .utf8) else { throw GitConfigurationFailure.output }
            let pair = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair[0].hasPrefix("credential.") else { throw GitConfigurationFailure.output }
            if origin.hasPrefix("file:"), !origin.dropFirst(5).hasPrefix("/") {
                origin = "file:" + root.appendingPathComponent(String(origin.dropFirst(5))).standardizedFileURL.path
            }
            entries.append(.init(scope: scope, origin: origin, key: String(pair[0]), value: pair.count == 2 ? String(pair[1]) : "", hasValue: pair.count == 2))
        }
        return Self(entries: entries)
    }
}
/// Fields written by the advanced property-sheet Apply operation. Untouched
/// entries retain their original spelling, repetition, boolean form and origin.
public struct GitCredentialFields: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let helper = Self(rawValue: 1)
    public static let username = Self(rawValue: 2)
    public static let useHTTPPath = Self(rawValue: 4)
    public static let all: Self = [.helper, .username, .useHTTPPath]
}
public struct GitCredentialDraft: Equatable, Sendable {
    public var url = ""
    public var helpers: [String] = []
    public var username = ""
    public var useHTTPPath = false
    public init() {}
    public var valid: Bool {
        !helpers.isEmpty && fieldsValid
    }
    public var fieldsValid: Bool {
        !url.contains("\0") && !url.contains("\n") && !url.contains("\r") &&
        !username.contains("\0") && helpers.allSatisfy { !$0.contains("\0") }
    }
    public func changedFields(from saved: Self) -> GitCredentialFields {
        var result: GitCredentialFields = []
        if helpers != saved.helpers { result.insert(.helper) }
        if username != saved.username { result.insert(.username) }
        if useHTTPPath != saved.useHTTPPath { result.insert(.useHTTPPath) }
        return result
    }
    func key(_ field: String) -> String { "credential." + (url.isEmpty ? "" : url + ".") + field }
}
extension GitRepository {
    public func simplifyCredentials(expected: GitCredentialSnapshot, helper: String?, file: URL?) throws {
        guard try credentialConfiguration() == expected else { throw GitCredentialFailure.changed }
        let groups = expected.groups
        guard groups.allSatisfy({ group in
            guard let file = group.file else { return false }
            return ["local", "global", "system", "worktree"].contains(group.scope) && FileManager.default.isWritableFile(atPath: file.path)
        }) else { throw GitCredentialFailure.readOnly }
        if let helper {
            guard let file, !helper.isEmpty, !helper.contains("\0"), FileManager.default.isWritableFile(atPath: FileManager.default.fileExists(atPath: file.path) ? file.path : file.deletingLastPathComponent().path) else { throw GitCredentialFailure.readOnly }
        }
        for group in groups { try removeCredential(group) }
        if let helper, let file {
            _ = try run(["config", "--file", file.path, "--no-includes", "--replace-all", "--", "credential.helper", helper])
        }
    }
    public func credentialConfiguration(cancellation: OperationCancellation? = nil) throws -> GitCredentialSnapshot {
        let result = try run(["config", "--includes", "--show-scope", "--show-origin", "--null", "--get-regexp", "^credential[.]"], successfulExitCodes: 0...1, cancellation: cancellation)
        return try GitCredentialSnapshot.parse(result.stdout, root: root)
    }
    /// Exact file writes also support XDG and included configuration. No other
    /// credential subsections or unrelated keys are rewritten.
    public func saveCredential(_ draft: GitCredentialDraft, file: URL, expected: GitCredentialSnapshot? = nil, fields: GitCredentialFields = .all) throws {
        guard draft.fieldsValid, fields.subtracting(.all).isEmpty, file.isFileURL, file.path.hasPrefix("/"), !file.path.contains("\0") else { throw GitConfigurationFailure.invalidValue }
        if let expected, try credentialConfiguration() != expected { throw GitCredentialFailure.changed }
        let scope = ["config", "--file", file.path, "--no-includes"]
        func write(_ key: String, _ value: String?) throws {
            do {
                if let value { _ = try run(scope + ["--replace-all", "--", key, value]) }
                else {
                    let args = scope + ["--unset-all", "--", key]
                    let result = try run(args, successfulExitCodes: 0...5)
                    guard result.exitCode == 0 || result.exitCode == 5 else { throw GitFailure(arguments: args, code: result.exitCode, message: result.text) }
                }
            } catch { throw GitConfigurationFailure.save(key: key, detail: error.localizedDescription) }
        }
        if fields.contains(.helper) {
            try write(draft.key("helper"), draft.helpers.first)
            for helper in draft.helpers.dropFirst() {
                do { _ = try run(scope + ["--add", "--", draft.key("helper"), helper]) }
                catch { throw GitConfigurationFailure.save(key: draft.key("helper"), detail: error.localizedDescription) }
            }
        }
        if fields.contains(.username) { try write(draft.key("username"), draft.username.isEmpty ? nil : draft.username) }
        // SettingGitCredential::SaveSettings sends an empty value for unchecked;
        // Save unsets that key, restoring the inherited effective setting.
        if fields.contains(.useHTTPPath) { try write(draft.key("useHttpPath"), draft.useHTTPPath ? "true" : nil) }
    }
    public func removeCredential(_ group: GitCredentialGroup, expected: GitCredentialSnapshot? = nil) throws {
        guard let file = group.file, ["local", "global", "system", "worktree"].contains(group.scope) else { throw GitConfigurationFailure.destination }
        if let expected, try credentialConfiguration() != expected { throw GitCredentialFailure.changed }
        for key in Set(group.entries.map(\.key)).sorted() {
            let args = ["config", "--file", file.path, "--no-includes", "--unset-all", "--", key]
            do {
                let result = try run(args, successfulExitCodes: 0...5)
                guard result.exitCode == 0 || result.exitCode == 5 else { throw GitFailure(arguments: args, code: result.exitCode, message: result.text) }
            } catch { throw GitConfigurationFailure.save(key: key, detail: error.localizedDescription) }
        }
    }
}
