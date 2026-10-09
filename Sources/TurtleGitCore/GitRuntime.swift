import Foundation

public enum GitRuntimeFailure: LocalizedError {
    case bundledGitMissing, bundledSSHMissing
    public var errorDescription: String? {
        switch self {
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
    public static func executable(bundle: Bundle = .main, appStore: Bool = isAppStoreBuild) throws -> URL {
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/Git/bin/git")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            let ssh = bundle.bundleURL.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh")
            if appStore && !FileManager.default.isExecutableFile(atPath: ssh.path) { throw GitRuntimeFailure.bundledSSHMissing }
            return bundled
        }
        if appStore { throw GitRuntimeFailure.bundledGitMissing }
        return URL(fileURLWithPath: "/usr/bin/git")
    }
    public static func environment(executable: URL) -> [String: String] {
        let bin = executable.deletingLastPathComponent()
        let runtime = bin.deletingLastPathComponent()
        guard runtime.lastPathComponent == "Git" else { return [:] }
        let sshBin = runtime.deletingLastPathComponent().appendingPathComponent("OpenSSH/bin")
        // Git retains precedence for GIT_SSH_COMMAND, core.sshCommand and GIT_SSH.
        // PATH selects our client only for Git's ordinary `ssh` lookup; no shell
        // command or global repository setting is injected.
        let sshPath = FileManager.default.isExecutableFile(atPath: sshBin.appendingPathComponent("ssh").path) ? sshBin.path + ":" : ""
        return ["GIT_EXEC_PATH": runtime.appendingPathComponent("libexec/git-core").path,
                "GIT_TEMPLATE_DIR": runtime.appendingPathComponent("share/git-core/templates").path,
                "PATH": sshPath + bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}
