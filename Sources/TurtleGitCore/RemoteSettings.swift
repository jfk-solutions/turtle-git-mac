// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RemoteTagPolicy: String, CaseIterable, Sendable {
    case reachable = "", none = "--no-tags", all = "--tags"
}
/// CSettingGitRemote's changed mask. Editing a name adds a remote; Rename is a
/// separate command. Callers must obtain overwrite consent before clearing name.
public struct RemoteSettingsFields: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let name = Self(rawValue: 0x01)
    public static let url = Self(rawValue: 0x02)
    public static let puttyKeyFile = Self(rawValue: 0x04)
    public static let tags = Self(rawValue: 0x08)
    public static let prune = Self(rawValue: 0x10)
    public static let pushDefault = Self(rawValue: 0x40)
    public static let pushURL = Self(rawValue: 0x80)
    public static let all: Self = [.name, .url, .puttyKeyFile, .tags, .prune, .pushDefault, .pushURL]
}
public struct RemoteSettings: Sendable {
    public var name: String
    public var url = ""
    public var pushURL = ""
    /// Interoperable Windows configuration only; this is not an OpenSSH identity.
    public var puttyKeyFile = ""
    public var tags: RemoteTagPolicy = .reachable
    public var prune: FetchOverride = .configured
    public var pushDefault = false
    public init(name: String = "") { self.name = name }
}
public enum RemoteSettingsFailure: LocalizedError {
    case name, url, invalidValue, output, inheritedValue(key: String, value: String)
    public var errorDescription: String? {
        switch self {
        case .name: return "Remote name must not be empty."
        case .url: return "Remote URL must not be empty."
        case .invalidValue: return "Remote settings cannot contain NUL."
        case .output: return "Git returned invalid configuration data."
        case let .inheritedValue(key, value): return "Saving config failed (key: \"\(key)\", value: \"\(value)\")."
        }
    }
}
extension GitRepository {
    private func remoteSettingValue(_ key: String, token: OperationCancellation) throws -> String {
        let result = try run(["config", "--null", "--get", key], successfulExitCodes: 0...1, cancellation: token)
        if result.exitCode == 1 { return "" }
        guard result.stdout.last == 0, let value = String(data: result.stdout.dropLast(), encoding: .utf8) else { throw RemoteSettingsFailure.output }
        return value
    }
    public func remoteSettings(name: String, cancellation: OperationCancellation? = nil) throws -> RemoteSettings {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !name.isEmpty else { throw RemoteSettingsFailure.name }
        guard !name.utf8.contains(0) else { throw RemoteSettingsFailure.invalidValue }
        let prefix = "remote." + name + "."
        var settings = RemoteSettings(name: name)
        settings.url = try remoteSettingValue(prefix + "url", token: token)
        settings.pushURL = try remoteSettingValue(prefix + "pushurl", token: token)
        settings.puttyKeyFile = try remoteSettingValue(prefix + "puttykeyfile", token: token)
        settings.tags = RemoteTagPolicy(rawValue: try remoteSettingValue(prefix + "tagopt", token: token)) ?? .reachable
        let prune = try remoteSettingValue(prefix + "prune", token: token)
        settings.prune = prune == "true" ? .enabled : prune == "false" ? .disabled : .configured
        settings.pushDefault = GitReferenceName.equal(try remoteSettingValue("remote.pushdefault", token: token), name)
        return settings
    }
    private func saveRemoteSetting(_ key: String, value: String, token: OperationCancellation) throws {
        if value.isEmpty {
            // Source ignores unset's failure but checks the effective value. Inherited
            // config and multiple values therefore cannot silently become "cleared".
            do { _ = try run(["config", "--local", "--unset", "--end-of-options", key], cancellation: token) }
            catch { try token.check() }
            if try !remoteSettingValue(key, token: token).isEmpty { throw RemoteSettingsFailure.inheritedValue(key: key, value: value) }
        } else {
            _ = try run(["config", "--local", "--end-of-options", key, value], cancellation: token)
        }
    }
    /// Apply only edited fields, in source order. Successful earlier writes remain
    /// when a later field fails; this is deliberately not a section replacement.
    /// No warning consent or fetch is implied by this backend operation.
    public func applyRemoteSettings(_ settings: RemoteSettings, changed: RemoteSettingsFields, cancellation: OperationCancellation? = nil) throws {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard [settings.name, settings.url, settings.pushURL, settings.puttyKeyFile].allSatisfy({ !$0.utf8.contains(0) }) else { throw RemoteSettingsFailure.invalidValue }
        let trimmedName = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if changed.contains(.pushDefault), !trimmedName.isEmpty {
            if settings.pushDefault { try saveRemoteSetting("remote.pushdefault", value: trimmedName, token: token) }
            else if GitReferenceName.equal(try remoteSettingValue("remote.pushdefault", token: token), trimmedName) {
                try saveRemoteSetting("remote.pushdefault", value: "", token: token)
            }
        }
        guard changed.isEmpty || !trimmedName.isEmpty else { throw RemoteSettingsFailure.name }
        var remaining = changed
        if changed.contains(.name) {
            guard !settings.url.isEmpty else { throw RemoteSettingsFailure.url }
            _ = try run(["remote", "add", "--", settings.name, settings.url], cancellation: token)
            remaining.remove(.url)
        }
        let prefix = "remote." + settings.name + "."
        if remaining.contains(.url) { try saveRemoteSetting(prefix + "url", value: settings.url.replacingOccurrences(of: "\\", with: "/"), token: token) }
        if remaining.contains(.puttyKeyFile) { try saveRemoteSetting(prefix + "puttykeyfile", value: settings.puttyKeyFile, token: token) }
        if remaining.contains(.tags) { try saveRemoteSetting(prefix + "tagopt", value: settings.tags.rawValue, token: token) }
        if remaining.contains(.prune) { try saveRemoteSetting(prefix + "prune", value: settings.prune == .enabled ? "true" : settings.prune == .disabled ? "false" : "", token: token) }
        if remaining.contains(.pushURL) { try saveRemoteSetting(prefix + "pushurl", value: settings.pushURL.replacingOccurrences(of: "\\", with: "/"), token: token) }
    }
    public func renameRemote(from oldName: String, to newName: String, cancellation: OperationCancellation? = nil) throws {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !oldName.isEmpty, !newName.isEmpty else { throw RemoteSettingsFailure.name }
        guard !oldName.utf8.contains(0), !newName.utf8.contains(0) else { throw RemoteSettingsFailure.invalidValue }
        _ = try run(["remote", "rename", "--", oldName, newName], cancellation: token)
    }
    public func removeRemote(name: String, cancellation: OperationCancellation? = nil) throws {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !name.isEmpty else { throw RemoteSettingsFailure.name }
        guard !name.utf8.contains(0) else { throw RemoteSettingsFailure.invalidValue }
        _ = try run(["remote", "rm", "--", name], cancellation: token)
    }
    /// Advisory only: source checks the first byte-exact destination occurrence
    /// and ignores this remote's own fetch mapping.
    public func remoteNameCollidesWithRefspec(_ name: String, cancellation: OperationCancellation? = nil) throws -> Bool {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !name.utf8.contains(0) else { throw RemoteSettingsFailure.invalidValue }
        let result = try run(["config", "--local", "--includes", "--null", "--get-regexp", "^(remote\\..*\\.fetch|svn-remote\\..*\\.(fetch|branches|tags))$"], successfulExitCodes: 0...1, cancellation: token)
        let own = Data(("remote." + name + ".fetch").utf8), match = Data((":refs/remotes/" + name).utf8)
        for record in result.stdout.split(separator: 0) {
            try token.check()
            guard let separator = record.firstIndex(of: 10) else { throw RemoteSettingsFailure.output }
            if Data(record[..<separator]) == own { continue }
            let value = Data(record[record.index(after: separator)...])
            if let range = value.range(of: match), range.upperBound == value.endIndex || value[range.upperBound] == 47 { return true }
        }
        return false
    }
}
