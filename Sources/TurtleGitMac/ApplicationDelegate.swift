import AppKit

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var repositoryModel: RepositoryModel?
    private var confirmingQuit = false
    var replyToTermination: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    func applicationWillTerminate(_ notification: Notification) { repositoryModel?.stopMonitoringForTermination(); repositoryModel?.finderWatches?.retire(); HistoricalPreviewFiles.discardAll(); RepositoryBrowserExportFiles.discardAll(); UnifiedDiffPreviewFiles.discardAll(); GitConfigurationPreviewFiles.discardAll(); DiffToolApplication.discardAll(); MergeToolApplication.discardAll() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if sender.windows.compactMap({ $0.delegate as? RepositoryAccessWindowController }).contains(where:{ $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if MergeSourceExport.activeExports > 0 || sender.windows.compactMap({ $0.delegate as? TextConflictWindowController }).contains(where: { $0.model.exportingSource }) { return .terminateCancel }
        if MergeEditorOpenWorkflow.activeSaves > 0 || sender.windows.contains(where: { ($0.delegate as? FileComparisonWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? FileComparisonWindowController)?.preparingReplacement == true || ($0.delegate as? TextConflictWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? TextConflictWindowController)?.preparingReplacement == true || ($0.delegate as? WorkingTreePatchWindowController)?.preparingReplacement == true }) { return .terminateCancel }
        if CleanProgressWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? CleanProgressWindowController }).contains(where: { $0.model.authorizing || $0.model.confirmingCancellation }) { return .terminateCancel }
        if CloneWindowModel.activeOperations > 0 || CloneProgressWindowModel.activeOperations > 0 || CreateRepositoryWindowModel.activeOperations > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CreateRepositoryWindowController }).contains(where: { !$0.model.canClose || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if CommitWindowModel.activeIssueProviderOperations > 0 { return .terminateCancel }
        if RevertProgressWindowModel.activeOperations > 0 { return .terminateCancel }
        if FileDropTransferModel.activePreparations > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FileDropTransferWindowController }).contains(where: { !$0.model.retired }) { return .terminateCancel }
        if RenameWindowModel.activeOperations > 0 || ReferenceBrowserWindowModel.activeMutations > 0 { return .terminateCancel }
        if RemoveWindowModel.activeOperations > 0 { return .terminateCancel }
        if RebaseWindowModel.activeReplayOperations > 0 { return .terminateCancel }
        if RebaseWindowModel.activePreparationReads > 0 || RebaseWindowController.activeReferencePickers > 0 { return .terminateCancel }
        if RebaseWindowModel.activeColumnReads > 0 { return .terminateCancel }
        if RebaseWindowModel.activeStashRestorations > 0 { return .terminateCancel }
        if SynchronizationWindowModel.activePushWorkflows > 0 { return .terminateCancel }
        if LogWindowModel.activeActionReads > 0 || LogWindowModel.activeWorkingCommandReads > 0 { return .terminateCancel }
        if ReferenceLogWindowModel.activeRevisionReads > 0 { return .terminateCancel }
        if WorktreeListWindowModel.activeOperations > 0 || WorktreeCreateWindowModel.activeOperations > 0 { return .terminateCancel }
        if PushWindowModel.activePreparationReads > 0 || PushWindowModel.activePushWorkflows > 0 || FetchWindowModel.activePreparationReads > 0 { return .terminateCancel }
        if StatisticsWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? StatisticsWindowController }).contains(where: { $0.model.hasSheet }) { return .terminateCancel }
        if RevisionGraphWindowModel.activeOperations > 0 || RevisionGraphFilterController.activeOperations > 0 { return .terminateCancel }
        if FileCopyWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileCopyWindowController }).contains(where: { $0.model.question || $0.model.confirmingCancel }) { return .terminateCancel }
        if FileMoveWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileMoveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.choosingFolder || $0.model.confirmingCancellation }) { return .terminateCancel }
        if ConflictReviewOperation.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? DeleteConflictWindowController }).contains(where: { !$0.model.operation.canClose }) || sender.windows.compactMap({ $0.delegate as? SubmoduleConflictWindowController }).contains(where: { !$0.model.operation.canClose }) { return .terminateCancel }
        if ResolveWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? ResolveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.hasChild || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if IgnoreWindowModel.activeOperations > 0 { return .terminateCancel }
        if AddWindowModel.activeOperations > 0 { return .terminateCancel }
        if CommitWindowModel.activeCommitPreflights > 0 { return .terminateCancel }
        if CommitWindowModel.activeFileOperations > 0 { return .terminateCancel }
        if CommitWindowModel.activeFileDrops > 0 { return .terminateCancel }
        if LogWindowModel.activeNoteReads > 0 || LogWindowModel.activeNoteSaves > 0 { return .terminateCancel }
        if InputWindowController.activeSaves > 0 { return .terminateCancel }
        if AddRemoteWindowModel.activeOperations > 0 || RemoteReferenceWindowModel.activeOperations > 0 { return .terminateCancel }
        if BisectWindowModel.activeOperations > 0 { return .terminateCancel }
        if GitPropertiesWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? GitPropertiesWindowController }).contains(where:{ $0.model.busy || $0.model.hasSettings || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserWindowModel.activeOperations > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BlameWindowController }).contains(where:{ $0.model.busy || $0.model.openingDocument || $0.model.searchFeedbackBusy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if BlameDocumentOpener.activeReads > 0 { return .terminateCancel }
        if BlameWindowModel.activeHistoryOperations > 0 { return .terminateCancel }
        if BlameWindowModel.activeSyntaxRequests > 0 { return .terminateCancel }
        if MergeRegexOperations.activeRequests > 0 { return .terminateCancel }
        if SVNWindowModel.activeOperations > 0 { return .terminateCancel }
        if ReviewPatchWorkflow.activeLoads > 0 { return .terminateCancel }
        if FileListComparisonSession.activeOperations > 0 { return .terminateCancel }
        if RevisionComparisonWindowModel.activeFileOperations > 0 { return .terminateCancel }
        if LogWindowModel.activeReferenceReads > 0 || LogWindowController.activeReferencePickers > 0 || ReferenceBrowserWindowModel.activeReads > 0 { return .terminateCancel }
        if LogWindowModel.activeHistoryLoads > 0 || LogWindowModel.activeFilterValidations > 0 { return .terminateCancel }
        if ExportWindowModel.activeReads > 0 || BranchTagWindowModel.activeReads > 0 || MergeWindowModel.activeReads > 0 || ResetWindowModel.activeReads > 0 || SwitchWindowModel.activeReads > 0 || SubmoduleUpdateWindowModel.activeReads > 0 || SubmoduleWorkingLogSession.activeReads > 0 || SubmoduleUpdateProgressWindowModel.activeOperations > 0 || SubmoduleDiffWindowModel.activeReads > 0 { return .terminateCancel }
        if RequestPullWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? RequestPullWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if FormatPatchWindowModel.activeOperations > 0 { return .terminateCancel }
        if LocalGitCommandProgress.activeOperations > 0 { return .terminateCancel }
        if StatusWindowModel.activeOperations > 0 { return .terminateCancel }
        if WorkingTreePatchWindowModel.activeOperations > 0 || FileComparisonWindowModel.activePaneExports > 0 { return .terminateCancel }
        if GitDaemonWindowModel.activeOperations > 0 { return .terminateCancel }
        if FirstStartWizardModel.activeWrites > 0 { return .terminateCancel }
        if CredentialSettingsModel.activeSaves > 0 { return .terminateCancel }
        if SSHKeyImportModel.activeOperations > 0 { return .terminateCancel }
        if SSHKeyGenerationModel.activeOperations > 0 { return .terminateCancel }
        if SSHIdentityPermissionsModel.activeOperations > 0 { return .terminateCancel }
        if SavedSSHAuthenticationModel.activeOperations > 0 { return .terminateCancel }
        if SSHTransportCoordinator.activeOperations > 0 { return .terminateCancel }
        if NetworkSettingsModel.activeSaves > 0 { return .terminateCancel }
        if EmailSettingsModel.activeOperations > 0 { return .terminateCancel }
        if LFSLocksWindowModel.activeOperations > 0 { return .terminateCancel }
        if StashRestoreWindowModel.activeOperations > 0 { return .terminateCancel }
        if ClientHookProcessPool.shared.activeScripts > 0 { return .terminateCancel }
        if HookSettingsModel.activeSaves > 0 { return .terminateCancel }
        if AutotextTesterModel.activeRequests > 0 { return .terminateCancel }
        if IssueRegexTesterModel.activeRequests > 0 { return .terminateCancel }
        if IssueTrackerSettingsModel.activeSaves > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SynchronizationWindowController }).contains(where: { $0.model.busy || $0.model.hasBlockingChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RevisionGraphWindowController }).contains(where: { $0.model.busy || $0.hasExportSheet || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeAbortWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeAbortProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if confirmingQuit { return .terminateLater }
        if sender.windows.compactMap({ $0.delegate as? MergeOpenWindowController }).contains(where: { $0.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImageLoadWindowController }).contains(where: { !$0.retired }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CommitWindowController }).contains(where: { $0.hasMessagePicker || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImageConflictWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RemoteSettingsWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RemoteTagWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserExportFiles.activeLoads > 0 { return .terminateCancel }
        if ExternalToolProcesses.activeRequests > 0 || UnifiedDiffApplication.activeRequests > 0 || DiffToolApplication.activeRequests > 0 || MergeToolApplication.activeRequests > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneWindowController }).contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CloneProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FetchWindowController }).contains(where: { $0.model.operationActive || $0.model.browsing || $0.model.managing || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PullProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingConflictHint || $0.model.dispatchingAction || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FetchProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingRebaseDecision || $0.model.dispatchingAction || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeWindowController }).contains(where: { $0.model.busy || $0.model.progress != nil || $0.model.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? MergeProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.model.confirmingConflictHint || $0.model.confirmingDeletion || $0.model.checkingDismissal || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchWindowController }).contains(where: { $0.model.busy || $0.model.progress != nil || $0.model.hasPendingTagConflict || $0.model.browser != nil || $0.model.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? SwitchProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.confirmingHard || $0.model.progress != nil || $0.model.showingModifiedFiles || $0.model.showingCommitPicker || $0.model.showingReferencePicker || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ResetProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ReferenceBrowserWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.renameReference != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BranchTagWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.model.hasPendingNameConflict || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashRestoreWindowController }).contains(where: { $0.model.busy || $0.model.prompt != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if PatchWindowModel.activeOperations != 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? PatchWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LogWindowController }).contains(where: { $0.model.busy || $0.model.orderingBlocked || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StatusWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        // A forced owner close can remove the window before its Git child has
        // stopped. Keep termination fenced until that child or atomic save ends.
        if HistoryCombineSelectionReader.activeReads > 0 || HistoryCombineWindowModel.activeOperations > 0 || HistoryRevertWindowModel.activeOperations > 0 ||
            HistoryNotesWindowModel.activeMutations > 0 || HistoryNotesWindowModel.activeReads > 0 || SynchronizationWindowModel.activeHistoryDeletions > 0 ||
            LogWindowModel.activeHistoryDeletions > 0 || GitConfigurationSettingsModel.activeSaves > 0 ||
            RemoteSettingsWindowModel.activeOperations > 0 || SettingsTransaction.activeApplications > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? HistoryNotesWindowController }).contains(where: { $0.model.loading || $0.model.saving || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? HistoryRevertWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BisectWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ExportWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorkingTreePatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ImportPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FormatPatchWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeCreateWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.contains(where: { $0.delegate is LFSFileOperationController }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? LFSLocksWindowController }).contains(where: { $0.model.busy || $0.model.showingProgress || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? WorktreeListWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CommitContainingReferencesWindowController }).contains(where: { $0.busy || $0.hasBlockingChild }) { return .terminateCancel }
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
        let synchronizations = sender.windows.compactMap { $0.delegate as? SynchronizationWindowController }
        let submoduleSyncs = sender.windows.compactMap { $0.delegate as? SubmoduleSyncWindowController }
        if submoduleSyncs.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let submoduleAdds = sender.windows.compactMap { $0.delegate as? SubmoduleAddWindowController }
        if submoduleAdds.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let submoduleAddProgress = sender.windows.compactMap { $0.delegate as? SubmoduleAddProgressWindowController }
        if submoduleAddProgress.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let updateProgress = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateProgressWindowController }
        if updateProgress.contains(where: { $0.model.activeOperation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        let updates = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateWindowController }
        let submoduleDiffs = sender.windows.compactMap { $0.delegate as? SubmoduleDiffWindowController }
        let comparisons = sender.windows.compactMap { $0.delegate as? RevisionComparisonWindowController }
        let fileComparisons = sender.windows.compactMap { $0.delegate as? FileComparisonWindowController }
        let progress = sender.windows.compactMap { $0.delegate as? RevertProgressWindowController }
        guard !adds.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !addProgress.contains(where: { $0.model.busy }), !browsers.contains(where: { $0.model.mutating }), !fileComparisons.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !submoduleDiffs.contains(where: { $0.model.busy || $0.model.hasUpdateChild }), !comparisons.contains(where: { $0.model.busy || $0.model.patchWindow?.model.busy == true || $0.model.unifiedWindows.values.contains(where: { $0.model.busy }) }), !updates.contains(where: { $0.model.busy }), !progress.contains(where: { $0.model.busy }), !reverts.contains(where: { $0.model.busy }), !commits.contains(where: { $0.model.busy }), repositoryModel?.busy != true, !controllers.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) else { return .terminateCancel }
        guard !imports.isEmpty || !commits.isEmpty || controllers.contains(where: { $0.model.dirty }) || fileComparisons.contains(where: { $0.model.dirty }) || reviews.contains(where: { $0.model.dirty }) else { return finishBackgroundWatches(sender) }
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
        for update in updateProgress { update.model.confirmingQuit = true }
        for add in submoduleAdds { add.model.confirmingQuit = true }
        for add in submoduleAddProgress { add.model.confirmingQuit = true }
        for sync in submoduleSyncs { sync.model.confirmingQuit = true }
        for sync in synchronizations { sync.model.confirmingQuit = true }
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
                    let saved = await withCheckedContinuation { continuation in controller.model.saveAllForQuit { continuation.resume(returning: $0) } }
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
                        controller.model.saveForQuit { continuation.resume(returning: $0) }
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
            for update in updateProgress { update.model.confirmingQuit = false }
            for add in submoduleAdds { add.model.confirmingQuit = false }
            for add in submoduleAddProgress { add.model.confirmingQuit = false }
            for sync in submoduleSyncs { sync.model.confirmingQuit = false }
            for sync in synchronizations { sync.model.confirmingQuit = false }
            for add in adds { add.model.confirmingQuit = false }; for add in addProgress { add.model.confirmingQuit = false }
            for revert in reverts { revert.model.confirmingQuit = false }
            for commit in commits { commit.setQuitConfirmation(false) }
            repositoryModel?.confirmingQuit = false
            for controller in controllers { controller.model.confirmingQuit = false }
            for controller in imports { controller.setQuitConfirmation(false) }
            for controller in reviews { controller.setQuitConfirmation(false) }
            for controller in lfsLocks { controller.model.confirmingQuit = false }
            for controller in statuses { controller.model.confirmingQuit = false }
            if allowQuit { repositoryModel?.stopMonitoringForTermination();await repositoryModel?.finderWatches?.shutdown() }
            confirmingQuit = false
            replyToTermination(sender, allowQuit)
        }
        return .terminateLater
    }
    private func finishBackgroundWatches(_ sender:NSApplication) -> NSApplication.TerminateReply {
        repositoryModel?.stopMonitoringForTermination()
        guard let manager=repositoryModel?.finderWatches else { return .terminateNow }
        let pending=manager.pendingOperations+(manager.backgroundService?.busy == true ? 1 : 0);manager.retire()
        guard pending>0 else { return .terminateNow }
        confirmingQuit=true
        Task { await manager.shutdown();confirmingQuit=false;replyToTermination(sender,true) }
        return .terminateLater
    }

}
