import AppKit
import SwiftUI
import TurtleGitCore

@main struct RequestPullVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Request Pull timed out")
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of:"'",with:"'\\''") + "'" }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.RequestPull.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let client = root.appendingPathComponent("client 雪"), destination = root.appendingPathComponent("remote space.git")
        for dir in [client,destination] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let repo = GitRepository(root:client,executable:git), remote = GitRepository(root:destination,executable:git)
        _ = try await remote.run(["init","--bare"]); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Request QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/remotes/origin/base",base])
        try Data("changed\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"request change 雪")
        try await repo.saveRemote(name:"origin",fetchURL:destination.path,pushURL:"",existing:false)
        var push = PushOptions(); push.remote = "origin"; push.source = "main"; _ = try await repo.push(push)
        try Data("staged\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); try Data("unstaged\n".utf8).write(to:client.appendingPathComponent("file"))
        let index = try await repo.run(["diff","--cached","--binary"]).stdout, working = try await repo.run(["diff","--binary"]).stdout, head = try await repo.run(["rev-parse","HEAD"]).stdout, refs = try await remote.run(["show-ref"]).stdout
        let model = RequestPullWindowModel(repository:repo,access:nil,preferences:prefs)
        precondition(model.start.isEmpty && model.repositoryURL.isEmpty && model.end == "HEAD" && !model.sendMail)
        model.load(); try await wait { !model.busy }; precondition(model.references.contains("main") && model.references.contains("remotes/origin/base"))
        let log = LogWindowModel(repository:repo,access:nil,selecting:true,labelDefaults:prefs)
        model.start = "main"; model.configureLog(log); try await wait { !log.busy && !log.entries.isEmpty }
        precondition(log.endRevision == "main" && !log.showWorkingTree && !log.entries.contains { $0.hash.isEmpty })
        model.acceptStart(nil); precondition(model.start == "main"); model.acceptStart(base); precondition(model.start == base)
        model.repositoryURL = destination.path; model.end = "bad name"; model.sendMail = true
        var handoffs:[(URL,Bool)] = []; model.presentDocument = { handoffs.append(($0,$1)) }
        model.create(); try await wait { !model.busy }
        precondition(model.error == RequestPullFailure.end.localizedDescription && model.document == nil && handoffs.isEmpty)
        let key = "History.RequestPull." + client.path + "."
        precondition(prefs.string(forKey:key + "endrevision") == "bad name" && prefs.string(forKey:key + "startrevision") == base && prefs.stringArray(forKey:RequestPullWindowModel.urlHistoryKey)?.first == destination.path && !prefs.bool(forKey:RequestPullWindowModel.sendMailKey))
        model.end = " main "; model.start = "remotes/origin/base"; model.create(); model.end = "wrong-after-snapshot"; model.sendMail = false
        model.create(); try await wait { !model.busy }
        precondition(model.error == nil && handoffs.count == 1 && handoffs[0].1 && handoffs[0].0.lastPathComponent == "pullrequest.txt")
        var options = RequestPullOptions(); options.start = base; options.repositoryURL = destination.path; options.end = "main"
        let bytes = try Data(contentsOf:handoffs[0].0), expected = try await repo.requestPull(options); precondition(bytes == expected)
        let reopened = RequestPullWindowModel(repository:repo,access:nil,preferences:prefs)
        precondition(reopened.start == "remotes/origin/base" && reopened.end == "main" && reopened.repositoryURL == destination.path && reopened.sendMail)
        let other = RequestPullWindowModel(repository:remote,access:nil,preferences:prefs,end:"release",repositoryURL:"explicit")
        precondition(other.start.isEmpty && other.end == "release" && other.repositoryURL == "explicit" && other.urls.contains(destination.path) && other.sendMail)
        model.openDocument(); precondition(handoffs.count == 2 && !handoffs[1].1)
        reopened.deleteURL(at:0); precondition(reopened.urls.isEmpty && prefs.stringArray(forKey:RequestPullWindowModel.urlHistoryKey)?.isEmpty == true)
        model.end = "main"; model.start = "missing"; model.create(); try await wait { !model.busy }; precondition(model.error?.hasPrefix("Failed to create pull-request.") == true && handoffs.count == 2)
        for delivery in [EmailDelivery.configured, .direct, .mailClient] {
            prefs.set(delivery.rawValue, forKey: "SendMail.DeliveryType")
            var shown: SendPatchWindowController?, closed = 0
            let controller = RequestPullWindowController(repository: repo, access: nil, end: "main", repositoryURL: destination.path,
                preferences: prefs, mailPresentation: { shown = $0 as? SendPatchWindowController })
            controller.onClosed = { closed += 1 }
            try await wait { !controller.model.busy }
            controller.model.start = base; controller.model.sendMail = true; controller.model.create()
            try await wait { !controller.model.busy && shown != nil }
            precondition(controller.model.composingMail && !controller.windowShouldClose(controller.window!))
            let options = shown!, file = controller.model.document!
            precondition(options.model.customSubject && options.model.delivery == (delivery == .mailClient ? .mailClient : .smtp) && options.window?.title == "Send Mail – TurtleGit")
            precondition(options.model.rows.map(\.file) == [file] && !options.model.previewBusy)
            options.model.combine = false; options.model.attachment = false; options.model.combinedSubject = "Request custom 雪"
            options.model.setHighlighted([]); options.model.combineChanged()
            precondition(options.model.subject == "Request custom 雪" && !options.model.previewBusy)
            var captured: SendPatchRequest?
            // Capture the real options preparation boundary without connecting to mail.
            options.model.onSubmit = { captured = $0 }
            options.model.to = "review@example.invalid"; options.model.cc = "copy@example.invalid"
            options.model.submit(); try await wait { options.model.pendingLoads == 0 && captured != nil }
            precondition(captured!.delivery.delivery == delivery && captured!.messages.count == 1)
            let message = captured!.messages[0], text = String(data: try Data(contentsOf: file), encoding: .utf8)!
            var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            precondition(message.subject == "Request custom 雪" && message.body == Data(lines.map { $0 + "\r\n" }.joined().utf8))
            precondition(message.to == ["review@example.invalid"] && message.cc == ["copy@example.invalid"] && message.attachments.isEmpty)
            try await wait { !controller.model.composingMail && closed == 1 }
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            controller.model.invalidate(); options.model.invalidate()
            var cancelOptions: SendPatchWindowController?, cancelClosed = 0
            let cancelController = RequestPullWindowController(repository: repo, access: nil, preferences: prefs,
                mailPresentation: { cancelOptions = $0 as? SendPatchWindowController })
            cancelController.onClosed = { cancelClosed += 1 }
            try await wait { !cancelController.model.busy }
            cancelController.model.presentDocument(handoffs[0].0, true)
            precondition(cancelController.model.composingMail && cancelOptions != nil)
            cancelOptions!.model.cancel()
            try await wait { !cancelController.model.composingMail && cancelClosed == 1 }
            cancelController.model.invalidate()
        }
        try FileManager.default.removeItem(at:handoffs[0].0.deletingLastPathComponent())
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath:helper.path + ".started"), release = URL(fileURLWithPath:helper.path + ".release")
        let script = """
        #!/bin/sh
        if [ "${4-}" = request-pull ] && [ ! -f "$0.release" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started"
          wait "$task_child"
        fi
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:helper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let cancellable = RequestPullWindowModel(repository:GitRepository(root:client,executable:helper),access:nil,preferences:prefs,end:"main",repositoryURL:destination.path)
        cancellable.start = base; var cancellationHandoffs = 0
        cancellable.presentDocument = { file,_ in cancellationHandoffs += 1; try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        cancellable.create(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
        let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0.trimmingCharacters(in:.whitespacesAndNewlines)) }; precondition(pids.count == 2)
        cancellable.cancel(); try await wait { !cancellable.busy }; precondition(cancellable.error == "User cancelled." && cancellable.document == nil && cancellationHandoffs == 0)
        try await wait { kill(pids[0],0) != 0 && kill(pids[1],0) != 0 }
        try Data().write(to:release); cancellable.create(); try await wait { !cancellable.busy }; precondition(cancellable.error == nil && cancellationHandoffs == 1)
        let afterIndex = try await repo.run(["diff","--cached","--binary"]).stdout, afterWorking = try await repo.run(["diff","--binary"]).stdout, afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, afterRefs = try await remote.run(["show-ref"]).stdout
        precondition(index == afterIndex && working == afterWorking && head == afterHead && refs == afterRefs)
        let host = NSHostingView(rootView:RequestPullDialog(model:model)); host.frame = NSRect(x:0,y:0,width:680,height:210); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0 && host.fittingSize.height > 0)
        print("Request Pull SMTP: actual configured/direct callers, retained hidden custom-subject options, non-combined editable subject, full original request body, To/CC and options Cancel/parent close verified at capture boundary; no SMTP or mail client launched. Private suite: \(suite)")
        log.invalidate(); model.invalidate(); reopened.invalidate(); other.invalidate(); cancellable.invalidate()
        print("Request Pull: native defaults/scoped fields/global case-sensitive history/pre-validation saves, Send Mail persistence gate, source-prefilled overrides, source Log selection/cancel, actual published request UTF-8 bytes and remotes/ start normalization, captured mail/text/duplicate gate, output fallback, real owned cancellation/retry and unchanged HEAD/index/working tree/remote refs. No displayed windows, editor, mail, standard preferences or clipboard writes.")
    }
}
