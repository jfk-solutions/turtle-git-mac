import AppKit
import TurtleGitCore

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SWIFT_PACKAGE
        if let file = Bundle.module.url(forResource: "ApplicationIcon", withExtension: "png", subdirectory: "Branding"), let icon = NSImage(contentsOf: file) { NSApp.applicationIconImage = icon }
        #endif
        TurtleGitHelp.install()
        startupDidFinishLaunching()
        if startupLaunchMode == .workspace { SupportReportService.shared.checkForPreviousCrash() }
        installFinderServices()
    }
    @objc func showHelp(_ sender: Any?) { TurtleGitHelp.showContext() }
    lazy var finderServicesProvider = TurtleGitFinderServicesProvider { [weak self] request in
        guard let self else { throw TurtleGitFinderServicesProvider.Failure.unavailable }
        try self.submitServiceRequest(request)
    }
    private var previousFinderServicesProvider: Any?
    private var finderServicesInstalled = false
    var workspaceServiceHandler: (RepositoryModel, FinderRequest) -> Bool = { $0.handleFinderService($1) }
    private(set) var pendingFinderServiceRequest: FinderRequest?
    private var pendingFinderServiceError: String?
    func installFinderServices() {
        guard !finderServicesInstalled, acceptingOpenURLs else { return }
        previousFinderServicesProvider = NSApp.servicesProvider
        finderServicesInstalled = true
        NSApp.servicesProvider = finderServicesProvider
    }
    func retireFinderServices() {
        finderServicesProvider.retire()
        pendingFinderServiceRequest = nil; pendingFinderServiceError = nil
        guard finderServicesInstalled else { return }
        finderServicesInstalled = false
        if (NSApp.servicesProvider as AnyObject?) === finderServicesProvider {
            NSApp.servicesProvider = previousFinderServicesProvider
        }
        previousFinderServicesProvider = nil
    }
    func submitServiceRequest(_ request: FinderRequest) throws {
        guard acceptingOpenURLs, !finderServicesProvider.retired, !confirmingQuit,
              repositoryModel?.confirmingQuit != true else { throw TurtleGitFinderServicesProvider.Failure.unavailable }
        guard let command = FinderServiceCommand(rawValue: request.action.rawValue) else { throw TurtleGitFinderServicesProvider.Failure.command }
        let captured = try command.request(paths: request.paths, alternateTool: request.alternateTool)
        if startupLaunchMode == .mergeTool {
            // Keep the service origin across the separate workspace launch; its
            // typed decoder must choose the owned Services permission workflow.
            let url = try command.serviceURL(paths: captured.paths, alternateTool: captured.alternateTool)
            workspaceOpenHandoff.submit([url]); return
        }
        if let repositoryModel, repositoryModel.busy || repositoryModel.hasPendingRepositoryWork {
            throw TurtleGitFinderServicesProvider.Failure.busy
        }
        guard pendingFinderServiceRequest == nil else { throw TurtleGitFinderServicesProvider.Failure.busy }
        if startupReady, startupDelivered, let repositoryModel {
            guard workspaceServiceHandler(repositoryModel, captured) else { throw TurtleGitFinderServicesProvider.Failure.busy }
        } else {
            pendingFinderServiceRequest = captured
        }
    }
    private func deliverPendingFinderService() {
        guard acceptingOpenURLs, startupReady, startupDelivered, startupLaunchMode == .workspace,
              let repositoryModel else { return }
        if let request = pendingFinderServiceRequest {
            pendingFinderServiceRequest = nil
            if confirmingQuit || repositoryModel.confirmingQuit || repositoryModel.busy || repositoryModel.hasPendingRepositoryWork || !workspaceServiceHandler(repositoryModel, request) {
                pendingFinderServiceError = "TurtleGit could not begin the queued service. Finish or cancel the current operation, then invoke the service again."
            }
        }
        if let message = pendingFinderServiceError { pendingFinderServiceError = nil; repositoryModel.error = message }
    }
    weak var repositoryModel: RepositoryModel? { didSet { deliverStartupCommand(); deliverPendingOpenURLs(); deliverPendingFinderService() } }
    var startupArguments = Array(CommandLine.arguments.dropFirst())
    var startupDirectory = FileManager.default.currentDirectoryPath
    var startupCommandHandler: ((RepositoryModel, [String], String) -> Void)?
    var startupMergeToolExit: (Int32) -> Void = { exit($0) }
    private var startupMergeToolActive = false
    private var pendingMergeToolExit: Int32?
    private var completingMergeToolExit = false
    private var mergeToolShutdownPrepared = false, mergeToolExitDelivered = false
    private var pendingOpenURLs: [URL] = []
    private var deliveringOpenURLs = false, acceptingOpenURLs = true
    var workspaceOpenHandler: (RepositoryModel, URL) -> Void = { $0.handle($1) }
    lazy var workspaceOpenHandoff: WorkspaceOpenHandoff = {
        let value = WorkspaceOpenHandoff()
        value.onStateChanged = { [weak self] in self?.completeMergeToolExitIfReady() }
        return value
    }()
    func application(_ application: NSApplication, open urls: [URL]) {
        guard acceptingOpenURLs else { return }
        if startupLaunchMode == .mergeTool { workspaceOpenHandoff.submit(urls) }
        else {
            for url in urls {
                if url.scheme == "turtlegit", url.host == "service" {
                    do { try submitServiceRequest(FinderServiceCommand.request(serviceURL: url)) }
                    catch { pendingFinderServiceError = error.localizedDescription }
                } else { pendingOpenURLs.append(url) }
            }
            deliverPendingOpenURLs(); deliverPendingFinderService()
        }
    }
    private func deliverPendingOpenURLs() {
        guard acceptingOpenURLs, !deliveringOpenURLs, startupReady, startupDelivered, startupLaunchMode == .workspace, let repositoryModel else { return }
        deliveringOpenURLs = true; defer { deliveringOpenURLs = false }
        while acceptingOpenURLs, !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs; pendingOpenURLs.removeAll()
            for url in urls {
                guard acceptingOpenURLs else { return }
                workspaceOpenHandler(repositoryModel, url)
            }
        }
    }
    private func finishMergeToolStartup(_ status: Int32) {
        guard pendingMergeToolExit == nil, !completingMergeToolExit, !mergeToolExitDelivered else { return }
        pendingMergeToolExit = status; completeMergeToolExitIfReady()
    }
    private func completeMergeToolExitIfReady() {
        guard let status = pendingMergeToolExit, !completingMergeToolExit, !workspaceOpenHandoff.hasPendingWork else { return }
        completingMergeToolExit = true
        Task { [self] in
            if !mergeToolShutdownPrepared {
                repositoryModel?.stopMonitoringForTermination()
                await repositoryModel?.finderWatches?.shutdown();await repositoryModel?.shutdownFinderPublication()
                mergeToolShutdownPrepared = true
            }
            completingMergeToolExit = false
            // Launch Services may deliver another request while shutdown yields.
            // Its accepted launch/acknowledgment must finish before process exit.
            guard !workspaceOpenHandoff.hasPendingWork, !mergeToolExitDelivered else { return }
            pendingMergeToolExit = nil; mergeToolExitDelivered = true; startupMergeToolActive = false
            applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            startupMergeToolExit(status)
        }
    }
    private var startupReady = false
    private(set) var startupDelivered = false
    var startupLaunchMode: TurtleGitLaunchMode { TurtleGitLaunchMode.resolve(arguments: startupArguments, currentDirectory: startupDirectory) }
    // The standalone Scene has no RepositoryWindow.onAppear. Retain its minimal
    // routing owner here, without starting Finder monitors or opening a workspace.
    private(set) var standaloneWorkspace: RepositoryModel?
    private var standaloneAppearance: AppAppearance?
    private var standaloneActivationRequested = false
    var activateStandaloneApplication: () -> Void = {
        // A tool executed directly by Git has no SwiftUI document window to
        // activate the process. makeKeyAndOrderFront on the later AppKit editor
        // cannot establish its key-window menu owner while the app is inactive.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    var makeStandaloneWorkspace: () -> RepositoryModel = { RepositoryModel(startMonitoring: false, initializePreferences: false) }
    var configureStandaloneServices: (RepositoryModel, AppAppearance) -> Void = { workspace, appearance in
        appearance.apply()
        SettingsPresentationService.shared.install(workspace: workspace, appearance: appearance)
    }
    func bootstrapStandaloneToolIfNeeded() {
        guard startupLaunchMode == .mergeTool, repositoryModel == nil, standaloneWorkspace == nil else { return }
        let workspace = makeStandaloneWorkspace(), appearance = AppAppearance(preferences: .standard)
        standaloneWorkspace = workspace; standaloneAppearance = appearance
        configureStandaloneServices(workspace, appearance)
        repositoryModel = workspace
    }
    func startupDidFinishLaunching() {
        bootstrapStandaloneToolIfNeeded(); startupReady = true
        if standaloneWorkspace != nil, !standaloneActivationRequested {
            standaloneActivationRequested = true; activateStandaloneApplication()
        }
        deliverStartupCommand(); deliverPendingFinderService()
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { startupLaunchMode == .workspace }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { startupLaunchMode == .workspace }
    private func deliverStartupCommand() {
        guard startupReady, !startupDelivered, let repositoryModel else { return }
        startupDelivered = true
        if let startupCommandHandler { startupCommandHandler(repositoryModel, startupArguments, startupDirectory) }
        else {
          let mergeTool = repositoryModel.handleMergeToolCommandLine(arguments: startupArguments, currentDirectory: startupDirectory, completion: { [weak self, weak repositoryModel] status in
            guard let self else { return }
            self.finishMergeToolStartup(status)
          })
          startupMergeToolActive = mergeTool
          if !mergeTool { repositoryModel.handleCommandLine(arguments: startupArguments, currentDirectory: startupDirectory) }
        }
        deliverPendingOpenURLs(); deliverPendingFinderService()
    }
    private var confirmingQuit = false
    var replyToTermination: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    func applicationWillTerminate(_ notification: Notification) { retireFinderServices(); acceptingOpenURLs = false; workspaceOpenHandoff.retire(); pendingOpenURLs.removeAll(); SupportReportService.shared.retire(); DockProgressPresenter.shared.clear(); repositoryModel?.stopMonitoringForTermination(); repositoryModel?.finderWatches?.retire(); HistoricalPreviewFiles.discardAll(); RepositoryBrowserExportFiles.discardAll(); UnifiedDiffPreviewFiles.discardAll(); GitConfigurationPreviewFiles.discardAll(); DiffToolApplication.discardAll(); MergeToolApplication.discardAll() }
    private func setTransferQuitConfirmation(_ sender: NSApplication, _ value: Bool) {
        for window in sender.windows {
            (window.delegate as? FileDropTransferWindowController)?.model.confirmingQuit = value
            (window.delegate as? FileMoveWindowController)?.model.confirmingQuit = value
            (window.delegate as? FileCopyWindowController)?.model.confirmingQuit = value
            (window.delegate as? ResolveWindowController)?.model.confirmingQuit = value
            (window.delegate as? AddProgressWindowController)?.model.confirmingQuit = value
            (window.delegate as? RevertProgressWindowController)?.model.confirmingQuit = value
            (window.delegate as? PresentationComparisonWindowController)?.model.confirmingQuit = value
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pendingFinderServiceRequest != nil { return .terminateCancel }
        if MergeExternalReloadCoordinator.activeRequests > 0 { return .terminateCancel }
        if SettingsSheetController.activeSheets > 0 || workspaceOpenHandoff.hasPendingWork || RepositoryModel.activeCommandFileOperations > 0 || repositoryModel?.hasPendingRepositoryWork == true { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? RepositoryAccessWindowController }).contains(where:{ $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if MergeSourceExport.activeExports > 0 || sender.windows.compactMap({ $0.delegate as? TextConflictWindowController }).contains(where: { $0.model.sourceExporter.hasPendingWork }) { return .terminateCancel }
        if MergeEditorOpenWorkflow.activeSaves > 0 || sender.windows.contains(where: { ($0.delegate as? FileComparisonWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? FileComparisonWindowController)?.preparingReplacement == true || ($0.delegate as? TextConflictWindowController)?.editorOpenWorkflow != nil || ($0.delegate as? TextConflictWindowController)?.preparingReplacement == true || ($0.delegate as? WorkingTreePatchWindowController)?.preparingReplacement == true }) { return .terminateCancel }
        if RevertWindowModel.activeOperations > 0 || sender.windows.compactMap({$0.delegate as? RevertWindowController}).contains(where:{$0.model.hasChild || $0.model.commands.busy || $0.window?.attachedSheet != nil}) { return .terminateCancel }
        if ImageComparisonViewModel.activeFileReads > 0 || ImageLoadWindowController.activeReleases > 0 { return .terminateCancel }
        if FinderFilesystemWorkflowRelease.activeRetirements > 0 || CleanProgressWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? CleanProgressWindowController }).contains(where: { $0.model.authorizing || $0.model.confirmingCancellation }) { return .terminateCancel }
        if sender.windows.contains(where:{ window in
            switch window.delegate {
            case let owner as RenameWindowController:return owner.finderServiceWorkPending
            case let owner as RemoveWindowController:return owner.finderServiceWorkPending
            case let owner as CleanWindowController:return owner.finderServiceWorkPending
            case let owner as CleanProgressWindowController:return owner.finderServiceWorkPending
            default:return false
            }
        }) {return .terminateCancel}
        if CloneWindowModel.activeOperations > 0 || CloneProgressWindowModel.activeOperations > 0 || CreateRepositoryWindowModel.activeOperations > 0 { return .terminateCancel }
        if CloneWindowController.activeChildReleases > 0 || CreateRepositoryWindowController.activeReleases > 0 { return .terminateCancel }
        if BranchTagWindowController.activeReleases > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? CreateRepositoryWindowController }).contains(where: { !$0.model.canClose || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if CommitWindowModel.activeIssueProviderOperations > 0 || IssueProviderPickerModel.activeOperations > 0 || IssueProviderCredentialEditorModel.activeReads > 0 || IssueProviderCredentialDrafts.activeOperations > 0 { return .terminateCancel }
        if RevertProgressWindowModel.activeOperations > 0 || RevertProgressWindowController.activeReleases > 0 || sender.windows.compactMap({$0.delegate as? RevertProgressWindowController}).contains(where:{$0.model.fileActionBusy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil}) { return .terminateCancel }
        if FileDropTransferModel.activePreparations > 0 || FileDropTransferWindowController.activeReleases > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? FileDropTransferWindowController }).contains(where: { !$0.model.retired }) { return .terminateCancel }
        if ReferenceBrowserWindowModel.activeComparisons > 0 || ReferenceBrowserWindowController.activeChildReleases > 0 || RenameWindowModel.activeOperations > 0 || ReferenceBrowserWindowModel.activeMutations > 0 { return .terminateCancel }
        if RemoveWindowModel.activeOperations > 0 { return .terminateCancel }
        if RebaseWindowModel.activeReplayOperations > 0 { return .terminateCancel }
        if sender.windows.compactMap({$0.delegate as? RebaseWindowController}).contains(where:{$0.model.revisionHistoryBlocked || $0.model.containingReferenceBlocked || $0.model.revisionFindBlocked || $0.model.pendingConfirmation != nil || $0.model.hasReplayQuestion || $0.model.confirmingReplayCancellation || $0.window?.attachedSheet != nil}) {return .terminateCancel}
        if RebaseWindowModel.activePreparationReads > 0 || RebaseWindowController.activeReferencePickers > 0 || RebaseWindowController.activeCommitPickers > 0 { return .terminateCancel }
        if RebaseWindowModel.activeColumnReads > 0 { return .terminateCancel }
        if RebaseWindowModel.activeStashRestorations > 0 { return .terminateCancel }
        if SynchronizationProgressModel.activeOperations > 0 || SynchronizationWindowModel.activePushWorkflows > 0 || SynchronizationWindowModel.activeInlineOperations > 0 || SynchronizationWindowController.activeInlineReleases > 0 { return .terminateCancel }
        if LogWindowModel.activeActionReads > 0 || LogWindowModel.activeWorkingCommandReads > 0 { return .terminateCancel }
        if ReferenceLogWindowModel.activeRevisionReads > 0 || ReferenceLogWindowModel.activeOwnedOperations > 0 { return .terminateCancel }
        if WorktreeListWindowModel.activeOperations > 0 || WorktreeCreateWindowModel.activeOperations > 0 { return .terminateCancel }
        if PushWindowModel.activePreparationReads > 0 || PushWindowModel.activePushWorkflows > 0 || FetchWindowModel.activePreparationReads > 0 { return .terminateCancel }
        if sender.windows.compactMap({$0.delegate as? CloneProgressWindowController}).contains(where:{$0.model.fileActionBusy}) || sender.windows.compactMap({$0.delegate as? FetchProgressWindowController}).contains(where:{$0.model.fileActionBusy}) {return .terminateCancel}
        if FetchWindowModel.activeProgressOperations > 0 || FetchWindowController.activeProgressReleases > 0 { return .terminateCancel }
        if StashSaveProgressWindowModel.activeOperations > 0 || ExportProgressWindowModel.activeOperations > 0 || ExportProgressWindowController.activeReleases > 0 { return .terminateCancel }
        if MergeProgressWindowModel.activeOperations > 0 || MergeWindowController.activeChildReleases > 0 { return .terminateCancel }
        if SwitchProgressWindowModel.activeOperations > 0 || SwitchWindowController.activeChildReleases > 0 || ResetProgressWindowModel.activeOperations > 0 || ResetWindowController.activeChildReleases > 0 || BisectWindowController.activeChildReleases > 0 { return .terminateCancel }
        if StatisticsWindowModel.activeOperations > 0 || StatisticsWindowController.activeExports > 0 || sender.windows.compactMap({ $0.delegate as? StatisticsWindowController }).contains(where: { $0.model.hasSheet }) { return .terminateCancel }
        if RevisionGraphFindController.activeOperations > 0 || CommitContainingReferencesWindowController.activeOperations > 0 || RevisionGraphWindowModel.activeOperations > 0 || RevisionGraphFilterController.activeOperations > 0 { return .terminateCancel }
        if FileCopyWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileCopyWindowController }).contains(where: { $0.model.question || $0.model.confirmingCancel }) { return .terminateCancel }
        if FileMoveWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? FileMoveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.choosingFolder || $0.model.confirmingCancellation }) { return .terminateCancel }
        if ConflictReviewOperation.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? DeleteConflictWindowController }).contains(where: { !$0.model.operation.canClose }) || sender.windows.compactMap({ $0.delegate as? SubmoduleConflictWindowController }).contains(where: { !$0.model.operation.canClose }) { return .terminateCancel }
        if ResolveWindowModel.activeOperations > 0 || ResolveWindowController.activeReleases > 0 || sender.windows.compactMap({ $0.delegate as? ResolveWindowController }).contains(where: { $0.model.hasQuestion || $0.model.hasChild || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if IgnoreWindowModel.activeOperations > 0 { return .terminateCancel }
        if LogMessageView.Coordinator.activeOperations > 0 { return .terminateCancel }
        if AddWindowModel.activeOperations > 0 || AddProgressWindowModel.activeOperations > 0 || AddProgressWindowController.activeReleases > 0 { return .terminateCancel }
        if CommitWindowModel.activeCommitPreflights > 0 { return .terminateCancel }
        if CommitWindowModel.activeReloads > 0 || CommitWindowModel.activeFileOperations > 0 || CommitWindowModel.activePreferenceOperations > 0 || CommitWindowModel.activeMetadataOperations > 0 { return .terminateCancel }
        if CommitWindowModel.activeFileDrops > 0 { return .terminateCancel }
        if LogWindowModel.activeNoteReads > 0 || LogWindowModel.activeNoteSaves > 0 || CommitNotePresenter.activeWarnings > 0 { return .terminateCancel }
        if MessageEditorStylingSession.activeOperations > 0 { return .terminateCancel }
        if InputWindowController.activeSaves > 0 { return .terminateCancel }
        if AddRemoteWindowModel.activeOperations > 0 || RemoteReferenceWindowModel.activeOperations > 0 || RemoteTagWindowModel.activeOperations > 0 { return .terminateCancel }
        if BisectWindowModel.activeOperations > 0 { return .terminateCancel }
        if GitPropertiesWindowModel.activeOperations > 0 || sender.windows.compactMap({ $0.delegate as? GitPropertiesWindowController }).contains(where:{ $0.model.busy || $0.model.hasSettings || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserWindowModel.activeOperations > 0 || RepositoryBrowserFileOperation.activeRequests > 0 { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BlameWindowController }).contains(where:{ $0.model.busy || $0.model.openingDocument || $0.model.searchFeedbackBusy || $0.hasBlockingHistoryChild || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if BlameDocumentOpener.activeReads > 0 { return .terminateCancel }
        if BlameWindowModel.activeHistoryOperations > 0 { return .terminateCancel }
        if BlameWindowModel.activeSyntaxRequests > 0 { return .terminateCancel }
        if MergeRegexFilterListController.activeEditors > 0 { return .terminateCancel }
        if ReleaseUpdateModel.activeOperations > 0 { return .terminateCancel }
        if MergeRegexOperations.activeRequests > 0 { return .terminateCancel }
        if TurtleGitAboutController.activeReads > 0 {return .terminateCancel}
        if SupportReportService.activeScans > 0 { return .terminateCancel }
        if SupportReportWindowModel.activeReads > 0 || SupportReportWindowModel.activeWrites > 0 || SupportReportWindowController.activePickers > 0 { return .terminateCancel }
        if SVNWindowModel.activeOperations > 0 { return .terminateCancel }
        if SendPatchWindowModel.activeLoads > 0 || SendPatchWindowController.activeTargetReads > 0 {return .terminateCancel}
        if SendPatchProgressModel.activeSubmissions > 0 || SendPatchProgressWindowController.activeReleases > 0 {return .terminateCancel}
        if ImportPatchWindowModel.activeWorkers > 0 || ImportPatchWindowController.activeReleases > 0 {return .terminateCancel}
        if ReviewPatchWorkflow.activeLoads > 0 { return .terminateCancel }
        if ImageConflictWindowModel.activeOperations > 0 { return .terminateCancel }
        if FileListComparisonSession.activeOperations > 0 { return .terminateCancel }
        if RevisionComparisonWindowModel.activeFileOperations > 0 { return .terminateCancel }
        if LogWindowModel.activeReferenceReads > 0 || LogWindowController.activeReferencePickers > 0 || ReferenceBrowserWindowModel.activeReads > 0 { return .terminateCancel }
        if LogWindowModel.activeFileOpenReads > 0 || LogDocumentOpenSession.activeRequests > 0 || LogWindowModel.activeHistoryLoads > 0 || LogWindowModel.activeFilterValidations > 0 { return .terminateCancel }
        if ExportWindowModel.activeReads > 0 || BranchTagWindowModel.activeReads > 0 || BranchTagWindowModel.activeCreations > 0 || MergeWindowModel.activeReads > 0 || ResetWindowModel.activeReads > 0 || SwitchWindowModel.activeReads > 0 || SubmoduleUpdateWindowModel.activeReads > 0 || SubmoduleWorkingLogSession.activeReads > 0 || SubmoduleUpdateProgressWindowModel.activeOperations > 0 || SubmoduleDiffWindowModel.activeReads > 0 { return .terminateCancel }
        if RequestPullWindowModel.activeOperations > 0 || RequestPullWindowController.activeReleases > 0 || sender.windows.compactMap({ $0.delegate as? RequestPullWindowController }).contains(where: { $0.activeOperation }) { return .terminateCancel }
        if FormatPatchWindowModel.activeOperations > 0 || FormatPatchWindowController.activeReleases > 0 { return .terminateCancel }
        if LocalGitCommandProgress.activeOperations > 0 { return .terminateCancel }
        if StatusWindowModel.activeOperations > 0 { return .terminateCancel }
        if MissingStagedFileRecoverySession.activeRequests > 0 { return .terminateCancel }
        if WorkingTreePatchWindowModel.activeOperations > 0 || FileComparisonWindowModel.activePaneExports > 0 || FileComparisonWindowModel.activeProjectionChoices > 0 { return .terminateCancel }
        if GitDaemonWindowModel.activeOperations > 0 || GitDaemonWindowModel.activeQuestions > 0 { return .terminateCancel }
        if FirstStartWizardModel.activeWrites > 0 || GeneralGitSettingsModel.activeOperations > 0 || GeneralGitSettingsModel.activeDialogs > 0 { return .terminateCancel }
        if GitConfigurationSettingsModel.activeFolderChoosers > 0 {return .terminateCancel}
        if GitConfigurationSettingsModel.activeSheetReleases > 0 || CredentialSettingsModel.activeSheetReleases > 0 || NetworkSettingsModel.activeSheetReleases > 0 || HookSettingsModel.activeReads > 0 || HookConfigurationController.activeReleases > 0 || HookConfigurationController.activeChoosers > 0 || RemoteSettingsWindowModel.activeRetirements > 0 || SettingsTransaction.activeRetirements > 0 {return .terminateCancel}
        if MergeFormatPrompt.activeDialogs > 0 { return .terminateCancel }
        if MergeEditorSettingsModel.activeProfileEditors > 0 { return .terminateCancel }
        if MergeNavigationRequests.activeRequests > 0 { return .terminateCancel }
        if MergeOpenWindowController.activeChoices > 0 { return .terminateCancel }
        if ToolApplicationChooser.activeChoosers > 0 {return .terminateCancel}
        if CredentialSettingsModel.activeSaves > 0 || CredentialSettingsModel.activeReads > 0 || CredentialSettingsModel.activeSelections > 0 { return .terminateCancel }
        if SSHKeyImportModel.activeOperations > 0 { return .terminateCancel }
        if SSHKeyGenerationModel.activeOperations > 0 { return .terminateCancel }
        if SSHIdentityPermissionsModel.activeOperations > 0 { return .terminateCancel }
        if SavedDataSettingsModel.activeCacheClears > 0 || SavedSSHAuthenticationModel.activeOperations > 0 { return .terminateCancel }
        if SSHTransportCoordinator.activeOperations > 0 { return .terminateCancel }
        if NetworkSettingsModel.activeSaves > 0 || NetworkSettingsModel.activeReads > 0 || NetworkSettingsModel.activeSSHChoosers > 0 { return .terminateCancel }
        if EmailSettingsModel.activeOperations > 0 || EmailSettingsModel.activeCredentialEditors > 0 { return .terminateCancel }
        if LFSLocksWindowModel.activeOperations > 0 { return .terminateCancel }
        if StashRestoreWindowModel.activeOperations > 0 || StashWindowModel.activePreparations > 0 || StashWindowController.activeChildReleases > 0 { return .terminateCancel }
        if SubmoduleAddProgressWindowModel.activeOperations > 0 || SubmoduleSyncWindowModel.activeOperations > 0 || SubmoduleUpdateProgressWindowController.activeChildReleases > 0 { return .terminateCancel }
        if ClientHookProcessPool.shared.activeScripts > 0 || ClientHookSession.activeOperations > 0 || ClientHookSession.activeQuestionReleases > 0 { return .terminateCancel }
        if HookSettingsModel.activeSaves > 0 { return .terminateCancel }
        if AutotextTesterModel.activeRequests > 0 { return .terminateCancel }
        if IssueRegexTesterModel.activeRequests > 0 { return .terminateCancel }
        if ProjectDialogSettingsModel.activeSaves > 0 || ProjectDialogSettingsModel.activeReads > 0 || GitConfigurationSettingsModel.activeReads > 0 || IssueTrackerSettingsModel.activeReads > 0 { return .terminateCancel }
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
        if sender.windows.compactMap({$0.delegate as? AddRemoteWindowController}).contains(where:{$0.model.error != nil || $0.window?.attachedSheet != nil}) || sender.windows.compactMap({$0.delegate as? RemoteReferenceWindowController}).contains(where:{$0.model.error != nil || $0.window?.attachedSheet != nil}) {return .terminateCancel}
        if sender.windows.compactMap({ $0.delegate as? RemoteTagWindowController }).contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if RepositoryBrowserExportFiles.activeLoads > 0 { return .terminateCancel }
        if PresentationComparisonWindowModel.activeRequests > 0 || sender.windows.compactMap({$0.delegate as? PresentationComparisonWindowController}).contains(where:{$0.window?.attachedSheet != nil}) {return .terminateCancel}
        if AlternativeEditor.activeRequests > 0 || ExternalDocumentApplication.activeRequests > 0 || ExternalToolProcesses.activeRequests > 0 || UnifiedDiffApplication.activeRequests > 0 || DiffToolApplication.activeRequests > 0 || MergeToolApplication.activeRequests > 0 { return .terminateCancel }
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
        if sender.windows.compactMap({ $0.delegate as? ResetProgressWindowController }).contains(where: { $0.model.busy || $0.model.hasPendingWork || $0.model.fileActionBusy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? ReferenceBrowserWindowController }).contains(where: { $0.model.busy || $0.model.hasChild || $0.model.renameReference != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? BranchTagWindowController }).contains(where: { $0.model.busy || $0.model.chooser.busy || $0.model.chooser.pickerTarget != nil || $0.model.hasPendingNameConflict || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashWindowController }).contains(where: { $0.model.busy || $0.model.preparing || $0.model.hasIdentitySettings || $0.model.confirmingUntracked || $0.model.progress != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashSaveProgressWindowController }).contains(where: { $0.model.busy || $0.model.confirmingCancellation || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if sender.windows.compactMap({ $0.delegate as? StashRestoreWindowController }).contains(where: { $0.model.busy || $0.model.prompt != nil || $0.window?.attachedSheet != nil }) { return .terminateCancel }
        if PatchDocumentSession.activeOperations != 0 { return .terminateCancel }
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
        let presentations = sender.windows.compactMap { $0.delegate as? PresentationComparisonWindowController }.filter { !$0.model.retired }
        let imports = sender.windows.compactMap { $0.delegate as? ImportPatchWindowController }
        let controllers = sender.windows.compactMap { $0.delegate as? TextConflictWindowController }
        let commits = sender.windows.compactMap { $0.delegate as? CommitWindowController }
        let adds = sender.windows.compactMap { $0.delegate as? AddWindowController }
        let lfsLocks = sender.windows.compactMap { $0.delegate as? LFSLocksWindowController }
        let statuses = sender.windows.compactMap { $0.delegate as? StatusWindowController }
        let historyReplays = sender.windows.compactMap { $0.delegate as? RebaseWindowController }
        let referenceBrowsers = sender.windows.compactMap { $0.delegate as? ReferenceBrowserWindowController }
        let blames = sender.windows.compactMap { $0.delegate as? BlameWindowController }
        let logs = sender.windows.compactMap { $0.delegate as? LogWindowController }
        let fetches = sender.windows.compactMap { $0.delegate as? FetchWindowController }
        let pullsInProgress = sender.windows.compactMap { $0.delegate as? PullProgressWindowController }
        let fetchesInProgress = sender.windows.compactMap { $0.delegate as? FetchProgressWindowController }
        let merges = sender.windows.compactMap { $0.delegate as? MergeWindowController }
        let mergesInProgress = sender.windows.compactMap { $0.delegate as? MergeProgressWindowController }
        let referenceCreations = sender.windows.compactMap { $0.delegate as? BranchTagWindowController }
        let clones = sender.windows.compactMap { $0.delegate as? CloneWindowController }
        let clonesInProgress = sender.windows.compactMap { $0.delegate as? CloneProgressWindowController }
        let creations = sender.windows.compactMap { $0.delegate as? CreateRepositoryWindowController }
        let requestPulls = sender.windows.compactMap { $0.delegate as? RequestPullWindowController }
        let mailProgresses = sender.windows.compactMap { $0.delegate as? SendPatchProgressWindowController }
        let formatPatches = sender.windows.compactMap { $0.delegate as? FormatPatchWindowController }
        let exports = sender.windows.compactMap { $0.delegate as? ExportWindowController }
        let exportsInProgress = sender.windows.compactMap { $0.delegate as? ExportProgressWindowController }
        let stashSaves = sender.windows.compactMap { $0.delegate as? StashWindowController }
        let stashProgress = sender.windows.compactMap { $0.delegate as? StashSaveProgressWindowController }
        let stashRestores = sender.windows.compactMap { $0.delegate as? StashRestoreWindowController }
        let switches = sender.windows.compactMap { $0.delegate as? SwitchWindowController }
        let switchProgress = sender.windows.compactMap { $0.delegate as? SwitchProgressWindowController }
        let resets = sender.windows.compactMap { $0.delegate as? ResetWindowController }
        let resetProgress = sender.windows.compactMap { $0.delegate as? ResetProgressWindowController }
        let bisects = sender.windows.compactMap { $0.delegate as? BisectWindowController }
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
        let patchDocuments = sender.windows.compactMap { $0.delegate as? PatchWindowController }.filter { $0.documentSession.enabled }
        let comparisons = sender.windows.compactMap { $0.delegate as? RevisionComparisonWindowController }
        let fileComparisons = sender.windows.compactMap { $0.delegate as? FileComparisonWindowController }
        let progress = sender.windows.compactMap { $0.delegate as? RevertProgressWindowController }
        guard !adds.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !addProgress.contains(where: { $0.model.busy }), !browsers.contains(where: { $0.model.mutating }), !fileComparisons.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }), !submoduleDiffs.contains(where: { $0.model.busy || $0.model.hasUpdateChild }), !comparisons.contains(where: { $0.model.busy || $0.model.patchWindow?.model.busy == true || $0.model.unifiedWindows.values.contains(where: { $0.model.busy }) }), !updates.contains(where: { $0.model.busy }), !progress.contains(where: { $0.model.busy }), !reverts.contains(where: { $0.model.busy }), !commits.contains(where: { $0.model.busy }), repositoryModel?.busy != true, !controllers.contains(where: { $0.model.busy || $0.window?.attachedSheet != nil }) else { return .terminateCancel }
        guard patchDocuments.contains(where: { $0.documentSession.dirty }) || !imports.isEmpty || !commits.isEmpty || controllers.contains(where: { $0.model.hasUnsavedEditorWork }) || fileComparisons.contains(where: { $0.model.dirty }) || reviews.contains(where: { $0.model.dirty }) || presentations.contains(where: { $0.model.revision.isDirty }) else { return finishBackgroundWatches(sender) }
        confirmingQuit = true
        for controller in patchDocuments { controller.model.confirmingQuit = true }
        for controller in lfsLocks { controller.model.confirmingQuit = true }
        for controller in statuses { controller.model.confirmingQuit = true }
        for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = true }
        for controller in referenceBrowsers { controller.model.confirmingQuit = true }
        for controller in blames { controller.model.confirmingQuit = true }
        for controller in logs { controller.model.confirmingQuit = true }
        for controller in fetches { controller.model.confirmingQuit = true }
        for controller in pullsInProgress { controller.model.confirmingQuit = true }
        for controller in fetchesInProgress { controller.model.confirmingQuit = true }
        for controller in merges { controller.model.confirmingQuit = true }
        for controller in mergesInProgress { controller.model.confirmingQuit = true }
        for controller in referenceCreations { controller.model.confirmingQuit = true }
        for controller in clones { controller.model.confirmingQuit = true }
        for controller in clonesInProgress { controller.model.confirmingQuit = true }
        for controller in creations { controller.model.confirmingQuit = true }
        for controller in requestPulls { controller.model.confirmingQuit = true }
        for controller in mailProgresses { controller.model.confirmingQuit = true }
        for controller in formatPatches { controller.model.confirmingQuit = true }
        for controller in exports { controller.model.confirmingQuit = true }
        for controller in exportsInProgress { controller.model.confirmingQuit = true }
        for controller in stashSaves { controller.model.confirmingQuit = true }
        for controller in stashProgress { controller.model.confirmingQuit = true }
        for controller in stashRestores { controller.model.confirmingQuit = true }
        for controller in switches { controller.model.confirmingQuit = true }
        for controller in switchProgress { controller.model.confirmingQuit = true }
        for controller in resets { controller.model.confirmingQuit = true }
        for controller in resetProgress { controller.model.confirmingQuit = true }
        for controller in bisects { controller.model.confirmingQuit = true }
        for controller in imports { controller.setQuitConfirmation(true) }
        for controller in reviews { controller.setQuitConfirmation(true) }
        setTransferQuitConfirmation(sender, true); repositoryModel?.confirmingQuit = true
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
            for controller in patchDocuments where controller.documentSession.dirty {
                if !(await controller.documentSession.resolveChanges()) { allowQuit = false; break }
            }
            for controller in reviews where allowQuit && controller.model.dirty {
                if !(await controller.model.resolveDraft(discardImmediately: false)) { allowQuit = false; break }
            }
            for controller in presentations where allowQuit && controller.model.revision.isDirty {
                if !(await controller.confirmQuit()) {allowQuit=false;break}
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
            for controller in controllers where allowQuit && controller.model.hasUnsavedEditorWork {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.path)” before quitting?"
                if controller.model.hasKeptSourceChanges { alert.informativeText = String(localized:"Save copies of the retained source panes before saving the merged result.") }
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
            if allowQuit { for commit in commits { commit.model.restoreCopies.removeAll() };for presentation in presentations {presentation.discardAfterApprovedQuit()} }
            if allowQuit, startupMergeToolActive { repositoryModel?.closeMergeToolLaunchesAfterApprovedQuit(); return }
            if allowQuit { repositoryModel?.stopMonitoringForTermination();await repositoryModel?.finderWatches?.shutdown();await repositoryModel?.shutdownFinderPublication() }
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
            setTransferQuitConfirmation(sender, false); repositoryModel?.confirmingQuit = false
            for controller in controllers { controller.model.confirmingQuit = false }
            for controller in imports { controller.setQuitConfirmation(false) }
            for controller in reviews { controller.setQuitConfirmation(false) }
            for controller in patchDocuments { controller.model.confirmingQuit = false }
            for controller in lfsLocks { controller.model.confirmingQuit = false }
            for controller in statuses { controller.model.confirmingQuit = false }
            for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = false }
            for controller in referenceBrowsers { controller.model.confirmingQuit = false }
            for controller in blames { controller.model.confirmingQuit = false }
            for controller in logs { controller.model.confirmingQuit = false }
            for controller in fetches { controller.model.confirmingQuit = false }
            for controller in pullsInProgress { controller.model.confirmingQuit = false }
            for controller in fetchesInProgress { controller.model.confirmingQuit = false }
            for controller in merges { controller.model.confirmingQuit = false }
            for controller in mergesInProgress { controller.model.confirmingQuit = false }
            for controller in referenceCreations { controller.model.confirmingQuit = false }
            for controller in clones { controller.model.confirmingQuit = false }
            for controller in clonesInProgress { controller.model.confirmingQuit = false }
            for controller in creations { controller.model.confirmingQuit = false }
            for controller in requestPulls { controller.model.confirmingQuit = false }
            for controller in mailProgresses { controller.model.confirmingQuit = false }
            for controller in formatPatches { controller.model.confirmingQuit = false }
            for controller in exports { controller.model.confirmingQuit = false }
            for controller in exportsInProgress { controller.model.confirmingQuit = false }
            for controller in stashSaves { controller.model.confirmingQuit = false }
            for controller in stashProgress { controller.model.confirmingQuit = false }
            for controller in stashRestores { controller.model.confirmingQuit = false }
            for controller in switches { controller.model.confirmingQuit = false }
            for controller in switchProgress { controller.model.confirmingQuit = false }
            for controller in resets { controller.model.confirmingQuit = false }
            for controller in resetProgress { controller.model.confirmingQuit = false }
            for controller in bisects { controller.model.confirmingQuit = false }
            confirmingQuit = false
            replyToTermination(sender, allowQuit)
        }
        return .terminateLater
    }
    private func finishBackgroundWatches(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if startupMergeToolActive {
            confirmingQuit = true; repositoryModel?.closeMergeToolLaunchesAfterApprovedQuit(); return .terminateLater
        }
        repositoryModel?.stopMonitoringForTermination()
        let manager=repositoryModel?.finderWatches
        let pending=(manager?.pendingOperations ?? 0)+(manager?.backgroundService?.busy == true ? 1 : 0)
        manager?.retire()
        // A live foreground writer must be retired before process exit even if
        // its last scan finished and no watched-root operation remains.
        guard pending>0 || manager?.hasPendingFinderPublication == true || repositoryModel?.hasPendingFinderPublication == true else { return .terminateNow }
        confirmingQuit=true
        let historyReplays = sender.windows.compactMap { $0.delegate as? RebaseWindowController }
        let referenceBrowsers = sender.windows.compactMap { $0.delegate as? ReferenceBrowserWindowController }
        let blames = sender.windows.compactMap { $0.delegate as? BlameWindowController }
        let logs = sender.windows.compactMap { $0.delegate as? LogWindowController }
        let fetches = sender.windows.compactMap { $0.delegate as? FetchWindowController }
        let pullsInProgress = sender.windows.compactMap { $0.delegate as? PullProgressWindowController }
        let fetchesInProgress = sender.windows.compactMap { $0.delegate as? FetchProgressWindowController }
        let merges = sender.windows.compactMap { $0.delegate as? MergeWindowController }
        let mergesInProgress = sender.windows.compactMap { $0.delegate as? MergeProgressWindowController }
        let referenceCreations = sender.windows.compactMap { $0.delegate as? BranchTagWindowController }
        let clones = sender.windows.compactMap { $0.delegate as? CloneWindowController }
        let clonesInProgress = sender.windows.compactMap { $0.delegate as? CloneProgressWindowController }
        let creations = sender.windows.compactMap { $0.delegate as? CreateRepositoryWindowController }
        let requestPulls = sender.windows.compactMap { $0.delegate as? RequestPullWindowController }
        let mailProgresses = sender.windows.compactMap { $0.delegate as? SendPatchProgressWindowController }
        let formatPatches = sender.windows.compactMap { $0.delegate as? FormatPatchWindowController }
        let exports = sender.windows.compactMap { $0.delegate as? ExportWindowController }
        let exportsInProgress = sender.windows.compactMap { $0.delegate as? ExportProgressWindowController }
        let stashSaves = sender.windows.compactMap { $0.delegate as? StashWindowController }
        let stashProgress = sender.windows.compactMap { $0.delegate as? StashSaveProgressWindowController }
        let stashRestores = sender.windows.compactMap { $0.delegate as? StashRestoreWindowController }
        let switches = sender.windows.compactMap { $0.delegate as? SwitchWindowController }
        let switchProgress = sender.windows.compactMap { $0.delegate as? SwitchProgressWindowController }
        let resets = sender.windows.compactMap { $0.delegate as? ResetWindowController }
        let resetProgress = sender.windows.compactMap { $0.delegate as? ResetProgressWindowController }
        let bisects = sender.windows.compactMap { $0.delegate as? BisectWindowController }
        for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = true }
        for controller in referenceBrowsers { controller.model.confirmingQuit = true }
        for controller in blames { controller.model.confirmingQuit = true }
        for controller in logs { controller.model.confirmingQuit = true }
        for controller in fetches { controller.model.confirmingQuit = true }
        for controller in pullsInProgress { controller.model.confirmingQuit = true }
        for controller in fetchesInProgress { controller.model.confirmingQuit = true }
        for controller in merges { controller.model.confirmingQuit = true }
        for controller in mergesInProgress { controller.model.confirmingQuit = true }
        for controller in referenceCreations { controller.model.confirmingQuit = true }
        for controller in clones { controller.model.confirmingQuit = true }
        for controller in clonesInProgress { controller.model.confirmingQuit = true }
        for controller in creations { controller.model.confirmingQuit = true }
        for controller in requestPulls { controller.model.confirmingQuit = true }
        for controller in mailProgresses { controller.model.confirmingQuit = true }
        for controller in formatPatches { controller.model.confirmingQuit = true }
        for controller in exports { controller.model.confirmingQuit = true }
        for controller in exportsInProgress { controller.model.confirmingQuit = true }
        for controller in stashSaves { controller.model.confirmingQuit = true }
        for controller in stashProgress { controller.model.confirmingQuit = true }
        for controller in stashRestores { controller.model.confirmingQuit = true }
        for controller in switches { controller.model.confirmingQuit = true }
        for controller in switchProgress { controller.model.confirmingQuit = true }
        for controller in resets { controller.model.confirmingQuit = true }
        for controller in resetProgress { controller.model.confirmingQuit = true }
        for controller in bisects { controller.model.confirmingQuit = true }
        let submoduleSyncs = sender.windows.compactMap { $0.delegate as? SubmoduleSyncWindowController }
        let submoduleAdds = sender.windows.compactMap { $0.delegate as? SubmoduleAddWindowController }
        let submoduleAddProgress = sender.windows.compactMap { $0.delegate as? SubmoduleAddProgressWindowController }
        let updates = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateWindowController }
        let submoduleDiffs = sender.windows.compactMap { $0.delegate as? SubmoduleDiffWindowController }
        let updateProgress = sender.windows.compactMap { $0.delegate as? SubmoduleUpdateProgressWindowController }
        for controller in submoduleSyncs { controller.model.confirmingQuit = true }
        for controller in submoduleAdds { controller.model.confirmingQuit = true }
        for controller in submoduleAddProgress { controller.model.confirmingQuit = true }
        for controller in updates { controller.model.confirmingQuit = true }
        for controller in submoduleDiffs { controller.model.confirmingQuit = true }
        for controller in updateProgress { controller.model.confirmingQuit = true }
        setTransferQuitConfirmation(sender, true); repositoryModel?.confirmingQuit = true
        Task {
            await manager?.shutdown();await repositoryModel?.shutdownFinderPublication()
            for controller in historyReplays { controller.model.revisionMenuLog.confirmingQuit = false }
            for controller in referenceBrowsers { controller.model.confirmingQuit = false }
            for controller in blames { controller.model.confirmingQuit = false }
            for controller in logs { controller.model.confirmingQuit = false }
            for controller in fetches { controller.model.confirmingQuit = false }
            for controller in pullsInProgress { controller.model.confirmingQuit = false }
            for controller in fetchesInProgress { controller.model.confirmingQuit = false }
            for controller in merges { controller.model.confirmingQuit = false }
            for controller in mergesInProgress { controller.model.confirmingQuit = false }
            for controller in referenceCreations { controller.model.confirmingQuit = false }
            for controller in clones { controller.model.confirmingQuit = false }
            for controller in clonesInProgress { controller.model.confirmingQuit = false }
            for controller in creations { controller.model.confirmingQuit = false }
            for controller in requestPulls { controller.model.confirmingQuit = false }
            for controller in mailProgresses { controller.model.confirmingQuit = false }
            for controller in formatPatches { controller.model.confirmingQuit = false }
            for controller in exports { controller.model.confirmingQuit = false }
            for controller in exportsInProgress { controller.model.confirmingQuit = false }
            for controller in stashSaves { controller.model.confirmingQuit = false }
            for controller in stashProgress { controller.model.confirmingQuit = false }
            for controller in stashRestores { controller.model.confirmingQuit = false }
            for controller in switches { controller.model.confirmingQuit = false }
            for controller in switchProgress { controller.model.confirmingQuit = false }
            for controller in resets { controller.model.confirmingQuit = false }
            for controller in resetProgress { controller.model.confirmingQuit = false }
            for controller in bisects { controller.model.confirmingQuit = false }
            for controller in submoduleSyncs { controller.model.confirmingQuit = false }
            for controller in submoduleAdds { controller.model.confirmingQuit = false }
            for controller in submoduleAddProgress { controller.model.confirmingQuit = false }
            for controller in updates { controller.model.confirmingQuit = false }
            for controller in submoduleDiffs { controller.model.confirmingQuit = false }
            for controller in updateProgress { controller.model.confirmingQuit = false }
            setTransferQuitConfirmation(sender, false); repositoryModel?.confirmingQuit = false
            confirmingQuit=false;replyToTermination(sender,true)
        }
        return .terminateLater
    }

}

/// Services supplies a private selection pasteboard. Capture it before returning
/// to the caller, then use the same owned permission/discovery route as Finder.
@MainActor final class TurtleGitFinderServicesProvider: NSObject {
    enum Failure: LocalizedError {
        case unavailable, busy, command, selection, selectionChanged, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return "TurtleGit cannot accept a Services request while it is closing."
            case .busy: return "TurtleGit is preparing another repository operation. Finish or cancel it, then invoke the service again."
            case .command: return "The requested TurtleGit service is not supported."
            case .selection: return "Select file or folder URLs to use this TurtleGit service."
            case .selectionChanged: return "The selected files changed while TurtleGit was receiving them. Invoke the service again."
            case .tooLarge: return "Select at most 10,000 items with no more than 1 MiB of file URL data."
            }
        }
    }
    private static let maximumItems = FinderServiceCommand.maximumPaths, maximumBytes = FinderServiceCommand.maximumRequestBytes
    private(set) var retired = false
    private var submit: (FinderRequest) throws -> Void
    init(submit: @escaping (FinderRequest) throws -> Void) { self.submit = submit; super.init() }
    func retire() { retired = true; submit = { _ in throw Failure.unavailable } }
    @objc(performFinderAction:userData:error:)
    func performFinderAction(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            guard !retired else { throw Failure.unavailable }
            guard let userData, let command = FinderServiceCommand(rawValue: userData) else { throw Failure.command }
            let paths = try Self.selection(from: pasteboard)
            let alternate = command.capturesAlternateTool ? ComparisonToolInvocation.capture : nil
            let request = try command.request(paths: paths, alternateTool: alternate)
            try submit(request)
        } catch let failure { error.pointee = failure.localizedDescription as NSString }
    }
    static func selection(from pasteboard: NSPasteboard) throws -> [URL] {
        let generation = pasteboard.changeCount, items = pasteboard.pasteboardItems ?? []
        var result: [URL] = [], bytes = 0
        func count(_ raw: String) throws {
            guard raw.utf8.count <= maximumBytes - bytes else { throw Failure.tooLarge }
            bytes += raw.utf8.count
        }
        guard items.count <= maximumItems else { throw Failure.tooLarge }
        if items.contains(where: { $0.types.contains(.fileURL) }) {
            // Never silently narrow a heterogeneous selection to the URLs that
            // readObjects(fileURLsOnly:) happens to understand.
            for item in items {
                guard item.types.contains(.fileURL), let raw = item.string(forType: .fileURL) else { throw Failure.selection }
                try count(raw)
                guard let url = URL(string: raw), url.isFileURL else { throw Failure.selection }
                result.append(url)
            }
        } else {
            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            guard items.count <= 1 else { throw Failure.selection }
            guard let paths = pasteboard.propertyList(forType: filenames) as? [String], !paths.isEmpty else { throw Failure.selection }
            guard paths.count <= maximumItems else { throw Failure.tooLarge }
            for path in paths {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure.selection }
                try count(path); result.append(FileTransferPaths.fileURL(path))
            }
        }
        guard !result.isEmpty else { throw Failure.selection }
        guard generation == pasteboard.changeCount else { throw Failure.selectionChanged }
        return result
    }
}
