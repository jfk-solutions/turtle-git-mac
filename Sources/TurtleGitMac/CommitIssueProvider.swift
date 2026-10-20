// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor final class CommitIssueProviderOwner {
    private weak var parent: NSWindow?
    private let model: CommitWindowModel
    private(set) var picker: IssueProviderPickerController?
    init(model: CommitWindowModel, parent: NSWindow) {
        self.model = model; self.parent = parent
        model.cancelProviderIssues = { [weak self] in self?.retire() }
        model.chooseProviderIssues = { [weak self] provider, context in
            guard let self, self.model.messageFocusAvailable, self.picker == nil, let parent = self.parent, parent.attachedSheet == nil else { return nil }
            return await withCheckedContinuation { continuation in
                let child = IssueProviderPickerController(provider: provider, context: context) { [weak self] result in self?.picker = nil; continuation.resume(returning: result) }
                self.picker = child
                if let window = child.window { parent.beginSheet(window) } else { child.close() }
            }
        }
    }
    func retire() { picker?.close(); picker = nil }
}
