import Foundation

public enum GitRuntimeFailure: LocalizedError {
    case bundledGitMissing, bundledSSHMissing, customGitInvalid
    public var errorDescription: String? {
        switch self {
        case .customGitInvalid: return "Choose an existing executable Git file using its absolute path."
        case .bundledGitMissing:
            return "This App Store build does not contain its Git engine. Build and embed the signed Git runtime before distributing the app."
        case .bundledSSHMissing:
            return "This App Store build does not contain its SSH client. Build and embed the signed OpenSSH runtime before distributing the app."
        }
    }
}

public enum GitRuntime {
    public static var isAppStoreBuild: Bool {
        #if TURTLEGIT_APP_STORE
        return true
        #else
        return false
        #endif
    }
    /// An App Store build never falls back to an optionally installed external Git.
    public static func executable(bundle: Bundle = .main, appStore: Bool = isAppStoreBuild, preferences: UserDefaults = .standard) throws -> URL {
        let settings = GitEnginePreferences.load(from: preferences)
        if !appStore {
            if settings.choice == .system { return URL(fileURLWithPath: "/usr/bin/git") }
            if settings.choice == .custom {
                guard settings.valid else { throw GitRuntimeFailure.customGitInvalid }
                return try settings.selectedExecutable()
            }
        }
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Git/bin/git")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            let ssh = bundle.bundleURL.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh")
            if appStore && !FileManager.default.isExecutableFile(atPath: ssh.path) { throw GitRuntimeFailure.bundledSSHMissing }
            return bundled
        }
        if appStore { throw GitRuntimeFailure.bundledGitMissing }
        return URL(fileURLWithPath: "/usr/bin/git")
    }
    public static func environment(executable: URL, preferences: UserDefaults = .standard, appStore: Bool = isAppStoreBuild) -> [String: String] {
        let extra = appStore ? "" : GitEnginePreferences.load(from: preferences).extraPath
        let extraPrefix = extra.isEmpty ? "" : extra + ":"
        let bin = executable.deletingLastPathComponent()
        let runtime = bin.deletingLastPathComponent()
        guard runtime.lastPathComponent == "Git" else {
            return extra.isEmpty ? [:] : ["PATH": bin.path + ":" + extraPrefix + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]
        }
        let sshBin = runtime.deletingLastPathComponent().appendingPathComponent("OpenSSH/bin")
        // Git retains precedence for GIT_SSH_COMMAND, core.sshCommand and GIT_SSH.
        // PATH selects our client only for Git's ordinary `ssh` lookup; no shell
        // command or global repository setting is injected.
        let sshPath = FileManager.default.isExecutableFile(atPath: sshBin.appendingPathComponent("ssh").path) ? sshBin.path + ":" : ""
        return ["GIT_EXEC_PATH": runtime.appendingPathComponent("libexec/git-core").path,
                "GIT_TEMPLATE_DIR": runtime.appendingPathComponent("share/git-core/templates").path,
                "PATH": sshPath + bin.path + ":" + extraPrefix + "/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}


public enum GitEngineChoice: String, CaseIterable, Sendable {
    case automatic, system, custom
}
public struct GitEnginePreferences: Equatable, Sendable {
    public var choice: GitEngineChoice = .automatic
    public var path = ""
    public var extraPath = ""
    public var bookmark: Data?
    public init() {}
    public var valid: Bool {
        guard !extraPath.contains("\0"), extraPath.isEmpty || extraPath.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({ $0.hasPrefix("/") }) else { return false }
        if choice != .custom { return true }
        return path.hasPrefix("/") && !path.contains("\0") && (bookmark != nil || FileManager.default.isExecutableFile(atPath: path))
    }
    public func selectedExecutable() throws -> URL {
        guard valid else { throw GitRuntimeFailure.customGitInvalid }
        let file: URL
        if let bookmark { file = try SystemRepositoryBookmarkProvider().resolve(bookmark).url }
        else { file = URL(fileURLWithPath: path) }
        guard FileManager.default.isExecutableFile(atPath: file.path) else { throw GitRuntimeFailure.customGitInvalid }
        GitEngineAccess.shared.retain(file); return file
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        var result = Self()
        result.choice = GitEngineChoice(rawValue: defaults.string(forKey: "TurtleGit.GitEngine") ?? "automatic") ?? .automatic
        result.path = defaults.string(forKey: "TurtleGit.GitExecutable") ?? ""
        result.extraPath = defaults.string(forKey: "TurtleGit.GitExtraPath") ?? ""
        result.bookmark = defaults.data(forKey: "TurtleGit.GitExecutableBookmark")
        return result
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw GitRuntimeFailure.customGitInvalid }
        defaults.set(choice.rawValue, forKey: "TurtleGit.GitEngine"); defaults.set(path, forKey: "TurtleGit.GitExecutable")
        defaults.set(extraPath, forKey: "TurtleGit.GitExtraPath"); defaults.set(bookmark, forKey: "TurtleGit.GitExecutableBookmark")
    }
}


/// Repository objects retain only the executable URL; keep selected grants alive
/// while captured engines are still used by open dialogs and child operations.
private final class GitEngineAccess: @unchecked Sendable {
    static let shared = GitEngineAccess()
    private let lock = NSLock()
    private var leases: [URL: RepositoryAccessLease] = [:]
    func retain(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        if leases[file] == nil { leases[file] = RepositoryAccessLease(url: file) }
    }
}
