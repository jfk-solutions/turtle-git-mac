import AppKit
import SwiftUI
import TurtleGitCore

private struct VerificationFailure: Error, CustomStringConvertible { let description: String }
@main struct SendPatchVerification {
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VerificationFailure(description: message) }
    }
    @MainActor static func settle(_ model: SendPatchWindowModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.pendingLoads != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(model.pendingLoads == 0, "Owned file preparation did not finish")
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), suite = "TurtleGit.SendPatch.QA." + UUID().uuidString
        guard let prefs = UserDefaults(suiteName: suite) else { throw VerificationFailure(description: "No private preferences") }
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let first = root.appendingPathComponent("1 雪\n.patch"), second = root.appendingPathComponent("2.patch")
        try Data("Subject: First 雪\n\none\n".utf8).write(to: first)
        try Data("Subject: Second\n\ntwo\n".utf8).write(to: second)
        let defaults = SendPatchWindowModel(files: [first], preferences: prefs)
        try require(!defaults.attachment && !defaults.combine && !defaults.canSubmit, "Defaults or missing backend gate")
        try require(defaults.checked.count == 1 && defaults.highlighted.count == 1, "Single-file initial check/highlight")
        defaults.refreshPreview(); try await settle(defaults)
        try require(defaults.subject == "First 雪", "Initial single-file subject")
        defaults.combinedSubject = "Custom"; defaults.combine = true; defaults.combineChanged()
        try require(defaults.subject == "Custom", "Combined subject")
        defaults.combine = false; defaults.combineChanged(); try await settle(defaults)
        try require(defaults.subject == "First 雪" && defaults.combinedSubject == "Custom", "Custom subject survives toggle")
        defaults.setChecked([]); try require(defaults.subject == "First 雪", "Unchecked highlighted row still previews")
        defaults.invalidate()

        for combine in [false, true] {
            for attachment in [false, true] {
                let model = SendPatchWindowModel(files: [second, first, second], preferences: prefs)
                model.combine = combine; model.attachment = attachment; model.combinedSubject = "Combined 雪"
                model.to = "to@example.invalid"; model.cc = "cc@example.invalid"
                try require(model.checked.count == 3 && model.highlighted.isEmpty, "Multiple-file initial state and duplicate IDs")
                model.setHighlighted([model.rows[1].id]); try await settle(model)
                if !combine { try require(model.subject == "First 雪", "Highlighted subject independently of checks") }
                model.setHighlighted(Set(model.rows.map(\.id))); try await settle(model)
                if !combine { try require(model.subject.isEmpty, "Multiple highlights clear subject") }
                model.setChecked([model.rows[0].id, model.rows[2].id])
                var requests: [SendPatchRequest] = [], closes = 0
                model.onSubmit = { requests.append($0) }; model.close = { closes += 1 }
                model.submit(); model.submit(); model.to = "changed@example.invalid"; model.combinedSubject = "Changed"; model.setChecked([])
                try await settle(model)
                try require(requests.count == 1 && closes == 1, "Exactly once snapshot submission/close")
                let request = requests[0]
                try require(request.files == [second, second], "Checked duplicate path ordering")
                try require(request.options.to == "to@example.invalid" && request.options.subject == "Combined 雪", "Captured options")
                try require(request.messages.count == (combine ? 1 : 2), "Prepared source modes")
                try require(request.messages.allSatisfy { $0.to == ["to@example.invalid"] && $0.cc == ["cc@example.invalid"] }, "Distinct recipients")
                try require(prefs.bool(forKey: "SendMail.Attach") == attachment && prefs.bool(forKey: "SendMail.Combine") == combine, "Saved options")
                try require(model.addresses.prefix(2) == ["to@example.invalid", "cc@example.invalid"], "Shared address history")
                model.invalidate()
            }
        }
        prefs.set(false, forKey: "SendMail.Combine")
        let smtp = SendPatchWindowModel(files: [first], delivery: .smtp, preferences: prefs)
        var smtpCalls = 0; smtp.onSubmit = { _ in smtpCalls += 1 }; smtp.to = " ; "; smtp.submit()
        try require(smtp.error != nil && !smtp.busy && smtpCalls == 0, "SMTP empty recipients rejected")
        smtp.cc = "review@example.invalid"; smtp.submit(); try await settle(smtp)
        try require(smtpCalls == 1, "CC-only SMTP preparation")
        smtp.invalidate()
        let client = SendPatchWindowModel(files: [first], preferences: prefs)
        var clientCalls = 0; client.onSubmit = { _ in clientCalls += 1 }; client.submit(); try await settle(client)
        try require(clientCalls == 1, "Mail-client empty recipients accepted")
        client.invalidate()
        let none = SendPatchWindowModel(files: [first], preferences: prefs)
        var noneSubmits = 0, noneCloses = 0
        none.onSubmit = { _ in noneSubmits += 1 }; none.close = { noneCloses += 1 }
        none.attachment = true; none.setChecked([]); none.submit(); none.submit()
        try require(noneSubmits == 0 && noneCloses == 1 && prefs.bool(forKey: "SendMail.Attach"), "All unchecked saves options and closes without delivery")
        none.invalidate()
        let invalid = SendPatchWindowModel(files: [root.appendingPathComponent("missing")], preferences: prefs)
        invalid.onSubmit = { _ in clientCalls += 1 }; invalid.attachment = false; invalid.submit(); try await settle(invalid)
        try require(invalid.error != nil && clientCalls == 1 && invalid.canSubmit && !prefs.bool(forKey: "SendMail.Attach"), "Failed preparation remains retryable")
        invalid.invalidate()
        let abandoned = SendPatchWindowModel(files: [first], preferences: prefs)
        var abandonedCalls = 0; abandoned.onSubmit = { _ in abandonedCalls += 1 }; abandoned.close = { abandonedCalls += 1 }
        abandoned.refreshPreview(); abandoned.submit(); abandoned.invalidate(); try await settle(abandoned)
        try require(abandonedCalls == 0 && abandoned.previewSubject.isEmpty && !abandoned.busy, "Invalidation fences late preview and submission")

        let cancelled = SendPatchWindowModel(files: [first], preferences: prefs)
        var cancelledSubmits = 0, cancelledCloses = 0
        cancelled.onSubmit = { _ in cancelledSubmits += 1 }; cancelled.close = { cancelledCloses += 1 }
        cancelled.submit(); cancelled.cancel(); cancelled.cancel(); try await settle(cancelled)
        try require(cancelledSubmits == 0 && cancelledCloses == 1 && !cancelled.canSubmit, "Cancel fences preparation and closes once")

        let native = SendPatchWindowModel(files: [first, second], preferences: prefs)
        let table = SendPatchTable(frame: NSRect(x: 0, y: 0, width: 650, height: 180))
        table.configure(rows: native.rows, checked: native.checked, highlighted: [native.rows[1].id])
        table.checksChanged = { native.setChecked($0) }; table.highlightChanged = { native.setHighlighted($0) }
        guard let checkbox = table.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSButton else { throw VerificationFailure(description: "No native checkbox") }
        checkbox.performClick(nil)
        try require(!native.checked.contains(native.rows[0].id) && table.selectedRowIndexes == IndexSet(integer: 1), "Checkbox does not change highlight")
        guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { throw VerificationFailure(description: "No keyboard event") }
        table.keyDown(with: space)
        try require(native.checked.isEmpty && table.selectedRowIndexes == IndexSet(integer: 1), "Space toggles highlighted check independently")
        table.interactionEnabled = false; checkbox.performClick(nil)
        try require(native.checked.isEmpty, "Disabled table ignores checkbox action")
        try require(table.headerView == nil && table.tableColumns[1].width > 400, "Source list layout and full path width")
        table.fitViewport(NSSize(width: 1500, height: 250))
        try require(table.frame.width >= 1500 && table.frame.height >= 250, "Resized viewport fills document")
        table.fitViewport(NSSize(width: 200, height: 100))
        try require(table.frame.width >= table.rect(ofColumn: 1).maxX, "Horizontal scroll document covers full path columns")
        native.invalidate(); try await settle(native)
        let completion = SendPatchAddressField.Coordinator(), combo = NSComboBox()
        completion.choices = ["Review 雪 <review@example.invalid>", "other@example.invalid"]
        combo.usesDataSource = true; combo.dataSource = completion; combo.completes = true
        try require(combo.numberOfItems == 2, "History provided through AppKit data source")
        try require(combo.dataSource?.comboBox?(combo, completedString: "keep@example.invalid;  rev") == "keep@example.invalid;  Review 雪 <review@example.invalid>", "Last-token semicolon completion preserves prefix")
        try require(combo.dataSource?.comboBox?(combo, completedString: "unknown") == nil, "Unknown prefix has no completion")
        let controller = SendPatchWindowController(files: [first], preferences: prefs)
        guard let window = controller.window else { throw VerificationFailure(description: "No native window") }
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await settle(controller.model)
        try require(!window.isVisible && window.contentMinSize == NSSize(width: 620, height: 380), "Hidden native options host")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try require((window.contentView?.fittingSize.width ?? 0) > 0, "Native host layout in appearance")
        }
        var windowSubmits = 0
        controller.model.onSubmit = { _ in windowSubmits += 1 }
        try require(controller.model.canSubmit, "Injected native host backend")
        controller.model.refreshPreview(); controller.model.submit(); window.performClose(nil); try await settle(controller.model)
        try require(!controller.model.canSubmit && windowSubmits == 0 && !controller.model.busy, "Actual user close invalidates pending preparation")
        print("Send Patch: source options/checked-highlighted subject states, four captured modes, duplicate ordering, private shared history, To/CC, client/SMTP recipient gates, retry, late close fencing, native checkbox/Space interactions, hidden light/dark layout. No mail client, main app or delivery.")
        print("Private suite cleaned: " + suite)
    }
    @MainActor static func main() async {
        do { try await verify() }
        catch { fputs("Send Patch verification failed: \(error)\n", stderr); exit(1) }
    }
}
