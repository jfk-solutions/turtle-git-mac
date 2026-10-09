import Foundation
import Darwin
import MachO
import TurtleGitCore

@main struct BundledSSHAgentReceiver {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain:"TurtleGitBundledAgentQA",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func main() {
        do { try check() }
        catch {
            FileHandle.standardError.write(Data(("Bundled SSH agent QA failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    final class Pending: @unchecked Sendable {
        let lock = NSLock()
        var failed = false
        func recordFailure() { lock.lock(); failed = true; lock.unlock() }
        func didFail() -> Bool { lock.lock(); defer { lock.unlock() }; return failed }
    }
    static func quote(_ text: String) -> String { "'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'" }
    static func check() throws {
        let app = URL(fileURLWithPath:CommandLine.arguments[1]), root = URL(fileURLWithPath:CommandLine.arguments[2])
        let image = app.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/TurtleGitCore").resolvingSymlinksInPath()
        let loaded = (0..<_dyld_image_count()).compactMap { index -> URL? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath()
        }
        try require(loaded.contains(image),"Embedded Core image")
        guard let bundle = Bundle(url:app) else { throw NSError(domain:"QA",code:1) }
        let resolved = try SSHAgentRuntime.resolve(bundle:bundle,appStore:true)
        let bin = app.appendingPathComponent("Contents/Helpers/OpenSSH/bin")
        try require(resolved.agent == bin.appendingPathComponent("ssh-agent") && resolved.add == bin.appendingPathComponent("ssh-add"),"Bundled agent/add resolution")
        try require(resolved.askpass == app.appendingPathComponent("Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass"),"Bundled response helper resolution")
        let phrase = "private fixture phrase " + UUID().uuidString
        let plain = root.appendingPathComponent("plain 雪 ' ; $(touch sentinel)")
        let encrypted = root.appendingPathComponent("encrypted 雪 ' ; $(touch sentinel)")
        for (key,password,comment) in [(plain,"","TurtleGit-plain-fixture"),(encrypted,phrase,"TurtleGit-encrypted-fixture")] {
            let process = Process(); process.executableURL = bin.appendingPathComponent("ssh-keygen")
            process.currentDirectoryURL = root
            process.arguments = ["-q","-t","ed25519","-N",password,"-C",comment,"-f",key.path]
            process.environment = ["PATH":"/usr/bin:/bin","HOME":root.path,"LANG":"C"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); try require(process.terminationStatus == 0,"Fixture key creation")
        }
        let monitor = root.appendingPathComponent("agent-monitor")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid\"\nexec " + quote(resolved.agent.path) + " \"$@\"\n"
        try Data(script.utf8).write(to:monitor)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:monitor.path)
        // The monitor execs the actual bundled agent in the same owned PID/group.
        let runtime = SSHAgentRuntime(agent:monitor,add:resolved.add,askpass:resolved.askpass)
        let agent = try SSHAgentSession(runtime:runtime,temporaryRoot:root); defer { agent.close() }
        guard let pid = Int32(try String(contentsOf:URL(fileURLWithPath:monitor.path+".pid"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw NSError(domain:"QA",code:1) }
        try require(kill(pid,0) == 0 && getpgid(pid) == pid,"Owned live agent group")
        let permissions = try FileManager.default.attributesOfItem(atPath:agent.directory.path)[.posixPermissions] as? Int
        try require(permissions == 0o700,"Private agent directory permissions")
        func cleanChannel() throws {
            let files = try FileManager.default.contentsOfDirectory(atPath:agent.directory.path)
            try require(!files.contains { $0.hasPrefix("credential-") || $0.hasPrefix("command-") },"One-use response/output cleanup")
        }
        try agent.add(keys:[plain]); try cleanChannel()
        let before = try agent.publicIdentities()
        try require(before.contains("TurtleGit-plain-fixture") && !before.contains("TurtleGit-encrypted-fixture"),"Initial loaded identity")
        for response in [nil,Optional("incorrect fixture response")] {
            do {
                try agent.add(keys:[encrypted],passphrase:response)
                throw NSError(domain:"QA",code:1,userInfo:[NSLocalizedDescriptionKey:"Encrypted key accepted without correct response"])
            } catch let error as SSHAgentFailure {
                guard case .command = error else { throw error }
                try require(!error.localizedDescription.contains(phrase),"Private response excluded from errors")
            }
            try require(try agent.publicIdentities() == before,"Earlier identity survives failed key loading")
            try cleanChannel()
        }
        try agent.add(keys:[encrypted],passphrase:phrase); try cleanChannel()
        let identities = try agent.publicIdentities()
        for key in [plain,encrypted] {
            let publicKey = try String(contentsOf:URL(fileURLWithPath:key.path+".pub"),encoding:.utf8).trimmingCharacters(in:.newlines)
            try require(identities.contains(publicKey),"Expected public identity loaded")
        }
        let cancelled = OperationCancellation(); cancelled.cancel()
        do {
            try agent.add(keys:[encrypted],passphrase:phrase,cancellation:cancelled)
            throw NSError(domain:"QA",code:1,userInfo:[NSLocalizedDescriptionKey:"Cancelled loading succeeded"])
        } catch is OperationCancellationFailure {}
        try require(try agent.publicIdentities() == identities,"Cancellation preserves existing identities"); try cleanChannel()
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("sentinel").path),"Literal key path preserved")
        agent.close()
        try require(kill(pid,0) != 0 && errno == ESRCH,"Owned bundled agent reaped")
        try require(!FileManager.default.fileExists(atPath:agent.directory.path),"Private agent directory removed")
        let secondMonitor = root.appendingPathComponent("agent-monitor-second")
        try Data(script.utf8).write(to:secondMonitor)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:secondMonitor.path)
        let loader = root.appendingPathComponent("slow-add")
        let loaderScript = """
        #!/bin/sh
        /bin/sleep 30 &
        child=$!
        trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s\n' "$$" "$child" > "$0.started.tmp"
        /bin/mv "$0.started.tmp" "$0.started"
        wait "$child"
        exec \(quote(resolved.add.path)) "$@"
        """
        try Data(loaderScript.utf8).write(to:loader)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:loader.path)
        let blocked = try SSHAgentSession(runtime:SSHAgentRuntime(agent:secondMonitor,add:loader,askpass:resolved.askpass),temporaryRoot:root)
        let finished = DispatchGroup(), pending = Pending()
        finished.enter()
        defer {
            blocked.close()
            if finished.wait(timeout:.now()+5) != .success {
                FileHandle.standardError.write(Data("Owned key-loading worker did not finish\n".utf8))
                exit(1)
            }
        }
        DispatchQueue.global(qos:.utility).async {
            defer { finished.leave() }
            do { try blocked.add(keys:[encrypted],passphrase:phrase) }
            catch { pending.recordFailure() }
        }
        let started = URL(fileURLWithPath:loader.path+".started")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath:started.path) && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        let children = try String(contentsOf:started,encoding:.utf8).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        try require(children.count == 2 && children.allSatisfy { kill($0,0) == 0 && getpgid($0) == children[0] },"Live owned loader and child")
        try require(try FileManager.default.contentsOfDirectory(atPath:blocked.directory.path).contains { $0.hasPrefix("credential-") },"Pending private response channel")
        guard let secondPID = Int32(try String(contentsOf:URL(fileURLWithPath:secondMonitor.path+".pid"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw NSError(domain:"QA",code:1) }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "inject-live-failure" {
            throw NSError(domain:"QA",code:1,userInfo:[NSLocalizedDescriptionKey:"Injected live-loading fixture failure"])
        }
        blocked.close()
        try require(finished.wait(timeout:.now()+5) == .success && pending.didFail(),"Abandoned key loading completed as failure")
        try require(children.allSatisfy { kill($0,0) != 0 } && kill(secondPID,0) != 0,"Bundled agent, loader and child reaped")
        try require(!FileManager.default.fileExists(atPath:blocked.directory.path),"Abandoned private response directory removed")
        print("Native bundled agent: literal plain/encrypted keys, missing/wrong/correct response, identity preservation, pre-cancellation, live-load closure, one-use cleanup and owned PID reaping passed. No app window, server authentication or signed sandbox acceptance.")
    }
}
