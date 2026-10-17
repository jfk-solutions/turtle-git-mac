// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct ProjectDialogSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var models = [ProjectDialogSettingsModel]()
    @MainActor static var windows = [NSWindow]()
    @MainActor static var releaseHeld: (() -> Void)?
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<1800 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Project settings wait at line \(line)")
    }
    @MainActor static func cleanup() async {
        models.forEach { $0.invalidate() }; releaseHeld?(); releaseHeld = nil
        windows.forEach { $0.close() }
        for _ in 0..<1800 {
            if ProjectDialogSettingsModel.activeReads == 0 && ProjectDialogSettingsModel.activeSaves == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); await cleanup(); print("PASS: Project dialog source forms, native picker ownership, exact configuration writes and retired reads/saves") }
        catch { await cleanup(); fputs("Project dialog source failure: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func capture(_ window: NSWindow) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_PROJECT_DIALOG_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture API unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Own window missing") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width * 2); options.height = Int(window.frame.height * 2)
            options.showsCursor = false; options.ignoreShadowsSingleWindow = true; options.includeChildWindows = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            try NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("project-dialog-source-" + suffix + ".png"))
            print("Captured Project dialogs \(suffix): \(options.width)x\(options.height)")
        }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Project Settings QA"), ("user.email", "project@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("tgit.logminsize", "12"), ("tgit.logwidthmarker", "72"), ("tgit.projectlanguage", "1033"), ("tgit.icon", "café.ico")] { _ = try await repo.run(["config", key, value]) }
        try Data("[tgit]\nlogminsize = 7\nprojectlanguage = 1031\n".utf8).write(to: root.appendingPathComponent(".tgitconfig"))
        try await repo.stage([".tgitconfig"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.ProjectSource." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "HintHierarchicalConfig"); defer { preferences.removePersistentDomain(forName: suite) }
        func model() -> ProjectDialogSettingsModel {
            let value = ProjectDialogSettingsModel(preferences: preferences); value.authorizeFile = { _ in true }; models.append(value); return value
        }
        let value = model(), workspace = RepositoryModel(startMonitoring: false), transaction = SettingsTransaction()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        windows.append(window); window.title = "Dialogs 3 – TurtleGit for Mac"; window.isReleasedWhenClosed = false; window.alphaValue = 0
        let host = NSHostingView(rootView: ProjectDialogSettingsPage(workspace: workspace, preferences: preferences, model: value, contextProvider: { (repo, nil, true) }).environment(\.settingsTransaction, transaction))
        window.contentView = host; window.setContentSize(.init(width: 760, height: 700)); window.orderFront(nil)
        defer { transaction.invalidate() }
        try await wait { value.loaded && !value.busy && value.window === window }
        let effective = value.formContext
        try require(!value.editable && value.draft.minimumMessageLength.value == "12", "Effective precedence or read-only policy")
        value.sourceSelection(context: effective).wrappedValue = .local
        try await wait { value.loaded && !value.busy && value.source == .local }
        let oldText = value.text(.minimum, context: value.formContext), oldSource = value.sourceSelection(context: value.formContext)
        value.text(.minimum, context: effective).wrappedValue = "99"
        try require(value.draft.minimumMessageLength.value == "12", "Effective callback reached Local")
        value.inherit(.minimum, context: value.formContext).wrappedValue = true
        oldText.wrappedValue = "98"; oldSource.wrappedValue = .global
        try require(value.draft.minimumMessageLength.inherit && value.source == .local && value.draft.minimumMessageLength.value == "12", "Dependency transition retained old controls")
        value.cancel(); oldText.wrappedValue = "97"
        try require(!value.modified && value.draft.minimumMessageLength.value == "12", "Cancel retained old control")
        // Canonically equivalent path spellings are still distinct Git configuration bytes.
        let before = value.state, decomposed = "cafe\u{301}.ico"
        value.text(.icon, context: value.formContext).wrappedValue = decomposed
        try require(value.modified && value.state != before, "Exact Unicode icon spelling was lost")
        try await wait { transaction.modified }; transaction.apply(closeAfter: false)
        try await wait { !transaction.busy && !value.busy }
        let firstSaved = try await repo.projectDialogSettings(source: .local)
        try require(transaction.error == nil && !value.modified && firstSaved.icon.value.utf8.elementsEqual(decomposed.utf8), "Property-sheet Apply lost exact icon spelling")
        // Picker starts at the current relative file and commits once to its captured draft.
        var pickerReply: ((URL?) -> Void)?, initial: URL?, remembered = [URL]()
        value.rememberIcon = { remembered.append($0) }; value.chooseIcon = { initial = $0; pickerReply = $1 }
        let prePicker = value.formContext, blockedText = value.text(.icon, context: prePicker)
        value.browseIcon(context: prePicker)
        try require(value.selectingIcon && !value.canSelectSource && initial?.path.utf8.elementsEqual(root.appendingPathComponent(decomposed).path.utf8) == true, "Picker origin or source blocking")
        blockedText.wrappedValue = "during picker"; value.load(.project)
        try require(value.source == .local && value.draft.icon.value.utf8.elementsEqual(decomposed.utf8), "Picker allowed concurrent edits/source switch")
        pickerReply?(root.appendingPathComponent("assets/project.ico")); pickerReply?(root.appendingPathComponent("duplicate.ico"))
        try require(!value.selectingIcon && value.draft.icon.value == "assets/project.ico" && remembered.count == 1, "Picker did not publish once/relative")
        blockedText.wrappedValue = "after picker"
        try require(value.draft.icon.value == "assets/project.ico", "Picker roundtrip revived prior field")
        value.browseIcon(context: value.formContext); let changedReply = pickerReply
        value.draft.icon.value = "newer.ico"; changedReply?(root.appendingPathComponent("old-choice.ico"))
        try require(value.draft.icon.value == "newer.ico" && remembered.count == 1, "Picker overwrote a newer draft")
        value.browseIcon(context: value.formContext); let retiredReply = pickerReply
        value.suspend(); value.activate(repository: repo, access: nil, localAvailable: true); retiredReply?(root.appendingPathComponent("retired.ico"))
        try require(value.draft.icon.value == "newer.ico" && remembered.count == 1, "Suspended picker published after reactivation")
        value.chooseIcon = nil
        // Actual native picker cancellation; selection/acceptance is injected above, no global input.
        value.browseIcon(context: value.formContext)
        try await wait { window.attachedSheet is NSOpenPanel }
        let panel = window.attachedSheet as! NSOpenPanel
        try require(panel.directoryURL?.standardizedFileURL == root.standardizedFileURL && panel.message == "Current overlay icon: newer.ico", "Native picker did not show current icon/folder: directory=\(String(describing: panel.directoryURL)), message=\(panel.message.debugDescription)")
        window.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
        try await wait { !value.selectingIcon && window.attachedSheet == nil }
        // Every editable field reaches a real project configuration, with inherited removal.
        value.language(context: value.formContext).wrappedValue = "-1"
        value.inherit(.minimum, context: value.formContext).wrappedValue = false
        value.text(.minimum, context: value.formContext).wrappedValue = "24"
        value.inherit(.border, context: value.formContext).wrappedValue = true
        value.signedOff(context: value.formContext).wrappedValue = .enabled
        value.destinationSelection(context: value.formContext).wrappedValue = .project
        value.confirmSavingTo = { $0 == .project }
        let saveResult = await value.apply(owner: window)
        let project = try await repo.projectDialogSettings(source: .project)
        try require(saveResult && project.language.value == "-1" && project.minimumMessageLength.value == "24" && project.messageWidthMarker.inherit && project.warnNoSignedOffBy == .enabled && project.icon.value == "newer.ico", "Full project write/removal differs")
        try require(try await repo.projectDialogSettings(source: .local).minimumMessageLength.value == "12", "Project save overwrote Local")
        // Invalid language and embedded NUL paths are rejected before any writes.
        for bad in ["-2", "4294967296", "invalid"] { value.draft.language = .init(value: bad, inherit: false); try require(value.validationError != nil, "Invalid project language accepted") }
        value.draft.language = .init(value: "0x409", inherit: false); try require(value.validationError == nil, "Source hex locale rejected")
        value.draft.icon.value = "bad\0path"; try require(value.validationError != nil, "NUL path accepted"); value.cancel()
        try await capture(window)
        // Read-only System/Effective and global-only scopes cannot be used as destinations.
        value.sourceSelection(context: value.formContext).wrappedValue = .project
        try await wait { value.loaded && !value.busy && value.source == .project }
        let projectContext = value.formContext
        value.destinationSelection(context: projectContext).wrappedValue = .system
        try require(value.destination == .project, "System destination accepted")
        value.sourceSelection(context: value.formContext).wrappedValue = .local
        try await wait { value.loaded && !value.busy && value.source == .local }
        value.text(.minimum, context: projectContext).wrappedValue = "70"
        try require(value.draft.minimumMessageLength.value == "12", "Old Project callback reached Local")
        let foreign = model(); foreign.activate(repository: repo, access: nil, localAvailable: true)
        try await wait { foreign.loaded && !foreign.busy }; foreign.load(.local); try await wait { foreign.loaded && !foreign.busy }
        foreign.text(.minimum, context: value.formContext).wrappedValue = "foreign"
        try require(foreign.draft.minimumMessageLength.value == "12", "Foreign form context accepted")
        let barePath = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, barePath.path])
        let bareRepo = GitRepository(root: barePath, executable: engine), bareModel = model()
        bareModel.activate(repository: bareRepo, access: nil, localAvailable: true)
        try await wait { bareModel.loaded && !bareModel.busy }
        bareModel.load(.project); try await wait { bareModel.loaded && !bareModel.busy && bareModel.source == .project }
        try require(bareModel.bare && bareModel.sourceAvailable(.project) && !bareModel.destinationAvailable(.project) && bareModel.destination == .local && bareModel.draft.minimumMessageLength.value == "7", "Bare project HEAD read/destination policy")
        let globalPath = root.deletingLastPathComponent().appendingPathComponent("global-only")
        try FileManager.default.createDirectory(at: globalPath, withIntermediateDirectories: true)
        let globalModel = model(); globalModel.activate(repository: GitRepository(root: globalPath, executable: engine), access: nil, localAvailable: false)
        try await wait { globalModel.loaded && !globalModel.busy }
        globalModel.load(.global); try await wait { globalModel.loaded && !globalModel.busy && globalModel.source == .global }
        let globalContext = globalModel.formContext
        globalModel.destinationSelection(context: globalContext).wrappedValue = .local
        globalModel.sourceSelection(context: globalContext).wrappedValue = .project
        try require(globalModel.destination == .global && globalModel.source == .global && !globalModel.sourceAvailable(.local), "Global-only scope allowed repository configuration")
        // Accepted source-ordered writes retain captured values through forced close.
        var finishWrite: CheckedContinuation<Void, Never>?
        value.text(.minimum, context: value.formContext).wrappedValue = "31"
        value.writeSettings = { repository, settings, destination, local in
            await withCheckedContinuation { finishWrite = $0; releaseHeld = { finishWrite?.resume(); finishWrite = nil } }
            try await repository.saveProjectDialogSettings(settings, destination: destination, hasRepository: local)
        }
        let save = Task { await value.apply(owner: window) }; try await wait { finishWrite != nil }
        let staleBusy = value.text(.minimum, context: value.formContext); staleBusy.wrappedValue = "32"
        window.close(); try require(!value.active && ProjectDialogSettingsModel.activeSaves == 1, "Owner close lost accepted save")
        releaseHeld?(); releaseHeld = nil; let closedResult = await save.value
        let closedSaved = try await repo.projectDialogSettings(source: .local)
        try require(!closedResult && closedSaved.minimumMessageLength.value == "31" && ProjectDialogSettingsModel.activeSaves == 0, "Retired captured save differs")
        let delayed = model(), files = try await repo.gitConfigurationFiles(hasRepository: true)
        var finishRead: CheckedContinuation<GitConfigurationFiles, Error>?, readToken: OperationCancellation?
        delayed.readConfigurationFiles = { _, _, token in readToken = token; return try await withCheckedThrowingContinuation { finishRead = $0; releaseHeld = { finishRead?.resume(returning: files); finishRead = nil } } }
        delayed.activate(repository: repo, access: nil, localAvailable: true); try await wait { finishRead != nil }
        delayed.invalidate(); try require(readToken?.isCancelled == true && ProjectDialogSettingsModel.activeReads == 1, "Retired read lost cancellation/count")
        releaseHeld?(); releaseHeld = nil; try await wait { ProjectDialogSettingsModel.activeReads == 0 }
        try require(!delayed.loaded && delayed.error == nil, "Retired read published")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Settings changed HEAD/index")
    }
}
