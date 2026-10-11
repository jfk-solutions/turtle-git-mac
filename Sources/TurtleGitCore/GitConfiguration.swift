// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Sources offered by SettingGitConfig; .tgitconfig is deliberately absent:
/// this upstream page does not honor project config for ordinary Git settings.
public enum GitConfigurationSource: String, CaseIterable, Sendable {
    case effective = "Effective", local = "Local", global = "Global", system = "System"
    var arguments: [String] {
        switch self {
        case .effective: return []
        case .local: return ["--local"]
        case .global: return ["--global"]
        case .system: return ["--system"]
        }
    }
}
public enum GitConfigurationBoolean: String, CaseIterable, Sendable {
    case inherit = "", disabled = "false", enabled = "true"
}
public struct GitConfigurationIdentity: Equatable, Sendable {
    public var value: String
    public var inherit: Bool
    public init(value: String = "", inherit: Bool = true) { self.value = value; self.inherit = inherit }
}
public struct GitConfigurationSettings: Equatable, Sendable {
    public var name = GitConfigurationIdentity()
    public var email = GitConfigurationIdentity()
    public var signingKey = GitConfigurationIdentity()
    public var autoCRLF = ""
    public var safeCRLF = ""
    public var quotePath: GitConfigurationBoolean = .inherit
    public var prune: GitConfigurationBoolean = .inherit
    public init() {}
    var values: [(String, String?)] {
        [("user.name", name.inherit ? nil : name.value),
         ("user.email", email.inherit ? nil : email.value),
         ("user.signingkey", signingKey.inherit ? nil : signingKey.value),
         ("core.quotepath", quotePath == .inherit ? nil : quotePath.rawValue),
         ("fetch.prune", prune == .inherit ? nil : prune.rawValue),
         ("core.autocrlf", autoCRLF.isEmpty ? nil : autoCRLF),
         ("core.safecrlf", safeCRLF.isEmpty ? nil : safeCRLF)]
    }
}
public enum GitConfigurationFailure: LocalizedError {
    case destination, invalidValue, output, save(key: String, detail: String)
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose Local or Global as the save destination."
        case .invalidValue: return "The Git configuration contains an invalid value."
        case .output: return "Git returned invalid configuration data."
        case .save(let key, let detail): return "Saving config failed (key: \"\(key)\"). Earlier settings may already have been saved.\n\n" + detail
        }
    }
}
extension GitRepository {
    private func configurationValue(_ key: String, source: GitConfigurationSource, boolean: Bool = false, cancellation: OperationCancellation?) throws -> String? {
        let result = try run(["config"] + source.arguments + ["--includes", "--null"] + (boolean ? ["--bool"] : []) + ["--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
        if result.exitCode == 1 { return nil }
        guard result.stdout.last == 0, let value = String(data: result.stdout.dropLast(), encoding: .utf8) else { throw GitConfigurationFailure.output }
        return value
    }
    public func gitConfiguration(source: GitConfigurationSource, cancellation: OperationCancellation? = nil) throws -> GitConfigurationSettings {
        try cancellation?.check()
        var settings = GitConfigurationSettings()
        func identity(_ key: String) throws -> GitConfigurationIdentity {
            let value = try configurationValue(key, source: source, cancellation: cancellation)
            return GitConfigurationIdentity(value: value ?? "", inherit: value == nil)
        }
        settings.name = try identity("user.name"); settings.email = try identity("user.email")
        settings.signingKey = try identity("user.signingkey")
        if source == .effective {
            let environment = ProcessInfo.processInfo.environment
            func author(_ environmentKey: String, key: String, fallback: String) throws -> String {
                if let value = environment[environmentKey], !value.isEmpty { return value }
                if let value = try configurationValue(key, source: source, cancellation: cancellation), !value.isEmpty { return value }
                return fallback
            }
            settings.name = GitConfigurationIdentity(value: try author("GIT_AUTHOR_NAME", key: "author.name", fallback: settings.name.value), inherit: false)
            settings.email = GitConfigurationIdentity(value: try author("GIT_AUTHOR_EMAIL", key: "author.email", fallback: settings.email.value), inherit: false)
            settings.signingKey.inherit = false
        }
        func boolean(_ key: String, defaultValue: GitConfigurationBoolean) throws -> GitConfigurationBoolean {
            if let value = try configurationValue(key, source: source, boolean: true, cancellation: cancellation), let parsed = GitConfigurationBoolean(rawValue: value) { return parsed }
            return source == .effective ? defaultValue : .inherit
        }
        settings.quotePath = try boolean("core.quotepath", defaultValue: .enabled)
        settings.prune = try boolean("fetch.prune", defaultValue: .disabled)
        func conversion(_ key: String, alternate: String) throws -> String {
            guard let value = try configurationValue(key, source: source, cancellation: cancellation) else { return "" }
            let normal = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normal == alternate { return alternate }
            return try configurationValue(key, source: source, boolean: true, cancellation: cancellation) ?? ""
        }
        settings.autoCRLF = try conversion("core.autocrlf", alternate: "input")
        settings.safeCRLF = try conversion("core.safecrlf", alternate: "warn")
        try cancellation?.check(); return settings
    }
    /// Applies the source page's seven fields in source order. Like upstream,
    /// errors stop the batch and do not roll back settings already written.
    public func saveGitConfiguration(_ settings: GitConfigurationSettings, destination: GitConfigurationSource, cancellation: OperationCancellation? = nil) throws {
        guard destination == .local || destination == .global else { throw GitConfigurationFailure.destination }
        guard ["", "false", "true", "input"].contains(settings.autoCRLF),
              ["", "false", "true", "warn"].contains(settings.safeCRLF),
              !settings.values.contains(where: { $0.1?.utf8.contains(0) == true }) else { throw GitConfigurationFailure.invalidValue }
        for (key, value) in settings.values {
            try cancellation?.check()
            do {
                if let value {
                    _ = try run(["config"] + destination.arguments + ["--replace-all", "--", key, value], cancellation: cancellation)
                } else {
                    // Missing keys are already inherited. --unset-all also clears
                    // repeated values, without following includes for writes.
                    let args = ["config"] + destination.arguments + ["--unset-all", "--", key]
                    let result = try run(args, successfulExitCodes: 0...5, cancellation: cancellation)
                    guard result.exitCode == 0 || result.exitCode == 5 else {
                        throw GitFailure(arguments: args, code: result.exitCode, message: result.text)
                    }
                }
            } catch {
                try cancellation?.check()
                throw GitConfigurationFailure.save(key: key, detail: error.localizedDescription)
            }
        }
    }
    public func gitConfigurationText(source: GitConfigurationSource, cancellation: OperationCancellation? = nil) throws -> String {
        let result = try run(["config"] + source.arguments + ["--includes", "--show-origin", "--list"], cancellation: cancellation)
        guard let text = String(data: result.stdout, encoding: .utf8) else { throw GitConfigurationFailure.output }
        return text
    }
}

public enum GitConfigurationFile: String, CaseIterable, Sendable {
    case local, project, global, xdg, system
}
public struct GitConfigurationFiles: Sendable {
    public let local: URL?, project: URL?, global: URL?, xdg: URL?, system: URL?
    public let bare: Bool
    public subscript(_ file: GitConfigurationFile) -> URL? {
        switch file {
        case .local: return local
        case .project: return project
        case .global: return global
        case .xdg: return xdg
        case .system: return system
        }
    }
}
extension GitRepository {
    public func gitConfigurationFiles(hasRepository: Bool, cancellation: OperationCancellation? = nil) throws -> GitConfigurationFiles {
        let environment = ProcessInfo.processInfo.environment
        func url(_ path: String) -> URL {
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        }
        // Git var reports runtime relocation and explicit config overrides. Older
        // engines lack these variables; fall back to their conventional paths.
        func paths(_ variable: String, fallback: [URL]) throws -> [URL] {
            let result = try run(["var", variable], successfulExitCodes: 0...129, cancellation: cancellation)
            if result.exitCode == 1 { return [] } // Enabled engine, disabled file.
            if result.exitCode == 0 {
                guard let value = String(data: result.stdout, encoding: .utf8) else { throw GitConfigurationFailure.output }
                return value.split(separator: "\n").map { url(String($0)) }
            }
            guard result.exitCode == 129 else { throw GitFailure(arguments: ["var", variable], code: result.exitCode, message: result.text) }
            return fallback
        }
        let home = environment["HOME"].map(url) ?? FileManager.default.homeDirectoryForCurrentUser
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : url($0) } ?? home.appendingPathComponent(".config")
        let globalFallback = environment["GIT_CONFIG_GLOBAL"].map { $0.isEmpty ? [] : [url($0)] } ?? [home.appendingPathComponent(".gitconfig"), xdg.appendingPathComponent("git/config")]
        let global = try paths("GIT_CONFIG_GLOBAL", fallback: globalFallback)
        let systemFallback = environment["GIT_CONFIG_NOSYSTEM"].map { $0 == "1" || $0.lowercased() == "true" } == true ? [] : [url(environment["GIT_CONFIG_SYSTEM"] ?? "/etc/gitconfig")]
        let system = try paths("GIT_CONFIG_SYSTEM", fallback: systemFallback).first
        let bare = hasRepository ? try isBare(cancellation: cancellation) : false
        let local: URL?
        if hasRepository {
            let path = try run(["rev-parse", "--git-path", "config"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            local = url(path)
        } else { local = nil }
        try cancellation?.check()
        return GitConfigurationFiles(local: local, project: hasRepository ? root.appendingPathComponent(".tgitconfig") : nil,
                                     global: global.first, xdg: global.dropFirst().first, system: system, bare: bare)
    }
    public func projectConfigurationFromHEAD(cancellation: OperationCancellation? = nil) throws -> Data {
        try run(["show", "HEAD:.tgitconfig"], cancellation: cancellation).stdout
    }
}
