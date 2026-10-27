// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Presentation-only SciEdit styling shared by the source Input/Notes and
/// Merge/Rebase editors. Commit keeps its existing model-driven style reader.
@MainActor final class MessageEditorStylingSession {
    static private(set) var activeOperations = 0
    private weak var editor: ProjectMessageTextView?
    typealias Query = @Sendable (IssueTrackerProperties, String, Bool, OperationCancellation) async throws -> [IssueMessageStyle]
    private let query: Query
    static func beginOperation() { activeOperations += 1 }
    static func endOperation() { activeOperations -= 1 }
    private var properties = IssueTrackerProperties()
    private var baseFont: NSFont?
    private var formatting = true, retired = false
    private var generation = 0
    private var text = ""
    private var task: Task<Void, Never>?
    private var token: OperationCancellation?
    private var preferences: UserDefaults?
    private var preferenceObserver: NSObjectProtocol?
    init(editor: ProjectMessageTextView, query: Query? = nil) {
        self.editor = editor
        let worker = IssueMessageStyler()
        self.query = query ?? { properties, text, formatting, cancellation in
            try await worker.styles(properties: properties, message: text, formattingEnabled: formatting, cancellation: cancellation)
        }
    }
    deinit { token?.cancel(); task?.cancel(); if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) } }
    func configure(properties: IssueTrackerProperties, preferences: UserDefaults, font: NSFont) {
        guard !retired, let editor else { return }
        if self.preferences !== preferences {
            if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
            self.preferences = preferences
            preferenceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPreferences() }
            }
        }
        let formatting = preferences.object(forKey: "StyleCommitMessages") as? Bool ?? true
        let changed = self.properties != properties || self.formatting != formatting || baseFont != font || !text.utf8.elementsEqual(editor.string.utf8)
        self.properties = properties; self.formatting = formatting; baseFont = font
        if changed { refresh() }
    }
    private func refreshPreferences() {
        guard !retired, let preferences else { return }
        let font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: preferences.object(forKey: "LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
        configure(properties: properties, preferences: preferences, font: font)
    }
    func refresh() {
        guard !retired, let editor, let baseFont else { return }
        generation += 1; token?.cancel(); task?.cancel()
        let request = generation, session = editor.messagePresentationSessionID, text = editor.string, properties = properties, formatting = formatting, query = query
        self.text = text
        // Remove stale positions immediately. Attribute changes preserve bytes,
        // caret, marked text and Undo and never make this a rich-text document.
        guard !editor.hasMarkedText() else { return }
        editor.applyIssueStyles([], base: baseFont)
        guard !text.isEmpty else { return }
        let cancellation = OperationCancellation(); token = cancellation
        task = Task { [weak self, weak editor] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard self?.generation == request, self?.retired == false, editor?.messagePresentationSessionID == session, editor?.hasMarkedText() == false else { return }
                Self.beginOperation()
                defer { Self.endOperation() }
                let styles = try await query(properties, text, formatting, cancellation)
                guard !Task.isCancelled, !cancellation.isCancelled, self?.generation == request, self?.retired == false,
                      let editor, editor.messagePresentationSessionID == session, !editor.hasMarkedText(), editor.string.utf8.elementsEqual(text.utf8) else { return }
                editor.applyIssueStyles(styles, base: baseFont)
            } catch { /* Invalid configuration never rewrites or blocks an editable draft. */ }
        }
    }
    func retire() {
        guard !retired else { return }; retired = true; generation += 1
        token?.cancel(); task?.cancel(); token = nil; task = nil; editor = nil
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }; preferenceObserver = nil; preferences = nil
    }
}
