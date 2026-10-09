import AppKit

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var repositoryModel: RepositoryModel?
    private var confirmingQuit = false
    var replyToTermination: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    func applicationWillTerminate(_ notification: Notification) { HistoricalPreviewFiles.discardAll(); RepositoryBrowserExportFiles.discardAll(); UnifiedDiffPreviewFiles.discardAll() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmingQuit { return .terminateLater }
        if RepositoryBrowserExportFiles.activeLoads > 0 { return .terminateCancel }
        if UnifiedDiffApplication.activeRequests > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneWindowController }).contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchWindowController }).contains(where: { $0.model.busy || $0.model.progress != nil || $0.model.hasPendingTagConflict || $0.model.browser != nil || $0.model.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.confirmingHard || $0.model.progress != nil || $0.model.showingModifiedFiles || $0.model.showingCommitPicker || $0.model.showingReferencePicker || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ReferenceBrowserWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.renameReference != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BranchTagWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.model.hasPendingNameConflict || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashRestoreWindowController }).contains(where: { $0.model.busy || $0.model.prompt != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PatchWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LogWindowController }).contains(where: { $0.model.busy }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StatusWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BisectWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ExportWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorkingTreePatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImportPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FormatPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeCreateWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.contains(where: { $0.delegate is LFSFileOperationController }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LFSLocksWindowController }).contains(where: { $0.model.busy || $0.model.showingProgress || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeListWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let reviews = sender.windows.compactMap { $0.delegate as? WorkingTreePatchWindowController }
        let imports = sender.windows.compactMap { $0.delegate as? ImportPatchWindowController }
        let controllers = sender.windows.compactMap { $0.delegate as? TextConflictWindowController }
        let commits = sender.windows.compactMap { $0.delegate as? CommitWindowController }
        let adds = sender.windows.compactMap { $0.delegate as? AddWindowController }
        let lfsLocks = sender.windows.compactMap { $0.delegate as? LFSLocksWindowController }
        let statuses = sender.windows.compactMap { $0.delegate as? StatusWindowController }
        let addProgress = sender.windows.compactMap { $0.delegate as? AddProgressWindowController }
        let reverts = sender.windows.compactMap { $0.delegate as? RevertWindowController }
        let browsers = sender.windows.compactMap { $0.delegate as? RepositoryBrowserWindowController }
        let updates = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateWindowController }
        let submoduleDiffs = sender.windows.compactMap { $0.delegate as? SubmoduleDiffWindowController }
        let comparisons = sender.windows.compactMap { $0.delegate as? RevisionComparisonWindowController }
        let fileComparisons = sender.windows.compactMap { $0.delegate as? FileComparisonWindowController }
        let progress = sender.windows.compactMap { $0.delegate as? RevertProgressWindowController }
        guard !adds.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !addProgress.contains(where: { $0.model.busy }), !browsers.contains(where: { $0.model.mutating }), !fileComparisons.contains(where: { $0.model.busy }), !submoduleDiffs.contains(where: { $0.model.busy }), !comparisons.contains(where: { $0.model.busy || $0.model.patchWindow?.model.busy == true || $0.model.unifiedWindows.values.contains(where: { $0.model.busy }) }), !updates.contains(where: { $0.model.busy }), !progress.contains(where: { $0.model.busy }), !reverts.contains(where: { $0.model.busy }), !commits.contains(where: { $0.model.busy }), repositoryModel?.busy != true, !controllers.contains(where: { $0.model.busy }) else { return .terminateCancel }
        guard !imports.isEmpty || !commits.isEmpty || controllers.contains(where: { $0.model.dirty }) || fileComparisons.contains(where: { $0.model.dirty }) || reviews.contains(where: { $0.model.dirty }) else { return .terminateNow }
        confirmingQuit = true
        for controller in lfsLocks { controller.model.confirmingQuit = true }
        for controller in statuses { controller.model.confirmingQuit = true }
        for controller in imports { controller.setQuitConfirmation(true) }
        for controller in reviews { controller.setQuitConfirmation(true) }
        repositoryModel?.confirmingQuit = true
        for browser in browsers { browser.model.confirmingQuit = true }
        for comparison in fileComparisons { comparison.model.confirmingQuit = true }
        for diff in submoduleDiffs { diff.model.confirmingQuit = true }
        for comparison in comparisons { comparison.model.confirmingQuit = true; comparison.model.patchWindow?.model.confirmingQuit = true; for viewer in comparison.model.unifiedWindows.values { viewer.model.confirmingQuit = true } }
        for update in updates { update.model.confirmingQuit = true }
        for add in adds { add.model.confirmingQuit = true }; for add in addProgress { add.model.confirmingQuit = true }
        for revert in reverts { revert.model.confirmingQuit = true }
        for commit in commits { commit.setQuitConfirmation(true) }
        for controller in controllers { controller.model.confirmingQuit = true }
        Task {
            var allowQuit = true
            for controller in reviews where controller.model.dirty {
                if !(await controller.model.resolveDraft(discardImmediately: false)) { allowQuit = false; break }
            }
            for controller in fileComparisons where allowQuit && controller.model.dirty {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.unsavedFilesDescription)” before quitting?"
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let saved = await withCheckedContinuation { continuation in controller.model.saveAll { continuation.resume(returning: $0) } }
                    if !saved { allowQuit = false }
                case .alertSecondButtonReturn: break
                default: allowQuit = false
                }
                if !allowQuit { break }
            }
            for controller in controllers where allowQuit && controller.model.dirty {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.path)” before quitting?"
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let saved = await withCheckedContinuation { continuation in
                        controller.model.save(markResolved: false) { continuation.resume(returning: $0) }
                    }
                    if !saved { allowQuit = false }
                case .alertSecondButtonReturn: break
                default: allowQuit = false
                }
                if !allowQuit { break }
            }
            if allowQuit {
                for commit in commits {
                    commit.window?.makeKeyAndOrderFront(nil)
                    let approved = await withCheckedContinuation { continuation in
                        commit.model.cancel(closeWindow: false) { continuation.resume(returning: $0) }
                    }
                    if !approved { allowQuit = false; break }
                }
            }
            if allowQuit {
                for controller in imports {
                    if !(await controller.model.confirmQuit()) { allowQuit = false; break }
                }
            }
            if allowQuit { for commit in commits { commit.model.restoreCopies.removeAll() } }
            for browser in browsers { browser.model.confirmingQuit = false }
            for diff in submoduleDiffs { diff.model.confirmingQuit = false }
            for comparison in fileComparisons { comparison.model.confirmingQuit = false }
            for comparison in comparisons { comparison.model.confirmingQuit = false; comparison.model.patchWindow?.model.confirmingQuit = false; for viewer in comparison.model.unifiedWindows.values { viewer.model.confirmingQuit = false } }
            for update in updates { update.model.confirmingQuit = false }
            for add in adds { add.model.confirmingQuit = false }; for add in addProgress { add.model.confirmingQuit = false }
            for revert in reverts { revert.model.confirmingQuit = false }
            for commit in commits { commit.setQuitConfirmation(false) }
            repositoryModel?.confirmingQuit = false
            for controller in controllers { controller.model.confirmingQuit = false }
            for controller in imports { controller.setQuitConfirmation(false) }
            for controller in reviews { controller.setQuitConfirmation(false) }
            for controller in lfsLocks { controller.model.confirmingQuit = false }
            for controller in statuses { controller.model.confirmingQuit = false }
            confirmingQuit = false
            replyToTermination(sender, allowQuit)
        }
        return .terminateLater
    }
}
