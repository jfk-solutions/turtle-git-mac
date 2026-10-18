// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor enum SettingsTeardownVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    static func wait(_ label: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Settings teardown timeout: " + label)
    }
    static func flush() async { for _ in 0..<4 { await Task.yield(); try? await Task.sleep(nanoseconds: 10_000_000) } }
    static func quiet<M: ObservableObject>(_ model: M, _ label: String, _ action: () -> Void) throws where M.ObjectWillChangePublisher == ObservableObjectPublisher {
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        action()
        withExtendedLifetime(subscription) {}
        try require(publications == 0, label + " synchronously published during graph retirement (\(publications))")
    }
    final class Scope {
        var windows: [NSWindow] = []
        var retire: [() -> Void] = []
        var release: [() -> Void] = []
        func window() -> NSWindow {
            let result = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            result.isReleasedWhenClosed = false; result.alphaValue = 0; windows.append(result); return result
        }
        func close() async throws {
            retire.reversed().forEach { $0() }; retire.removeAll()
            release.forEach { $0() }; release.removeAll()
            for owner in windows { if let sheet = owner.attachedSheet { owner.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }; owner.contentViewController = nil; owner.close() }
            windows.removeAll()
            try await SettingsTeardownVerification.drain()
        }
    }
    actor Passwords: ProxyPasswordStoring {
        func load() async throws -> String { "" }
        func save(_ value: String) async throws { throw Failure(description: "Teardown must not write Keychain") }
    }
    actor SMTPStore: SMTPCredentialStore {
        func login() async throws -> String { "" }
        func store(login: String, password: String) async throws { throw Failure(description: "Teardown must not store SMTP secrets") }
        func clear() async throws { throw Failure(description: "Teardown must not clear SMTP secrets") }
    }
    static func drain() async throws {
        try await wait("all retired read/save/dialog owners") {
            GitConfigurationSettingsModel.activeReads == 0 && GitConfigurationSettingsModel.activeSaves == 0 && GitConfigurationSettingsModel.activeFolderChoosers == 0 && GitConfigurationSettingsModel.activeSheetReleases == 0 &&
            CredentialSettingsModel.activeReads == 0 && CredentialSettingsModel.activeSaves == 0 && CredentialSettingsModel.activeSelections == 0 && CredentialSettingsModel.activeSheetReleases == 0 &&
            NetworkSettingsModel.activeReads == 0 && NetworkSettingsModel.activeSaves == 0 && NetworkSettingsModel.activeSSHChoosers == 0 && NetworkSettingsModel.activeSheetReleases == 0 &&
            GeneralGitSettingsModel.activeOperations == 0 && GeneralGitSettingsModel.activeDialogs == 0 && MergeEditorSettingsModel.activeProfileEditors == 0 &&
            HookSettingsModel.activeReads == 0 && HookSettingsModel.activeSaves == 0 && HookConfigurationController.activeReleases == 0 && EmailSettingsModel.activeOperations == 0 && EmailSettingsModel.activeCredentialEditors == 0 &&
            RemoteSettingsWindowModel.activeOperations == 0 && RemoteSettingsWindowModel.activeRetirements == 0 && SettingsTransaction.activeApplications == 0 && SettingsTransaction.activeRetirements == 0 && SettingsSheetController.activeSheets == 0
        }
    }
    // Destroy the actual production representable/probe inside NSHosting's graph.
    // The narrow spy distinguishes synchronous graph mutation from legal queued UI reset.
    static func destroyHost<M: ObservableObject, V: View>(_ model: M, view: V, owner: NSWindow, label: String, ready: () -> Bool) async throws where M.ObjectWillChangePublisher == ObservableObjectPublisher {
        var host: NSHostingController<AnyView>? = NSHostingController(rootView: AnyView(view))
        owner.contentViewController = host; owner.orderFront(nil); owner.contentView?.layoutSubtreeIfNeeded()
        try await wait(label + " mounted", ready); await flush()
        var tearingDown = false, synchronous = 0
        let subscription = model.objectWillChange.sink { if tearingDown { synchronous += 1 } }
        tearingDown = true
        autoreleasepool { owner.contentViewController = nil; host = nil; owner.close() }
        tearingDown = false
        withExtendedLifetime(subscription) {}
        try require(synchronous == 0, label + " published inside actual hosted-page destruction")
        await flush()
    }
    static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Settings teardown"), ("user.email", "teardown@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        try Data("private\n".utf8).write(to: root.appendingPathComponent("file")); try await repository.stage(["file"]); _ = try await repository.commit(message: "base")
        let beforeHead = try await repository.run(["rev-parse", "HEAD"]).stdout, beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.SettingsTeardown." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "HintHierarchicalConfig")
        defer { preferences.removePersistentDomain(forName: suite) }
        let scope = Scope()
        do {
            let files = try await repository.gitConfigurationFiles(hasRepository: true)
            let gitModel = GitConfigurationSettingsModel(preferences: preferences)
            gitModel.authorizeFile = { _ in true }; scope.retire.append { gitModel.deactivate() }
            var heldGit: CheckedContinuation<GitConfigurationFiles, Error>?, gitToken: OperationCancellation?
            scope.release.append { heldGit?.resume(throwing: OperationCancellationFailure.cancelled); heldGit = nil }
            gitModel.readConfigurationFiles = { _, _, token in gitToken = token; return try await withCheckedThrowingContinuation { heldGit = $0 } }
            gitModel.activate(repository: repository, access: nil, localAvailable: true)
            try await wait("held Git metadata") { heldGit != nil }
            let gitReceipt = gitModel.editorIdentity
            try quiet(gitModel, "Git deactivate") { gitModel.deactivate() }
            try require(!gitModel.isActive && !gitModel.acceptsSourceSelection(gitReceipt) && gitToken?.isCancelled == true && GitConfigurationSettingsModel.activeReads == 1, "Git retirement did not immediately revoke editor/read authority while retaining worker")
            gitModel.load(.local); try require(GitConfigurationSettingsModel.activeReads == 1, "Retired Git accepted a new source read")
            heldGit?.resume(returning: files); heldGit = nil
            try await wait("retired Git read drain") { GitConfigurationSettingsModel.activeReads == 0 }
            try require(!gitModel.loaded && gitModel.error == nil, "Retired Git metadata published")
            gitModel.readConfigurationFiles = { _, _, _ in files }
            gitModel.activate(repository: repository, access: nil, localAvailable: true)
            try await wait("Git loaded") { gitModel.loaded && !gitModel.busy }
            gitModel.load(.local); try await wait("Git local") { gitModel.loaded && !gitModel.busy && gitModel.source == .local }
            let firstOwner = UUID(), secondOwner = UUID(), firstProbe = UUID(), secondProbe = UUID(), oldWindow = scope.window(), newWindow = scope.window()
            gitModel.attachPresentation(firstOwner); gitModel.attachProbe(owner: firstOwner, identity: firstProbe, window: oldWindow)
            try quiet(gitModel, "Git old presentation detach") { gitModel.detachPresentation(firstOwner) }
            gitModel.attachPresentation(secondOwner); gitModel.attachProbe(owner: secondOwner, identity: secondProbe, window: newWindow)
            gitModel.activate(repository: repository, access: nil, localAvailable: true)
            try quiet(gitModel, "Git stale probe detach") { gitModel.detachProbe(firstProbe); gitModel.detachPresentation(firstOwner) }
            await flush()
            try require(gitModel.isActive && gitModel.window === newWindow && gitModel.acceptsEditor(gitModel.editorIdentity), "Old Git graph retirement reset a newer editor/owner")

            let general = GeneralGitSettingsModel(preferences: preferences), generalOwner = scope.window(), generalAttachment = UUID()
            scope.retire.append { general.suspend() }; general.attach(to: generalOwner, attachment: generalAttachment); await flush()
            var heldEngine: CheckedContinuation<String, Error>?, engineToken: OperationCancellation?
            scope.release.append { heldEngine?.resume(throwing: OperationCancellationFailure.cancelled); heldEngine = nil }
            general.inspectEngine = { _, token in engineToken = token; return try await withCheckedThrowingContinuation { heldEngine = $0 } }
            let language = general.languageBinding(), originalLanguage = general.language
            general.check(); try await wait("held engine probe") { heldEngine != nil }
            try quiet(general, "General suspend") { general.detach(attachment: generalAttachment) }
            language.wrappedValue = "de"; general.check()
            try require(!general.canEditPage && general.language == originalLanguage && engineToken?.isCancelled == true && GeneralGitSettingsModel.activeOperations == 1, "General stale binding/worker lifetime was not fenced immediately")
            let nextGeneral = UUID(); general.attach(to: generalOwner, attachment: nextGeneral)
            try quiet(general, "General stale detach") { general.detach(attachment: generalAttachment) }
            heldEngine?.resume(returning: "git version retired"); heldEngine = nil
            try await wait("engine worker drain") { GeneralGitSettingsModel.activeOperations == 0 }; await flush()
            try require(general.canEditPage && general.version.isEmpty, "Old General retirement clobbered reopened page or installed stale version")

            let finder = FinderContextMenuSettingsModel(defaults: preferences, publish: { _ in false }, notify: {})
            let finderOwner = scope.window(), finderAttachment = UUID(); scope.retire.append { finder.setActive(nil) }
            finder.attach(to: finderOwner, page: .primary, attachment: finderAttachment); await flush()
            let context = finder.context(.primary), paths = finder.binding(\.excludedPaths, context: context), initialPaths = finder.draft.excludedPaths
            try quiet(finder, "Finder detach") { finder.detach(attachment: finderAttachment) }
            paths.wrappedValue = "/stale"; try require(!finder.accepts(context) && finder.draft.excludedPaths == initialPaths, "Detached Finder binding retained authority")
            finder.attach(to: finderOwner, page: .extended, attachment: UUID())
            try quiet(finder, "Finder stale detach") { finder.detach(attachment: finderAttachment) }; await flush()
            try require(finder.accepts(finder.context(.extended)) && finder.activePage == .extended, "Old Finder deferred reset replaced new page")

            let profile = root.appendingPathComponent("private-profiles.ini")
            let merge = MergeEditorSettingsModel(defaults: preferences, commentProfileURL: profile), mergeOwner = scope.window(), mergeAttachment = UUID()
            scope.retire.append { merge.setActive(false) }; merge.attach(to: mergeOwner, attachment: mergeAttachment); await flush()
            let tab = merge.binding(\.tabSize), oldTab = merge.tabSize
            try quiet(merge, "Merge detach") { merge.detach(attachment: mergeAttachment) }
            tab.wrappedValue = "77"; try require(merge.tabSize == oldTab, "Detached Merge binding edited draft")
            merge.attach(to: mergeOwner, attachment: UUID()); try quiet(merge, "Merge stale detach") { merge.detach(attachment: mergeAttachment) }; await flush()
            let current = merge.binding(\.tabSize); current.wrappedValue = "8"; try require(merge.tabSize == "8", "Old Merge retirement disabled new controls")
            merge.openProfiles(context: merge.editContext)
            guard let session = merge.profileSession else { throw Failure(description: "Profile editor did not open") }
            let profileBinding = merge.profileBinding(session), sheet = scope.window()
            mergeOwner.beginSheet(sheet, completionHandler: nil); merge.attachProfileWindow(sheet, session: session.id)
            try quiet(merge, "Merge held profile retirement") { merge.setActive(false) }
            profileBinding.wrappedValue = "stale"
            try require(merge.profileSession?.text == session.text && MergeEditorSettingsModel.activeProfileEditors == 1 && sheet.sheetParent === mergeOwner, "Profile retirement lost sheet ownership or accepted stale editor")
            try await wait("profile actual detach") { sheet.sheetParent == nil && MergeEditorSettingsModel.activeProfileEditors == 0 }
            let colors = MergeColorsSettingsModel(preferences: preferences, dark: false), colorsOwner = scope.window(), colorsAttachment = UUID()
            scope.retire.append { colors.setActive(false) }; colors.attach(to: colorsOwner, attachment: colorsAttachment); await flush()
            let palette = colors.editContext
            try quiet(colors, "Merge colors detach") { colors.detach(attachment: colorsAttachment) }
            colors.selectPalette(true, context: palette); try require(!colors.dark && !colors.accepts(palette), "Detached color selector retained authority")
            colors.attach(to: colorsOwner, attachment: UUID()); try quiet(colors, "Merge colors stale detach") { colors.detach(attachment: colorsAttachment) }; await flush()
            try require(colors.accepts(colors.editContext), "Old colors retirement disabled new page")

            let credential = CredentialSettingsModel(repository: repository, access: nil, localAvailable: true)
            scope.retire.append { credential.deactivate() }; credential.authorizeFile = { _ in true }
            credential.activate(); try await wait("Credential loaded") { credential.snapshot != nil && !credential.busy }
            // An empty private configuration correctly opens the simple None
            // mode. Enter the actual Advanced editor before testing its authority.
            credential.editMode("advanced", identity: credential.editorIdentity)
            try require(credential.canEditFields, "Credential Advanced editor did not accept authorized mode selection")
            let credentialReceipt = credential.editorIdentity, username = credential.draft.username
            try quiet(credential, "Credential deactivate") { credential.deactivate() }
            credential.editUsername("stale", identity: credentialReceipt)
            try require(!credential.isActive && credential.draft.username == username, "Retired Credential editor accepted input")
            credential.activate(); await flush(); try require(credential.canEditFields, "Deferred Credential retirement reset current activation")
            let oldCredentialOwner = UUID(), newCredentialOwner = UUID(), oldCredentialProbe = UUID(), newCredentialProbe = UUID(), credentialWindow = scope.window()
            credential.attachPresentation(oldCredentialOwner); credential.attachProbe(owner: oldCredentialOwner, identity: oldCredentialProbe, window: scope.window())
            credential.attachPresentation(newCredentialOwner); credential.attachProbe(owner: newCredentialOwner, identity: newCredentialProbe, window: credentialWindow)
            try quiet(credential, "Credential stale probe detach") { credential.detachProbe(oldCredentialProbe); credential.detachPresentation(oldCredentialOwner) }
            await flush(); try require(credential.isActive && credential.window === credentialWindow && credential.canEditFields, "Old Credential probe retired replacement owner")

            let network = NetworkSettingsModel(repository: repository, access: nil, localAvailable: true, preferences: preferences, passwords: Passwords())
            scope.retire.append { network.deactivate() }; network.authorizeFile = { _ in true }; network.activate()
            try await wait("Network loaded") { network.loaded && !network.busy }
            let networkReceipt = network.editorIdentity
            try quiet(network, "Network deactivate") { network.deactivate() }
            try require(!network.acceptsEditor(networkReceipt) && !network.canEditSSH, "Retired Network controls retained authority")
            network.activate(); await flush(); try require(network.acceptsEditor(network.editorIdentity), "Deferred Network retirement reset current activation")
            let oldNetworkOwner = UUID(), newNetworkOwner = UUID(), oldNetworkProbe = UUID(), newNetworkProbe = UUID(), networkWindow = scope.window()
            network.attachPresentation(oldNetworkOwner); network.attachProbe(owner: oldNetworkOwner, identity: oldNetworkProbe, window: scope.window())
            network.attachPresentation(newNetworkOwner); network.attachProbe(owner: newNetworkOwner, identity: newNetworkProbe, window: networkWindow)
            try quiet(network, "Network stale probe detach") { network.detachProbe(oldNetworkProbe); network.detachPresentation(oldNetworkOwner) }
            await flush(); try require(network.isActive && network.window === networkWindow && network.acceptsEditor(network.editorIdentity), "Old Network probe retired replacement owner")

            let remote = RemoteSettingsWindowModel(repository: repository, access: nil, preferences: preferences), remoteAttachment = UUID()
            scope.retire.append { remote.invalidate() }; remote.attach(attachment: remoteAttachment); remote.load()
            try await wait("Remote loaded") { !remote.busy }; var updates = 0; remote.updated = { updates += 1 }
            try quiet(remote, "Remote invalidate") { remote.invalidate(attachment: remoteAttachment) }
            try require(remote.closed && !remote.acceptsAttachment(remoteAttachment) && updates == 0, "Remote retirement synchronously updated native view or retained authority")
            let secondRemote = UUID(); remote.attach(attachment: secondRemote)
            try quiet(remote, "Remote stale view retirement") { remote.invalidate(attachment: remoteAttachment) }; await flush()
            try require(!remote.closed && remote.acceptsAttachment(secondRemote), "Old Remote teardown closed replacement view")

            let hooks = HookSettingsModel(preferences: preferences), hooksOwner = scope.window(), hooksAttachment = UUID()
            scope.retire.append { hooks.invalidate() }; hooks.attach(to: hooksOwner, attachment: hooksAttachment)
            hooks.activate(repository: repository, access: nil); try await wait("Hooks loaded") { hooks.loaded && !hooks.busy }; await flush()
            hooks.configure(add: true); try await wait("Hook editor attached") { hooks.hasEditor && hooksOwner.attachedSheet != nil }
            let hooksBefore = hooks.hooks
            try quiet(hooks, "Hook detach with editor") { hooks.detach(attachment: hooksAttachment) }
            hooks.configure(add: true); hooks.remove()
            try require(!hooks.editable && hooks.hasEditor && HookConfigurationController.activeReleases == 1 && hooks.hooks == hooksBefore, "Hook teardown lost deferred editor ownership or accepted commands")
            hooks.attach(to: hooksOwner, attachment: UUID()); try quiet(hooks, "Hook stale detach") { hooks.detach(attachment: hooksAttachment) }
            try await wait("Hook actual editor release") { !hooks.hasEditor && hooksOwner.attachedSheet == nil && HookConfigurationController.activeReleases == 0 }; await flush()
            try require(hooks.editable, "Old Hook reset retired new page")

            let email = EmailSettingsModel(preferences: preferences, credentials: SMTPStore(), mailClientAvailable: false)
            scope.retire.append { email.invalidate() }; email.delivery = .configured; email.authenticate = true
            let mailOwner = UUID(), replacementMailOwner = UUID(); email.claimCredentialOwner(mailOwner)
            var mailReply: (((String, String)?) -> Void)?
            scope.release.append { mailReply?(nil); mailReply = nil }
            email.presentCredentialEditor = { _, reply in mailReply = reply }; email.cancelCredentialEditor = { }
            email.editCredentials(); try require(mailReply != nil && EmailSettingsModel.activeCredentialEditors == 1, "SMTP editor ownership not established")
            email.claimCredentialOwner(replacementMailOwner)
            try quiet(email, "SMTP stale host detach") { email.revokeCredentialOwner(mailOwner) }
            try quiet(email, "Email invalidate with outstanding reply") { email.invalidate() }
            try require(!email.credentialControls && EmailSettingsModel.activeCredentialEditors == 1, "SMTP retirement released accepted reply before its actual callback")
            let retiredReply = mailReply; mailReply = nil; retiredReply?(("late", "secret")); retiredReply?(nil)
            try await wait("SMTP retired reply drain") { EmailSettingsModel.activeCredentialEditors == 0 }
            try require(email.login.isEmpty && EmailSettingsModel.activeOperations == 0, "Late/duplicate SMTP reply started secret storage")
            let hostedEmail = EmailSettingsModel(preferences: preferences, credentials: SMTPStore(), mailClientAvailable: false)
            scope.retire.append { hostedEmail.invalidate() }

            let retiredTransaction = SettingsTransaction()
            var cancelledDrafts = 0
            retiredTransaction.register("retired-page", participant: .init(page: .credential, modified: { true }, validate: { nil }, apply: { false }, cancel: { credential.cancelDraft(); cancelledDrafts += 1 }))
            try quiet(credential, "Transaction-owned draft cancellation") { retiredTransaction.invalidate() }
            try require(cancelledDrafts == 0, "Transaction invoked draft callbacks inside graph invalidation")
            await flush(); try require(cancelledDrafts == 1, "Retired transaction lost/duplicated its captured draft cancellation")

            // Real NSHosting destruction exercises the production onDisappear +
            // dismantleNSView path that previously aborted hosted CI.
            let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) })
            scope.retire.append { workspace.stopMonitoringForTermination() }
            let appearance = SettingsAppearanceDraft(appearance: AppAppearance(preferences: preferences))
            try await destroyHost(gitModel, view: GitConfigurationSettingsPage(workspace: workspace, globalOnly: true, preferences: preferences, model: gitModel), owner: scope.window(), label: "Git Settings") { gitModel.isActive && !gitModel.busy }
            try await destroyHost(general, view: GeneralSettings(appearance: appearance, model: general, preferences: preferences), owner: scope.window(), label: "General Settings") { general.window != nil && general.canEditPage }
            try await destroyHost(finder, view: FinderContextMenuSettingsPage(model: finder, extendedOnly: false), owner: scope.window(), label: "Finder Settings") { finder.accepts(finder.context(.primary)) }
            try await destroyHost(merge, view: MergeEditorSettings(defaults: preferences, commentProfileURL: profile, model: merge), owner: scope.window(), label: "Merge Settings") { merge.active }
            try await destroyHost(colors, view: MergeColorsSettings(model: colors), owner: scope.window(), label: "Merge Colors") { colors.accepts(colors.editContext) }
            try await destroyHost(credential, view: CredentialSettingsPage(model: credential), owner: scope.window(), label: "Credential Settings") { credential.isActive && !credential.busy }
            try await destroyHost(network, view: NetworkSettingsPage(model: network), owner: scope.window(), label: "Network Settings") { network.loaded && !network.busy }
            try await destroyHost(hooks, view: HookSettingsPage(model: hooks, repository: repository, access: nil), owner: scope.window(), label: "Hook Settings") { hooks.editable }
            try await destroyHost(hostedEmail, view: EmailSettingsPage(model: hostedEmail), owner: scope.window(), label: "Email Settings") { !hostedEmail.busy }
            try await destroyHost(remote, view: RemoteSettingsEmbeddedPage(model: remote), owner: scope.window(), label: "Remote Settings") { !remote.closed && !remote.busy }
            try await scope.close()
            try require(try await repository.run(["rev-parse", "HEAD"]).stdout == beforeHead && Data(contentsOf: root.appendingPathComponent(".git/index")) == beforeIndex, "Settings teardown changed Git index/history")
            print("PASS: Settings retirement has no synchronous graph publication, fences stale controls immediately, retains actual workers/sheets and survives real hosted-page destruction")
        } catch { let failure = error; try await scope.close(); throw failure }
    }
}
