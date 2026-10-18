// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum CredentialAdvancedEditingVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2600 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Credential advanced operation did not settle at \(line)")
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init", "-b", "main"])
        let scoped = "https://advanced.invalid/path", helperless = "https://helperless.invalid", includedURL = "https://included.invalid", migration = "https://migration.invalid"
        let included = root.appendingPathComponent(".git/credential-included.config")
        let includedBytes = Data(("[credential \"" + includedURL + "\"]\nusername = included-user\nuseHttpPath = yes\ncustom = kept\n").utf8)
        try includedBytes.write(to: included)
        _ = try await repository.run(["config", "--local", "include.path", included.path])
        for helper in ["", "!literal helper '$()'"] { _ = try await repository.run(["config", "--local", "--add", "credential." + scoped + ".helper", helper]) }
        for username in ["first", "second"] { _ = try await repository.run(["config", "--local", "--add", "credential." + scoped + ".username", username]) }
        _ = try await repository.run(["config", "--local", "credential." + scoped + ".useHttpPath", "yes"])
        _ = try await repository.run(["config", "--local", "credential." + helperless + ".username", "helperless-user"])
        for username in ["destination-first", "destination-last"] { _ = try await repository.run(["config", "--local", "--add", "credential." + migration + ".username", username]) }
        for value in ["", "off"] { _ = try await repository.run(["config", "--local", "--add", "credential." + migration + ".useHttpPath", value]) }
        let model = CredentialSettingsModel(repository: repository, access: nil, localAvailable: true)
        model.authorizeFile = { _ in true }
        var writes: [GitCredentialFields] = [], questions = 0
        model.confirmAction = { _, _, _ in questions += 1; return true }
        model.writeCredentialFields = { draft, file, expected, fields in
            writes.append(fields)
            try await repository.saveCredential(draft, file: file, expected: expected, fields: fields)
        }
        let suite = "TurtleGit.CredentialAdvanced." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: CredentialSettingsPage(model: model).defaultAppStorage(preferences))
        window.contentView = host
        var permission: CheckedContinuation<Bool, Never>?, selection: CheckedContinuation<CredentialSettingsModel.PendingChangesDecision, Never>?
        defer {
            permission?.resume(returning: false); selection?.resume(returning: .cancel)
            model.deactivate(); window.contentView = nil; window.close(); preferences.removePersistentDomain(forName: suite)
        }
        do {
            try require(TurtleGitHelp.settingsTopic(.credential) == .credentials, "Credential page did not route to dedicated help")
            model.activate(); window.orderFront(nil)
            try await wait { model.snapshot != nil && !model.busy }
            guard let first = model.snapshot?.groups.first(where: { $0.url == scoped }), let noHelper = model.snapshot?.groups.first(where: { $0.url == helperless }), let origin = model.snapshot?.groups.first(where: { $0.url == includedURL }) else { throw Failure(description: "Real credential fixture groups absent") }
            model.select(first.id); try await wait { !model.busy && model.selected == first.id }
            window.contentView?.layoutSubtreeIfNeeded()
            try await wait { views(host).contains { ($0 as? NSComboBox)?.accessibilityLabel() == "Credential helper" } }
            guard let combo = views(host).compactMap({ $0 as? NSComboBox }).first(where: { $0.accessibilityLabel() == "Credential helper" }), let editor = combo.delegate as? CloneHistoryCombo.Coordinator else { throw Failure(description: "Production native helper editor missing") }
            let retiredHelper = editor.change, retiredIdentity = model.editorIdentity
            // Plain Apply changes only Helper. Username repetition and the raw
            // yes value survive, without an overwrite question.
            model.editHelper("replacement-helper", identity: model.editorIdentity)
            let priorQuestions = questions
            try require(await model.apply(), "Helper-only Apply failed")
            try require(writes.last == .helper && questions == priorQuestions, "Apply used full replacement or an Add overwrite question")
            let changed = try await repository.credentialConfiguration(), changedGroup = changed.groups.first { $0.id == first.id }!
            try require(changedGroup.entries.filter { $0.field != "helper" } == first.entries.filter { $0.field != "helper" }, "Helper Apply collapsed untouched raw/repeated fields")
            // SaveSettings' URL bit migrates the helper, without treating the
            // source's unchanged Username/HTTP-path as destination overrides.
            guard let destinationBefore = model.snapshot?.groups.first(where: { $0.url == migration }) else { throw Failure(description: "Migration destination missing") }
            let questionsBeforeMigration = questions
            model.editURL(migration, identity: model.editorIdentity)
            try require(await model.apply(), "URL migration Apply failed")
            guard let destinationAfter = model.group else { throw Failure(description: "Migration result missing") }
            try require(writes.last == .helper && questions == questionsBeforeMigration, "Migrating Apply used explicit Save fields/question")
            try require(destinationAfter.helpers == changedGroup.helpers && destinationAfter.entries.filter { $0.field != "helper" } == destinationBefore.entries, "Migrating Apply overwrote untouched destination optional values")
            try require(model.snapshot?.groups.first(where: { $0.id == first.id })?.entries == changedGroup.entries, "Migrating Apply changed source origin")
            // Helperless and included-origin groups are editable in place.
            model.select(noHelper.id); try await wait { !model.busy && model.selected == noHelper.id }
            try require(!model.canAdd && model.advancedValid && model.validationError == nil, "Existing helperless group requires a helper")
            model.destination = .global
            try require(!model.advancedValid && model.validationError != nil, "Helperless destination copy bypassed source new-entry eligibility")
            model.cancelDraft()
            let untouched = model.draft
            retiredHelper("old combo callback"); model.editURL("https://stale.invalid", identity: retiredIdentity)
            model.editUsername("stale", identity: retiredIdentity); model.editHTTPPath(true, identity: retiredIdentity)
            model.editDestination(.global, identity: retiredIdentity); model.editMode("none", identity: retiredIdentity)
            model.select(first.id, identity: retiredIdentity)
            try require(model.draft == untouched && model.selected == noHelper.id && model.mode == "advanced", "Retired native field/list callback edited another group")
            model.editUsername("helperless-updated", identity: model.editorIdentity)
            try require(await model.apply(), "Helperless username Apply failed")
            try require(writes.last == .username && model.draft.helpers.isEmpty, "Helperless Apply synthesized a helper")
            model.select(origin.id); try await wait { !model.busy && model.selected == origin.id }
            model.editUsername("included-updated", identity: model.editorIdentity)
            try require(await model.apply(), "Included-origin Apply failed")
            try require(model.target == included && model.snapshot?.groups.first(where: { $0.id == origin.id })?.username == "included-updated", "Included-origin edit was redirected to main local config")
            let includeAfterUsername = try Data(contentsOf: included)
            try require(includeAfterUsername != includedBytes && String(decoding: includeAfterUsername, as: UTF8.self).contains("custom = kept"), "Included unknown field lost")
            // Source unchecked means unset, even after a true -> false edit
            // returns to an originally unchecked value.
            model.select(first.id); try await wait { !model.busy && model.selected == first.id }
            model.editHTTPPath(false, identity: model.editorIdentity)
            try require(await model.apply(), "Unchecked HTTP-path Apply failed")
            try require(writes.last == .useHTTPPath && model.group?.entries.contains(where: { $0.field == "usehttppath" }) == false, "Unchecked HTTP-path persisted false instead of unsetting")
            model.editHTTPPath(true, identity: model.editorIdentity); model.editHTTPPath(false, identity: model.editorIdentity)
            try require(model.modified, "Source touched checkbox mask was lost after reverting")
            let reapplied = await model.apply(); try require(reapplied, "Reverted checkbox Apply failed")
            // Explicit Add New/Save remains a full replacement and confirms,
            // even with otherwise unchanged current fields.
            let beforeSaveQuestions = questions
            try require(await model.saveAdvanced(), "Explicit Add New/Save failed")
            try require(writes.last == .all && questions == beforeSaveQuestions + 1, "Explicit Save reused partial Apply semantics")
            model.select(nil); try await wait { !model.busy && model.selected == nil }
            model.editURL("https://new-save.invalid", identity: model.editorIdentity)
            model.editHelper("new-helper", identity: model.editorIdentity)
            try require(await model.saveAdvanced(), "Explicit new helper Save failed")
            try require(writes.last == .helper && model.group?.entries.count == 1, "New helper Save materialized blank optional overrides")
            model.select(first.id); try await wait { !model.busy && model.selected == first.id }
            // The production sheet offers both source actions; Save persists
            // before changing selection and inherits hidden owner appearance.
            model.confirmAction = nil; model.editUsername("saved-on-selection", identity: model.editorIdentity)
            model.select(noHelper.id)
            try await wait { window.attachedSheet != nil }
            let sheet = window.attachedSheet!, buttons = views(sheet.contentView!).compactMap { $0 as? NSButton }.map(\.title)
            try require(buttons.contains("Save") && buttons.contains("Discard") && buttons.contains("Cancel") && sheet.alphaValue == 0, "Selection sheet lost source choices or escaped hidden owner")
            try require(model.busy && CredentialSettingsModel.activeSelections == 1, "Selection sheet lost parent operation ownership")
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            try await wait { !model.busy && model.selected == noHelper.id }
            try require(model.snapshot?.groups.first(where: { $0.id == first.id })?.username == "saved-on-selection" && writes.last == .username, "Save selection did not commit only pending fields")
            model.choosePendingChanges = { .discard }; model.editUsername("discarded", identity: model.editorIdentity)
            let count = writes.count
            model.select(first.id); try await wait { !model.busy && model.selected == first.id }
            try require(writes.count == count && model.snapshot?.groups.first(where: { $0.id == noHelper.id })?.username == "helperless-updated", "Discard selection wrote pending fields")
            model.choosePendingChanges = { .cancel }; model.editUsername("retain", identity: model.editorIdentity)
            model.select(noHelper.id); try await wait { !model.busy }
            try require(model.selected == first.id && model.draft.username == "retain", "Cancel selection lost the draft")
            model.cancelDraft()
            // A failed selected Save must retain the current selection/draft.
            model.choosePendingChanges = { .save }; model.editUsername("stale selection", identity: model.editorIdentity)
            _ = try await repository.run(["config", "--local", "credential.external", "preserved-external"])
            model.select(noHelper.id); try await wait { !model.busy }
            try require(model.selected == first.id && model.draft.username == "stale selection" && model.error != nil, "Failed selection Save discarded the edited group")
            model.cancelDraft(); model.refresh(); try await wait { !model.busy }
            // Permission suspension captures the exact draft/mask. Retirement
            // must prevent any late write, even after the same page returns.
            model.editUsername("retired permission", identity: model.editorIdentity)
            model.authorizeFile = { _ in await withCheckedContinuation { permission = $0 } }
            let pending = Task { await model.apply() }
            try await wait { permission != nil }
            let protected = model.draft, captured = model.editorIdentity, writesBeforeRetirement = writes.count
            model.editUsername("busy callback", identity: captured)
            try require(model.draft == protected, "Busy editor accepted a late field callback")
            model.deactivate(); model.activate(); permission?.resume(returning: true); permission = nil
            try require(!(await pending.value), "Retired permission authorized a new write")
            try require(writes.count == writesBeforeRetirement && !model.busy, "Retired permission wrote or kept page blocked")
            // A held selection response cannot mutate a reactivated page.
            model.authorizeFile = { _ in true }; model.cancelDraft(); model.editUsername("retained late question", identity: model.editorIdentity)
            model.choosePendingChanges = { await withCheckedContinuation { selection = $0 } }
            model.select(noHelper.id); try await wait { selection != nil }
            model.deactivate(); model.activate(); selection?.resume(returning: .discard); selection = nil
            try await wait { !model.busy }
            try require(model.selected == first.id && model.draft.username == "retained late question", "Late selection response replaced the reactivated editor")
            model.deactivate(); window.orderOut(nil)
            try await wait { CredentialSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeReads == 0 && CredentialSettingsModel.activeSelections == 0 }
        } catch {
            model.deactivate(); permission?.resume(returning: false); permission = nil; selection?.resume(returning: .cancel); selection = nil
            window.orderOut(nil)
            try? await wait { CredentialSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeReads == 0 && CredentialSettingsModel.activeSelections == 0 }
            throw error
        }
    }
}
