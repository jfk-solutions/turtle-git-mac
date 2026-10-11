// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit

@MainActor final class SettingsTransaction: ObservableObject {
    struct Participant {
        let page: SettingsPageID
        let modified: () -> Bool
        let validate: () -> String?
        let apply: () async -> Bool
        let cancel: () -> Void
    }
    private(set) static var activeApplications = 0
    private var participants: [String: Participant] = [:]
    private var order: [String] = []
    private var invalidated = false
    weak var window: NSWindow?
    private(set) var busy = false
    private(set) var error: String?
    var changed: () -> Void = {}
    var failed: (SettingsPageID) -> Void = { _ in }
    var completed: (Bool) -> Void = { _ in }
    var modified: Bool { participants.values.contains { $0.modified() } }
    func register(_ id: String, participant: Participant) {
        guard !invalidated else { return }
        if participants[id] == nil { order.append(id) }
        participants[id] = participant; notify()
    }
    func unregister(_ id: String) { participants.removeValue(forKey: id); order.removeAll { $0 == id }; notify() }
    func notify() { objectWillChange.send(); changed() }
    func apply(closeAfter: Bool) {
        guard !invalidated, !busy else { return }
        busy = true; error = nil; Self.activeApplications += 1; notify()
        var ordered: [(index: Int, participant: Participant)] = []
        for (index, id) in order.enumerated() {
            if let participant = participants[id] { ordered.append((index, participant)) }
        }
        ordered.sort { left, right in
            let leftPage = left.participant.page.applyOrder, rightPage = right.participant.page.applyOrder
            return leftPage == rightPage ? left.index < right.index : leftPage < rightPage
        }
        let entries = ordered.map { $0.participant }
        Task { [self] in
            defer { Self.activeApplications -= 1 }
            for entry in entries where entry.modified() {
                guard !invalidated else { busy = false; return }
                if let message = entry.validate() {
                    busy = false; error = message; notify(); failed(entry.page); return
                }
                guard await entry.apply() else {
                    busy = false
                    if !invalidated { error = "Settings were not saved. Review this page and try again."; notify(); failed(entry.page) }
                    return
                }
            }
            busy = false
            if !invalidated { notify(); completed(closeAfter) }
        }
    }
    func cancel() {
        guard !busy else { return }
        for id in order { participants[id]?.cancel() }; error = nil; notify()
    }
    func invalidate() {
        invalidated = true; changed = {}; failed = { _ in }; completed = { _ in }
        if !busy { cancelDrafts() }
        participants.removeAll(); order.removeAll()
    }
    private func cancelDrafts() { for id in order { participants[id]?.cancel() } }
}
private struct SettingsTransactionKey: EnvironmentKey { static let defaultValue: SettingsTransaction? = nil }
extension EnvironmentValues {
    var settingsTransaction: SettingsTransaction? {
        get { self[SettingsTransactionKey.self] }
        set { self[SettingsTransactionKey.self] = newValue }
    }
}
private struct SettingsParticipantModifier<Value: Equatable>: ViewModifier {
    @Environment(\.settingsTransaction) private var transaction
    let id: String, page: SettingsPageID, value: Value
    let modified: () -> Bool, validate: () -> String?, apply: () async -> Bool, cancel: () -> Void
    func body(content: Content) -> some View {
        content.onAppear {
            transaction?.register(id, participant: .init(page: page, modified: modified, validate: validate, apply: apply, cancel: cancel))
        }.onChange(of: value) { _ in transaction?.notify() }
    }
}
extension View {
    func settingsParticipant<Value: Equatable>(_ id: String, page: SettingsPageID, value: Value,
        modified: @escaping () -> Bool, validate: @escaping () -> String? = { nil },
        apply: @escaping () async -> Bool, cancel: @escaping () -> Void) -> some View {
        modifier(SettingsParticipantModifier(id: id, page: page, value: value, modified: modified, validate: validate, apply: apply, cancel: cancel))
    }
}

enum SettingsScalar: Equatable {
    case boolean(Bool), integer(Int), string(String)
    func save(_ key: String, defaults: UserDefaults = .standard) {
        switch self {
        case .boolean(let value): defaults.set(value, forKey: key)
        case .integer(let value): defaults.set(value, forKey: key)
        case .string(let value): defaults.set(value, forKey: key)
        }
    }
}
