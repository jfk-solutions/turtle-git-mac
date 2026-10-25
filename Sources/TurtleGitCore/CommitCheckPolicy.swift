// Source: CommitDlg::OnCheck/UpdateCheckLinks, GitStatusListCtrl::Check/AddEntry.
// GPL-2.0-or-later; Copyright (C) 2009-2026 TortoiseGit.
import Foundation

public enum CommitCheckCategory:String,CaseIterable,Sendable {
    case all,none,unversioned,versioned,added,deleted,modified,files,submodules
}
/// Check-link masks differ from the single status caption and from shown counts.
/// In particular Copy belongs to Added; a pure Rename enables Modified but does
/// not match its MODIFIED-only mask in the pinned source.
public enum CommitCheckPolicy {
    private struct Actions:OptionSet {
        let rawValue:Int
        static let modified=Self(rawValue:1),renamed=Self(rawValue:2),added=Self(rawValue:4),deleted=Self(rawValue:8),unmerged=Self(rawValue:16),copy=Self(rawValue:32),unversioned=Self(rawValue:64),ignored=Self(rawValue:128)
    }
    private static func actions(_ entry:StatusEntry)->Actions {
        if entry.index == "?" {return .unversioned}
        if entry.index == "!" {return .ignored}
        var result=Actions()
        for code in [entry.index,entry.worktree] {
            switch code {case "M","T":result.insert(.modified);case "R":result.insert(.renamed);case "A":result.insert(.added);case "D","K":result.insert(.deleted);case "U":result.insert(.unmerged);case "C":result.insert(.copy);default:break}
        }
        if entry.state == .conflicted {result.insert(.unmerged)}
        // ParseRawDiff(mergeReplacedStatus=true) retains R over an A/D companion.
        if result.contains(.renamed) {result.subtract([.added,.deleted])}
        return result
    }
    public static func matches(_ category:CommitCheckCategory,entry:StatusEntry,submodules:GitPathSet)->Bool {
        let flags=actions(entry)
        switch category {
        case .all,.none:return true
        case .unversioned:return flags.contains(.unversioned)
        case .versioned:return !flags.intersection([.modified,.renamed,.added,.deleted,.unmerged,.copy,.ignored]).isEmpty
        case .added:return !flags.intersection([.added,.copy]).isEmpty
        case .deleted:return flags.contains(.deleted)
        case .modified:return flags.contains(.modified)
        case .files:return !submodules.contains(entry.path)
        case .submodules:return submodules.contains(entry.path)
        }
    }
    public static func isAvailable(_ category:CommitCheckCategory,entries:[StatusEntry],submodules:GitPathSet)->Bool {
        if category == .all || category == .none {return true}
        if category == .files {return entries.contains{!submodules.contains($0.path)}}
        if category == .submodules {return entries.contains{submodules.contains($0.path)}}
        var unversioned=0,added=0,deleted=0,modified=0
        for entry in entries {
            let flags=actions(entry)
            if flags == .added || flags == .copy {added+=1}
            else if flags == .deleted {deleted+=1}
            else if flags == .renamed || flags == .modified {modified+=1}
            else if flags != .unmerged && flags != [.unmerged,.added] && flags != [.unmerged,.modified] {unversioned+=1}
        }
        switch category {case .unversioned:return unversioned>0;case .versioned:return entries.count>unversioned;case .added:return added>0;case .deleted:return deleted>0;case .modified:return modified>0;default:return false}
    }
    public static func paths(_ category:CommitCheckCategory,entries:[StatusEntry],submodules:GitPathSet,checking:Bool,doNotAutoselectSubmodules:Bool)->GitPathSet {
        GitPathSet(entries.filter {entry in
            matches(category,entry:entry,submodules:submodules) && (!checking || !doNotAutoselectSubmodules || [CommitCheckCategory.all,.none,.submodules].contains(category) || !submodules.contains(entry.path))
        }.map(\.id))
    }
}
