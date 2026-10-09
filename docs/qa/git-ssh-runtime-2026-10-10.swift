import Foundation
import Darwin
import MachO
import TurtleGitCore

@main struct GitSSHRuntimeReceiver {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain:"TurtleGitGitSSHRuntimeQA",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func main() async {
        do { try await check() }
        catch {
            FileHandle.standardError.write(Data(("Git SSH runtime QA failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    static func check() async throws {
        let app = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        guard let bundle = Bundle(url:app) else { throw NSError(domain:"QA",code:1) }
        let expectedFramework = app.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/TurtleGitCore").resolvingSymlinksInPath()
        let loadedImages = (0..<_dyld_image_count()).compactMap { index -> URL? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath()
        }
        try require(loadedImages.contains(expectedFramework),"Receiver must load the app's embedded Core image")
        let git = try GitRuntime.executable(bundle:bundle,appStore:true)
        try require(git == app.appendingPathComponent("Contents/Helpers/Git/bin/git"),"Packaged Git resolution")
        let agent = try SSHAgentRuntime.resolve(bundle:bundle,appStore:true)
        try require(agent.agent == app.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh-agent") && agent.add == app.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh-add"),"Packaged agent resolution")
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:repository,withIntermediateDirectories:false)
        let core = GitRepository(root:repository,executable:git)
        let environment = ["HOME":root.path,"GIT_CONFIG_SYSTEM":"/dev/null","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_COUNT":"0","GIT_SSH_COMMAND":"ssh -V","SSH_AUTH_SOCK":root.appendingPathComponent("private fixture socket").path,"SSH_AGENT_PID":""]
        _ = try await core.run(["init","--quiet"],environmentOverrides:environment)
        // OpenSSH -V exits after printing its version; it never connects.
        // Git then reports the expected failed remote exchange (128).
        let result = try await core.run(["ls-remote","ssh://fixture.invalid/repository"],environmentOverrides:environment,successfulExitCodes:128...128)
        try require(result.text.contains("OpenSSH_"+CommandLine.arguments[3]) && result.text.contains("OpenSSL "+CommandLine.arguments[4]),"Packaged Git must invoke the bundled SSH/OpenSSL version")
        print("Native Core: packaged Git/agent resolution and bundled SSH version-only lookup passed; no app window, authentication or signed sandbox acceptance.")
    }
}
