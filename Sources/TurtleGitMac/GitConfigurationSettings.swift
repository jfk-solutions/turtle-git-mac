// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class GitConfigurationSettingsModel: ObservableObject {
    private(set) static var activeSaves = 0
    @Published private(set) var source: GitConfigurationSource = .effective
    @Published var destination: GitConfigurationSource = .local
    @Published var draft = GitConfigurationSettings()
    @Published private(set) var saved = GitConfigurationSettings()
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var error: String?
    @Published var configurationText: String?
    private(set) var repository: GitRepository?
    private var access: RepositoryAccessLease?
    private var hasRepository = false
    private var active = false
    private var saving = false
    private var pendingContext: (GitRepository, RepositoryAccessLease?, Bool)?
    private var generation = UUID()
    private var readToken: OperationCancellation?
    private var alert: NSAlert?
    private var answer: ((Bool) -> Void)?
    weak var window: NSWindow?
    var localAvailable: Bool { hasRepository }
    var editable: Bool { loaded && source != .effective && !busy }
    var changed: Bool { draft != saved }
    func activate(repository: GitRepository, access: RepositoryAccessLease?, localAvailable: Bool) {
        if saving { pendingContext = (repository, access, localAvailable); return }
        self.repository = repository; self.access = access; hasRepository = localAvailable
        active = true; destination = localAvailable ? .local : .global
        load(.effective, initial: true)
    }
    func deactivate() {
        active = false; pendingContext = nil; generation = UUID(); readToken?.cancel(); readToken = nil
        if !saving { busy = false }; configurationText = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }
        alert = nil; let pending = answer; answer = nil; pending?(false)
    }
    private func checkAccess(_ repository: GitRepository, access: RepositoryAccessLease?, local: Bool) throws {
        if GitRuntime.isAppStoreBuild && local && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
    }
    func load(_ source: GitConfigurationSource, initial: Bool = false) {
        guard active, let repository, (!busy || readToken != nil), source != .local || hasRepository else { return }
        readToken?.cancel(); let token = OperationCancellation(), request = UUID(); generation = request; readToken = token
        self.source = source; loaded = false; busy = true; error = nil
        if source == .local || source == .global { destination = source }
        Task { [weak self, access] in
            guard let self else { return }
            defer { if self.generation == request { self.readToken = nil; self.busy = false } }
            do {
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                var value = try await repository.gitConfiguration(source: source, cancellation: token)
                guard self.active, self.generation == request, !token.isCancelled else { return }
                if initial && value.name.value.isEmpty && value.email.value.isEmpty {
                    value = try await repository.gitConfiguration(source: .global, cancellation: token)
                    guard self.active, self.generation == request, !token.isCancelled else { return }
                    self.source = .global; self.destination = .global
                    value.name.inherit = false; value.email.inherit = false
                }
                self.draft = value; self.saved = value; self.loaded = true
            } catch { if self.active, self.generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func confirmSave(to destination: GitConfigurationSource) async -> Bool {
        guard active, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "Save settings to \(destination.rawValue)?"
        alert.informativeText = "The selected config source differs from the save destination."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Save")
        self.alert = alert
        return await withCheckedContinuation { continuation in
            var answered = false
            let answer: (Bool) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning: value) }
            self.answer = answer
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.alert === alert else { answer(false); return }
                self.alert = nil; self.answer = nil; answer(response == .alertSecondButtonReturn && self.active)
            }
        }
    }
    func apply() {
        guard active, editable, changed, let repository, destination != .local || hasRepository else { return }
        let value = draft, destination = destination, request = generation, access = access
        busy = true; saving = true; error = nil
        Self.activeSaves += 1
        Task { [weak self] in
            defer { Self.activeSaves -= 1 }
            guard let self else { return }
            defer {
                self.saving = false
                if self.generation == request || !self.active { self.busy = false }
                if let pending = self.pendingContext {
                    self.pendingContext = nil
                    self.activate(repository: pending.0, access: pending.1, localAvailable: pending.2)
                }
            }
            do {
                if self.source != destination { guard await self.confirmSave(to: destination) else { return } }
                guard self.active, self.generation == request else { return }
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                // Each Git config write holds its own lock. Retain the grant and
                // allow this source-ordered batch to finish after owner closure.
                try await repository.saveGitConfiguration(value, destination: destination)
                guard self.active, self.generation == request else { return }
                self.saved = value
            } catch { if self.active, self.generation == request { self.error = error.localizedDescription } }
        }
    }
    func viewConfiguration(_ source: GitConfigurationSource) {
        guard active, !busy, let repository else { return }
        let token = OperationCancellation(), request = UUID(); generation = request; readToken = token; busy = true; error = nil
        Task { [weak self, access] in
            guard let self else { return }
            defer { if self.generation == request { self.readToken = nil; self.busy = false } }
            do {
                try self.checkAccess(repository, access: access, local: self.hasRepository)
                let text = try await repository.gitConfigurationText(source: source, cancellation: token)
                guard self.active, self.generation == request, !token.isCancelled else { return }
                self.configurationText = text
            } catch { if self.active, self.generation == request, !token.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
struct GitConfigurationSettingsPage: View {
    @ObservedObject var workspace: RepositoryModel
    @StateObject private var model = GitConfigurationSettingsModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Config source") {
                Picker("Config source", selection: Binding(get: { model.source }, set: { model.load($0) })) {
                    ForEach(GitConfigurationSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source).disabled(source == .local && !model.localAvailable)
                    }
                }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().padding(8).disabled(model.busy)
            }
            GroupBox("User Info") {
                VStack(spacing: 10) {
                    identity("Name:", field: $model.draft.name)
                    identity("Email:", field: $model.draft.email)
                    identity("Signing key ID:", field: $model.draft.signingKey)
                }.padding(8)
            }
            GroupBox("Auto CrLf convert") {
                HStack {
                    Picker("AutoCrLf:", selection: $model.draft.autoCRLF) { ForEach(["", "false", "true", "input"], id: \.self) { Text($0.isEmpty ? " " : $0).tag($0) } }
                    Picker("SafeCrLf:", selection: $model.draft.safeCRLF) { ForEach(["", "false", "true", "warn"], id: \.self) { Text($0.isEmpty ? " " : $0).tag($0) } }
                }.padding(8).disabled(!model.editable)
            }
            HStack {
                GitConfigurationCheckbox(title: "QuotePath", value: $model.draft.quotePath, enabled: model.editable)
                GitConfigurationCheckbox(title: "Prune", value: $model.draft.prune, enabled: model.editable)
            }
            HStack {
                Text("Save to:")
                Picker("Save to", selection: $model.destination) {
                    if model.localAvailable { Text("Local").tag(GitConfigurationSource.local) }
                    Text("Global").tag(GitConfigurationSource.global)
                }.labelsHidden().frame(width: 190).disabled(!model.editable)
            }
            HStack {
                Button("View effective config") { model.viewConfiguration(.effective) }
                Button("View systemwide gitconfig") { model.viewConfiguration(.system) }
            }.disabled(model.busy)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.deactivate(); model.window?.performClose(nil) }.disabled(model.busy)
                Button("Apply", action: model.apply).disabled(!model.editable || !model.changed)
            }
        }.padding(20)
        .background(GitConfigurationWindowProbe(model: model).frame(width: 0, height: 0))
        .onAppear(perform: activate).onChange(of: workspace.root) { _ in activate() }.onDisappear { model.deactivate() }
        .sheet(isPresented: Binding(get: { model.configurationText != nil }, set: { if !$0 { model.configurationText = nil } })) {
            VStack(alignment: .leading) {
                ScrollView([.horizontal, .vertical]) { Text(model.configurationText ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).padding() }
                HStack { Spacer(); Button("Close") { model.configurationText = nil }.keyboardShortcut(.cancelAction) }.padding()
            }.frame(minWidth: 680, minHeight: 420)
        }
    }
    private func activate() {
        do { let context = try workspace.gitConfigurationContext(); model.activate(repository: context.repository, access: context.access, localAvailable: context.localAvailable) }
        catch { model.error = error.localizedDescription }
    }
    private func identity(_ label: String, field: Binding<GitConfigurationIdentity>) -> some View {
        HStack {
            Text(label).frame(width: 105, alignment: .leading)
            TextField(label, text: field.value).disabled(!model.editable || field.wrappedValue.inherit)
            Toggle("inherit", isOn: field.inherit).toggleStyle(.checkbox).disabled(!model.editable)
        }
    }
}
private struct GitConfigurationCheckbox: NSViewRepresentable {
    let title: String
    @Binding var value: GitConfigurationBoolean
    let enabled: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.allowsMixedState = true; button.toolTip = "Mixed inherits the value from another config source."; return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self; button.isEnabled = enabled
        button.state = value == .inherit ? .mixed : value == .enabled ? .on : .off
    }
    final class Coordinator: NSObject {
        var parent: GitConfigurationCheckbox
        init(_ parent: GitConfigurationCheckbox) { self.parent = parent }
        @objc func changed(_ sender: NSButton) { parent.value = sender.state == .mixed ? .inherit : sender.state == .on ? .enabled : .disabled }
    }
}
private struct GitConfigurationWindowProbe: NSViewRepresentable {
    let model: GitConfigurationSettingsModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) { model.window = view.window }
    final class Probe: NSView {
        weak var model: GitConfigurationSettingsModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); model?.window = window }
    }
}
