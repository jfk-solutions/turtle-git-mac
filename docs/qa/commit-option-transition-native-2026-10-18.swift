// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum CommitOptionTransitionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2600 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Commit options did not settle at \(line)")
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func drained() -> Bool {
        CommitWindowModel.activeMetadataOperations == 0 && CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeCommitPreflights == 0 && CommitWindowModel.activeFileOperations == 0 && CommitWindowModel.activePreferenceOperations == 0 && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Option QA"), ("user.email", "option@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("tgit.commitstagingsupport", "false")] { _ = try await repo.run(["config", key, value]) }
        for path in ["first", "second"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["first", "second"]); _ = try await repo.commit(message: "Original HEAD message")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout
        try Data("staged content\n".utf8).write(to: root.appendingPathComponent("first")); try await repo.stage(["first"])
        try Data("working content\n".utf8).write(to: root.appendingPathComponent("second"))
        let patch = try await repo.run(["diff", "--cached", "--binary"]).stdout, first = try Data(contentsOf: root.appendingPathComponent("first")), second = try Data(contentsOf: root.appendingPathComponent("second"))
        let suite = "TurtleGit.CommitOptions." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "HintStagingMode"); prefs.set(false, forKey: "EnableGravatar"); prefs.set(true, forKey: "AddBeforeCommit")
        let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs), model = owner.model, window = owner.window!
        var metadataModel: CommitWindowModel?
        var held: CheckedContinuation<String?, Error>?, heldToken: OperationCancellation?
        defer { held?.resume(throwing: OperationCancellationFailure.cancelled); metadataModel?.invalidateForClose(); owner.close(); prefs.removePersistentDomain(forName: suite) }
        do {
            window.alphaValue = 0; window.orderFront(nil); model.reload()
            try await wait { !model.busy && model.entries.count == 2 && !model.savingPreferences }
            window.contentView?.layoutSubtreeIfNeeded()
            var probes = views(window.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }
            try require(!probes.isEmpty, "Production file-list native interaction missing")
            let files = model.entries, checked = model.checked, receipt = model.fileMenu(model.entries.map(\.id))
            model.message = "normal draft"; model.messageOnly = true
            try await wait { probes.allSatisfy { !$0.enabled } }
            try require(!model.fileListAvailable && model.canCommit && !model.canReceiveFileDrop, "Message-only mode disabled commit or retained file-list/drop ownership")
            model.checkAll(false); model.setGroupChecked(files, checked: false)
            model.setFileChecked(files[0], files: files, highlighted: files.map(\.id), checked: false)
            for probe in probes { probe.toggleCheck(files, files[0]) }
            var dispatched = false
            model.withFileMenu(receipt) { dispatched = true }
            try require(model.checked == checked && !dispatched, "Suspended classic list accepted old inclusion/menu/Space callback")
            model.messageOnly = false
            try await wait { probes.contains { $0.enabled } }
            model.withFileMenu(receipt) { dispatched = true }
            try require(!dispatched, "Message-only away/back revived a stale file menu")
            model.setStagingEnabled(true)
            try await wait { !model.busy && !model.savingPreferences && model.stagingEnabled && !model.stagingHintVisible }
            window.contentView?.layoutSubtreeIfNeeded(); probes = views(window.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }
            try require(!probes.isEmpty, "Staging native interaction missing")
            let stagedReceipt = model.fileMenu(model.entries.map(\.id)), stagedBytes = try Data(contentsOf: root.appendingPathComponent(".git/index"))
            model.messageOnly = true
            try await wait { probes.allSatisfy { !$0.enabled } }
            model.moveToStage(files.map(\.id), staged: false); model.checkAll(false); model.setGroupChecked(files, checked: false)
            for probe in probes { probe.toggleCheck(files, files[0]) }
            model.withFileMenu(stagedReceipt) { dispatched = true }
            try require(!dispatched && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == stagedBytes, "Suspended staging list modified the index")
            model.messageOnly = false; model.setStagingEnabled(false)
            try await wait { !model.busy && !model.savingPreferences && !model.stagingEnabled }
            // The actual native revision picker inherits private settings and hidden ownership.
            guard let editor = owner.messageEditor() else { throw Failure(description: "Commit editor missing") }
            model.pickRevision(false) { _ in }
            try await wait { window.attachedSheet?.delegate is LogWindowController }
            let picker = window.attachedSheet!.delegate as! LogWindowController
            try require(picker.window?.alphaValue == 0 && picker.model.colorPreferences === prefs, "Message picker escaped hidden/private settings")
            picker.close(); try await wait { !owner.hasMessagePicker && !model.busy }
            _ = editor // Retain the real editor through subsequent native onChange transitions.
            // Use the production metadata model without a view for injected
            // failures; this avoids opening a diagnostic sheet on the desktop.
            let metadata = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
            metadataModel = metadata; metadata.reload()
            try await wait { !metadata.busy && metadata.entries.count == 2 }
            metadata.message = "normal draft"
            let originalRead = metadata.queryAmendMessage
            metadata.queryAmendMessage = { _ in throw Failure(description: "injected HEAD message failure") }
            metadata.amend = true; metadata.amendChanged()
            try await wait { metadata.amendMessageReadFailed && !metadata.loadingAmendMessage }
            try require(!metadata.canCommit && metadata.message == "normal draft", "Failed amend read enabled a commit with unrelated normal draft")
            metadata.error = nil; metadata.amend = false; metadata.amendChanged()
            try await wait { !metadata.busy && !metadata.amendMessageReadFailed && metadata.message == "normal draft" }
            metadata.queryAmendMessage = { token in heldToken = token; return try await withCheckedThrowingContinuation { held = $0 } }
            metadata.amend = true; metadata.amendChanged(); try await wait { held != nil && metadata.loadingAmendMessage }
            metadata.amend = false; metadata.amendChanged(); try await wait { heldToken?.isCancelled == true && !metadata.busy }
            try require(CommitWindowModel.activeMetadataOperations > 0, "Cancelled amend read lost actual ownership")
            held?.resume(returning: "late message"); held = nil
            try await wait { CommitWindowModel.activeMetadataOperations == 0 }
            try require(metadata.message == "normal draft" && !metadata.amendMessageReadFailed, "Late amend reply replaced the normal draft or failure state")
            metadata.queryAmendMessage = originalRead; metadata.amend = true; metadata.amendChanged()
            try await wait { !metadata.busy && !metadata.loadingAmendMessage && metadata.message.contains("Original HEAD message") && CommitWindowModel.activeMetadataOperations == 0 }
            metadata.message = "Amended option family message"; metadata.amend = false; metadata.amendChanged()
            try await wait { !metadata.busy && metadata.message == "normal draft" }
            metadata.amend = true; metadata.amendChanged()
            try await wait { !metadata.busy && metadata.message == "Amended option family message" && CommitWindowModel.activeMetadataOperations == 0 }
            metadata.invalidateForClose(); metadataModel = nil
            model.amend = true
            try await wait { !model.busy && !model.loadingAmendMessage && model.message.contains("Original HEAD message") && CommitWindowModel.activeMetadataOperations == 0 }
            model.message = "Amended option family message"
            model.messageOnly = true; try require(model.canCommit, "Recovered amend draft remained disabled")
            let beforeCommitPatch = try await repo.run(["diff", "--cached", "--binary"]).stdout
            try require(!patch.isEmpty && beforeCommitPatch == patch, "Option/list transitions changed the pre-existing staged modification before Commit")
            model.commit(.commit)
            try await wait { window.attachedSheet?.delegate is CommitProgressWindowController }
            let progress = window.attachedSheet!.delegate as! CommitProgressWindowController
            try require(progress.window?.alphaValue == 0, "Actual progress sheet appeared outside hidden owner")
            try await wait { !progress.model.busy }
            try require(progress.model.success, "Real message-only amend failed: " + progress.model.output)
            progress.model.choose(nil)
            try await wait { !model.messageFocusAvailable && drained() }
            let newHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            let finalMessage = try await repo.run(["log", "-1", "--format=%B"]).text
            let finalTree = try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, finalPatch = try await repo.run(["diff", "--cached", "--binary"]).stdout
            let firstIndex = try await repo.run(["show", ":first"]).stdout, secondIndex = try await repo.run(["show", ":second"]).stdout
            try require(newHead != head && finalMessage.contains("Amended option family message"), "Real amend lost accepted message")
            // Classic Message only follows source unchecked-row preparation:
            // displayed tracked modifications are reset in the index to HEAD.
            // This differs from merely toggling the option or using staging mode.
            try require(finalTree == tree && finalPatch.isEmpty && firstIndex == Data("base\n".utf8) && secondIndex == Data("base\n".utf8), "Classic Message-only amend changed the committed tree or failed source in-scope index normalization; treeEqual=\(finalTree == tree), cachedPatchBytes=\(finalPatch.count), firstIndex=\(String(decoding: firstIndex, as: UTF8.self)), secondIndex=\(String(decoding: secondIndex, as: UTF8.self))")
            try require(try Data(contentsOf: root.appendingPathComponent("first")) == first && Data(contentsOf: root.appendingPathComponent("second")) == second, "Option transitions changed working files")
            print("PASS: source Message-only classic/staging suspension, stale native callbacks, private hidden message/progress children, amend failure/retry/draft/cancel ownership and real message-only amend with preserved tree/working input and source in-scope index normalization")
        } catch {
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            metadataModel?.invalidateForClose(); owner.close(); try? await wait { drained() }; throw error
        }
    }
}
