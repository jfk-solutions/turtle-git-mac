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
        // request-pull invokes ls-remote in its subprocess; its authentication
        // helpers must already be present in the inherited outer environment.
        let commands: Set<String> = ["clone", "fetch", "pull", "push", "ls-remote", "request-pull", "submodule", "svn", "lfs", "credential"]
        let identity=GitCommandIdentity(arguments)
        if identity.command=="remote",let action=identity.arguments.drop(while:{["-v","--verbose","--"].contains($0)}).first,["update","prune","show"].contains(action) {return true}
        return identity.command.map{commands.contains($0)} ?? false
    }
    public static func shouldInstall(arguments: [String], environment: [String: String], helper: URL?) -> Bool {
        let explicit=GitCommandIdentity(arguments).overridesConfiguration("core.askpass")
        return helper != nil && !explicit && mayAuthenticate(arguments) && environment["GIT_ASKPASS"] == nil && environment["TURTLEGIT_DISABLE_ASKPASS"] != "1"
    }
    public static func sshEnvironment(arguments: [String], environment: [String: String], helper: URL?) -> [String: String] {
        guard let helper, mayAuthenticate(arguments), environment["SSH_ASKPASS"] == nil,
              environment["TURTLEGIT_DISABLE_ASKPASS"] != "1",
              environment["SSH_ASKPASS_REQUIRE"]?.lowercased() != "never" else { return [:] }
        let alias = helper.deletingLastPathComponent().appendingPathComponent("TurtleGitOpenSSHAskpass")
        guard FileManager.default.isExecutableFile(atPath: alias.path) else { return [:] }
        var result = ["SSH_ASKPASS": alias.path]
        if environment["SSH_ASKPASS_REQUIRE"] == nil { result["SSH_ASKPASS_REQUIRE"] = "force" }
        return result
    }
}
