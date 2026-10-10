import AppKit
import SwiftUI
@testable import TurtleGitCore

private struct VerificationFailure: Error, CustomStringConvertible { let description: String }
private actor PrivateSMTPStore: SMTPCredentialStore {
    func login() async throws -> String { "" }
    func store(login: String, password: String) async throws { }
    func clear() async throws { }
}
private actor DeliveryCredentials: SMTPTransportCredentialSource {
    var reads = 0
    var missing = false
    var delayed = false
    func configure(missing: Bool = false, delayed: Bool = false) { self.missing = missing; self.delayed = delayed }
    func count() -> Int { reads }
    func credentials() async throws -> SMTPLoginSecret? {
        reads += 1
        if delayed { try await Task.sleep(nanoseconds: 150_000_000) }
        return missing ? nil : SMTPLoginSecret(login: "fixture-login", password: "fixture-secret")
    }
}
private actor DeliveryProbe {
    let expected: [PatchMailMessage]
    init(expected: [PatchMailMessage]) { self.expected = expected }
    var calls = 0
    var authenticated = false
    func submit(_ messages: [PatchMailMessage], _ sender: PatchMailSender, _ server: SMTPServer, _ authentication: SMTPAuthentication?) throws -> [SMTPReceipt] {
        guard messages == expected, messages.count == 2, sender == PatchMailSender(name: "Captured", email: "sender@example.invalid"),
              server.host == "fixture.invalid", server.port == 2525, server.encryption == .startTLS,
              messages.allSatisfy({ $0.to == ["to@example.invalid"] && $0.cc == ["cc@example.invalid"] }) else {
            throw VerificationFailure(description: "Delivery capture changed")
        }
        if let authentication {
            guard authentication.login == "fixture-login", authentication.password == "fixture-secret" else {
                throw VerificationFailure(description: "Atomic credential pair changed")
            }
        }
        calls += 1; authenticated = authentication != nil; return []
    }
    func state() -> (Int, Bool) { (calls, authenticated) }
}
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
        let list = SendPatchWindowModel(files: [first, first, second], preferences: prefs)
        list.setChecked([list.rows[2].id])
        let newFile = root.appendingPathComponent("drop 雪.patch")
        try Data("Subject: Drop\n\nbody\n".utf8).write(to: newFile)
        try require(list.appendDroppedFiles([first, root, newFile, newFile, URL(string: "https://example.invalid/remote.patch")!]), "Accepted non-directory unique dropped path")
        try require(list.rows.map(\.file) == [first, first, second, newFile], "Dropped paths append in order, existing duplicates retained")
        try require(list.checked.count == 2 && list.highlighted.isEmpty && !list.checked.contains(list.rows[0].id), "Drops check new rows without rechecking existing rows or changing highlight")
        try require(!list.appendDroppedFiles([first, newFile, root]), "Duplicate/directory-only drop ignored")
        let listTable = SendPatchTable(frame: NSRect(x: 0, y: 0, width: 650, height: 200))
        listTable.menuPreferences = prefs
        listTable.configure(rows: list.rows, checked: list.checked, highlighted: [])
        try require(listTable.contextMenuForSelection() == nil, "No highlighted rows, no context menu")
        var views: [URL] = [], alternates: [URL] = [], reviews: [URL] = [], applied: [[URL]] = []
        list.showPatch = { views.append($0) }; list.showAlternatePatch = { alternates.append($0) }
        list.reviewPatch = { reviews.append($0) }; list.applyPatches = { applied.append($0) }
        listTable.canViewPatch = true
        listTable.openPatch = { list.openPatch($0) }; listTable.openAlternatePatch = { list.openPatch($0, alternate: true) }
        listTable.reviewPatch = { list.review($0) }; listTable.applyPatches = { list.apply($0) }
        listTable.configure(rows: list.rows, checked: list.checked, highlighted: [list.rows[0].id])
        guard let single = listTable.contextMenuForSelection() else { throw VerificationFailure(description: "No single-row menu") }
        try require(single.items.map(\.title) == ["View Patch", "Review Patch with TurtleGitMerge", "Apply Patch…"], "Source menu order and no recursive Send Mail")
        try require(single.items.allSatisfy { $0.image != nil }, "Original context icons")
        // Menu actions retain the highlighted IDs at opening, independent of
        // checkboxes and later selection changes.
        listTable.configure(rows: list.rows, checked: list.checked, highlighted: [list.rows[3].id])
        single.performActionForItem(at: 0); single.performActionForItem(at: 1); single.performActionForItem(at: 2)
        try require(views == [first] && reviews == [first] && applied == [[first]], "Captured unchecked highlighted row actions")
        listTable.viewPatch(list.rows[2].id, alternate: true)
        try require(alternates == [second], "Alternate viewer intent")
        listTable.configure(rows: list.rows, checked: list.checked, highlighted: [list.rows[0].id, list.rows[1].id, list.rows[2].id])
        guard let multiple = listTable.contextMenuForSelection() else { throw VerificationFailure(description: "No multi-row menu") }
        try require(multiple.items.map(\.title) == ["Apply Patch…"], "Multi-highlight menu only Apply")
        multiple.performActionForItem(at: 0)
        try require(applied.last == [first, first, second], "Apply uses highlighted list order and duplicate rows, not checks")
        prefs.set(false, forKey: "ShowAppContextMenuIcons")
        try require(listTable.contextMenuForSelection()?.items.allSatisfy { $0.image == nil } == true, "Context icon preference")
        prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        listTable.interactionEnabled = false
        try require(listTable.contextMenuForSelection() == nil, "Disabled list has no context menu")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([newFile as NSURL])
        listTable.droppedFiles = { list.appendDroppedFiles($0) }
        try require(!listTable.acceptFiles(from: board), "Disabled drop rejected")
        listTable.interactionEnabled = true
        let more = root.appendingPathComponent("more.patch")
        try Data("Subject: More\n\nbody".utf8).write(to: more)
        board.clearContents(); board.writeObjects([more as NSURL, newFile as NSURL])
        try require(listTable.acceptFiles(from: board) && list.rows.last?.file == more, "Native file URL pasteboard drop")
        list.invalidate()
        try require(!list.appendDroppedFiles([second]), "Closed owner rejects late drops")
        list.apply(Set(list.rows.map(\.id))); try require(applied.count == 2, "Closed owner rejects actions")
        try await settle(list)

        let completion = SendPatchAddressField.Coordinator(), combo = NSComboBox()
        completion.choices = ["Review 雪 <review@example.invalid>", "other@example.invalid"]
        combo.usesDataSource = true; combo.dataSource = completion; combo.completes = true
        try require(combo.numberOfItems == 2, "History provided through AppKit data source")
        try require(combo.dataSource?.comboBox?(combo, completedString: "keep@example.invalid;  rev") == "keep@example.invalid;  Review 雪 <review@example.invalid>", "Last-token semicolon completion preserves prefix")
        try require(combo.dataSource?.comboBox?(combo, completedString: "unknown") == nil, "Unknown prefix has no completion")
        // Settings page and Send use different absent delivery defaults upstream.
        prefs.removeObject(forKey: "SendMail.DeliveryType")
        try require(EmailConfiguration(preferences: prefs).delivery == .direct, "Settings default direct SMTP")
        let dynamic = SendPatchWindowModel(files: [first], preferences: prefs)
        try require(dynamic.delivery == .mailClient, "Absent Send preference defaults to mail client")
        var captured: SendPatchRequest?
        dynamic.onSubmit = { captured = $0 }
        var config = EmailConfiguration(preferences: prefs)
        config.delivery = .configured; config.server = "smtp.example.invalid"; config.port = 587
        config.encryption = .startTLS; config.authenticate = true; config.save(prefs)
        try require(dynamic.delivery == .smtp, "Settings edits observed without reopening Send")
        dynamic.submit()
        try require(dynamic.error != nil && captured == nil && dynamic.pendingLoads == 0, "Updated SMTP mode requires To/CC")
        dynamic.cc = "review@example.invalid"; dynamic.submit()
        var later = config; later.delivery = .mailClient; later.server = "later.example.invalid"; later.port = 25; later.save(prefs)
        try await settle(dynamic)
        try require(captured?.delivery == config && captured?.options.cc == "review@example.invalid", "Delivery/options captured before async preparation")
        dynamic.invalidate(); prefs.removeObject(forKey: "SendMail.DeliveryType")

        var settingsOpened = 0, settingsClosed = 0
        var emailWindow: EmailSettingsWindowController?
        let controller = SendPatchWindowController(files: [first], preferences: prefs, settingsPresenter: { received in
            settingsOpened += 1
            let settings = EmailSettingsWindowController(preferences: received, credentials: PrivateSMTPStore())
            settings.onClosed = { settingsClosed += 1 }; emailWindow = settings
        })
        controller.model.showSettings?()
        try require(settingsOpened == 1 && controller.model.canInteract && emailWindow?.window?.isVisible == false, "Independent hidden Email settings route")
        if let settings = emailWindow {
            let deadline = Date().addingTimeInterval(10)
            while settings.model.pendingOperations != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(settings.model.pendingOperations == 0, "Settings credential refresh finished")
            settings.model.delivery = .configured; settings.model.server = "applied.example.invalid"; settings.model.port = ""
            settings.accept(); try require(settingsClosed == 0, "Invalid OK must keep settings open")
            settings.model.port = "465"; settings.model.encryption = .tls; settings.accept()
            try require(settingsClosed == 1 && prefs.string(forKey: "SendMail.Address") == "applied.example.invalid" && prefs.integer(forKey: "SendMail.Port") == 465, "Settings OK applies shared options and closes")
        }
        prefs.set(EmailDelivery.mailClient.rawValue, forKey: "SendMail.DeliveryType")
        controller.model.showSettings?()
        try require(settingsOpened == 2 && controller.model.canInteract, "Independent settings do not block Send")
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
        try require(settingsClosed == 1, "Closing Send must not close independent Email settings")
        controller.model.showSettings?(); try require(settingsOpened == 2, "Closed Send cannot open settings")
        if let settings = emailWindow {
            let deadline = Date().addingTimeInterval(10)
            while settings.model.pendingOperations != 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            settings.window?.performClose(nil)
        }
        try require(settingsClosed == 2 && EmailSettingsWindowController.current == nil, "Private settings close; global production settings not opened")
        do {
        // Configured delivery orchestration uses captured values only. Neither
        // this injected transport nor credential source sends mail/uses Keychain.
        var mailOptions = PatchMailOptions(); mailOptions.to = "to@example.invalid"; mailOptions.cc = "cc@example.invalid"
        let prepared = try PatchMailPreparation.messages(files: [first, second], options: mailOptions)
        var captureConfiguration = EmailConfiguration(preferences: prefs); captureConfiguration.delivery = .configured
        captureConfiguration.server = "fixture.invalid"; captureConfiguration.port = 2525; captureConfiguration.encryption = .startTLS; captureConfiguration.authenticate = true
        let captured = SendPatchRequest(files: [first, second], options: mailOptions, messages: prepared, delivery: captureConfiguration)
        let credentialSource = DeliveryCredentials(), probe = DeliveryProbe(expected: prepared)
        let senderSource: SendPatchSMTPDelivery.SenderSource = { token in
            if token.isCancelled { throw OperationCancellationFailure.cancelled }
            return PatchMailSender(name: "Captured", email: "sender@example.invalid")
        }
        let submit: SendPatchSMTPDelivery.Transport = { messages, sender, server, authentication, _, _ in
            try await probe.submit(messages, sender, server, authentication)
        }
        // Change preferences and selected files after capturing the request.
        prefs.set("changed.invalid", forKey: "SendMail.Address")
        prefs.set(false, forKey: "SendMail.AuthenticationRequired")
        try Data("replaced after capture".utf8).write(to: first)
        _ = try await SendPatchSMTPDelivery.send(captured, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: senderSource, transport: submit)
        let capturedState = await probe.state(), reads = await credentialSource.count()
        try require(capturedState.0 == 1 && capturedState.1 && reads == 1, "One captured authenticated submission")
        captureConfiguration.authenticate = false
        let unauthenticated = SendPatchRequest(files: captured.files, options: captured.options, messages: captured.messages, delivery: captureConfiguration)
        _ = try await SendPatchSMTPDelivery.send(unauthenticated, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: senderSource, transport: submit)
        let unauthenticatedState = await probe.state(), unauthenticatedReads = await credentialSource.count()
        try require(unauthenticatedState.0 == 2 && !unauthenticatedState.1 && unauthenticatedReads == 1, "No credential query when authentication disabled")
        await credentialSource.configure(missing: true)
        do {
            _ = try await SendPatchSMTPDelivery.send(captured, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: senderSource, transport: submit)
            throw VerificationFailure(description: "Missing authenticated credentials accepted")
        } catch SendPatchSMTPDeliveryFailure.credentials { }
        await credentialSource.configure(delayed: true)
        let cancelledToken = OperationCancellation()
        let cancelledDelivery = Task {
            try await SendPatchSMTPDelivery.send(captured, credentials: credentialSource, cancellation: cancelledToken, onProgress: { _ in }, sender: senderSource, transport: submit)
        }
        try await Task.sleep(nanoseconds: 40_000_000); cancelledToken.cancel()
        do { _ = try await cancelledDelivery.value; throw VerificationFailure(description: "Cancelled credential capture submitted") }
        catch is OperationCancellationFailure { }
        captureConfiguration.port = 70_000
        let invalidServer = SendPatchRequest(files: captured.files, options: captured.options, messages: captured.messages, delivery: captureConfiguration)
        let beforeInvalid = await credentialSource.count()
        do {
            _ = try await SendPatchSMTPDelivery.send(invalidServer, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: senderSource, transport: submit)
            throw VerificationFailure(description: "Invalid port accepted")
        } catch SMTPFailure.configuration { }
        captureConfiguration.port = 2525; captureConfiguration.delivery = .mailClient
        let wrongDelivery = SendPatchRequest(files: captured.files, options: captured.options, messages: captured.messages, delivery: captureConfiguration)
        do {
            _ = try await SendPatchSMTPDelivery.send(wrongDelivery, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: senderSource, transport: submit)
            throw VerificationFailure(description: "Mail client routed through SMTP")
        } catch SendPatchSMTPDeliveryFailure.delivery { }
        do {
            _ = try await SendPatchSMTPDelivery.send(captured, credentials: credentialSource, cancellation: OperationCancellation(), onProgress: { _ in }, sender: { _ in PatchMailSender(name: "invalid\r\nheader", email: "sender@example.invalid") }, transport: submit)
            throw VerificationFailure(description: "Invalid sender queried credentials")
        } catch is PatchMailMIMEFailure { }
        let afterInvalid = await credentialSource.count(), finalState = await probe.state()
        try require(beforeInvalid == afterInvalid && finalState.0 == 2, "Invalid/cancelled/missing credential requests must never reach transport")
        guard CommandLine.arguments.count == 3, let port = Int(CommandLine.arguments[2]) else { throw VerificationFailure(description: "Missing private SMTP port") }
        let repository = GitRepository(root: root)
        _ = try await repository.run(["init", "--quiet"])
        _ = try await repository.run(["config", "--local", "user.name", "Captured"])
        _ = try await repository.run(["config", "--local", "user.email", "sender@example.invalid"])
        var liveOptions = mailOptions; liveOptions.combine = true; liveOptions.attachment = true; liveOptions.subject = "Captured series"
        let liveMessages = try PatchMailPreparation.messages(files: [second, second], options: liveOptions)
        var loopback = EmailConfiguration(preferences: prefs); loopback.delivery = .configured
        loopback.server = "localhost"; loopback.port = UInt32(port); loopback.encryption = .none; loopback.authenticate = false
        let liveRequest = SendPatchRequest(files: [second, second], options: liveOptions, messages: liveMessages, delivery: loopback)
        try liveMessages[0].body.write(to: root.appendingPathComponent("expected-body"))
        try liveMessages[0].attachments[0].bytes.write(to: root.appendingPathComponent("expected-attachment"))
        loopback.save(prefs); prefs.set(0, forKey: "AutoCloseGitProgress")
        var shownOptions: SendPatchWindowController?, shownProgress: SendPatchProgressWindowController?, formatCloses = 0
        let format = FormatPatchWindowController(repository: repository, access: nil, preferences: prefs, mailPresentation: { controller in
            if let options = controller as? SendPatchWindowController { shownOptions = options }
            if let progress = controller as? SendPatchProgressWindowController { shownProgress = progress }
        })
        format.onClosed = { formatCloses += 1 }
        let loadDeadline = Date().addingTimeInterval(10)
        while format.model.busy && Date() < loadDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!format.model.busy, "Format parent load")
        format.model.composeMail([second, second])
        guard let options = shownOptions else { throw VerificationFailure(description: "Format configured mail options not presented") }
        try require(format.model.composingMail && options.window?.isVisible == false, "Retained hidden options and Format close fence")
        options.model.to = liveOptions.to; options.model.cc = liveOptions.cc; options.model.combine = true
        options.model.attachment = true; options.model.combinedSubject = liveOptions.subject
        options.model.submit(); try await settle(options.model)
        guard let progress = shownProgress else { throw VerificationFailure(description: "Configured progress not presented") }
        let deliveryDeadline = Date().addingTimeInterval(15)
        while progress.model.busy && Date() < deliveryDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!progress.model.busy && progress.model.success && progress.model.accepted == 1 && progress.model.percentage == 100, "Actual Format options/progress/Git sender/SDK SMTP submission")
        try require(progress.window?.isVisible == false && format.model.composingMail, "Progress retained until user close without ordered windows")
        progress.window?.performClose(nil)
        try require(!format.model.composingMail && formatCloses == 1, "Final close releases Format parent once")
        var importOptions: SendPatchWindowController?
        let importer = ImportPatchWindowController(repository: repository, access: nil, preferences: prefs, mailPresentation: { importOptions = $0 as? SendPatchWindowController })
        importer.model.add([second]); importer.model.sendMail(Set(importer.model.items.map(\.id)))
        try require(importer.model.composingMail && importOptions != nil, "Import selected mail configured route")
        importOptions?.model.cancel()
        try require(!importer.model.composingMail && importer.model.error == nil, "Cancelling Import mail options unlocks parent")
        importer.window?.performClose(nil)

        // Hidden progress checks inject outcomes; no repeated network sends.
        let receipt = SMTPReceipt(response: 250)
        let failed = SendPatchProgressModel(request: captured, repository: repository, access: nil, preferences: prefs, submission: { _, notify in
            notify(.sending(index: 0, total: 2, attempt: 1)); notify(.accepted(index: 0, response: 250))
            notify(.sending(index: 1, total: 2, attempt: 1)); notify(.retry(index: 1, nextAttempt: 2))
            throw SMTPSeriesFailure(index: 1, attempts: 1, accepted: [receipt], cause: SMTPFailure.transfer(code: 55, response: 0, possiblySubmitted: true))
        })
        prefs.set(false, forKey: "UseSystemLocaleForDates"); prefs.set(false, forKey: "ShowGitexeTimings")
        failed.start(); failed.start()
        while failed.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(failed.notifications.last?.path.contains(" ms @ ") == true && failed.notifications.last?.path.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil, "List finish row always has timings and respects fixed-date preference")
        prefs.removeObject(forKey: "UseSystemLocaleForDates"); prefs.removeObject(forKey: "ShowGitexeTimings")
        try require(!failed.success && !failed.cancelled && failed.accepted == 1 && failed.percentage == 50, "Partial acceptance and uncertain delivery remain failures")
        try require(failed.output.contains("Retrying message 2") && failed.output.contains("verify before retrying") && failed.completionRange != nil, "Retry/error/uncertainty/footer retained")
        let stopped = SendPatchProgressModel(request: captured, repository: repository, access: nil, preferences: prefs, submission: { token, notify in
            notify(.sending(index: 0, total: 2, attempt: 1))
            while !token.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
            throw OperationCancellationFailure.cancelled
        })
        let stoppedController = SendPatchProgressWindowController(model: stopped)
        var confirm: ((Bool) -> Void)?
        stopped.confirmCancellation = { confirm = $0 }; prefs.set(true, forKey: "ConfirmKillProcess")
        stopped.start(); stoppedController.window?.performClose(nil)
        try require(stopped.busy && stopped.confirmingCancellation, "User close requests Abort confirmation without closing")
        confirm?(false); try require(stopped.busy && !stopped.cancelling, "No leaves send running")
        stopped.cancel(); confirm?(true); confirm?(true)
        let stopDeadline = Date().addingTimeInterval(10)
        while stopped.busy && Date() < stopDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!stopped.busy && stopped.cancelled && !stopped.success && stopped.accepted == 0, "Confirmed Abort cancels owned operation")
        stoppedController.window?.performClose(nil); prefs.set(false, forKey: "ConfirmKillProcess")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let hidden = SendPatchProgressWindowController(model: failed)
            hidden.window?.appearance = NSAppearance(named: appearance); hidden.window?.contentView?.layoutSubtreeIfNeeded()
            try require(hidden.window?.isVisible == false && (hidden.window?.contentView?.fittingSize.height ?? 0) < 430, "Hidden progress layout fits light/dark")
            hidden.window?.performClose(nil)
        }
        try require(progress.model.notifications.map(\.action) == ["Command", "Sending...", "Finished!"], "Source-style combined notifications without invented file actions")
        try require(failed.notifications.contains { $0.action == "Notice" && $0.path == "Retrying in 2 seconds..." } && failed.notifications.last?.kind == .finishedFailure, "Retry notice and failure finish row")
        let rows = [SendPatchNotification(action: "Command", path: "Send Email", kind: .command),
            SendPatchNotification(action: "Sending...", path: "/b.patch", kind: .sending),
            SendPatchNotification(action: "Sending...", path: "/A.patch", kind: .sending),
            SendPatchNotification(action: "Notice", path: "boundary", kind: .notice),
            SendPatchNotification(action: "Sending...", path: "/d.patch", kind: .sending),
            SendPatchNotification(action: "Sending...", path: "/C.patch", kind: .sending),
            SendPatchNotification(action: "Finished!", path: "Success", kind: .finishedSuccess)]
        let table = SendPatchNotificationTable(); table.preferences = prefs
        let clipboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.Progress.QA." + UUID().uuidString)); table.clipboard = clipboard
        defer { clipboard.releaseGlobally() }
        table.configure(rows, running: true); table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        try require(table.tableColumns.map(\.title) == ["Action", "Path"] && table.contextMenuForSelection() == nil, "Source columns and no running context menu")
        table.tableView(table, didClick: table.tableColumns[1]); try require(table.rows == rows, "Running header sort ignored")
        guard let copyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else { throw VerificationFailure(description: "No synthetic Copy key") }
        try require(table.performKeyEquivalent(with: copyKey), "Native keyboard Copy during send")
        try require(clipboard.string(forType: .string) == "Command: Send Email  \r\nSending...: /b.patch  \r\n", "Keyboard includes Action/Path and source empty third column spacing")
        table.configure(rows, running: false); table.tableView(table, didClick: table.tableColumns[1])
        try require(table.rows.map(\.path) == ["Send Email", "/A.patch", "/b.patch", "boundary", "/C.patch", "/d.patch", "Success"], "Sort each action block without moving auxiliary boundaries")
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false); prefs.set(true, forKey: "ShowAppContextMenuIcons")
        try require(table.contextMenuForSelection()?.items.map(\.title) == ["Copy to clipboard"] && table.contextMenuForSelection()?.items.first?.image != nil, "Completed base notification Copy menu and original icon only")
        table.tableColumns[0].width = 213; table.fitViewport(NSSize(width: 700, height: 200))
        try require(table.tableColumns[0].width == 213, "Manual column width survives viewport layout")
        table.copyPaths(nil); try require(clipboard.string(forType: .string) == "Send Email\r\n/b.patch", "Context Copy contains only Path column")
        prefs.set(false, forKey: "ShowAppContextMenuIcons"); try require(table.contextMenuForSelection()?.items.first?.image == nil, "Copy menu obeys icon preference"); prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        table.configure(rows + [SendPatchNotification(action: "Notice", path: "appended", kind: .notice)], running: false)
        try require(table.selectedRowIndexes == IndexSet([0, 2]), "Selected row identities survive append/sort")
        table.deselectAll(nil)
        let hitPoint = table.convert(NSPoint(x: 10, y: table.rect(ofRow: 1).midY), to: nil)
        guard let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: hitPoint, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { throw VerificationFailure(description: "No synthetic context click") }
        try require(table.menu(for: rightClick)?.items.count == 1 && table.selectedRowIndexes == IndexSet(integer: 1), "First context click selects the clicked completed row")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var color: NSColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { color = rows[1].color(preferences: prefs).usingColorSpace(.sRGB) }
            try require(color != nil && color!.blueComponent > color!.redComponent, "Modified row remains colorful in both appearances")
        }
        prefs.set(16, forKey: "GitOutputLimitinKiB")
        let bulkNotificationModel = SendPatchProgressModel(request: captured, repository: repository, access: nil, preferences: prefs, submission: { _, notify in
            for _ in 0..<1000 { notify(.sending(index: 0, total: 2, attempt: 1)) }
            return []
        })
        bulkNotificationModel.start()
        let bulkDeadline = Date().addingTimeInterval(10)
        while bulkNotificationModel.busy && Date() < bulkDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(!bulkNotificationModel.busy && bulkNotificationModel.notifications.count == 1003 && bulkNotificationModel.notifications.last?.kind == .finishedFailure, "Notification list keeps all rows independently of CLI log limits")
        try require(bulkNotificationModel.notifications.filter { $0.kind == .sending }.allSatisfy { $0.path == first.path }, "Newline filename remains one complete Sending path")
        prefs.removeObject(forKey: "GitOutputLimitinKiB")
        print("Send notification table: Action/Path, source row kinds/colors, base Copy-only context/icon gates, running keyboard copy, completed block sorting and selection preservation passed with private clipboard.")
        print("Native configured progress and Format/Import routes: retained hidden options/result, real loopback success, accepted-prefix uncertainty, retry/footer, Abort confirmation/No/Yes and light/dark checks passed.")
        let afterLoopback = await credentialSource.count()
        try require(afterLoopback == afterInvalid, "Production unauthenticated entry queried credentials")
        print("Actual configured submission captured private Git sender and submitted combined MIME/To/CC to owned loopback server with SDK frameworks; no user Keychain or real mail service.")
        print("Configured SMTP orchestration: immutable request/sender/server/To/CC/bytes, atomic credential capture only when required, missing/invalid/cancelled gates passed with injected transport; no real Keychain or delivery.")
        }
        print("Send Patch: source options/checked-highlighted subject states, four captured modes, duplicate ordering, private shared history, To/CC, client/SMTP recipient gates, retry, late close fencing, native checkbox/Space interactions, hidden light/dark layout. Private loopback SMTP only; no mail client, main app or real mail service.")
        print("Private suite cleaned: " + suite)
    }
    @MainActor static func main() async {
        do { try await verify() }
        catch { fputs("Send Patch verification failed: \(error)\n", stderr); exit(1) }
    }
}
