// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import SwiftUI
import TurtleGitCore

actor PrivateIssueCredentials: IssueProviderCredentialStore {
    private var values: [String: String] = [:]
    private(set) var writes = 0
    func token(for endpoint: URL) async throws -> String? { values[endpoint.absoluteString] }
    func setToken(_ token: String?, for endpoint: URL) async throws {
        writes += 1; values[endpoint.absoluteString] = token
    }
}
@MainActor @main enum NativeIssueProviderVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: UInt = #line) throws { if !value { throw Failure(description: "\(line): \(message)") } }
    static func wait(_ message: String, line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "\(line): native provider timeout: \(message)")
    }
    static func ready(_ model: CommitWindowModel) -> Bool {
        !model.busy && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage && model.changelistsLoaded
    }
    @MainActor final class Context {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), endpoint = URL(string: CommandLine.arguments[3])!, control = URL(fileURLWithPath: CommandLine.arguments[4]), receipts = URL(fileURLWithPath: CommandLine.arguments[5])
        let secret = ProcessInfo.processInfo.environment["TURTLEGIT_PRIVATE_PROVIDER_TOKEN"]!
        let suite: String, preferences: UserDefaults
        let credentials = PrivateIssueCredentials()
        var owners: [NSWindowController] = []
        init() { suite = "TurtleGit.NativeIssueProvider.QA." + UUID().uuidString; preferences = UserDefaults(suiteName: suite)!; preferences.set(0, forKey: "AutoCloseGitProgress"); DialogGeometry.install(preferences: preferences) }
        var parameters: String { String(data: try! JSONSerialization.data(withJSONObject: ["endpoint": endpoint.absoluteString, "linkText": "Private issues…"], options: [.sortedKeys]), encoding: .utf8)! }
        func state(_ value: [String: Any]) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: control, options: .atomic) }
        func requests(_ action: String) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: receipts) else { return [] }
            return data.split(separator: 10).compactMap { line in
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let body = record["body"] as? [String: Any], body["action"] as? String == action else { return nil }
                return record
            }
        }
        func track<T: NSWindowController>(_ value: T) -> T { owners.append(value); value.window?.alphaValue = 0; value.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); value.showWindow(nil); return value }
        func repository(_ name: String) async throws -> GitRepository {
            let directory = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repository = GitRepository(root: directory, executable: git)
            _ = try await repository.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Native provider QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("tgit.commitstagingsupport", "false")] { _ = try await repository.run(["config", key, value]) }
            try Data("base\n".utf8).write(to: directory.appendingPathComponent("tracked.txt")); try await repository.stage(["tracked.txt"]); _ = try await repository.commit(message: "baseline")
            try Data("selected change\n".utf8).write(to: directory.appendingPathComponent("tracked.txt")); return repository
        }
        func association(_ repository: GitRepository) throws {
            try NativeIssueAssociations.save([NativeIssueAssociation(path: repository.root.path, provider: "org.turtlegit.issue-http", parameters: parameters)], to: preferences)
        }
        func commitOwner(_ repository: GitRepository) -> CommitWindowController {
            let value = CommitWindowController(repository: repository, access: nil, defaults: preferences)
            value.model.issueProviderCredentials = credentials
            return track(value)
        }
        func prepare(_ owner: CommitWindowController, message: String = "Native provider commit") async throws {
            owner.model.reload(paths: ["tracked.txt"]); try await wait("Commit reload") { ready(owner.model) }
            owner.model.message = message; owner.model.checked = ["tracked.txt"]
            try await wait("Commit ready") { owner.model.canCommit }
        }
        func privacy() throws {
            func containsSecret(_ value: Any) -> Bool {
                if let value = value as? String { return value.contains(secret) }
                if let value = value as? Data { return value.range(of: Data(secret.utf8)) != nil }
                if let value = value as? [String: Any] { return value.values.contains { containsSecret($0) } }
                if let value = value as? [Any] { return value.contains { containsSecret($0) } }
                return false
            }
            try require(!(preferences.persistentDomain(forName: suite) ?? [:]).values.contains { containsSecret($0) }, "provider credential leaked to preferences/archive")
            let log = try Data(contentsOf: receipts)
            try require(!String(decoding: log, as: UTF8.self).contains(secret), "provider credential leaked to HTTP body/receipts")
        }
        func cleanup() async {
            try? state([:]); owners.forEach { $0.close() }
            for window in NSApp.windows { if let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }; window.close(); window.orderOut(nil) }
            for _ in 0..<3000 { if CommitWindowModel.activeIssueProviderOperations == 0 && IssueProviderPickerModel.activeOperations == 0 && CommitWindowModel.activeCommitPreflights == 0 && CommitWindowModel.activeReloads == 0 && IssueProviderCredentialEditorModel.activeReads == 0 && IssueProviderCredentialDrafts.activeOperations == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            preferences.removePersistentDomain(forName: suite); DialogGeometry.install(preferences: .standard)
        }
    }
    static func run(_ body: (Context) async throws -> Void) async throws {
        let context = Context()
        do { try await body(context); try context.privacy(); await context.cleanup(); try require(CommitWindowModel.activeIssueProviderOperations == 0 && IssueProviderPickerModel.activeOperations == 0 && CommitWindowModel.activeCommitPreflights == 0 && CommitWindowModel.activeReloads == 0 && IssueProviderCredentialEditorModel.activeReads == 0 && IssueProviderCredentialDrafts.activeOperations == 0, "native provider operations did not drain") }
        catch { await context.cleanup(); throw error }
    }
    static func settings() async throws { try await run { context in
        let repository = try await context.repository("settings")
        let host = context.track(NSWindowController(window: NSWindow(contentRect: NSRect(x: 0,y: 0,width: 850,height: 550), styleMask: [.titled,.closable], backing: .buffered, defer: false)))
        let model = IssueProviderSettingsModel(preferences: context.preferences, credentialStore: context.credentials)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        host.window?.contentViewController = NSHostingController(rootView: IssueProviderSettingsPage(workspace: workspace, preferences: context.preferences, model: model))
        host.window?.contentView?.layoutSubtreeIfNeeded(); model.window = host.window
        defer { workspace.stopMonitoringForTermination() }
        @MainActor func add(secret: Bool) async throws -> IssueProviderAssociationEditor {
            model.add(root: repository.root)
            guard let editor = model.editor else { throw Failure(description: "Missing native association editor") }
            editor.model.row.provider = "org.turtlegit.issue-http"; editor.model.row.parameters = context.parameters
            if secret {
                editor.editCredentials()
                guard let credential = editor.credentialEditor else { throw Failure(description: "Missing native credential editor") }
                try await wait("credential read") { !credential.model.loading }
                try require(credential.model.secret.isEmpty && !credential.model.stored, "New credential exposed a secret")
                credential.model.secret = context.secret; try require(credential.model.canSave, "Valid private credential refused")
                credential.model.save(); try await wait("credential draft close") { editor.credentialEditor == nil }
            }
            return editor
        }
        let cancelled = try await add(secret: true); cancelled.model.cancel()
        try await wait("association cancel") { !model.hasChild }
        let zeroWrites = await context.credentials.writes
        try require(model.rows.isEmpty && !model.credentials.modified && zeroWrites == 0, "Association Cancel published credentials or rows")
        let accepted = try await add(secret: true); accepted.model.accept()
        try await wait("association accept") { !model.hasChild }
        let beforeApply = await context.credentials.writes
        try require(model.rows.count == 1 && model.modified && beforeApply == 0, "Association OK wrote credentials before Settings Apply")
        let applied = await model.applySettings(), token = try await context.credentials.token(for: context.endpoint)
        try require(applied && token == context.secret && !model.modified, "Settings Apply failed atomic credential/association publication")
        let savedID = model.rows[0].id; model.selection = [savedID]; model.edit()
        guard let edited = model.editor else { throw Failure(description: "Missing Edit child") }
        edited.editCredentials(); guard let credential = edited.credentialEditor else { throw Failure(description: "Missing stored credential child") }
        try await wait("stored credential read") { !credential.model.loading }
        try require(credential.model.stored && credential.model.secret.isEmpty, "Stored bearer was copied into native text field")
        credential.model.secret = "discarded-private-replacement"; credential.model.save()
        try await wait("replacement draft") { edited.credentialEditor == nil }
        edited.model.accept(); try await wait("edit close") { !model.hasChild }; model.cancel()
        let retained = try await context.credentials.token(for: context.endpoint)
        try require(retained == context.secret && !model.modified, "Settings Cancel wrote a replacement credential")
        model.selection = [savedID]; model.edit(copy: true)
        guard let copied = model.editor else { throw Failure(description: "Missing Copy child") }
        try require(copied.model.row.id != savedID && copied.model.row.parameters == context.parameters, "Copy lost provider parameters or reused row identity")
        let copyRoot = context.root.appendingPathComponent("copy"); try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        copied.model.row.path = copyRoot.path; copied.model.accept()
        try await wait("copy close") { !model.hasChild }
        try require(model.rows.count == 2 && model.modified, "Copy did not create a separate draft association")
        model.cancel(); try require(model.rows.count == 1 && model.rows[0].id == savedID, "Settings Cancel retained copied draft")
        model.retire()
        // The retained offline provider follows the same generic Session and
        // actual Commit-owned picker path, without any HTTP requests.
        let catalogParameters = #"{"linkText":"Offline tickets","messageTemplate":"Ticket: %BUGID%","requireIssue":true,"issues":[{"id":"2","summary":"Second"},{"id":"1","summary":"First 雪"}]}"#
        try NativeIssueAssociations.save([NativeIssueAssociation(path: repository.root.path, provider: NativeIssueCatalogProvider.identifier, parameters: catalogParameters)], to: context.preferences)
        let immediate = context.track(IssueProviderPickerController(provider: try NativeIssueCatalogProvider(parameters: catalogParameters), context: NativeIssueProviderContext(repositoryRoot: repository.root, paths: ["tracked.txt"], message: "immediate", issueID: "1")) { _ in })
        try require(immediate.model.loaded && immediate.model.loadedIssues.map(\.id) == ["2", "1"] && immediate.model.selected == ["1"], "Legacy offline picker lost immediate catalog/selection loading")
        immediate.finish(nil); try await wait("immediate catalog close") { !immediate.hasPendingWork }
        let catalogOwner = context.commitOwner(repository); try await context.prepare(catalogOwner, message: "Offline body")
        try require(catalogOwner.model.nativeIssueProvider != nil, "Retained catalog failed generic Session construction")
        let beforeHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let beforeIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        catalogOwner.model.commit(); try await wait("offline required issue refusal") { !catalogOwner.model.busy && catalogOwner.model.error != nil }
        let refusedHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let refusedIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        try require(beforeHead == refusedHead && beforeIndex == refusedIndex && catalogOwner.model.commitProgress == nil, "Offline required-issue check mutated Git before picker selection")
        catalogOwner.model.error = nil
        try await wait("offline refusal alert/reload ownership settled") { ready(catalogOwner.model) && !catalogOwner.model.inputsBlocked && !catalogOwner.model.attemptWorkPending && catalogOwner.window?.attachedSheet == nil && catalogOwner.model.nativeIssueProvider != nil }
        catalogOwner.model.selectProviderIssues()
        try await wait("offline generic picker loaded") { catalogOwner.issueProviderOwner?.picker?.model.loaded == true }
        guard let offlinePicker = catalogOwner.issueProviderOwner?.picker else { throw Failure(description: "Missing offline native picker") }
        try require(offlinePicker.model.loadedIssues.map(\.id) == ["2", "1"], "Generic Session reordered offline catalog")
        offlinePicker.model.selected = ["1", "2"]; offlinePicker.model.query = "First"
        try require(offlinePicker.model.rows.map(\.id) == ["1"] && offlinePicker.model.selected == ["1", "2"], "Offline filtering discarded hidden selected IDs")
        offlinePicker.model.submit(); try await wait("offline picker result") { !catalogOwner.model.issueProviderWorkPending }
        try require(catalogOwner.model.issueID == "2,1" && catalogOwner.model.message == "Offline body\nTicket: 2,1\n", "Generic picker lost offline catalog order/message")
        catalogOwner.model.onCommitProgress = nil; catalogOwner.model.commit()
        try await wait("actual offline provider commit") { !catalogOwner.model.attemptWorkPending && !catalogOwner.model.busy }
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let committedBody = try await repository.run(["log", "-1", "--format=%B"]).text
        try require(afterHead != beforeHead && committedBody.contains("Ticket: 2,1") && committedBody.components(separatedBy: "Ticket:").count == 2 && context.requests("listIssues").isEmpty && context.requests("checkCommit").isEmpty, "Offline Commit failed, duplicated ticket text, or contacted remote provider")
    } }
    static func commit() async throws { try await run { context in
        let repository = try await context.repository("commit")
        try await context.credentials.setToken(context.secret, for: context.endpoint)
        _ = try await repository.run(["config", "turtlegit.issueprovider", "org.turtlegit.issue-http"])
        _ = try await repository.run(["config", "turtlegit.issueproviderparams", context.parameters])
        let owner = context.commitOwner(repository); try await context.prepare(owner)
        try require(owner.model.nativeIssueProvider == nil && owner.model.issueProviderError != nil && context.requests("listIssues").isEmpty, "Project configuration authorized a remote provider without a local association")
        try context.association(repository); try await context.prepare(owner)
        try require(owner.model.nativeIssueProvider != nil, "Enabled local association did not load authenticated provider")
        owner.model.selectProviderIssues()
        try await wait("actual picker HTTP list") { owner.issueProviderOwner?.picker?.model.loaded == true }
        guard let picker = owner.issueProviderOwner?.picker else { throw Failure(description: "Missing actual picker") }
        try require(picker.model.loadedIssues.count == 2, "HTTP issues did not populate native picker")
        picker.model.query = "Forty"; try require(picker.model.rows.map(\.id) == ["42"], "Native issue filtering failed")
        picker.model.query = ""; picker.model.selected = ["17", "42"]; picker.model.submit()
        try await wait("picker result") { !owner.model.issueProviderBusy && owner.issueProviderOwner?.picker == nil }
        try require(owner.model.message.contains("Provider issues: 17,42") && owner.model.issueID == "17,42", "HTTP selection failed message/issue-ID publication")
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        var progress: CommitProgressWindowModel?, presentations = 0
        let original = owner.model.onCommitProgress
        owner.model.onCommitProgress = { value in progress = value; presentations += 1; original?(value) }
        try context.state(["rejectCheck": true]); owner.model.commit()
        try await wait("provider preflight refusal") { !owner.model.busy && owner.model.error != nil }
        let refusedHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let refusedIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        try require(presentations == 0 && refusedHead == head && refusedIndex == index && context.requests("commitFinished").isEmpty && owner.issueProviderOwner?.runtimeAlert == nil && !owner.model.issueProviderAcknowledgementPending, "Provider refusal staged files, committed, presented progress or became an overridable runtime error")
        owner.model.error = nil
        try await wait("HTTP refusal alert/reload ownership settled") { ready(owner.model) && !owner.model.inputsBlocked && !owner.model.attemptWorkPending && owner.window?.attachedSheet == nil && owner.model.canCommit }
        try context.state(["holdAction": "commitFinished", "finishWarning": "Private completion warning"])
        owner.model.commit()
        try await wait("held completion receipt") { context.requests("commitFinished").count == 1 }
        let committed = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let receipt = context.requests("commitFinished").first?["body"] as? [String: Any] else { throw Failure(description: "Missing completion receipt") }
        try require(receipt["revision"] as? String == committed && committed.utf8.count == 40 && progress?.busy == true, "Completion did not capture immutable successful revision before awaiting HTTP")
        try Data("external\n".utf8).write(to: repository.root.appendingPathComponent("external.txt")); try await repository.stage(["external.txt"]); _ = try await repository.commit(message: "external advance while provider waits")
        let advanced = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(advanced != committed && receipt["revision"] as? String == committed, "Completion revision followed later HEAD")
        try context.state(["finishWarning": "Private completion warning"])
        try await wait("owned completion warning acknowledgement") { owner.issueProviderOwner?.runtimeAlert?.window.sheetParent != nil }
        owner.issueProviderOwner?.runtimeAlert?.buttons[0].performClick(nil)
        try await wait("successful progress with completion warning") { progress?.busy == false }
        guard let result = progress else { throw Failure(description: "No actual commit progress") }
        try require(result.success && result.output.contains("Private completion warning") && presentations == 1, "Completion warning changed successful commit outcome")
        result.choose(nil); try await wait("completion acknowledgement drain") { !owner.model.attemptWorkPending }
        let count = try await repository.run(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(count == "3" && finalHead == advanced && context.requests("commitFinished").count == 1, "Provider completion duplicated a commit or rewrote later HEAD")
        for action in ["listIssues", "commitMessage", "checkCommit", "commitFinished"] {
            try require(!context.requests(action).isEmpty && context.requests(action).allSatisfy { $0["authorized"] as? Bool == true }, "Actual HTTP \(action) omitted bearer authentication")
        }
    } }
    static func checkFailure() async throws { try await run { context in
        try await context.credentials.setToken(context.secret, for: context.endpoint)
        @MainActor func prepare(_ name: String) async throws -> (GitRepository, CommitWindowController) {
            let repository = try await context.repository(name)
            try context.association(repository)
            let owner = context.commitOwner(repository); try await context.prepare(owner)
            return (repository, owner)
        }
        // A transport/runtime failure is acknowledged once and continues the
        // same attempt. Actual Git and HTTP receipts prove no recursive retry.
        let (repository, owner) = try await prepare("runtime-accepted")
        let hookDirectory = repository.root.appendingPathComponent(".git/private-provider-hooks")
        try FileManager.default.createDirectory(at: hookDirectory, withIntermediateDirectories: true)
        let hook = hookDirectory.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf x >> \"$0.count\"\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await repository.run(["config", "core.hooksPath", hookDirectory.path])
        let originalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let originalIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        var progress: CommitProgressWindowModel?, presentations = 0, acknowledgements = 0
        let presentProgress = owner.model.onCommitProgress
        owner.model.onCommitProgress = { value in progress = value; presentations += 1; presentProgress?(value) }
        guard let providerOwner = owner.issueProviderOwner else { throw Failure(description: "Missing native provider owner") }
        providerOwner.presentRuntimeFailure = { parent, alert, reply in
            acknowledgements += 1
            alert.beginSheetModal(for: parent) { response in reply(response); reply(response) }
            return true
        }
        let checksBefore = context.requests("checkCommit").count, finishedBefore = context.requests("commitFinished").count
        try context.state(["checkHTTPStatus": 503]); owner.model.commit()
        try await wait("owned runtime acknowledgement") { providerOwner.runtimeAlert?.window.sheetParent === owner.window && owner.model.issueProviderAcknowledgementPending }
        try require(owner.model.busy && owner.model.attemptWorkPending && presentations == 0 && !owner.model.canCommit, "Runtime error escaped its captured preflight before acknowledgement")
        guard let alert = providerOwner.runtimeAlert else { throw Failure(description: "Missing actual runtime alert") }
        try require(alert.window.alphaValue == 0 && alert.buttons.count == 1 && alert.buttons[0].title == "OK", "Runtime acknowledgement was visible or offered an extra commit decision")
        let waitingHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let waitingIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        try require(waitingHead == originalHead && waitingIndex == originalIndex && !FileManager.default.fileExists(atPath: hook.path + ".count"), "Runtime acknowledgement staged files, committed or ran Git hooks before OK")
        alert.buttons[0].performClick(nil)
        try await wait("actual single commit after acknowledgement") { progress?.busy == false && progress?.success == true }
        let count = try await repository.run(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try await repository.run(["log", "-1", "--format=%B"]).text
        let hookCount = try Data(contentsOf: URL(fileURLWithPath: hook.path + ".count"))
        try require(count == "2" && body.contains("Native provider commit") && acknowledgements == 1 && presentations == 1 && hookCount == Data("x".utf8), "Acknowledged runtime failure repeated or changed the captured commit/hooks")
        try require(context.requests("checkCommit").count == checksBefore + 1 && context.requests("commitFinished").count == finishedBefore + 1, "Runtime acknowledgement repeated provider preflight/completion")
        try require(!String(describing: alert.informativeText).contains(context.secret), "Runtime diagnostic exposed credential")
        progress?.choose(nil)
        try await wait("accepted attempt drain") { !owner.model.attemptWorkPending }

        // Other provider phases retain their own source contracts. A picker
        // failure stays editable, while a post-success error cannot retry Git.
        let (_, pickerOwner) = try await prepare("picker-error")
        pickerOwner.model.selectProviderIssues()
        try await wait("failure-family picker loaded") { pickerOwner.issueProviderOwner?.picker?.model.loaded == true }
        guard let picker = pickerOwner.issueProviderOwner?.picker else { throw Failure(description: "Missing failure-family picker") }
        picker.model.selected = ["17"]
        let pickerDraft = pickerOwner.model.message
        try context.state(["messageError": true]); picker.model.submit()
        try await wait("picker error retained") { !picker.model.busy && picker.model.error != nil }
        try require(pickerOwner.issueProviderOwner?.picker === picker && pickerOwner.model.message == pickerDraft && picker.model.selected == ["17"] && pickerOwner.issueProviderOwner?.runtimeAlert == nil, "Message-provider failure escaped its picker or changed the draft")
        try context.state([:]); picker.model.submit()
        try await wait("picker retry applies once") { !pickerOwner.model.issueProviderBusy }
        try require(pickerOwner.model.message.components(separatedBy: "Provider issues:").count == 2, "Picker retry lost or duplicated provider text")

        for mode in ["recommit", "push", "cancel", "close", "stale"] {
            let (finishRepository, finishOwner) = try await prepare("completion-runtime-" + mode)
            var finishedProgress: CommitProgressWindowModel?, pushes = 0
            let presentFinishProgress = finishOwner.model.onCommitProgress
            finishOwner.model.onCommitProgress = { value in finishedProgress = value; presentFinishProgress?(value) }
            finishOwner.model.onPush = { _ in pushes += 1 }
            let finishChecks = context.requests("checkCommit").count, finishReceipts = context.requests("commitFinished").count
            try context.state(["finishHTTPStatus": 503])
            finishOwner.model.commit(mode == "recommit" ? .recommit : .push)
            try await wait("owned completion runtime acknowledgement " + mode) { finishOwner.issueProviderOwner?.runtimeAlert?.window.sheetParent != nil && finishOwner.model.issueProviderAcknowledgementPending }
            guard let finishAlert = finishOwner.issueProviderOwner?.runtimeAlert, let result = finishedProgress else { throw Failure(description: "Missing completion result/notice") }
            try require(finishAlert.window.sheetParent === finishOwner.window?.attachedSheet && finishAlert.window.alphaValue == 0 && result.busy, "Completion failure did not own an invisible nested progress notice")
            let completionDiagnostic = result.output
            try require(completionDiagnostic.contains("completion failed") && finishAlert.informativeText.contains("completion failed"), "Completion error was not reported before its acknowledgement: " + mode)
            switch mode {
            case "cancel": result.cancellation.cancel()
            case "close": finishOwner.close()
            case "stale": let old = finishOwner.model.message; finishOwner.model.message = "Later draft"; finishOwner.model.message = old; finishAlert.buttons[0].performClick(nil)
            default: finishAlert.buttons[0].performClick(nil)
            }
            try await wait("completion runtime attempt drains " + mode) { !finishOwner.model.attemptWorkPending && !finishOwner.model.issueProviderAcknowledgementPending }
            let finishCount = try await finishRepository.run(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let actualChecks = context.requests("checkCommit").count - finishChecks
            let actualReceipts = context.requests("commitFinished").count - finishReceipts
            // Retirement intentionally clears visible progress output. Preserve
            // the actual reported notice as the immutable pre-close witness.
            let diagnosticRetained = mode == "close" ? result.isAbandoned && result.output.isEmpty && completionDiagnostic.contains("completion failed") : result.output.contains("completion failed")
            let details = "mode=\(mode), commits=\(finishCount), success=\(result.success), busy=\(result.busy), abandoned=\(result.isAbandoned), checks=\(actualChecks), receipts=\(actualReceipts), diagnostic=\(diagnosticRetained), pushes=\(pushes)"
            try require(finishCount == "2" && result.success && diagnosticRetained && actualChecks == 1 && actualReceipts == 1, "Completion error lost Git success or repeated Git/provider work: " + details)
            try require(pushes == (mode == "push" ? 1 : 0), "Completion acknowledgement lost/repeated or authorized stale Push: " + mode)
            if mode == "recommit" {
                try await wait("ReCommit ready after acknowledged completion error") { ready(finishOwner.model) && finishOwner.model.message.isEmpty && finishOwner.model.messageFocusAvailable }
            }
        }

        // Retiring or mutating the suspended draft must never make the OK
        // callback authority for a newer commit. Include away/back mutations.
        for mode in ["message", "paths", "scope", "author", "options", "issue", "cancel", "close", "presentation"] {
            let (repository, owner) = try await prepare("runtime-" + mode)
            let head = try await repository.run(["rev-parse", "HEAD"]).stdout
            let index = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
            let before = context.requests("commitFinished").count
            var presentations = 0
            owner.model.onCommitProgress = { _ in presentations += 1 }
            guard let providerOwner = owner.issueProviderOwner else { throw Failure(description: "Missing owned provider prompt") }
            if mode == "presentation" { providerOwner.presentRuntimeFailure = { _, _, _ in false } }
            try context.state(["malformedCheck": true]); owner.model.commit()
            if mode != "presentation" {
                try await wait("runtime pending " + mode) { providerOwner.runtimeAlert?.window.sheetParent === owner.window && owner.model.issueProviderAcknowledgementPending }
                switch mode {
                case "message": let old = owner.model.message; owner.model.message = "Changed draft"; owner.model.message = old
                case "paths": let old = owner.model.checked; owner.model.checked = []; owner.model.checked = old
                case "scope": let old = owner.model.scopePaths; owner.model.scopePaths = ["other"]; owner.model.scopePaths = old
                case "author": let old = owner.model.author; owner.model.author = "Other <other@example.invalid>"; owner.model.author = old
                case "options": owner.model.messageOnly.toggle(); owner.model.messageOnly.toggle()
                case "issue": let old = owner.model.issueID; owner.model.issueID = "99"; owner.model.issueID = old
                case "cancel": owner.model.cancel(closeWindow: false)
                case "close": owner.close()
                default: break
                }
                if mode != "cancel" && mode != "close" { providerOwner.runtimeAlert?.buttons[0].performClick(nil) }
            }
            try await wait("refused runtime attempt drain " + mode) { !owner.model.attemptWorkPending && !owner.model.issueProviderAcknowledgementPending && providerOwner.runtimeAlert == nil }
            let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
            let afterIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
            try require(presentations == 0 && afterHead == head && afterIndex == index && context.requests("commitFinished").count == before, "Stale/cancelled runtime acknowledgement mutated Git: " + mode)
        }
    } }
    static func lifetime() async throws { try await run { context in
        let repository = try await context.repository("lifetime"); try context.association(repository)
        try await context.credentials.setToken(context.secret, for: context.endpoint)
        let delegate = TurtleGitApplicationDelegate()
        let owner = context.commitOwner(repository); try await context.prepare(owner, message: "Original draft")
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        owner.model.selectProviderIssues(); try await wait("picker loaded") { owner.issueProviderOwner?.picker?.model.loaded == true }
        guard let picker = owner.issueProviderOwner?.picker else { throw Failure(description: "Missing late-edit picker") }
        try context.state(["holdAction": "commitMessage"]); picker.model.selected = ["17"]; picker.model.submit()
        try await wait("held message request") { context.requests("commitMessage").count == 1 }
        owner.model.message = "Late editor change"; owner.model.issueID = "late"
        try context.state([:]); try await wait("late result drain") { !owner.model.issueProviderWorkPending }
        try require(owner.model.message == "Late editor change" && owner.model.issueID == "late", "Late provider result overwrote newer editor input")
        try context.state(["holdAction": "listIssues"]); owner.model.selectProviderIssues()
        try await wait("held list request") { context.requests("listIssues").count == 2 }
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored a held picker request")
        var closed = 0; owner.onClosed = { closed += 1 }
        owner.close()
        try require(owner.model.issueProviderWorkPending && closed == 0, "Closed owner released an outstanding picker before request drain")
        try await wait("closed picker ownership drain") { !owner.model.issueProviderWorkPending && closed == 1 }
        try context.state([:]); try await Task.sleep(nanoseconds: 50_000_000)
        try require(owner.model.message == "Late editor change" && owner.model.issueID == "late" && closed == 1, "Retired picker published after owner close")
        let checkOwner = context.commitOwner(repository); try await context.prepare(checkOwner)
        try context.state(["holdAction": "checkCommit"]); checkOwner.model.commit()
        try await wait("held preflight request") { context.requests("checkCommit").count == 1 && checkOwner.model.issueProviderPreflightPending }
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored provider preflight ownership")
        var checkClosed = 0; checkOwner.onClosed = { checkClosed += 1 }; checkOwner.close()
        try require(checkClosed == 0 && checkOwner.model.attemptWorkPending, "Closed Commit released held provider preflight immediately")
        try await wait("preflight cancellation drain") { !checkOwner.model.attemptWorkPending && checkClosed == 1 }
        try context.state([:]); try await Task.sleep(nanoseconds: 50_000_000)
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: repository.root.appendingPathComponent(".git/index"))
        try require(head == afterHead && index == afterIndex && context.requests("commitFinished").isEmpty && checkOwner.model.commitProgress == nil, "Cancelled provider preflight mutated Git or continued after retirement")
        let completionRepository = try await context.repository("completion-cancel"); try context.association(completionRepository)
        let completionOwner = context.commitOwner(completionRepository); try await context.prepare(completionOwner)
        var completionProgress: CommitProgressWindowModel?
        let present = completionOwner.model.onCommitProgress
        completionOwner.model.onCommitProgress = { value in completionProgress = value; present?(value) }
        try context.state(["holdAction": "commitFinished"]); completionOwner.model.commit()
        try await wait("held completion cancellation") { context.requests("commitFinished").count == 1 && completionProgress?.busy == true }
        let successfulHead = try await completionRepository.run(["rev-parse", "HEAD"]).stdout
        guard let completionProgress else { throw Failure(description: "Missing completion progress") }
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored held successful completion")
        completionProgress.cancel()
        try await wait("HTTP completion cancellation") { !completionProgress.busy }
        try require(completionProgress.success && !completionProgress.cancelled && completionProgress.output.contains("completion"), "Cancelled provider completion misreported an existing successful commit as Git failure")
        completionProgress.choose(nil); try await wait("cancelled completion acknowledgement") { !completionOwner.model.attemptWorkPending }
        try context.state([:])
        let retainedHead = try await completionRepository.run(["rev-parse", "HEAD"]).stdout
        let commitCount = try await completionRepository.run(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(retainedHead == successfulHead && commitCount == "2" && context.requests("commitFinished").count == 1, "Cancelling provider completion duplicated or removed actual Git commit")
    } }
    static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitIssueProviderOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden); defer { method_exchangeImplementations(original, hidden) }
        switch ProcessInfo.processInfo.environment["TURTLEGIT_NATIVE_PROVIDER_CASE"] {
        case "settings": try await settings()
        case "commit": try await commit()
        case "lifetime": try await lifetime()
        case "check-failure": try await checkFailure()
        default: throw Failure(description: "Unknown native provider case")
        }
        print("PASS: native issue provider case completed")
    }
}
private extension NSWindow {
    @objc func turtleGitIssueProviderOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        alphaValue = 0; setFrameOrigin(NSPoint(x: -20000, y: -20000)); turtleGitIssueProviderOrder(place, relativeTo: otherWindowNumber)
    }
}
