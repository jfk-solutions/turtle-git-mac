import SwiftUI
import AppKit
import TurtleGitCore
import UniformTypeIdentifiers

// Select one concrete SwiftUI App before it creates scenes. SceneBuilder on
// supported older SDKs has no buildEither; branching belongs in this entry.
@main struct TurtleGitApplication {
    @MainActor static func main() {
        if let status = RebaseEditor.handle(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) { exit(status) }
        GitConfigurationPermissions.restore()
        ProgressActionLog.install()
        OperationSounds.enabled = true
        DialogGeometry.install()
        let launch = TurtleGitLaunchMode.resolve(arguments: Array(CommandLine.arguments.dropFirst()), currentDirectory: FileManager.default.currentDirectoryPath)
        if launch == .unifiedDiff {
            TurtleGitUnifiedDiffApp.main()
        } else if launch == .mergeTool {
            TurtleGitMergeToolApp.main()
        } else {
            TurtleGitApplicationDelegate.generalApplicationConfiguration = { delegate in
                WorkspaceSceneOwner.shared.configure(applicationDelegate: delegate)
            }
            TurtleGitMacApp.main()
        }
    }
}

struct TurtleGitUnifiedDiffApp: App {
    @NSApplicationDelegateAdaptor(TurtleGitApplicationDelegate.self) private var applicationDelegate
    @StateObject private var patchMenu = PatchMenuContext()
    var body: some Scene {
        Settings { EmptyView() }
            .commands { UnifiedDiffBaseCommands(context: patchMenu); PatchFileCommands(context: patchMenu) }
    }
}

struct UnifiedDiffBaseCommands: Commands {
    @ObservedObject var context: PatchMenuContext
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { context.openDocument() }.keyboardShortcut("o").disabled(!context.documentAvailable)
        }
        CommandGroup(replacing: .appSettings) { }
        CommandGroup(replacing: .appInfo) {
            Button("About TurtleGitUDiff…") { TurtleGitAboutService.shared.show(.unified) }
        }
        CommandGroup(replacing: .help) {
            Button("TurtleGit Help") { TurtleGitHelp.showContext() }.keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct TurtleGitMergeToolApp: App {
    @NSApplicationDelegateAdaptor(TurtleGitApplicationDelegate.self) private var applicationDelegate
    @StateObject private var mergeToolMenu = MergeToolMenuContext()
    var body: some Scene {
        // Settings has no automatic document window. The delegate creates only
        // the requested AppKit tool/chooser after launch has finished.
        Settings { EmptyView() }
            .commands { MergeToolBaseCommands(context: mergeToolMenu) }
    }
}

struct TurtleGitMacApp: App {
    @NSApplicationDelegateAdaptor(TurtleGitApplicationDelegate.self) private var applicationDelegate
    @StateObject private var workspaceScene = WorkspaceSceneOwner.shared
    @StateObject private var hookProcesses = ClientHookProcessPool.shared
    @StateObject private var blameMenuContext = BlameMenuContext()
    @StateObject private var patchMenuContext = PatchMenuContext()
    @StateObject private var statisticsMenuContext = StatisticsMenuContext()
    @StateObject private var messageMenuContext = MessageEditorMenuContext()
    var body: some Scene {
        // AppKit delivers the actual launch intent after scene construction.
        // No repository window exists until the delegate requests the host.
        Settings { EmptyView() }
        .commands {
            AppUtilityCommands()
            EditorFileCommands(blame: blameMenuContext, patch: patchMenuContext, statistics: statisticsMenuContext, message: messageMenuContext)
            RepositoryCommands(model: workspaceScene.commandModel, hookProcesses: hookProcesses,
                               openRepository: { applicationDelegate.requestWorkspace(openRepository: true) },
                               openRecent: { saved in
                                   guard let model = workspaceScene.presentWorkspace() else { return }
                                   model.openRecent(saved)
                               })
            WorkspaceAppearanceCommands(appearance: workspaceScene.appearance)
            #if DEBUG
            CommandMenu("Development") {
                Button("Save Window Screenshot…") { DocumentationCapture.saveWindow() }.keyboardShortcut("s", modifiers: [.command, .option, .shift])
            }
            #endif
        }
    }
}
@MainActor private struct WorkspaceAppearanceCommands: Commands {
    @ObservedObject var appearance: AppAppearance
    var body: some Commands {
        CommandMenu("Appearance") {
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

// Keep command domains below the ten-child limit of older SwiftUI SDKs.
// The Scene builder has five Debug/four Release children; these providers have
// four and four. Actions, placements, shortcut bindings and order stay local.
@MainActor private struct AppUtilityCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsPresentationService.shared.show() }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About TurtleGit for Mac") { SettingsPresentationService.showAbout() }
            Menu("About Tools") {
                ForEach(TurtleGitAboutTool.tools, id: \.self) { tool in Button("About " + tool.title) { TurtleGitAboutService.shared.show(tool) } }
            }
        }
        CommandGroup(replacing: .help) {
            Button("TurtleGit Help") { SettingsPresentationService.showHelp() }.keyboardShortcut("?", modifiers: .command)
            Button { SupportReportService.shared.show() } label: { CommandLabel(title: "Report a Problem…", icon: .help) }
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { ReleaseUpdateService.shared.show() }
            Button("First Start Wizard…") { FirstStartWizardService.shared.show() }
            Button("SSH Key Generator…") { SSHKeyGenerationService.shared.show() }
            Button("Saved SSH Authentication…") { SavedSSHAuthenticationService.shared.show() }
        }
    }
}
@MainActor private struct RepositoryCommands: Commands {
    @ObservedObject var model: RepositoryModel
    @ObservedObject var hookProcesses: ClientHookProcessPool
    var openRepository: () -> Void
    var openRecent: (SavedRepository) -> Void
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button { model.showFileTransfer(copy: true, urls: []) } label: { CommandLabel(title: "Copy and Add…", icon: .add) }.disabled(model.root == nil || model.bare || model.busy)
            Button { model.showFileTransfer(copy: true) } label: { CommandLabel(title: "Paste Copy and Add…", icon: .copy) }.disabled(model.root == nil || model.bare || model.busy)
            Button { model.showFileTransfer(copy: false) } label: { CommandLabel(title: "Paste Move…", icon: .rename) }.disabled(model.root == nil || model.bare || model.busy)
        }
        CommandGroup(after: .newItem) {
            Button { if let owner = PatchWindowController.focusedOwner(NSApp.keyWindow ?? NSApp.mainWindow), owner.documentSession.enabled { owner.documentSession.openDocument() } else { BlameWindowController.openFocused(NSApp.keyWindow ?? NSApp.mainWindow) { openRepository() } } } label: { CommandLabel(title:"Open…",icon:.open) }.keyboardShortcut("o")
            Button { model.showClipboardPatch() } label: { CommandLabel(title: "Review Clipboard Patch…", icon: .patch) }.disabled(model.busy || model.confirmingQuit)
            Button { model.showReviewPatch(files: []) } label: { CommandLabel(title: RepositoryAction.reviewPatch.title, icon: RepositoryAction.reviewPatch.icon) }.disabled(model.busy || model.confirmingQuit)
            Button { model.showMergeOpen() } label: { CommandLabel(title: "Open in TurtleGitMerge…", icon: .open) }.disabled(model.busy || model.confirmingQuit)
            Button("Cancel Running Hook Scripts", action: hookProcesses.cancelAll).disabled(hookProcesses.activeScripts == 0)
            Button { model.showAutotextTester() } label: { CommandLabel(title: "Autotext Tester…", icon: .settings) }.disabled(model.busy || model.confirmingQuit)
            Button { model.showIssueRegexTester() } label: { CommandLabel(title: "Bugtraq Regex Tester…", icon: .settings) }.disabled(model.busy || model.confirmingQuit)
            Button("Load Images…") { model.showLoadImages() }.disabled(model.busy || model.confirmingQuit)
            Menu("Open Recent") {
                ForEach(model.recentRepositories) { saved in
                    Button(saved.name) { openRecent(saved) }.help(saved.lastKnownPath)
                }
                Divider()
                Button { model.showRepositoryAccess() } label: { CommandLabel(title:"Manage Repository Access…",icon:.settings) }
            }.disabled(model.busy || model.confirmingQuit)
            Button("Close Repository") { model.closeRepository() }.disabled(model.busy || model.root == nil)
            Button("Clone…") { model.activate(.clone) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Create Repository…") { model.activate(.initialize) }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("TurtleGit") {
            ForEach(RepositoryAction.allCases.filter { $0 != .reviewPatch && $0 != .clone && $0 != .initialize && $0 != .editConflict && $0 != .diffLater && $0 != .clearComparisonMark && $0.resolveChoice == nil }) { action in
                Button { model.activate(action) } label: { CommandLabel(title: action.title, icon: action.icon) }.disabled(model.root == nil || model.busy || (action.svnOperation != nil && !model.hasGitSVN) || (model.bare && action.requiresWorkingTree) || (action == .mergeAbort && !model.mergeActive) || (action == .rename && !model.canRenameSelection) || ([RepositoryAction.remove, .removeKeep].contains(action) && !model.canRemoveSelection) || (action.isIgnore && !model.canIgnoreSelection(action)) || (action.isResolve && !model.canResolveSelection))
            }
            Button { model.showLFSLocks() } label: { CommandLabel(title: "LFS Locks…", icon: .lock) }.disabled(model.root == nil || model.bare || model.busy || model.confirmingQuit)
            Button { model.showSynchronization() } label: { CommandLabel(title: "Git Synchronization…", icon: .sync) }.disabled(model.root == nil || model.bare || model.busy || model.confirmingQuit)
            Divider()
            Button { model.activate(.diffLater) } label: { CommandLabel(title: model.comparisonMarkTitle, icon: .compare) }.disabled(model.busy || model.confirmingQuit)
            Button { model.activate(.clearComparisonMark) } label: { CommandLabel(title: RepositoryAction.clearComparisonMark.title, icon: .compare) }.disabled(model.busy || model.confirmingQuit || model.workingComparisonMark == nil)
        }
    }
}

@MainActor private struct EditorFileCommands: Commands {
    let blame: BlameMenuContext
    let patch: PatchMenuContext
    let statistics: StatisticsMenuContext
    let message: MessageEditorMenuContext
    var body: some Commands {
        BlameCommands(context: blame)
        PatchFileCommands(context: patch)
        StatisticsFileCommands(context: statistics)
        MessageEditorCommands(context: message)
    }
}

struct WorkspaceStatusRow:Identifiable {
    let entry:StatusEntry
    var id:String {GitPathRowIdentity.encode(entry.path)}
    var path:String {entry.path}
    var originalPath:String? {entry.originalPath}
    var state:FileState {entry.state}
    var staged:Bool {entry.staged}
}

struct RepositoryWindow: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: RepositoryModel
    var onWorkspaceWindowAttached: () -> Void = {}
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                Text(model.root?.path ?? "No repository selected").textSelection(.enabled).lineLimit(1).id(model.root.map { Data($0.path.utf8) })
                Spacer()
                if model.root != nil { Label(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch, systemImage: "arrow.triangle.branch") }
                if model.busy { ProgressView().controlSize(.small) }
            }.font(.system(size: 12)).padding(10).background(.bar)
            Divider()
            if model.root == nil { welcome } else {
                HSplitView {
                    ScrollView { VStack(alignment: .leading, spacing: 8) {
                        Text("TurtleGit").font(.headline).padding(.bottom, 8)
                        ForEach([RepositoryAction.status, .commit, .log, .daemon, .revisionGraph, .referenceBrowser, .repositoryBrowser, .export, .bisect, .formatPatch, .importPatch, .requestPull]) { action in
                            Button { model.activate(action) } label: {
                                CommandLabel(title: action.title, icon: action.icon).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(model.section == action ? Color.accentColor.opacity(0.14) : .clear)
                                    .cornerRadius(4)
                            }.buttonStyle(.plain).disabled(model.bare && action.requiresWorkingTree)
                        }
                        Divider()
                        ForEach([RepositoryAction.pull, .push, .fetch, .branch, .tag, .switchBranch, .merge, .mergeAbort, .rebase, .stash, .stashApply, .stashPop, .stashList, .reflog]) { action in
                            Button { model.activate(action) } label: { CommandLabel(title: action.title, icon: action.icon) }.buttonStyle(.plain).padding(6).disabled((model.bare && action.requiresWorkingTree) || (action == .mergeAbort && !model.mergeActive))
                        }
                        Spacer()
                        Text("Native macOS port • In development").font(.caption).foregroundStyle(.secondary)
                    }.padding(12) }.frame(minWidth: 185, idealWidth: 205, maxWidth: 260).disabled(model.busy)
                    VSplitView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.bare ? "Bare repository" : model.section.title.replacingOccurrences(of: "…", with: "")).font(.title2).padding(.horizontal, 12)
                            if model.bare {
                                VStack(spacing: 12) {
                                    Text("This repository stores Git history without a working tree.").foregroundStyle(.secondary)
                                    HStack {
                                        Button { model.activate(.log) } label: { CommandLabel(title: "Show Log", icon: .log) }
                                        Button { model.activate(.fetch) } label: { CommandLabel(title: "Fetch…", icon: .fetch) }
                                        Button { model.activate(.push) } label: { CommandLabel(title: "Push…", icon: .push) }
                                    }.disabled(model.busy)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else { status }
                        }.padding(.vertical, 12).frame(minHeight: 260)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(model.bare ? "Operation output" : "Diff / Operation output").font(.headline)
                                Spacer()
                                if !model.bare {
                                    Toggle("Staged diff", isOn: $model.stagedDiff).toggleStyle(.checkbox)
                                    Button("Show diff") { model.showDiff() }.disabled(model.busy)
                                }
                            }.padding(10).background(.bar)
                            OutputView(text: model.output).frame(minHeight: 120)
                        }
                    }.frame(minWidth: 620)
                }
            }
            Divider()
            HStack {
                Text(model.bare ? "Bare repository • no working tree" : "\(model.visibleEntries.count) changed • \(model.entries.filter(\.staged).count) staged")
                Spacer()
                Text(model.finderStatus).lineLimit(1).help(model.finderStatus)
                Text(model.busy ? "Working…" : "Ready")
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 920, minHeight: 650)
        .background(RepositoryWindowCapture(model: model, onAttached: onWorkspaceWindowAttached).frame(width: 0, height: 0))
        .sheet(item: $model.dialog) { action in OperationDialog(model: model, action: action) }
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 56)).foregroundStyle(.green)
            Text("TurtleGit for Mac").font(.largeTitle)
            Text("A macOS fork of TortoiseGit").foregroundStyle(.secondary)
            HStack {
                Button("Open Repository…") { model.chooseRepository() }.keyboardShortcut(.defaultAction)
                Button("Clone…") { model.activate(.clone) }
                Button("Create Repository…") { model.activate(.initialize) }
            }
            if !model.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent repositories").font(.headline)
                    ForEach(Array(model.recentRepositories.prefix(5))) { saved in
                        HStack {
                            Button { model.openRecent(saved) } label: {
                                VStack(alignment: .leading) {
                                    Text(saved.name)
                                    Text(saved.lastKnownPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { model.forgetRepository(saved) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).help("Forget saved permission. Repository files remain on disk.")
                        }
                    }
                }.frame(maxWidth: 500).padding(12).background(.quaternary).cornerRadius(8)
            }
            Text("Open repositories to publish status badges to the Finder extension.\nEnable the signed Finder extension in System Settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var status: some View {
        VStack(spacing: 8) {
            Table(model.visibleEntries.map {WorkspaceStatusRow(entry:$0)}, selection: $model.nativeSelection) {
                TableColumn("Status") { entry in
                    CommandLabel(title: FileListLabels.caption(entry.state.rawValue.capitalized), icon: entry.state.icon, localized:false).foregroundStyle(entry.entry.statusTextColor(selected:model.selection.contains(entry.path),preferences:model.fileComparisonPreferences))
                }.width(min: 120, ideal: 145, max: 180)
                TableColumn("Staged") { entry in Text(entry.staged ? "✓" : "").foregroundStyle(entry.entry.statusTextColor(selected:model.selection.contains(entry.path),preferences:model.fileComparisonPreferences)) }.width(55)
                TableColumn("File") { entry in Text(entry.path).foregroundStyle(entry.entry.statusTextColor(selected:model.selection.contains(entry.path),preferences:model.fileComparisonPreferences)).help(entry.originalPath.map { "Renamed from \($0)" } ?? entry.path) }
            }.fileListFont()
            .onCopyCommand {
                let context = model.captureWorkspaceMenu()
                guard model.claimWorkspaceMenu(context),!context.paths.isEmpty else{return []}
                return [NSItemProvider(object:context.paths.joined(separator:"\n") as NSString)]
            }
            .frame(minHeight: 140)
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { model.receiveTransferDrop($0) }
            .contextMenu(forSelectionType:String.self) { ids in
                let context = model.captureWorkspaceMenu(GitPathRowIdentity.paths(ids))
                TurtleGitContextMenu {
                    Button { if model.claimWorkspaceMenu(context) { model.showDiff(paths:context.paths) } } label: { CommandLabel(title: "Diff", icon: .compare) }
                    Button { if model.claimWorkspaceMenu(context) { model.stage(paths:context.paths) } } label: { CommandLabel(title: "Add / Stage", icon: .add) }.disabled(context.paths.isEmpty)
                    Button { if model.claimWorkspaceMenu(context) { model.unstage(paths:context.paths) } } label: { CommandLabel(title: "Unstage", icon: .revert) }.disabled(context.paths.isEmpty)
                    Button { if model.claimWorkspaceMenu(context) { model.activate(.revert,paths:context.paths) } } label: { CommandLabel(title: "Revert…", icon: .revert) }.disabled(!context.canRevert)
                    Button { if model.claimWorkspaceMenu(context) { model.activate(.clean,paths:context.paths) } } label: { CommandLabel(title: RepositoryAction.clean.title, icon: .clean) }.disabled(context.bare || model.busy || model.confirmingQuit)
                    Button { if model.claimWorkspaceMenu(context) { model.activate(.rename,paths:context.paths) } } label: { CommandLabel(title: "Rename…", icon: .rename) }.disabled(!context.canRename)
                    if context.canResolve && !context.paths.isEmpty {
                        ResolveSelectionMenu(paths: context.paths, rebase: context.rebase, canEdit: context.entries.count == 1 && context.entries.contains(where: { $0.state == .conflicted })) { action, paths in if model.claimWorkspaceMenu(context) { model.activate(action, paths: paths) } }
                    }
                    if context.merging {
                        Button { if model.claimWorkspaceMenu(context) { model.activate(.mergeAbort,paths:context.paths) } } label: { CommandLabel(title: RepositoryAction.mergeAbort.title, icon: .mergeAbort) }.disabled(model.busy || model.confirmingQuit)
                    }
                    if context.canIgnore(.ignore) {
                        IgnoreSelectionMenu(paths: context.paths) { action, paths in if model.claimWorkspaceMenu(context) { model.activate(action, paths: paths) } }
                    }
                    if context.canIgnore(.ignoreDelete) {
                        IgnoreSelectionMenu(paths: context.paths, deleting: true) { action, paths in if model.claimWorkspaceMenu(context) { model.activate(action, paths: paths) } }
                    }
                    Group {
                        Divider()
                        Button {if model.claimWorkspaceMenu(context) {model.activate(.move,paths:context.paths)}} label:{CommandLabel(title:"Move…",icon:.rename)}.disabled(!context.canMove)
                        Button {if model.claimWorkspaceMenu(context) {model.activate(.log,paths:context.paths)}} label:{CommandLabel(title:"Show log",icon:.log)}
                        if context.paths.count == 1 {Button {if model.claimWorkspaceMenu(context) {model.activate(.blame,paths:context.paths)}} label:{CommandLabel(title:"Blame",icon:.blame)}.disabled(!context.canBlame)}
                        Button {if model.claimWorkspaceMenu(context) {model.revealWorkspaceFiles(model.workspaceURLs(context.paths))}} label:{CommandLabel(title:"Show in Finder",icon:.explore)}.disabled(context.paths.isEmpty)
                        Button {if model.claimWorkspaceMenu(context) {model.copyWorkspaceFiles(context.paths)}} label:{CommandLabel(title:"Copy files",icon:.copy)}.disabled(context.paths.isEmpty)
                        Button {if model.claimWorkspaceMenu(context) {model.copyWorkspaceItems(context.paths)}} label:{CommandLabel(title:"Copy and Add…",icon:.add)}.disabled(context.paths.isEmpty)
                        Menu {
                            Button {if model.claimWorkspaceMenu(context) {model.copyWorkspacePaths(context.paths)}} label:{CommandLabel(title:"Relative paths",icon:.copy)}
                            Button {if model.claimWorkspaceMenu(context) {model.copyWorkspacePaths(context.paths,full:true)}} label:{CommandLabel(title:"Full paths",icon:.copy)}
                            Button {if model.claimWorkspaceMenu(context) {model.copyWorkspacePaths(context.paths,names:true)}} label:{CommandLabel(title:"File/folder names",icon:.copy)}
                        } label:{CommandLabel(title:"Copy to clipboard",icon:.copy)}.disabled(context.paths.isEmpty)
                    }
                    Divider()
                    if context.paths.count == 1 {
                        Button { if model.claimWorkspaceMenu(context) { model.activate(.diffLater,paths:context.paths) } } label: { CommandLabel(title: model.comparisonMarkTitle, icon: .compare) }.disabled(model.busy || model.confirmingQuit)
                    }
                    Button { if model.claimWorkspaceMenu(context) { model.activate(.remove,paths:context.paths) } } label: { CommandLabel(title: "Delete", icon: .remove) }.disabled(!context.canRemove)
                    Button { if model.claimWorkspaceMenu(context) { model.activate(.removeKeep,paths:context.paths) } } label: { CommandLabel(title: "Delete (keep local)", icon: .remove) }.disabled(!context.canRemove)
                }.disabled(model.busy || model.confirmingQuit)
            } primaryAction:{ids in
                let context = model.captureWorkspaceMenu(GitPathRowIdentity.paths(ids))
                if model.claimWorkspaceMenu(context) {model.showDiff(paths:context.paths)}
            }
            HStack {
                Button("Add / Stage selected") { model.stage() }.disabled(model.selection.isEmpty || model.busy)
                Button("Unstage selected") { model.unstage() }.disabled(model.selection.isEmpty || model.busy)
                Spacer()
                Toggle("Show ignored files", isOn: $model.showIgnored).toggleStyle(.checkbox)
            }.padding(.horizontal, 12)
        }
    }
}

private struct RepositoryWindowCapture: NSViewRepresentable {
    let model: RepositoryModel
    let onAttached: () -> Void
    func makeNSView(context: Context) -> NSView { CaptureView(model: model, onAttached: onAttached) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class CaptureView: NSView {
        weak var model: RepositoryModel?
        private weak var capturedWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?
        private var keyObserver: NSObjectProtocol?
        private var closed = false
        private let onAttached: () -> Void
        init(model: RepositoryModel, onAttached: @escaping () -> Void) { self.model = model; self.onAttached = onAttached; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
            if let capturedWindow, model?.workspaceWindow === capturedWindow { model?.workspaceWindow = nil }
            capturedWindow = window; closed = false
            guard let window else { return }
            model?.workspaceWindow = window
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.model?.workspaceWindow === window else { return }
                    self.closed = true; self.model?.workspaceWindow = nil
                }
            }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.capturedWindow === window,
                          self.model?.workspaceWindow == nil || self.model?.workspaceWindow === window else { return }
                    self.closed = false
                    if self.model?.workspaceWindow !== window { self.model?.workspaceWindow = window }
                    self.notifyAttachment()
                }
            }
            notifyAttachment()
        }
        private func notifyAttachment() {
            // Present child workflows after this native attachment/layout turn,
            // and refuse an attachment that closed before the queued callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, let window = self.capturedWindow,
                      self.model?.workspaceWindow === window else { return }
                self.onAttached()
            }
        }
        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }
}

struct OperationDialog: View {
    @ObservedObject var model: RepositoryModel
    let action: RepositoryAction
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(action.title.replacingOccurrences(of: "…", with: "")).font(.title2)
            Text(model.root?.path ?? "Choose a destination after continuing.").font(.caption).textSelection(.enabled)
            if action.requiresValue { TextField(action.prompt, text: $value).textFieldStyle(.roundedBorder) }
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let args = action.arguments(value: value) {
                Text("git " + args.joined(separator: " ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { model.execute(action, value: value) }.keyboardShortcut(.defaultAction)
                    .disabled(action.requiresValue && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
    var explanation: String {
        switch action {
        case .pull: return "Fetch and fast-forward the current branch from its configured upstream. Diverged branches require a separate merge or rebase."
        case .push: return "Push using this repository’s configured remote and refspec. Authentication uses your existing Git and SSH configuration."
        case .rebase: return "Review the branch, upstream and ordered commits in the Rebase window before rewriting history."
        case .merge: return "Merge this revision into the current branch. Git may create a merge commit or leave conflicts for resolution."
        case .clone: return "Choose an empty destination directory. Git will clone the repository into that directory."
        case .stashPop: return "Apply the latest stash and remove it if application succeeds. Conflicts may require manual resolution."
        default: return "Run this operation in the selected repository. Review its arguments before continuing."
        }
    }
}

struct OutputView: NSViewRepresentable {
    let text: String
    var usesLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let view = nsView.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        let font = usesLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize)
            : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        if view.font != font { let ranges = view.selectedRanges; view.font = font; view.selectedRanges = ranges }
    }
}
