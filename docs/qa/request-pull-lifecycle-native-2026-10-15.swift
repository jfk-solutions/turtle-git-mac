// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct RequestPullLifecycleVerification {
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RequestPullLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !condition() else { return }
        let windows = NSApp.windows.map { window -> String in
            var details = "title=\(window.title.debugDescription),visible=\(window.isVisible),sheet=\(String(describing:window.attachedSheet?.title)),parent=\(String(describing:window.sheetParent?.title))"
            if let owner = window.windowController as? RequestPullWindowController {
                let model = owner.model
                details += ",request{busy=\(model.busy),pending=\(model.pendingOperations),waiting=\(model.waitingForHandoff)/\(owner.waitingController != nil),retired=\(model.isRetired),choosing=\(model.choosingStart),picker=\(owner.picker != nil),error=\(String(describing:model.error)),confirmingError=\(model.confirmingError),errorWindow=\(owner.errorWindow != nil),mail=\(model.composingMail),editor=\(model.openingEditor),document=\(String(describing:model.document?.path))}"
            }
            if let owner = window.windowController as? LogWindowController { details += ",log{busy=\(owner.model.busy),pending=\(owner.model.pendingHistoryLoads)}" }
            return details
        }.joined(separator: "; ")
        try check(false, "Timed out waiting for Request Pull lifecycle at \(file):\(line); operations=\(RequestPullWindowModel.activeOperations),releases=\(RequestPullWindowController.activeReleases),history=\(LogWindowModel.activeHistoryLoads),editor=\(AlternativeEditor.activeRequests)/\(ExternalToolProcesses.activeRequests); windows=\(windows)")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.RequestPullLifecycle.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Request QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        for value in ["base", "tip"] {
            try Data((value + "\n").utf8).write(to: root.appendingPathComponent("file")); try await repository.stage(["file"])
            _ = try await repository.commit(message: value)
        }
        let first = try await repository.run(["rev-parse", "HEAD~1"]).text.trimmingCharacters(in: .newlines)
        let remote = root.appendingPathComponent("published 雪.git")
        _ = try await repository.run(["clone", "--bare", "--", root.path, remote.path])
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let controller = RequestPullWindowController(repository: repository, access: nil, preferences: prefs)
        defer { controller.close() }; controller.window!.alphaValue = 0; controller.showWindow(nil)
        try await wait { !controller.model.busy }
        var configured = 0, reply: ((LogEntry?) -> Void)?, lastPicker: LogWindowController?
        controller.configureLogPicker = { if $0.colorPreferences === prefs { configured += 1 } }
        controller.makePicker = { repository, access, revision, preferences, choose in
            reply = choose
            let child = LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, initialRevision: revision)
            lastPicker = child; return child
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.window!.appearance = NSAppearance(named: appearance); controller.model.start = first
            controller.chooseStart(); try await wait { controller.picker?.model.busy == false && controller.picker?.model.entries.isEmpty == false }
            let log = controller.picker!
            try check(log.model.endRevision == first && !log.model.showWorkingTree && log.model.selecting && configured > 0 && log.window!.alphaValue == 0 && log.window!.appearance == controller.window!.appearance, "Start Log lost entered revision/private appearance/selection")
            controller.model.create(); controller.model.load(); controller.model.cancel()
            try check(controller.model.choosingStart && !controller.model.busy && controller.model.document == nil && !controller.windowShouldClose(controller.window!), "Competing operations escaped owned picker")
            let selected = log.model.entries.first { $0.hash == first }!
            log.model.finishSelection(selected)
            try await wait { !controller.model.choosingStart && controller.window!.attachedSheet == nil }
            try check(controller.model.start == first, "Start did not receive selected commit")
            controller.model.start = "retained after accepted choice"; reply?(selected)
            try check(controller.model.start == "retained after accepted choice", "Repeated choice was not one-use")
            controller.model.start = first; controller.chooseStart()
            try await wait { controller.picker?.model.busy == false && controller.picker?.model.entries.isEmpty == false }
            let stale = controller.picker!; controller.model.repositoryURL = "changed during picker"
            stale.model.finishSelection(stale.model.entries.first)
            try await wait { !controller.model.choosingStart && controller.window!.attachedSheet == nil }
            try check(controller.model.start == first && controller.model.repositoryURL == "changed during picker", "Stale picker replaced edited input")
            controller.chooseStart(); try await wait { controller.picker?.model.busy == false }
            controller.picker!.model.finishSelection(nil)
            try await wait { !controller.model.choosingStart && controller.window!.attachedSheet == nil }
            try check(controller.model.start == first, "Cancel changed Start")
        }
        controller.presentPicker = { _, _ in false }; controller.chooseStart()
        let refusedPicker = lastPicker!
        try await wait { refusedPicker.model.pendingHistoryLoads == 0 && refusedPicker.window?.sheetParent == nil && controller.picker == nil && !controller.model.choosingStart }
        try check(controller.picker == nil && !controller.model.choosingStart, "Refused picker retained owner")
        controller.presentPicker = { parent, child in parent.beginSheet(child); return true }
        controller.chooseStart(); try await wait { controller.picker?.model.busy == false && controller.picker?.model.entries.isEmpty == false }
        let retiringPicker = controller.picker!, retiredEntry = retiringPicker.model.entries.first!
        controller.close(); reply?(retiredEntry)
        try check(controller.picker == nil && controller.model.isRetired && !controller.model.choosingStart && controller.model.start == first, "Retired picker callback changed input")
        try await wait { retiringPicker.model.pendingHistoryLoads == 0 && retiringPicker.window?.sheetParent == nil && controller.window?.attachedSheet == nil }

        var opened = [URL]()
        let document = RequestPullWindowController(repository: repository, access: nil, end: "main", repositoryURL: remote.path, preferences: prefs)
        defer { document.close() }; document.window!.alphaValue = 0; document.showWindow(nil)
        document.openDocument = { opened.append($0); return false }
        try await wait { !document.model.busy }; document.model.start = first; document.model.sendMail = false; document.model.create()
        try await wait { !document.model.busy && !document.model.hasPendingWork && !document.model.waitingForHandoff && document.waitingController == nil && document.model.document != nil && opened.count == 1 && document.errorWindow != nil }
        let file = document.model.document!
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try check(opened == [file] && document.model.error?.contains("Open request") == true && !document.model.isRetired, "Failed document launch did not retain fallback")
        var options = RequestPullOptions(); options.start = first; options.repositoryURL = remote.path; options.end = "main"
        try check(try Data(contentsOf: file) == (try await repository.requestPull(options)), "Generated fallback lost exact request bytes")
        // Dismiss the actual error alert before using the exposed fallback button.
        document.model.error = nil; try await wait { document.window!.attachedSheet == nil && document.errorWindow == nil && !document.model.confirmingError && !document.model.waitingForHandoff }
        document.openDocument = { opened.append($0); return true }; document.model.openDocument()
        try await wait { document.model.isRetired && !document.model.hasPendingWork && document.waitingController == nil && document.window!.attachedSheet == nil }
        try check(opened == [file, file] && document.model.isRetired && FileManager.default.fileExists(atPath: file.path), "Successful retry should retire owner while retaining document")
        document.model.openDocument(); try check(opened.count == 2, "Retired fallback reopened external editor")

        var shown: SendPatchWindowController?
        let mail = RequestPullWindowController(repository: repository, access: nil, end: "main", repositoryURL: remote.path, preferences: prefs, mailPresentation: { shown = $0 as? SendPatchWindowController })
        defer { mail.close() }; mail.window!.alphaValue = 0; mail.window!.appearance = NSAppearance(named: .darkAqua); mail.showWindow(nil)
        try await wait { !mail.model.busy }; mail.model.start = first; mail.model.sendMail = true; mail.model.create()
        try await wait { !mail.model.busy && !mail.model.hasPendingWork && !mail.model.waitingForHandoff && mail.waitingController == nil && shown != nil }
        let mailFile = mail.model.document!; defer { try? FileManager.default.removeItem(at: mailFile.deletingLastPathComponent()) }
        try check(mail.model.composingMail && shown!.window!.alphaValue == 0 && shown!.window!.appearance == mail.window!.appearance && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Mail ownership/theme/Quit gate lost")
        let owned = shown!; var submitted = false; owned.model.onSubmit = { _ in submitted = true }
        mail.close(); owned.model.to = "qa@example.invalid"; owned.model.submit()
        try await wait { mail.model.isRetired && !mail.model.hasPendingWork && !mail.model.composingMail && mail.waitingController == nil && mail.window!.attachedSheet == nil && !owned.window!.isVisible }
        try check(!mail.model.composingMail && mail.model.isRetired && !submitted && !owned.window!.isVisible, "Forced owner failed to retire mail options")

        // Drive the actual repository authorization/adoption dispatcher, not only URL decoding.
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false })
        workspace.requiresRepositoryScope = false; workspace.notifyFinder = {}; workspace.open(root)
        defer { workspace.stopMonitoringForTermination() }
        try await wait { !workspace.busy && workspace.root != nil }
        var invoked: RequestPullWindowController?
        workspace.makeRequestPull = { repository, access, end, url in RequestPullWindowController(repository: repository, access: access, end: end, repositoryURL: url, preferences: prefs) }
        workspace.requestPullPresentation = { child in invoked = child; child.window!.alphaValue = 0 }
        let link = FinderRequest(action: .requestPull, paths: [root], requestPullEnd: "feature/雪", requestPullURL: "ssh://host/space &?#/雪.git").url!
        workspace.handle(link); try await wait { !workspace.busy && invoked != nil && invoked?.model.busy == false }
        try check(invoked!.model.end == "feature/雪" && invoked!.model.repositoryURL == "ssh://host/space &?#/雪.git" && invoked!.model.access != nil && invoked!.model.document == nil, "Authorized URL dispatch lost editable command presets or generated without OK")
        invoked!.close(); invoked = nil

        let wrapper = root.appendingPathComponent("controlled-git"), phase = root.appendingPathComponent("controlled-git.phase"), marker = root.appendingPathComponent("controlled-git.started")
        let quote = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        task_phase=$(cat "$0.phase" 2>/dev/null)
        for task_arg in "$@"; do
          if [ "$task_arg" = "$task_phase" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
        done
        exec \(quote) "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slowRepository = GitRepository(root: root, executable: wrapper)
        for command in ["for-each-ref", "check-ref-format", "request-pull"] {
            for forced in [false, true] {
                try Data((command == "for-each-ref" ? command : "").utf8).write(to: phase)
                let slow = RequestPullWindowController(repository: slowRepository, access: nil, end: "main", repositoryURL: remote.path, preferences: prefs)
                defer { slow.close() }; slow.window!.alphaValue = 0; slow.showWindow(nil)
                var cancellationAlert: NSAlert?
                slow.presentError = { alert, parent, reply in cancellationAlert = alert; alert.beginSheetModal(for: parent, completionHandler: reply) }
                if command != "for-each-ref" {
                    try await wait { !slow.model.busy }; try Data(command.utf8).write(to: phase)
                    slow.model.start = first; slow.model.sendMail = false; slow.model.create()
                }
                try await wait { FileManager.default.fileExists(atPath: marker.path) }
                let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                try check(pids.count == 2 && RequestPullWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Owned operation lost process/Quit lifetime")
                if forced { slow.close() }
                else if command == "request-pull" {
                    // The macOS waiting sheet owns input. Press its native Cancel
                    // button, acknowledge cancellation, then close options.
                    try check(slow.waitingWindow?.sheetParent === slow.window, "Generation did not own its native waiting window")
                    try check(slow.waitingController!.cancelButton.isEnabled && slow.waitingController!.cancelButton.keyEquivalent == "\u{1b}", "Waiting sheet Cancel/Escape unavailable")
                    slow.waitingController!.cancelButton.performClick(nil)
                    try await wait { !slow.model.busy && !slow.model.hasPendingWork && slow.waitingController == nil && cancellationAlert?.window.sheetParent === slow.window && pids.allSatisfy { kill($0, 0) != 0 } }
                    try check(slow.model.error == "User cancelled." && slow.model.document == nil && cancellationAlert!.window.defaultButtonCell === (cancellationAlert!.buttons[0].cell as? NSButtonCell), "Waiting-window Cancel lost owned default acknowledgement or published document")
                    cancellationAlert!.buttons[0].performClick(nil)
                    try await wait { slow.errorWindow == nil && !slow.model.confirmingError && slow.window!.attachedSheet == nil }
                    slow.window!.performClose(nil)
                } else { slow.window!.performClose(nil) }
                try await wait { !slow.model.busy && !slow.model.hasPendingWork && slow.model.isRetired && slow.waitingController == nil && slow.window!.attachedSheet == nil && pids.allSatisfy { kill($0, 0) != 0 } }
                try check(slow.model.document == nil && (forced ? slow.model.error == nil : true), "Closed operation published a request/error")
                try FileManager.default.removeItem(at: marker)
            }
        }
        try Data("for-each-ref".utf8).write(to: phase)
        let denied = RequestPullWindowModel(repository: slowRepository, access: nil, preferences: prefs, end: "main", repositoryURL: remote.path)
        denied.requiresRepositoryScope = true; denied.load(); try await wait { !denied.busy }
        try check(denied.references.isEmpty && denied.error == RepositoryAccessFailure.securityScopeUnavailable.localizedDescription, "Unsigned repository scope permitted load")
        try Data("check-ref-format".utf8).write(to: phase)
        denied.start = first; denied.create(); try await wait { !denied.busy }
        try check(denied.document == nil && denied.error == RepositoryAccessFailure.securityScopeUnavailable.localizedDescription && !FileManager.default.fileExists(atPath: marker.path), "Unsigned repository scope permitted generation")
        denied.invalidate()
        try check(try await repository.run(["rev-parse", "HEAD"]).stdout == head && Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: root.appendingPathComponent(".git/config")) == config, "Read-only workflow changed HEAD/index/config")
        try check(RequestPullWindowModel.activeOperations == 0 && !NSApp.windows.contains { $0.isVisible }, "Owned Request Pull work/windows remain")
        print("PASS Request Pull lifecycle: real Start Log, captured/stale/duplicate/Cancel/refused/retired choices, inherited themes, actual document fallback, forced mail retirement, authorized URL preset dispatch, scope denial, all read/validation/generation close phases and reaped helpers; HEAD/index/config unchanged. No editor, SMTP, Apple Mail or Finder activated.")
    }
}
