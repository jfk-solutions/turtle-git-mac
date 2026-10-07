import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class PushWindowController: NSWindowController, NSWindowDelegate {
    let model: PushWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = PushWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 590), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Push – TurtleGit"; window.minSize = NSSize(width: 720, height: 610); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PushDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 750, height: 590)); window.center()
        model.close = { [weak window] in window?.close() }
        model.confirmPush = { [weak window] message, allBranches, deletion, choose in
            guard let window, window.attachedSheet == nil else { choose(false, false); return }
            let alert = Self.submissionAlert(message: message, allBranches: allBranches, deletion: deletion)
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn, alert.suppressionButton?.state == .on) }
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "The process is still running."
            alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
    }
    static func submissionAlert(message: String, allBranches: Bool, deletion: Bool) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = deletion ? .warning : .informational
        alert.messageText = message
        let yes = alert.addButton(withTitle: "Yes"), no = alert.addButton(withTitle: "No")
        if allBranches {
            yes.keyEquivalent = ""; no.keyEquivalent = "\r"; alert.window.defaultButtonCell = no.cell as? NSButtonCell
            alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show this message again"
        } else { yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell }
        return alert
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.transportRunning else { return true }
        model.cancel(); return false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class PushWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    @Published var options = PushOptions()
    @Published var remotes: [String] = []
    @Published var references: [CheckoutReference] = []
    @Published var localBranch: String?
    @Published var busy = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    private var cancellation: OperationCancellation?
    var transportRunning: Bool { cancellation != nil }
    var canCancel: Bool { !busy || transportRunning && !cancelling && !confirmingCancellation }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { choose in choose(false) }
    @Published var url = ""
    @Published var urls: [String] = []
    @Published var destinationHistory: [String] = []
    @Published var pushOptionHistory: [String] = []
    @Published var managingRemotes = false
    @Published var error: String?
    @Published var confirmation: String?
    var confirmPush: (String, Bool, Bool, @escaping (Bool, Bool) -> Void) -> Void = { _, _, _, _ in }
    @Published var browsingDestination: Bool?
    var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) ?? NSPasteboard.general.string(forType: .fileURL) }
    var close: () -> Void = {}
    var onPushed: (String) -> Void = { _ in }
    private var generation = 0
    private var key: String { "Push." + repository.root.path }
    var urlHistoryKey: String { "History.PushURLS." + repository.root.path }
    var destinationHistoryKey: String { "History.RemoteBranch." + repository.root.path }
    var pushOptionHistoryKey: String { "History.PushOption." + repository.root.path }
    var submodulePreferenceKey: String { "History.PushRecurseSubmodules." + repository.root.path }
    var canSave: Bool { !options.arbitraryURL && !options.allRemotes && !options.allBranches && localBranch != nil && !options.setUpstream }
    var canTrack: Bool { !options.arbitraryURL && (options.allBranches || localBranch != nil) }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) { self.repository = repository; self.access = access; self.preferences = preferences }
    func load(source: String? = nil) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                remotes = try await repository.remoteNames(); references = try await repository.checkoutReferences()
                options = PushOptions()
                urls = FetchDialogHistory.load(preferences, key: urlHistoryKey, caseSensitive: true)
                pushOptionHistory = FetchDialogHistory.load(preferences, key: pushOptionHistoryKey, caseSensitive: true)
                url = ""
                let current = try await repository.branch()
                options.source = PushSourcePresentation.normalized(source ?? (current.isEmpty ? "HEAD" : current))
                options.allBranches = source == nil && preferences.bool(forKey: key + ".allBranches")
                options.allRemotes = remotes.count > 1 && preferences.bool(forKey: key + ".allRemotes")
                options.submodules = await repository.pushSubmoduleDefault()
                if let stored = preferences.object(forKey: submodulePreferenceKey) as? NSNumber,
                   PushSubmodules.allCases.indices.contains(stored.intValue) { options.submodules = PushSubmodules.allCases[stored.intValue] }
                let defaults = try await repository.pushDefaults(source: options.source)
                options.remote = defaults.remote; loadDestination(defaults.destination); options.setUpstream = defaults.setUpstream; localBranch = defaults.localBranch
                if options.remote.isEmpty, let saved = preferences.string(forKey: key + ".remote"), remotes.contains(saved) { options.remote = saved }
            } catch { self.error = error.localizedDescription }
        }
    }
    func sourceChanged() {
        generation += 1; let request = generation, source = options.source
        guard !FetchDialogHistory.trim(source).isEmpty else { localBranch = nil; adjustSettings(); return }
        Task {
            do {
                let defaults = try await repository.pushDefaults(source: source)
                guard request == generation else { return }
                localBranch = defaults.localBranch; loadDestination(defaults.destination)
                if !options.arbitraryURL, !options.allRemotes { options.remote = defaults.remote }
                options.setUpstream = defaults.setUpstream; adjustSettings()
            } catch { if request == generation { self.error = error.localizedDescription } }
        }
    }
    func adjustSettings() {
        if !canTrack { options.setUpstream = false }
        if !canSave { options.savePushRemote = false; options.savePushBranch = false }
    }
    private func loadDestination(_ destination: String) {
        destinationHistory = FetchDialogHistory.load(preferences, key: destinationHistoryKey, caseSensitive: false)
        options.destination = ""
        if !destination.isEmpty { selectDestination(destination, atFront: false) }
    }
    func selectDestination(_ destination: String, atFront: Bool = true) {
        destinationHistory = FetchDialogHistory.inserting(destination, into: destinationHistory, atFront: atFront, caseSensitive: false)
        let normalized = FetchDialogHistory.trim(destination.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        options.destination = destinationHistory.first { $0.compare(normalized, options: .caseInsensitive) == .orderedSame } ?? destination
    }
    func deleteURLHistory(at index: Int) {
        guard !busy, let result = FetchDialogHistory.removing(index, entries: urls, preferences: preferences, key: urlHistoryKey) else { return }
        urls = result.entries; url = result.selection
    }
    func deleteDestinationHistory(at index: Int) {
        guard !busy, let result = FetchDialogHistory.removing(index, entries: destinationHistory, preferences: preferences, key: destinationHistoryKey) else { return }
        destinationHistory = result.entries; options.destination = result.selection
    }
    func deletePushOptionHistory(at index: Int) {
        guard !busy, let result = FetchDialogHistory.removing(index, entries: pushOptionHistory, preferences: preferences, key: pushOptionHistoryKey) else { return }
        pushOptionHistory = result.entries; options.pushOption = result.selection
    }
    func selectArbitraryURL() {
        options.arbitraryURL = true; options.allRemotes = false
        if let input = clipboardText().flatMap({ FetchClipboardInput.selection($0, isPull: true) }) {
            url = input.url; if let branch = input.branch { options.destination = branch }
        } else { url = urls.first ?? "" }
        adjustSettings()
    }
    private func saveHistories(_ snapshot: PushOptions) {
        // PushDlg excludes all-branch submissions and remote deletions from URL/branch history.
        if !snapshot.allBranches && !(snapshot.source.isEmpty && !snapshot.destination.isEmpty) {
            if snapshot.arbitraryURL { urls = FetchDialogHistory.save(snapshot.remote, entries: urls, preferences: preferences, key: urlHistoryKey, caseSensitive: true) }
            destinationHistory = FetchDialogHistory.save(snapshot.destination, entries: destinationHistory, preferences: preferences, key: destinationHistoryKey, caseSensitive: false)
        }
        pushOptionHistory = FetchDialogHistory.save(snapshot.pushOption, entries: pushOptionHistory, preferences: preferences, key: pushOptionHistoryKey, caseSensitive: true)
    }
    func cancel() {
        guard busy else { close(); return }
        guard let token = cancellation, !cancelling, !confirmingCancellation else { return }
        func stop() { cancelling = true; token.cancel() }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true
            confirmCancellation { [weak self] proceed in
                guard let self, self.cancellation === token else { return }
                self.confirmingCancellation = false
                if proceed { self.cancelling = true; token.cancel() }
            }
        } else { stop() }
    }
    private func askToPush(_ message: String, allBranches: Bool, deletion: Bool) {
        confirmation = message
        confirmPush(message, allBranches, deletion) { [weak self] proceed, remember in
            guard let self else { return }
            self.confirmation = nil
            // PushDlg explicitly remembers Yes even when this invocation chose No.
            if allBranches && remember { self.preferences.set(true, forKey: "PushAllBranches") }
            if proceed { self.push(confirmed: true) }
        }
    }
    func push(confirmed: Bool = false) {
        guard !busy, confirmed || confirmation == nil else { return }
        if !confirmed {
            let source = FetchDialogHistory.trim(options.source), destination = FetchDialogHistory.trim(options.destination)
            if options.allBranches && !preferences.bool(forKey: "PushAllBranches") {
                askToPush("Do you really want to push all local branches?", allBranches: true, deletion: false); return
            }
            if !options.allBranches && source.isEmpty {
                askToPush(destination.isEmpty ? "The local branch name and the remote branch name are empty.\nContinue?" : "The local branch/tag name is empty. This results in a remote removal.\nContinue?", allBranches: false, deletion: !destination.isEmpty); return
            }
        }
        confirmation = nil
        var snapshot = options
        snapshot.source = FetchDialogHistory.trim(snapshot.source); snapshot.destination = FetchDialogHistory.trim(snapshot.destination)
        if snapshot.arbitraryURL { snapshot.remote = FetchDialogHistory.trim(url) }
        let token = OperationCancellation(); cancellation = token; cancelling = false; error = nil
        busy = true
        Task {
            defer { cancellation = nil; cancelling = false; confirmingCancellation = false; busy = false }
            do {
                try await repository.validatePushOptions(snapshot, cancellation: token)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                saveHistories(snapshot)
                preferences.set(snapshot.allBranches, forKey: key + ".allBranches")
                preferences.set(!snapshot.arbitraryURL && snapshot.allRemotes, forKey: key + ".allRemotes")
                preferences.set(PushSubmodules.allCases.firstIndex(of: snapshot.submodules)!, forKey: submodulePreferenceKey)
                if !snapshot.arbitraryURL && !snapshot.allRemotes { preferences.set(snapshot.remote, forKey: key + ".remote") }
                let output = try await repository.push(snapshot, cancellation: token)
                guard !token.isCancelled else { throw OperationCancellationFailure.cancelled }
                onPushed(output); close()
            }
            catch { self.error = error.localizedDescription }
        }
    }
    func pick(_ reference: CheckoutReference, destination: Bool) {
        if !destination { options.source = PushSourcePresentation.normalized(reference.name); sourceChanged() }
        else {
            for remote in remotes.sorted(by: { $0.count > $1.count }) {
                let prefix = "refs/remotes/" + remote + "/"
                if reference.name.hasPrefix(prefix) { options.remote = remote; selectDestination(String(reference.name.dropFirst(prefix.count))); options.arbitraryURL = false; options.allRemotes = false; break }
            }
        }
        browsingDestination = nil
    }
}

private struct PushDialog: View {
    @ObservedObject var model: PushWindowModel
    var body: some View {
        VStack(spacing: 14) {
            Group {
            GroupBox("Ref") { VStack(alignment: .leading, spacing: 8) {
                Toggle("Push all branches", isOn: $model.options.allBranches)
                HStack { Text("Local:").frame(width: 115, alignment: .leading); PushRefCombo(value: $model.options.source, choices: ["HEAD"] + model.references.filter { $0.name.hasPrefix("refs/heads/") || $0.remote }.map(\.name), local: true, normalizeSource: true)
                    Button("…") { model.browsingDestination = false }.accessibilityLabel("Browse local references")
                }.disabled(model.options.allBranches)
                HStack { Text("Remote:").frame(width: 115, alignment: .leading); FetchHistoryCombo(value: $model.options.destination, choices: model.destinationHistory, label: "Remote branch or tag", onDelete: model.deleteDestinationHistory)
                    Button("…") { model.browsingDestination = true }.accessibilityLabel("Browse remote references")
                }.disabled(model.options.allBranches)
            }.padding(8) }
            GroupBox("Destination") { VStack(spacing: 8) {
                HStack { PushDestinationRadio(title: "Remote:", selected: !model.options.arbitraryURL) { model.options.arbitraryURL = false }.frame(width: 115)
                    PushRemotePopup(values: [""] + (model.remotes.count > 1 ? ["*"] : []) + model.remotes,
                        selection: Binding(get: { model.options.allRemotes ? "*" : model.options.remote }, set: { model.options.allRemotes = $0 == "*"; if $0 != "*" { model.options.remote = $0 } })).disabled(model.options.arbitraryURL)
                    Button("Manage") { model.managingRemotes = true }.disabled(model.options.arbitraryURL)
                }
                HStack { PushDestinationRadio(title: "Arbitrary URL:", selected: model.options.arbitraryURL) { model.selectArbitraryURL() }.frame(width: 115)
                    FetchHistoryCombo(value: $model.url, choices: model.urls, label: "Destination URL or path", onDelete: model.deleteURLHistory).disabled(!model.options.arbitraryURL)
                }
            }.padding(8) }
            GroupBox("Options") { VStack(alignment: .leading, spacing: 8) {
                HStack { Toggle("Force with lease", isOn: $model.options.forceWithLease).disabled(model.options.force || model.options.includeTags)
                    Toggle("Force", isOn: $model.options.force).disabled(model.options.forceWithLease); Spacer() }
                Toggle("Include Tags", isOn: $model.options.includeTags).disabled(model.options.forceWithLease)
                Text("SSH authentication uses the configured Git credential helpers and SSH agent.").font(.caption).foregroundStyle(.secondary)
                Toggle("Set upstream/track remote branch", isOn: $model.options.setUpstream).disabled(!model.canTrack || model.options.savePushRemote || model.options.savePushBranch)
                Toggle("Always push to the selected remote archive for this local branch", isOn: $model.options.savePushRemote).disabled(!model.canSave)
                Toggle("Always push to the selected remote branch for this local branch", isOn: $model.options.savePushBranch).disabled(!model.canSave)
                HStack { Text("Recurse submodule").frame(width: 155, alignment: .leading); Picker("Recurse submodule", selection: $model.options.submodules) { Text("None").tag(PushSubmodules.none); Text("Check").tag(PushSubmodules.check); Text("On-demand").tag(PushSubmodules.onDemand) }.labelsHidden(); Spacer() }
                HStack { Text("Push option:").frame(width: 155, alignment: .leading); FetchHistoryCombo(value: $model.options.pushOption, choices: model.pushOptionHistory, label: "Push option", onDelete: model.deletePushOptionHistory) }
            }.padding(8) }
            }.disabled(model.busy)
            Spacer(minLength: 0)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("OK") { model.push() }.keyboardShortcut(.defaultAction).disabled(model.busy)
                Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).disabled(!model.canCancel)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-push.html")!) }
            }
        }.padding(16)
        .onChange(of: model.options.source) { _ in model.sourceChanged() }
        .onChange(of: model.options.arbitraryURL) { _ in model.adjustSettings() }
        .onChange(of: model.options.allRemotes) { _ in model.adjustSettings() }
        .onChange(of: model.options.allBranches) { _ in model.adjustSettings() }
        .onChange(of: model.options.setUpstream) { _ in model.adjustSettings() }
        .alert("Push failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.managingRemotes) { PushRemoteSettings(model: model) }
        .sheet(isPresented: Binding(get: { model.browsingDestination != nil }, set: { if !$0 { model.browsingDestination = nil } })) { PushReferenceChooser(model: model, destination: model.browsingDestination == true) }
    }
}
private struct PushReferenceChooser: View {
    @ObservedObject var model: PushWindowModel
    let destination: Bool
    @State private var search = ""
    @State private var selection: String?
    var references: [CheckoutReference] { model.references.filter { $0.symbolicTarget == nil && (destination ? $0.remote : !$0.remote) && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)) } }
    var body: some View { VStack(spacing: 12) {
        Text(destination ? "Browse remote references" : "Browse local references").font(.headline)
        TextField("Filter", text: $search)
        List(selection: $selection) { ForEach(references) { Text($0.label).tag($0.name) } }
        HStack { Spacer(); Button("Cancel") { model.browsingDestination = nil }.keyboardShortcut(.cancelAction)
            Button("OK") { if let reference = references.first(where: { $0.name == selection }) { model.pick(reference, destination: destination) } }.keyboardShortcut(.defaultAction).disabled(selection == nil) }
    }.padding(16).frame(width: 650, height: 430) }
}
struct PushDestinationRadio: NSViewRepresentable {
    let title: String; let selected: Bool; let select: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton { NSButton(radioButtonWithTitle: title, target: context.coordinator, action: #selector(Coordinator.clicked(_:))) }
    func updateNSView(_ button: NSButton, context: Context) { button.state = selected ? .on : .off; button.isEnabled = enabled; context.coordinator.select = select }
    final class Coordinator: NSObject { var select: () -> Void = {}; @objc func clicked(_ sender: NSButton) { select() } }
}

struct PushRemoteSettings: View {
    var onClose: (() -> Void)? = nil
    @ObservedObject var model: PushWindowModel
    @State private var selection: String?
    @State private var name = ""
    @State private var fetchURL = ""
    @State private var pushURL = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRemove = false
    func load(_ selected: String?) {
        name = selected ?? ""; fetchURL = ""; pushURL = ""
        guard let selected else { return }; busy = true
        Task {
            defer { busy = false }
            do { let urls = try await model.repository.remoteURLs(name: selected); fetchURL = urls.fetch; pushURL = urls.push }
            catch { self.error = error.localizedDescription }
        }
    }
    func save(removing: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if removing, let selection { _ = try await model.repository.run(["remote", "remove", "--", selection]) }
                else { try await model.repository.saveRemote(name: name, fetchURL: fetchURL, pushURL: pushURL, existing: selection != nil) }
                model.remotes = try await model.repository.remoteNames(); model.references = try await model.repository.checkoutReferences()
                if !model.remotes.contains(model.options.remote) { model.options.remote = model.remotes.first ?? "" }
                selection = nil; load(nil)
            } catch { self.error = error.localizedDescription }
        }
    }
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        Text("Remote settings").font(.headline)
        HStack { List(model.remotes, id: \.self, selection: $selection) { Text($0) }.frame(width: 160)
            VStack(alignment: .leading) {
                TextField("Remote name", text: $name).disabled(selection != nil)
                Text("Fetch URL"); TextField("Fetch URL", text: $fetchURL)
                Text("Push URL (empty uses fetch URL)"); TextField("Push URL", text: $pushURL)
                Spacer()
                HStack { Button("New") { selection = nil; load(nil) }; Button("Save") { save() }.disabled(name.isEmpty || fetchURL.isEmpty)
                    Button("Remove") { confirmRemove = true }.disabled(selection == nil) }
            }
        }
        HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Close") { if let onClose { onClose() } else { model.managingRemotes = false } }.keyboardShortcut(.cancelAction) }
    }.padding(16).frame(width: 700, height: 320).disabled(busy)
        .onChange(of: selection) { load($0) }
        .alert("Remote settings failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .alert("Remove remote?", isPresented: $confirmRemove) { Button("Remove", role: .destructive) { save(removing: true) }; Button("Cancel", role: .cancel) {} } message: { Text("Remove this remote's configuration and local remote-tracking references? The remote repository remains available.") }
    }
}

struct PushRefCombo: NSViewRepresentable {
    @Binding var value: String
    let choices: [String]
    let local: Bool
    var normalizeSource = false
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(); combo.delegate = context.coordinator; combo.completes = true
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal); return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        let coordinator = context.coordinator; coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.local = local; coordinator.change = { value = $0 }
        let values = Array(Set(choices.map { normalizeSource ? PushSourcePresentation.normalized($0) : $0 })).sorted(); let labels = values.map { local && $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
        if coordinator.values != values { combo.removeAllItems(); combo.addItems(withObjectValues: labels) }
        coordinator.values = values; coordinator.labels = labels
        let display = !normalizeSource && local && value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
        if combo.stringValue != display { combo.stringValue = display }
        combo.isEnabled = enabled; combo.setAccessibilityLabel(local ? "Local ref or revision" : "Remote branch or tag")
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var values: [String] = [], labels: [String] = []; var local = false, updating = false
        var change: (String) -> Void = { _ in }
        func controlTextDidChange(_ notification: Notification) {
            guard !updating, let combo = notification.object as? NSComboBox else { return }
            let text = combo.stringValue; change(labels.firstIndex(of: text).map { values[$0] } ?? text)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard !updating, let combo = notification.object as? NSComboBox, values.indices.contains(combo.indexOfSelectedItem) else { return }; change(values[combo.indexOfSelectedItem])
        }
    }
}
struct PushRemotePopup: NSViewRepresentable {
    let values: [String]
    @Binding var selection: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false); button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:)); button.setContentHuggingPriority(.defaultLow, for: .horizontal); return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        if context.coordinator.values != values || button.numberOfItems == 0 { button.removeAllItems(); button.addItems(withTitles: values.map { $0 == "*" ? "– All –" : ($0.isEmpty ? "Choose remote" : $0) }) }
        context.coordinator.values = values; context.coordinator.change = { selection = $0 }
        if let index = values.firstIndex(of: selection) { button.selectItem(at: index) }
        button.isEnabled = enabled; button.setAccessibilityLabel("Remote archive")
    }
    final class Coordinator: NSObject { var values: [String] = []; var change: (String) -> Void = { _ in }
        @objc func changed(_ sender: NSPopUpButton) { guard values.indices.contains(sender.indexOfSelectedItem) else { return }; change(values[sender.indexOfSelectedItem]) }
    }
}

/// PushDlg normalizes initial/local-browser branches, while retaining tag/hash identity.
/// Other consumers of PushRefCombo keep their existing qualified-reference behavior.
enum PushSourcePresentation {
    static func normalized(_ source: String) -> String {
        if source.hasPrefix("refs/heads/") { return String(source.dropFirst(11)) }
        if source.hasPrefix("refs/remotes/") { return String(source.dropFirst(5)) }
        return source
    }
}
