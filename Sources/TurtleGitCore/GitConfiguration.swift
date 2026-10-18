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
/// The four explicit values checked by CAppUtils::CheckUserData before replay.
/// This deliberately does not accept Git's synthesized login/host fallback.
public struct ReplayUserIdentity: Equatable, Sendable {
    public let authorName: String, authorEmail: String, committerName: String, committerEmail: String
    public init(authorName: String, authorEmail: String, committerName: String, committerEmail: String) {
        self.authorName = authorName; self.authorEmail = authorEmail
        self.committerName = committerName; self.committerEmail = committerEmail
    }
    public var complete: Bool { ![authorName, authorEmail, committerName, committerEmail].contains(where: \.isEmpty) }
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
    /// Match the pinned GetUser*/GetCommitter* lookup, including its unusual
    /// GIT_AUTHOR_EMAIL override for the committer-email check. Actual Git still
    /// receives its own ordinary environment; this is the source UI preflight.
    public func replayUserIdentity(environment: [String: String] = ProcessInfo.processInfo.environment, cancellation: OperationCancellation? = nil) throws -> ReplayUserIdentity {
        try cancellation?.check()
        func value(_ environmentKey: String, _ key: String, _ fallback: String) throws -> String {
            try cancellation?.check()
            if let value = environment[environmentKey], !value.isEmpty { return value }
            if let value = try configurationValue(key, source: .effective, cancellation: cancellation), !value.isEmpty { return value }
            return try configurationValue(fallback, source: .effective, cancellation: cancellation) ?? ""
        }
        let result = try ReplayUserIdentity(
            authorName: value("GIT_AUTHOR_NAME", "author.name", "user.name"),
            authorEmail: value("GIT_AUTHOR_EMAIL", "author.email", "user.email"),
            committerName: value("GIT_COMMITTER_NAME", "committer.name", "user.name"),
            committerEmail: value("GIT_AUTHOR_EMAIL", "committer.email", "user.email"))
        try cancellation?.check(); return result
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

/// CGitSettings scope selection for SetDialogs3 (includes .tgitconfig).
public enum ProjectDialogSettingsSource: String, CaseIterable, Sendable {
    case effective = "Effective", local = "Local", project = "Project", global = "Global", system = "System"
}
public struct ProjectDialogSettings: Equatable, Sendable {
    public var language = GitConfigurationIdentity()
    public var minimumMessageLength = GitConfigurationIdentity()
    public var messageWidthMarker = GitConfigurationIdentity()
    public var warnNoSignedOffBy: GitConfigurationBoolean = .inherit
    public var icon = GitConfigurationIdentity()
    public init() {}
    public var minimumLength: Int { max(0, Int((minimumMessageLength.value as NSString).intValue)) }
    public var borderColumn: Int { max(0, Int((messageWidthMarker.value as NSString).intValue)) }
    static let pattern = "^tgit[.](projectlanguage|logminsize|logwidthmarker|warnnosignedoffby|icon)$"
    var values: [(String, String?)] {
        [("tgit.projectlanguage", language.inherit ? nil : language.value),
         ("tgit.logminsize", minimumMessageLength.inherit ? nil : minimumMessageLength.value),
         ("tgit.logwidthmarker", messageWidthMarker.inherit ? nil : messageWidthMarker.value),
         ("tgit.warnnosignedoffby", warnNoSignedOffBy == .inherit ? nil : warnNoSignedOffBy.rawValue),
         ("tgit.icon", icon.inherit ? nil : icon.value)]
    }
}
extension GitRepository {
    private func projectDialogSettingsArguments(_ source: ProjectDialogSettingsSource) -> [String] {
        switch source {
        case .effective: return []
        case .local: return ["--local"]
        case .project: return ["--file", root.appendingPathComponent(".tgitconfig").path]
        case .global: return ["--global"]
        case .system: return ["--system"]
        }
    }
    private func scopedProjectSettingsValues(pattern: String, source: ProjectDialogSettingsSource, hasRepository: Bool, cancellation: OperationCancellation?) throws -> [String: String] {
        try cancellation?.check()
        if source == .local && !hasRepository { throw GitConfigurationFailure.destination }
        let values: [String: String]
        if source == .effective && hasRepository {
            values = try projectConfiguration(pattern: pattern, cancellation: cancellation)
        } else {
            var arguments = projectDialogSettingsArguments(source), temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            if source == .project {
                guard hasRepository else { throw GitConfigurationFailure.destination }
                if try isBare(cancellation: cancellation) {
                    let bytes = try? projectConfigurationFromHEAD(cancellation: cancellation)
                    try cancellation?.check()
                    if let bytes {
                        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("ProjectDialogConfig-" + UUID().uuidString)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        temporary = directory
                        let file = directory.appendingPathComponent(".tgitconfig"); try bytes.write(to: file)
                        arguments = ["--file", file.path]
                    } else { return [:] }
                } else if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".tgitconfig").path) {
                    return [:]
                }
            }
            let bytes = try run(["config"] + arguments + ["--includes", "--null", "--get-regexp", pattern], successfulExitCodes: 0...1, cancellation: cancellation).stdout
            var result: [String: String] = [:]
            for record in bytes.split(separator: 0) {
                guard let separator = record.firstIndex(of: 10) else {
                    result[String(decoding: record, as: UTF8.self).lowercased()] = "true"; continue
                }
                let key = String(decoding: record[..<separator], as: UTF8.self).lowercased()
                guard let value = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8) else { throw GitConfigurationFailure.output }
                result[key] = value
            }
            values = result
        }
        try cancellation?.check(); return values
    }
    public func projectDialogSettings(source: ProjectDialogSettingsSource, hasRepository: Bool = true, cancellation: OperationCancellation? = nil) throws -> ProjectDialogSettings {
        let values = try scopedProjectSettingsValues(pattern: ProjectDialogSettings.pattern, source: source, hasRepository: hasRepository, cancellation: cancellation)
        var result = ProjectDialogSettings()
        func identity(_ key: String, fallback: String) -> GitConfigurationIdentity {
            GitConfigurationIdentity(value: values[key] ?? (source == .effective ? fallback : ""), inherit: source != .effective && values[key] == nil)
        }
        result.language = identity("tgit.projectlanguage", fallback: "0")
        result.minimumMessageLength = identity("tgit.logminsize", fallback: "0")
        result.messageWidthMarker = identity("tgit.logwidthmarker", fallback: "0")
        result.icon = identity("tgit.icon", fallback: "")
        if let value = values["tgit.warnnosignedoffby"] {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "on", ""].contains(normalized) { result.warnNoSignedOffBy = .enabled }
            else if ["false", "no", "off"].contains(normalized) { result.warnNoSignedOffBy = .disabled }
            else if let number = Int64(normalized) { result.warnNoSignedOffBy = number == 0 ? .disabled : .enabled }
            else { throw GitConfigurationFailure.invalidValue }
        } else { result.warnNoSignedOffBy = source == .effective ? .disabled : .inherit }
        try cancellation?.check(); return result
    }
    public func saveProjectDialogSettings(_ settings: ProjectDialogSettings, destination: ProjectDialogSettingsSource, hasRepository: Bool = true, cancellation: OperationCancellation? = nil) throws {
        try saveScopedProjectSettings(settings.values, destination: destination, hasRepository: hasRepository, cancellation: cancellation)
    }
    private func saveScopedProjectSettings(_ values: [(String, String?)], destination: ProjectDialogSettingsSource, hasRepository: Bool, cancellation: OperationCancellation?) throws {
        guard destination == .local || destination == .global || destination == .project else { throw GitConfigurationFailure.destination }
        if destination == .local || destination == .project {
            guard hasRepository else { throw GitConfigurationFailure.destination }
        }
        if destination == .project, try isBare(cancellation: cancellation) { throw GitConfigurationFailure.destination }
        guard !values.contains(where: { $0.1?.utf8.contains(0) == true }) else { throw GitConfigurationFailure.invalidValue }
        let scope = projectDialogSettingsArguments(destination)
        // Git for macOS otherwise precomposes every argv value, including
        // config text. Preserve the submitted bytes without changing the
        // repository's persistent filesystem/path preference.
        let command = ["-c", "core.precomposeUnicode=false", "config"]
        for (key, value) in values {
            try cancellation?.check()
            do {
                if let value { _ = try run(command + scope + ["--replace-all", "--", key, value], cancellation: cancellation) }
                else {
                    if destination == .project, !FileManager.default.fileExists(atPath: root.appendingPathComponent(".tgitconfig").path) { continue }
                    let arguments = command + scope + ["--unset-all", "--", key]
                    let result = try run(arguments, successfulExitCodes: 0...5, cancellation: cancellation)
                    guard result.exitCode == 0 || result.exitCode == 5 else { throw GitFailure(arguments: arguments, code: result.exitCode, message: result.text) }
                }
            } catch {
                try cancellation?.check()
                throw GitConfigurationFailure.save(key: key, detail: error.localizedDescription)
            }
        }
    }
}

public struct FirstStartConfiguration: Sendable {
    public let name: String, email: String
    public let helpers: [String]
    public let selectedHelper: String
    public let advancedCredentials: Bool
}
extension GitRepository {
    public func firstStartConfiguration(cancellation: OperationCancellation? = nil) throws -> FirstStartConfiguration {
        let output = try run(["config", "--includes", "--null", "--get-regexp", "^(user[.](name|email)|credential[.].*helper)$"], successfulExitCodes: 0...1, cancellation: cancellation)
        var entries: [(String, String)] = []
        for record in output.stdout.split(separator: 0) {
            guard let text = String(data: Data(record), encoding: .utf8) else { throw GitConfigurationFailure.output }
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            entries.append((parts[0].lowercased(), parts.count == 2 ? String(parts[1]) : ""))
        }
        let executablePath = try run(["--exec-path"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let path = GitRuntime.environment(executable: executable)["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = [executablePath] + path.split(separator: ":").map(String.init)
        var helpers = [""]
        for name in ["osxkeychain", "manager", "manager-core", "cache", "store"] {
            if directories.contains(where: { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent("git-credential-" + name).path) }) { helpers.append(name) }
        }
        let plain = entries.filter { $0.0 == "credential.helper" }
        let selected = plain.last?.1 ?? ""
        let advanced = plain.count > 1 || entries.contains { $0.0.hasPrefix("credential.") && $0.0 != "credential.helper" } || !helpers.contains(selected)
        return FirstStartConfiguration(name: entries.last { $0.0 == "user.name" }?.1 ?? "", email: entries.last { $0.0 == "user.email" }?.1 ?? "", helpers: helpers, selectedHelper: selected, advancedCredentials: advanced)
    }
    /// Wizard writes only its two fields, preserving all unrelated Git settings.
    public func saveFirstStartIdentity(name: String, email: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty, !name.contains("\0"), !email.contains("\0") else { throw GitConfigurationFailure.invalidValue }
        for (key, value) in [("user.name", name), ("user.email", email)] {
            do { _ = try run(["config", "--global", "--replace-all", "--", key, value]) }
            catch { throw GitConfigurationFailure.save(key: key, detail: error.localizedDescription) }
        }
    }
    public func saveFirstStartCredentialHelper(_ helper: String) throws {
        guard !helper.contains("\0") else { throw GitConfigurationFailure.invalidValue }
        if helper.isEmpty {
            let arguments = ["config", "--global", "--unset-all", "--", "credential.helper"]
            let result = try run(arguments, successfulExitCodes: 0...5)
            guard result.exitCode == 0 || result.exitCode == 5 else { throw GitFailure(arguments: arguments, code: result.exitCode, message: result.text) }
        } else { _ = try run(["config", "--global", "--replace-all", "--", "credential.helper", helper]) }
    }
}


public enum IssueTrackerStringKey: String, CaseIterable, Sendable {
    case url = "bugtraq.url", message = "bugtraq.message", label = "bugtraq.label"
    case nativeProvider = "turtlegit.issueprovider", nativeParameters = "turtlegit.issueproviderparams"
    case parameters = "bugtraq.providerparams", provider32 = "bugtraq.provideruuid", provider64 = "bugtraq.provideruuid64", regex = "bugtraq.logregex"
}
public struct IssueTrackerSettings: Equatable, Sendable {
    public var fields = Dictionary(uniqueKeysWithValues: IssueTrackerStringKey.allCases.map { ($0, GitConfigurationIdentity()) })
    public var append: GitConfigurationBoolean = .inherit
    public var number: GitConfigurationBoolean = .inherit
    public var warnIfNoIssue: GitConfigurationBoolean = .inherit
    public init() {}
    public var valid: Bool { !fields.values.contains { !$0.inherit && $0.value.contains("\0") } }
    public var regexParts: (check: String, extract: String) {
        let text = (fields[.regex]?.value ?? "").replacingOccurrences(of:"\r\n",with:"\n")
        guard let newline = text.firstIndex(of:"\n") else { return (text.trimmingCharacters(in:.whitespacesAndNewlines), "") }
        return (String(text[..<newline]).trimmingCharacters(in:.whitespacesAndNewlines),String(text[text.index(after:newline)...]).trimmingCharacters(in:.whitespacesAndNewlines))
    }
    static let pattern = "^(bugtraq[.](url|message|label|providerparams|provideruuid|provideruuid64|append|number|warnifnoissue|logregex)|turtlegit[.](issueprovider|issueproviderparams))$"
    var values: [(String, String?)] {
        var values = IssueTrackerStringKey.allCases.filter { $0 != .regex }.map { key -> (String,String?) in
            let field = fields[key] ?? GitConfigurationIdentity(); return (key.rawValue,field.inherit ? nil:field.value)
        }
        values += [("bugtraq.append",append == .inherit ? nil:append.rawValue),("bugtraq.number",number == .inherit ? nil:number.rawValue),("bugtraq.warnifnoissue",warnIfNoIssue == .inherit ? nil:warnIfNoIssue.rawValue)]
        let regex = fields[.regex] ?? GitConfigurationIdentity()
        values.append((IssueTrackerStringKey.regex.rawValue,regex.inherit ? nil:regex.value.replacingOccurrences(of:"\r\n",with:"\n")))
        return values
    }
}
extension GitRepository {
    public func issueTrackerSettings(source: ProjectDialogSettingsSource, hasRepository: Bool = true, cancellation: OperationCancellation? = nil) throws -> IssueTrackerSettings {
        let values = try scopedProjectSettingsValues(pattern: IssueTrackerSettings.pattern, source: source, hasRepository: hasRepository, cancellation: cancellation)
        var result = IssueTrackerSettings()
        for key in IssueTrackerStringKey.allCases {
            let fallback = key == .label ? "Bug-ID/Issue-Nr:" : ""
            result.fields[key] = GitConfigurationIdentity(value:values[key.rawValue] ?? (source == .effective ? fallback:""),inherit:source != .effective && values[key.rawValue] == nil)
        }
        func boolean(_ key: String, fallback: GitConfigurationBoolean) throws -> GitConfigurationBoolean {
            guard let value = values[key] else { return source == .effective ? fallback:.inherit }
            switch value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() {
            case "true","yes","on": return .enabled
            case "false","no","off","": return .disabled
            default: guard let number = Int64(value.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw GitConfigurationFailure.invalidValue }; return number == 0 ? .disabled:.enabled
            }
        }
        result.append = try boolean("bugtraq.append",fallback:.enabled)
        result.number = try boolean("bugtraq.number",fallback:.enabled)
        result.warnIfNoIssue = try boolean("bugtraq.warnifnoissue",fallback:.disabled)
        return result
    }
    public func saveIssueTrackerSettings(_ settings: IssueTrackerSettings, destination: ProjectDialogSettingsSource, hasRepository: Bool = true, cancellation: OperationCancellation? = nil) throws {
        try saveScopedProjectSettings(settings.values,destination:destination,hasRepository:hasRepository,cancellation:cancellation)
    }
}


extension GitRepository {
    /// Source ProjectProperties uses the merged Git/.tgitconfig values. Disabled
    /// local approval is stored separately per user, never in the shared file.
    public func projectClientHooks(cancellation: OperationCancellation? = nil) throws -> [ClientHook] {
        let values = try scopedProjectSettingsValues(pattern: ClientHookConfiguration.pattern, source: .effective, hasRepository: true, cancellation: cancellation)
        var hooks: [ClientHook] = []
        func boolean(_ key: String) throws -> Bool {
            guard let value = values[key] else { return false }
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "on", "1": return true
            case "", "false", "no", "off", "0": return false
            default:
                guard let number = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ClientHookFailure.configuration("Invalid Boolean value for " + key) }
                return number != 0
            }
        }
        for type in ClientHookType.allCases {
            try cancellation?.check()
            let prefix = type.configurationPrefix
            guard let command = values[prefix + "cmdline"], !command.isEmpty else { continue }
            hooks.append(ClientHook(type: type, path: root.path, command: command,
                wait: try boolean(prefix + "wait"), show: try boolean(prefix + "show"), local: true))
        }
        return hooks
    }
    public func saveProjectClientHooks(_ hooks: [ClientHook], cancellation: OperationCancellation? = nil) throws {
        try ClientHookConfiguration.validate(hooks)
        guard hooks.allSatisfy({ $0.local && $0.path == root.path }) else {
            throw ClientHookFailure.configuration("Local hooks must belong to this repository.")
        }
        var values: [(String,String?)] = []
        for type in ClientHookType.allCases {
            let hook = hooks.first { $0.type == type }, prefix = type.configurationPrefix
            values.append((prefix + "cmdline",hook?.command))
            values.append((prefix + "wait",hook.map { $0.wait ? "true" : "false" }))
            values.append((prefix + "show",hook.map { $0.show ? "true" : "false" }))
        }
        try saveScopedProjectSettings(values,destination:.project,hasRepository:true,cancellation:cancellation)
    }
}
