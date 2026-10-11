import AppKit
import TurtleGitCore

/// The source error/notification aliases use native macOS system sounds.
/// Disabled in headless receivers unless explicitly enabled by the application entry point.
@MainActor enum OperationSounds {
    static var enabled = false
    static func report(failed: Bool, preferences: UserDefaults) {
        guard enabled, !preferences.bool(forKey: "NoSounds") else { return }
        NSSound(named: NSSound.Name(failed ? "Basso" : "Pop"))?.play()
    }
}

/// Enabled by the application entry point; headless receivers must opt in with a private store.
@MainActor enum ProgressActionLog {
    private final class Recorded { weak var owner: AnyObject?; init(_ owner: AnyObject) { self.owner = owner } }
    private static var recorded: [ObjectIdentifier: Recorded] = [:]
    private static var store: ActionLogStore?
    private static var preferences = UserDefaults.standard
    static func install(store: ActionLogStore = ActionLogStore(), preferences: UserDefaults = .standard) {
        self.store = store; self.preferences = preferences; recorded.removeAll()
    }
    static func record(owner: AnyObject, repository: URL, output: String, cancelled: Bool, failed: Bool = false, notify: Bool = false) {
        guard let store else { return }
        recorded = recorded.filter { $0.value.owner != nil }
        let key = ObjectIdentifier(owner); guard recorded[key] == nil else { return }
        recorded[key] = Recorded(owner)
        if notify { OperationSounds.report(failed: failed || cancelled, preferences: preferences) }
        // A log write failure must never change the Git operation's outcome.
        try? store.append(repository: repository, output: output, cancelled: cancelled,
                          maximumLines: ActionLogStore.maximumLines(preferences: preferences))
    }
    static func nextAttempt(_ model: any ActionLogProgress, savePrevious: Bool = true) {
        if savePrevious { model.saveActionLog() }; recorded.removeValue(forKey: ObjectIdentifier(model))
    }
}
@MainActor protocol ActionLogProgress: AnyObject {
    var actionLogRepository: URL { get }
    var busy: Bool { get }
    var actionLogFailed: Bool { get }
    var output: String { get }
    var actionLogCancelled: Bool { get }
    var actionLogEligible: Bool { get }
}
extension ActionLogProgress {
    var actionLogEligible: Bool { true }
    var actionLogFailed: Bool { false }
    func saveActionLog() { guard actionLogEligible else { return }; ProgressActionLog.record(owner: self, repository: actionLogRepository, output: output, cancelled: actionLogCancelled, failed: actionLogFailed, notify: !busy) }
}
extension CloneProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { destination }; var actionLogCancelled: Bool { cancelled } }
extension FetchProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension PullProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension MergeProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension MergeAbortWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogEligible: Bool { showingProgress || !output.isEmpty }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension CommitProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension SwitchProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension ResetProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension CleanProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { failed }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelRequested } }
extension ExportProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension StashSaveProgressWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }
extension FormatPatchWindowModel: ActionLogProgress { var actionLogFailed: Bool { !success }; var actionLogRepository: URL { repository.root }; var actionLogCancelled: Bool { cancelled } }

extension SendPatchProgressModel { var actionLogFailed: Bool { !success } }

extension SubmoduleUpdateProgressWindowModel { var actionLogFailed: Bool { !success } }

extension SubmoduleSyncWindowModel { var actionLogFailed: Bool { !success } }

extension SubmoduleAddProgressWindowModel { var actionLogFailed: Bool { !success } }
