// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum GitAskpassRuntime {
    public static func command(_ helper: URL) -> String {
        helper.path
    }
    public static func bundled(bundle: Bundle = .main) -> URL? {
        let path = bundle.bundleURL.appendingPathComponent("Contents/Helpers/GitAskpass/TurtleGitGitAskpass")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }
    public static func mayAuthenticate(_ arguments: [String]) -> Bool {
        let commands: Set<String> = ["clone", "fetch", "pull", "push", "ls-remote", "submodule", "svn", "lfs", "credential"]
        return arguments.prefix(while: { $0 != "--" }).contains { commands.contains($0) }
    }
    public static func shouldInstall(arguments: [String], environment: [String: String], helper: URL?) -> Bool {
        let explicit = arguments.contains { $0.lowercased().hasPrefix("core.askpass=") || $0.lowercased().hasPrefix("--config-env=core.askpass=") }
        return helper != nil && !explicit && mayAuthenticate(arguments) && environment["GIT_ASKPASS"] == nil && environment["TURTLEGIT_DISABLE_ASKPASS"] != "1"
    }
}
