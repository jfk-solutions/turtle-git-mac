// Adapts Settings/SetSavedDataPage.cpp (GPL-2.0-or-later; see NOTICE).
import Foundation

public enum SavedDataCategory: CaseIterable, Sendable {
    case urlHistory, messageHistory, dialogGeometry, storedDecisions
    public var title: String {
        switch self { case .urlHistory: return "URL history"; case .messageHistory: return "Log messages (Input dialog)"; case .dialogGeometry: return "Dialog sizes and positions"; case .storedDecisions: return "Stored decisions" }
    }
}
public struct SavedDataSummary: Equatable, Sendable {
    public let entries: Int
    public let histories: Int
    public var available: Bool { histories > 0 }
}
/// Explicit namespaces prevent history clearing from becoming a preference reset.
public struct SavedDataStore {
    private let preferences: UserDefaults
    public init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    public static let sourceDecisionKeys = [
        "OldMsysgitVersionWarning", "OpenRebaseRemoteBranchEqualsHEAD", "OpenRebaseRemoteBranchUnchanged",
        "OpenRebaseRemoteBranchFastForwards", "DaemonNoSecurityWarning", "NothingToCommitShowUnversioned",
        "NoJumpNotFoundWarning", "HintHierarchicalConfig", "HintStagingMode", "TagOptNoTagsWarning",
        "NoStashIncludeUntrackedWarning", "CommitMergeHint", "AskSetTrackedBranch", "StashPopShowChanges",
        "StashPopShowConflictChanges", "CommitWarnOnUnresolved", "CommitAskBeforeCancel", "PushAllBranches",
        "CommitMessageContainsConflictHint", "MergeConflictsNeedsCommit", "CommitMessageTemplateNotEdited"
    ]
    public static let nativeDecisionKeys = [
        "Commit.SkipCancelConfirmation", "Commit.TemplateNotEdited.Proceed",
        "StashPop.ShowChanges", "StashPop.ShowConflictChanges", "DeleteFileWhenEmpty"
    ]
    private func matches(_ key: String, category: SavedDataCategory) -> Bool {
        switch category {
        case .urlHistory:
            return ["Clone.URLHistory", "FormatPatchDirectories", "History.PullURLS", "History.RequestPull.url"].contains(key)
                || key.hasPrefix("History.PushURLS.")
        case .messageHistory: return key.hasPrefix("Commit.MessageHistory.")
        case .dialogGeometry: return WindowGeometryStore.owns(key)
        case .storedDecisions: return Self.sourceDecisionKeys.contains(key) || Self.nativeDecisionKeys.contains(key)
        }
    }
    public func summary(_ category: SavedDataCategory) -> SavedDataSummary {
        let values = preferences.dictionaryRepresentation().filter { matches($0.key, category: category) }
        let entries = values.values.reduce(0) { $0 + (($1 as? [String])?.count ?? 1) }
        return SavedDataSummary(entries: entries, histories: values.count)
    }
    public func clear(_ category: SavedDataCategory) {
        for key in preferences.dictionaryRepresentation().keys where matches(key, category: category) {
            preferences.removeObject(forKey: key)
        }
    }
}
