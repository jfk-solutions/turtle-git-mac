// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum NetworkSettingsFailure: LocalizedError {
    case proxy, ssh
    public var errorDescription: String? {
        switch self {
        case .proxy: return "Enter a proxy host, optional supported scheme, and a port between 1 and 65535."
        case .ssh: return "Choose an executable OpenSSH client using its absolute path."
        }
    }
}
public struct GitProxySettings: Equatable, Sendable {
    public var enabled = false
    public var server = ""
    public var port = ""
    public var username = ""
    public var password = ""
    public init() {}
    public init(configuration: String?) throws {
        self.init()
        guard let configuration, !configuration.isEmpty else { return }
        guard let components = URLComponents(string: configuration.contains("://") ? configuration : "http://" + configuration),
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw NetworkSettingsFailure.proxy }
        enabled = true; server = (components.scheme == "http" ? "" : (components.scheme ?? "http") + "://") + host
        port = components.port.map(String.init) ?? ""
        username = components.user ?? ""; password = components.password ?? ""
        _ = try value()
    }
    public func value() throws -> String? {
        guard ![server, port, username, password].contains(where: { $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }) else { throw NetworkSettingsFailure.proxy }
        guard enabled else { return nil }
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, var components = URLComponents(string: server.contains("://") ? server : "http://" + server),
              ["http", "https", "socks", "socks4", "socks4a", "socks5", "socks5h"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw NetworkSettingsFailure.proxy }
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !port.isEmpty && port != "0" {
            guard port.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(port), (1...65535).contains(number) else { throw NetworkSettingsFailure.proxy }
            components.port = number
        }
        if let port = components.port, !(1...65535).contains(port) { throw NetworkSettingsFailure.proxy }
        components.path = ""
        if !username.isEmpty {
            // Only unreserved characters stay literal in userinfo, including @/:.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            guard let user = username.addingPercentEncoding(withAllowedCharacters: allowed), let password = password.addingPercentEncoding(withAllowedCharacters: allowed) else { throw NetworkSettingsFailure.proxy }
            components.percentEncodedUser = user; components.percentEncodedPassword = self.password.isEmpty ? nil : password
        } else if !password.isEmpty { throw NetworkSettingsFailure.proxy }
        guard let value = components.string else { throw NetworkSettingsFailure.proxy }; return value
    }
}
public struct SSHClientPreferences: Equatable, Sendable {
    public var path = ""
    public var bookmark: Data?
    public init() {}
    public func executable() throws -> URL? {
        if path.isEmpty { return nil }
        var engine = GitEnginePreferences(); engine.choice = .custom; engine.path = path; engine.bookmark = bookmark
        guard engine.valid else { throw NetworkSettingsFailure.ssh }
        return try engine.selectedExecutable()
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        var result = Self(); result.path = defaults.string(forKey: "TurtleGit.SSHClient") ?? ""; result.bookmark = defaults.data(forKey: "TurtleGit.SSHClientBookmark"); return result
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        _ = try executable(); defaults.set(path, forKey: "TurtleGit.SSHClient"); defaults.set(bookmark, forKey: "TurtleGit.SSHClientBookmark")
    }
    public func environment(existing: [String: String], appStore: Bool = GitRuntime.isAppStoreBuild) -> [String: String] {
        guard !appStore, !path.isEmpty, existing["GIT_SSH"] == nil, existing["GIT_SSH_COMMAND"] == nil else { return [:] }
        // An unavailable saved client must fail SSH rather than fall back to a
        // different client; ordinary configuration commands can still repair it.
        let selected = (try? executable())?.path ?? (path.hasPrefix("/") && !path.contains("\0") ? path : "/usr/bin/false")
        var values = ["GIT_SSH": selected]
        if existing["GIT_SSH_VARIANT"] == nil { values["GIT_SSH_VARIANT"] = "ssh" }
        return values
    }
    public func version(cancellation: OperationCancellation) throws -> String {
        guard let executable = try executable() else { return "Automatic OpenSSH" }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("out"), stderr = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: stdout.path, contents: nil); FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr); defer { try? out.close(); try? err.close() }
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"
        let operation = OperationCancellation(), start = DispatchTime.now().uptimeNanoseconds
        let code = try CancellableGitProcess.run(executable: executable, arguments: ["-V"], environment: environment, output: out.fileDescriptor, error: err.fileDescriptor, cancellation: operation, pollOutput: {
            if cancellation.isCancelled || DispatchTime.now().uptimeNanoseconds - start > 10_000_000_000 { operation.cancel() }
        })
        try cancellation.check()
        let text = String(decoding: try Data(contentsOf: stdout) + Data(contentsOf: stderr), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, text.hasPrefix("OpenSSH_") else { throw NetworkSettingsFailure.ssh }; return text
    }
}
extension GitRepository {
    public func proxyConfiguration(source: GitConfigurationSource = .effective, cancellation: OperationCancellation? = nil) throws -> GitProxySettings {
        let result = try run(["config"] + source.arguments + ["--includes", "--null", "--get", "http.proxy"], successfulExitCodes: 0...1, cancellation: cancellation)
        if result.exitCode == 1 { return GitProxySettings() }
        guard result.stdout.last == 0, let value = String(data: result.stdout.dropLast(), encoding: .utf8) else { throw GitConfigurationFailure.output }
        return try GitProxySettings(configuration: value)
    }
    public func saveProxyConfiguration(_ settings: GitProxySettings) throws {
        if let value = try settings.value() {
            // Do not expose the arguments or Git diagnostics: proxy userinfo may
            // contain a password. The UI reports only the key on write failure.
            do { _ = try run(["config", "--global", "--replace-all", "--", "http.proxy", value]) }
            catch { throw GitConfigurationFailure.save(key: "http.proxy", detail: "Could not save global proxy configuration.") }
        } else {
            let arguments = ["config", "--global", "--unset-all", "--", "http.proxy"]
            do {
                let result = try run(arguments, successfulExitCodes: 0...5)
                guard result.exitCode == 0 || result.exitCode == 5 else { throw NetworkSettingsFailure.proxy }
            } catch { throw GitConfigurationFailure.save(key: "http.proxy", detail: "Could not clear global proxy configuration.") }
        }
    }
}
