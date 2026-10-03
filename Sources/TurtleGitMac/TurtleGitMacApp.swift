import SwiftUI
import AppKit
import TurtleGitCore

@main struct TurtleGitMacApp: App {
    @StateObject private var model = RepositoryModel()
    init() {
        if let status = RebaseEditor.handle(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) { exit(status) }
    }
    var body: some Scene {
        WindowGroup("TurtleGit for Mac") {
            RepositoryWindow(model: model)
                .onOpenURL { model.handle($0) }
                #if DEBUG
                .onAppear {
                    if Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") == true, model.root == nil,
                       let path = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationRepository") as? String {
                        model.open(URL(fileURLWithPath: path, isDirectory: true))
                    }
                }
                #endif
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository…") { model.chooseRepository() }.keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentRepositories) { saved in
                        Button(saved.name) { model.openRecent(saved) }.help(saved.lastKnownPath)
                    }
                }.disabled(model.busy || model.recentRepositories.isEmpty)
                Button("Close Repository") { model.closeRepository() }.disabled(model.busy || model.root == nil)
                Button("Clone…") { model.activate(.clone) }
                Button("Create Repository…") { model.activate(.initialize) }
            }
            CommandMenu("TurtleGit") {
                ForEach(RepositoryAction.allCases.filter { $0 != .clone && $0 != .initialize }) { action in
                    Button { model.activate(action) } label: { CommandLabel(title: action.title, icon: action.icon) }.disabled(model.root == nil || model.busy)
                }
            }
            #if DEBUG
            CommandMenu("Development") {
                Button("Save Window Screenshot…") { DocumentationCapture.saveWindow() }.keyboardShortcut("7", modifiers: [.command, .shift])
            }
            #endif
        }
    }
}

struct RepositoryWindow: View {
    @ObservedObject var model: RepositoryModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                Text(model.root?.path ?? "No repository selected").textSelection(.enabled).lineLimit(1)
                Spacer()
                if model.root != nil { Label(model.branch.isEmpty ? "Unborn / detached HEAD" : model.branch, systemImage: "arrow.triangle.branch") }
                if model.busy { ProgressView().controlSize(.small) }
            }.font(.system(size: 12)).padding(10).background(.bar)
            Divider()
            if model.root == nil { welcome } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TurtleGit").font(.headline).padding(.bottom, 8)
                        ForEach([RepositoryAction.status, .commit, .log]) { action in
                            Button { model.activate(action) } label: {
                                Text(action.title).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(model.section == action ? Color.accentColor.opacity(0.14) : .clear)
                                    .cornerRadius(4)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                        ForEach([RepositoryAction.pull, .push, .fetch, .branch, .tag, .switchBranch, .merge, .rebase, .stash, .stashPop]) { action in
                            Button(action.title) { model.activate(action) }.buttonStyle(.plain).padding(6)
                        }
                        Spacer()
                        Text("Native macOS port • In development").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(minWidth: 185, idealWidth: 205, maxWidth: 260).disabled(model.busy)
                    VSplitView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.section.title.replacingOccurrences(of: "…", with: "")).font(.title2).padding(.horizontal, 12)
                            status
                        }.padding(.vertical, 12).frame(minHeight: 260)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Diff / Operation output").font(.headline)
                                Spacer()
                                Toggle("Staged diff", isOn: $model.stagedDiff).toggleStyle(.checkbox)
                                Button("Show diff") { model.showDiff() }.disabled(model.busy)
                            }.padding(10).background(.bar)
                            OutputView(text: model.output).frame(minHeight: 120)
                        }
                    }.frame(minWidth: 620)
                }
            }
            Divider()
            HStack {
                Text("\(model.visibleEntries.count) changed • \(model.entries.filter(\.staged).count) staged")
                Spacer()
                Text(model.finderStatus).lineLimit(1).help(model.finderStatus)
                Text(model.busy ? "Working…" : "Ready")
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 920, minHeight: 650)
        .background(RepositoryWindowCapture(model: model).frame(width: 0, height: 0))
        .toolbar {
            Button { model.chooseRepository() } label: { Label("Open", systemImage: "folder") }.disabled(model.busy)
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.root == nil || model.busy)
            Button { model.activate(.commit) } label: { Label("Commit", systemImage: "checkmark.circle") }.disabled(model.root == nil || model.busy)
            Button { model.activate(.log) } label: { Label("Show log", systemImage: "clock") }.disabled(model.root == nil || model.busy)
        }
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
            Table(model.visibleEntries, selection: $model.selection) {
                TableColumn("Status") { entry in
                    CommandLabel(title: entry.state.rawValue.capitalized, icon: entry.state.icon).foregroundStyle(color(entry.state))
                }.width(min: 120, ideal: 145, max: 180)
                TableColumn("Staged") { entry in Text(entry.staged ? "✓" : "") }.width(55)
                TableColumn("File") { entry in Text(entry.path).help(entry.originalPath.map { "Renamed from \($0)" } ?? entry.path) }
            }
            .frame(minHeight: 140)
            .contextMenu {
                Button { model.showDiff() } label: { CommandLabel(title: "Diff", icon: .compare) }
                Button { model.stage() } label: { CommandLabel(title: "Add / Stage", icon: .add) }.disabled(model.selection.isEmpty)
                Button { model.unstage() } label: { CommandLabel(title: "Unstage", icon: .revert) }.disabled(model.selection.isEmpty)
            }
            HStack {
                Button("Add / Stage selected") { model.stage() }.disabled(model.selection.isEmpty || model.busy)
                Button("Unstage selected") { model.unstage() }.disabled(model.selection.isEmpty || model.busy)
                Spacer()
                Toggle("Show ignored files", isOn: $model.showIgnored).toggleStyle(.checkbox)
            }.padding(.horizontal, 12)
        }
    }
    func color(_ state: FileState) -> Color {
        switch state {
        case .normal, .added: return .green
        case .modified: return .orange
        case .deleted, .conflicted: return .red
        case .ignored, .untracked: return .secondary
        }
    }
}

private struct RepositoryWindowCapture: NSViewRepresentable {
    let model: RepositoryModel
    func makeNSView(context: Context) -> NSView { CaptureView(model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class CaptureView: NSView {
        weak var model: RepositoryModel?
        init(model: RepositoryModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.workspaceWindow = window }
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
        case .rebase: return "Rebase the current branch onto this revision. This rewrites local commits; conflict continuation and abort dialogs are not available yet."
        case .merge: return "Merge this revision into the current branch. Git may create a merge commit or leave conflicts for resolution."
        case .clone: return "Choose an empty destination directory. Git will clone the repository into that directory."
        case .stashPop: return "Apply the latest stash and remove it if application succeeds. Conflicts may require manual resolution."
        default: return "Run this operation in the selected repository. Review its arguments before continuing."
        }
    }
}

struct OutputView: NSViewRepresentable {
    let text: String
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
        if let view = nsView.documentView as? NSTextView, view.string != text { view.string = text }
    }
}
