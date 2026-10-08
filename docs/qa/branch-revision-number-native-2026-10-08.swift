import AppKit
import SwiftUI
import TurtleGitCore

@main struct BranchRevisionNumberVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Branch revision display timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.BranchRevisionNumber.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let repo = GitRepository(root:root, executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Counter QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        _ = try await repo.run(["commit","--allow-empty","-m","base"])
        _ = try await repo.run(["checkout","-b","side"])
        _ = try await repo.run(["commit","--allow-empty","-m","side one"])
        _ = try await repo.run(["commit","--allow-empty","-m","side two"])
        let side = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["checkout","main"])
        _ = try await repo.run(["commit","--allow-empty","-m","main two"])
        _ = try await repo.run(["merge","--no-ff","side","-m","merge"])
        let head = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let count = try await repo.branchRevisionNumber(head); precondition(count == "3")
        let disabled = LogWindowModel(repository:repo,access:nil,selecting:true,labelDefaults:prefs)
        disabled.reload(); try await wait { !disabled.busy && disabled.entries.count == 5 }; try await Task.sleep(nanoseconds:100_000_000)
        precondition(disabled.branchRevisionNumber == nil && !disabled.message.contains("Branch RevNo"))
        prefs.set(true,forKey:"ShowBranchRevisionNumber")
        disabled.select([head]); try await Task.sleep(nanoseconds:100_000_000); precondition(disabled.branchRevisionNumber == nil)
        let log = LogWindowModel(repository:repo,access:nil,selecting:true,labelDefaults:prefs)
        log.reload(); try await wait { !log.busy && log.branchRevisionNumber == "3" }
        precondition(log.message.hasPrefix("SHA-1: " + head + ", Branch RevNo: 3\n"))
        let index = log.entries.firstIndex { $0.hash == side }!; precondition(log.graph[index].column > 0)
        log.select([side]); try await Task.sleep(nanoseconds:150_000_000); precondition(log.branchRevisionNumber == nil && !log.message.contains("Branch RevNo"))
        log.select([head]); log.select([side]); try await Task.sleep(nanoseconds:150_000_000); precondition(log.branchRevisionNumber == nil)
        log.select([head,side]); precondition(log.branchRevisionNumber == nil && !log.message.contains("Branch RevNo"))
        prefs.set(false,forKey:"ShowBranchRevisionNumber"); log.select([head]); try await wait { log.branchRevisionNumber == "3" }
        let remoteURL = root.appendingPathComponent("remote.git"); try FileManager.default.createDirectory(at:remoteURL,withIntermediateDirectories:true)
        let remote = GitRepository(root:remoteURL,executable:git); _ = try await remote.run(["init","--bare"])
        try await repo.saveRemote(name:"origin",fetchURL:remoteURL.path,pushURL:"",existing:false)
        let push = PushWindowModel(repository:repo,access:nil,preferences:prefs); push.load(); try await wait { !push.busy }
        push.options.source = "main"; push.options.destination = "published"; push.options.setUpstream = false
        var outputs:[String] = []; var closed = 0
        push.onPushed = { outputs.append($0) }; push.close = { closed += 1 }
        prefs.set(true,forKey:"ShowBranchRevisionNumber"); push.push(); prefs.set(false,forKey:"ShowBranchRevisionNumber")
        try await wait { !push.busy }; precondition(push.error == nil && closed == 1 && outputs.last!.hasSuffix("\n3\n"))
        push.push(); try await wait { !push.busy }; precondition(push.error == nil && closed == 2 && !outputs.last!.split(separator:"\n").contains("3"))
        let received = try await remote.run(["rev-parse","refs/heads/published"]).text.trimmingCharacters(in:.newlines); precondition(received == head)
        let after = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines); precondition(after == head)
        let host = NSHostingView(rootView:LogDialogSettings().defaultAppStorage(prefs)); host.frame = NSRect(x:0,y:0,width:800,height:650); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        disabled.invalidate(); log.invalidate()
        print("Branch revision number: real first-parent merge count, Log main/side lane display, multiple/rapid selection clearing, constructor preference snapshots, actual Push setting captured at submission and reopened default, unchanged local HEAD/remote published hash; private hidden settings layout. No displayed windows, standard preferences or clipboard writes.")
    }
}
