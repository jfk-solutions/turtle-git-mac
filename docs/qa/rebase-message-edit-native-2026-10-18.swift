// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum RebaseMessageEditVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    // Git versions spell UTC as either Z or +00:00. Preserve every other
    // offset and the complete timestamp; equal instants alone are insufficient.
    static func sameAuthorDate(_ actual:String?,_ expected:String)->Bool {
        guard let actual else{return false}
        let pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$"
        guard actual.range(of:pattern,options:.regularExpression) != nil,expected.range(of:pattern,options:.regularExpression) != nil else{return false}
        let parser=ISO8601DateFormatter()
        guard let actualInstant=parser.date(from:actual),let expectedInstant=parser.date(from:expected),actualInstant==expectedInstant else{return false}
        func utcSpelling(_ value:String)->String {value.hasSuffix("+00:00") ? String(value.dropLast(6))+"Z":value}
        func roundTrips(_ value:String,_ instant:Date)->Bool {
            var seconds=0
            if !value.hasSuffix("Z") {
                let suffix=String(value.suffix(6))
                guard let hours=Int(suffix.dropFirst().prefix(2)),let minutes=Int(suffix.suffix(2)),hours<24,minutes<60 else{return false}
                seconds=(hours*3600+minutes*60)*(suffix.first=="-" ? -1:1)
            }
            guard let zone=TimeZone(secondsFromGMT:seconds) else{return false}
            let formatter=ISO8601DateFormatter();formatter.timeZone=zone
            return utcSpelling(formatter.string(from:instant))==utcSpelling(value)
        }
        return utcSpelling(actual)==utcSpelling(expected) && roundTrips(actual,actualInstant) && roundTrips(expected,expectedInstant)
    }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Replay message editing did not settle at \(line)")
    }
    static func drained() -> Bool { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 && RebaseWindowModel.activeReplayOperations == 0 && CommitWindowModel.activeMetadataOperations == 0 && CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeCommitPreflights == 0 && CommitWindowModel.activeFileOperations == 0 && CommitWindowModel.activePreferenceOperations == 0 }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let editor = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_EDITOR"] ?? FileManager.default.currentDirectoryPath + "/build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Message QA"), ("user.email", "messages@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        var authoredSecond=0
        func commit(_ path: String) async throws -> LogEntry {
            let date="2001-02-03T04:05:0\(authoredSecond)Z";authoredSecond += 1
            try Data((path + "\n").utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
            _ = try await repo.run(["commit","-m",path],environmentOverrides:["GIT_AUTHOR_DATE":date,"GIT_COMMITTER_DATE":date])
            return try await repo.rebaseCommit("HEAD")
        }
        _ = try await commit("base"); _ = try await repo.run(["switch", "-c", "source"])
        let first = try await commit("first"), second = try await commit("second")
        let firstDate="2001-02-03T04:05:01Z"
        try require(sameAuthorDate(first.date,firstDate),"Authored UTC witness lost its fixed original date/offset")
        _ = try await repo.run(["switch", "main"])
        var plan = try await repo.cherryPickPlan(revisions: [second.hash, first.hash]); plan.options.addCherryPickedFrom = true
        for index in plan.entries.indices { plan.entries[index].action = .edit }
        let paused = try await repo.startRebase(plan, editorExecutable: editor)
        try require(paused.state.isEditPause && paused.state.isCherryPick, "Advanced Cherry Pick did not pause for Edit")
        let suite = "TurtleGit.ReplayMessageEdit." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "Gravatar"); prefs.set(false, forKey: "StagingSupport")
        var owners: [RebaseWindowController] = []
        defer { owners.forEach { $0.close() }; prefs.removePersistentDomain(forName: suite) }
        func open() async throws -> RebaseWindowController {
            let owner = RebaseWindowController(repository: repo, access: nil, preferences: prefs); owners.append(owner)
            owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(NSPoint(x: -2400, y: -2400)); owner.window?.orderFront(nil)
            owner.model.editorExecutable = editor; owner.model.load()
            try await wait { !owner.model.busy && owner.model.state?.isEditPause == true && drained() }
            return owner
        }
        do {
            let initial = try await open(), initialModel = initial.model
            if !(initialModel.amendMessage.contains("cherry picked from commit " + first.hash) && initialModel.replayMessageCommit?.author == first.author && sameAuthorDate(initialModel.replayMessageCommit?.date,firstDate)) {
                print("Initial Edit attribution diagnostic: message=\(String(reflecting: initialModel.amendMessage)), expectedTrailerOID=\(String(reflecting: first.hash))")
                print("Initial Edit metadata diagnostic: expectedAuthor=\(String(reflecting: first.author)), actualAuthor=\(String(reflecting: initialModel.replayMessageCommit?.author)), expectedDate=\(String(reflecting: firstDate)), originalGitDate=\(String(reflecting: first.date)), actualDate=\(String(reflecting: initialModel.replayMessageCommit?.date)), appliedCommit=\(String(reflecting: initialModel.replayMessageCommit?.hash))")
                if let state = initialModel.state {
                    print("Initial Edit state diagnostic: active=\(state.active), editPause=\(state.isEditPause), cherryPick=\(state.isCherryPick), stoppedCommit=\(String(reflecting: state.stoppedCommit)), stoppedEntryID=\(String(reflecting: state.stoppedEntryID)), originalHead=\(String(reflecting: state.originalHead)), onto=\(String(reflecting: state.onto)), step=\(state.currentStep)/\(state.total), session=\(String(reflecting: state.session))")
                } else { print("Initial Edit state diagnostic: state=nil") }
            }
            try require(initialModel.amendMessage.contains("cherry picked from commit " + first.hash) && initialModel.replayMessageCommit?.author == first.author && sameAuthorDate(initialModel.replayMessageCommit?.date,firstDate), "Edit lost applied attribution/author/date")
            let draft = "Approved first\n\n(cherry picked from commit " + first.hash + ")\n"
            let binding = initialModel.messageBinding(initialModel.formContext), editorID = initialModel.replayMessageEditorID
            binding.wrappedValue = draft; initialModel.refreshState()
            try await wait { !initialModel.busy && drained() }
            try require(initialModel.amendMessage == draft && initialModel.replayMessageEditorID == editorID, "Same stopped phase refresh replaced draft or reset undo identity")
            initial.close(); try await wait { drained() }
            let owner = try await open(), model = owner.model
            let restoredDraft = model.amendMessage == draft, restoredAttribution = model.options.addCherryPickedFrom, editable = model.canEditMessage
            print("Reopened Edit: draft=\(restoredDraft), attribution=\(restoredAttribution), editable=\(editable), savedAttribution=\(String(describing: model.state?.session?.addCherryPickedFrom))")
            try require(restoredDraft && restoredAttribution && editable, "Reopened Edit did not recover stopped-phase draft/options: draft=\(restoredDraft), attribution=\(restoredAttribution), editable=\(editable)")
            let stoppedHead = try await repo.rebaseCommit("HEAD")
            try Data("amended first content\n".utf8).write(to: root.appendingPathComponent("first"))
            var selection: CommitWindowModel?
            model.configureCommitSelection = { selection = $0 }
            model.request("continue")
            try await wait { selection != nil && selection?.canCommit == true && model.selectingSplit && !model.preparingMessageSelection }
            let cancelled = selection!
            try require(cancelled.amend && cancelled.amendDiffToLastCommit && cancelled.replaySplit?.conflictRecovery == true && cancelled.message == draft && owner.window?.attachedSheet?.alphaValue == 0, "Dirty Edit did not open the owned hidden checked-amend dialog")
            cancelled.close(); try await wait { !model.selectingSplit && !model.busy && drained() }
            let cancelledState = try await repo.rebaseState(), cancelHead = try await repo.rebaseCommit("HEAD")
            try require(cancelledState.split == nil && cancelledState.isEditPause && cancelHead.hash == stoppedHead.hash && model.amendMessage == draft, "Cancelling first amend selection changed HEAD or discarded draft")
            selection = nil; model.request("continue")
            try await wait { selection?.canCommit == true && model.selectingSplit }
            let accepted = selection!; accepted.checked = ["first"]; accepted.message = draft; accepted.commit(.commit)
            try await wait { !model.selectingSplit && !model.busy && drained() }
            let amended = try await repo.rebaseCommit("HEAD")
            try require(model.state?.isEditPause == true && amended.subject == "Approved first" && amended.parents == stoppedHead.parents && amended.author == first.author && sameAuthorDate(amended.date,firstDate) && model.replayMessageCommit?.hash == amended.hash, "Checked amendment lost topology, author/date or refreshed message context")
            let firstEditorID = model.replayMessageEditorID, stale = model.messageBinding(model.formContext)
            model.request("continue")
            try await wait { !model.busy && model.state?.stoppedCommit == second.hash && model.state?.isEditPause == true && drained() }
            try require(model.amendMessage.contains("cherry picked from commit " + second.hash) && !model.amendMessage.contains("Approved first") && model.replayMessageEditorID != firstEditorID, "Next occurrence reused prior draft/undo/attribution")
            let secondMessage = model.amendMessage; stale.wrappedValue = "stale first edit"
            try require(model.amendMessage == secondMessage, "Retired message binding edited the next occurrence")
            model.messageBinding(model.formContext).wrappedValue = ""; model.refreshState(); try await wait { !model.busy && drained() }
            try require(model.amendMessage.isEmpty, "Empty editable draft was replaced by original commit text")
            model.messageBinding(model.formContext).wrappedValue = "Approved second\n\n(cherry picked from commit " + second.hash + ")\n"
            model.request("continue"); try await wait { !model.busy && model.finished && drained() }
            let final = try await repo.rebaseCommit("HEAD"), messages = try await repo.run(["log", "--format=%s", "main~2..main"]).text
            try require(!model.active && final.subject == "Approved second" && messages == "Approved second\nApproved first\n" && prefs.data(forKey: "Rebase.MessageDraft." + root.standardizedFileURL.path) == nil, "Completed replay retained draft or lost approved messages")
            owner.close(); try await wait { drained() }
            print("PASS: Advanced Cherry Pick applied attribution/author/date, refresh/reopen message drafts, hidden dirty Edit amend cancel/accept, author/topology preservation, next occurrence undo/binding retirement, empty draft and completion cleanup")
        } catch {
            owners.forEach { $0.close() }; try? await wait { drained() }
            _ = try? await repo.abortRebase()
            throw error
        }
    }
}
