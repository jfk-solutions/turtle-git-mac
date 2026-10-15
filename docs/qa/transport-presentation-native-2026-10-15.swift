import AppKit
import SwiftUI
import TurtleGitCore

@main struct TransportPresentationVerification {
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Transport presentation did not settle at line \(line)")
    }
    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.TransportPresentation." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false,forKey:"DownloadAnimation"); prefs.set(false,forKey:"FetchVerbose"); prefs.set(16,forKey:"GitOutputLimitinKiB")
        var state = GitProgressOutputState(preferences:prefs), parser = GitCliOutputParser(limit:16*1024)
        parser.appendChunk(Data("Receiving objects: 50%\r".utf8)); state.consume(parser.processPending(),parser:parser)
        precondition(state.percentage == 50 && !state.presentation.animateActivity)
        prefs.set(64,forKey:"GitOutputLimitinKiB"); prefs.set(true,forKey:"DownloadAnimation")
        parser.appendChunk(Data(String(repeating:"payload 雪🦎 progress\n",count:2000).utf8)); state.consume(parser.processPending(),parser:parser)
        precondition(state.limit == 16*1024 && state.output.contains("Output truncated") && !state.output.contains("�") && state.percentage == nil)
        let activity = GitCommandActivityView(frame:NSRect(x:0,y:0,width:16,height:16)); activity.setAnimating(false)
        precondition(activity.indicator.isHidden && activity.accessibilityLabel() == "Operation in progress")
        activity.setAnimating(true); precondition(!activity.indicator.isHidden)
        activity.setAnimating(false); precondition(activity.indicator.isHidden)
        let producerRoot = root.appendingPathComponent("producer"), consumerRoot = root.appendingPathComponent("consumer")
        try FileManager.default.createDirectory(at:producerRoot,withIntermediateDirectories:true)
        let producer = GitRepository(root:producerRoot,executable:git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Transport QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message:"base")
        _ = try await producer.run(["clone","--",producerRoot.path,consumerRoot.path])
        let helper = root.appendingPathComponent("record-git"), record = root.appendingPathComponent("arguments")
        let script = "#!/bin/sh\nif [ \"$4\" = fetch ]; then printf '%s\\000' \"$@\" > " + quoted(record.path) + "; fi\nexec " + quoted(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let repo = GitRepository(root:consumerRoot,executable:helper), options = FetchOptions()
        prefs.set(false,forKey:"DownloadAnimation")
        let captured = FetchProgressWindowModel(repository:repo,access:nil,options:options,preferences:prefs)
        let push = PushProgressWindowModel(options:PushOptions(),superproject:nil,preferences:prefs)
        let clone = CloneProgressWindowModel(options:CloneOptions(),destination:root.appendingPathComponent("unused"),executable:git,destinationAccess:RepositoryAccessLease(url:root),sourceAccess:nil,keyAccess:nil,preferences:prefs)
        prefs.set(true,forKey:"DownloadAnimation")
        precondition(!captured.progressPresentation.animateActivity && !push.progressPresentation.animateActivity && !clone.progressPresentation.animateActivity)
        let fresh = FetchProgressWindowModel(repository:repo,access:nil,options:options,preferences:prefs)
        precondition(fresh.progressPresentation.animateActivity)
        captured.invalidate(); fresh.invalidate(); push.invalidate(); clone.invalidate()
        let model = FetchWindowModel(repository:repo,access:nil,isPull:false,preferences:prefs)
        defer { model.invalidate() }; model.load(); try await wait { !model.busy && !model.preparingRemote }
        model.options.remote = "origin"; model.options.branch = "main"
        var selected: FetchProgressWindowModel?
        model.onFetchProgress = { value in selected = value; prefs.set(true,forKey:"FetchVerbose") }
        model.fetch(); try await wait { selected != nil && selected?.busy == false }
        let first = selected!, args = try Data(contentsOf:record).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
        precondition(!first.options.verbose && first.success && !args.contains("--verbose") && args.contains("--progress"))
        model.finishFetch(first); selected = nil
        model.fetch(); try await wait { selected != nil && selected?.busy == false }
        let secondArgs = try Data(contentsOf:record).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
        precondition(selected!.options.verbose && selected!.success && secondArgs.contains("--verbose"))
        model.finishFetch(selected!); selected = nil
        prefs.set(false,forKey:"FetchVerbose")
        let sync = SynchronizationWindowModel(repository:repo,access:nil,preferences:prefs)
        defer { sync.invalidate() }; sync.reload(initial:true); try await wait { !sync.busy }
        sync.fetch(.fetch); try await wait { !sync.busy && !sync.transportRunning }
        let syncArgs = try Data(contentsOf:record).split(separator:0).map { String(decoding:$0,as:UTF8.self) }
        precondition(sync.commandSucceeded && !syncArgs.contains("-v") && syncArgs.contains("--progress"))
        print("PASS: captured native activity/Clone/Push/Fetch policies; real standalone Fetch submission snapshot and later enabled invocation; Sync preference; native static/spinning activity, captured output byte bound, Unicode and progress after truncation")
    }
}
