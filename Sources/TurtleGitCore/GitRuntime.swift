import Foundation

public enum GitRuntimeFailure: LocalizedError {
    case bundledGitMissing
    public var errorDescription: String? {
        "This App Store build does not contain its Git engine. Build and embed the signed Git runtime before distributing the app."
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
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if appStore { throw GitRuntimeFailure.bundledGitMissing }
        return URL(fileURLWithPath: "/usr/bin/git")
    }
    public static func environment(executable: URL) -> [String: String] {
        let bin = executable.deletingLastPathComponent()
        let runtime = bin.deletingLastPathComponent()
        guard runtime.lastPathComponent == "Git" else { return [:] }
        return ["GIT_EXEC_PATH": runtime.appendingPathComponent("libexec/git-core").path,
                "GIT_TEMPLATE_DIR": runtime.appendingPathComponent("share/git-core/templates").path,
                "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
    }
}
