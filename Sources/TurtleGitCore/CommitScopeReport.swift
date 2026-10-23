// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts CommitDlg::OnBnClickedWholeProject and HandleMenuItemClick.
import Foundation

public enum CommitScopePreference {
    public static func key(root:URL)->String {"Commit.ShowWholeProject."+FileTransferPaths.lexicalPath(root.path)}
}

public enum CommitFileListReport {
    /// CTGitPath::GetActionName priority; unversioned report rows are Added.
    public static func actionLabel(_ entry:StatusEntry,statistics:CommitFile?=nil)->String {
        let action=statistics?.action.first ?? entry.index
        if entry.state == .conflicted {return "Conflict"}
        if entry.state == .untracked || action == "A" || entry.worktree == "A" {return "Added"}
        if entry.worktree == "D" {return "Missing"}
        if action == "D" {return "Deleted"}
        if [action,entry.worktree].contains(where:{$0 == "M" || $0 == "T"}) {return "Modified"}
        if action == "R" || entry.worktree == "R" {return "Rename"}
        if action == "C" || entry.worktree == "C" {return "Copy"}
        if entry.state == .ignored {return "Ignored"}
        return "Unknown"
    }
    public static func displayedPath(_ entry:StatusEntry,statistics:CommitFile?=nil,abbreviateRenames:Bool)->String {
        if entry.originalPath != nil {return StatusListClipboard.displayedPath(entry,abbreviate:abbreviateRenames)}
        if let statistics,statistics.oldPath != nil,(statistics.action.hasPrefix("R") || statistics.action.hasPrefix("C")) {
            return StatusListClipboard.displayedPath(statistics,abbreviate:abbreviateRenames)
        }
        return entry.path
    }
    /// The caller supplies the same grouped/sorted file order displayed by the
    /// list; LF is the native message-editor ending. Padding counts UTF-16 units.
    public static func text(entries:[StatusEntry],checked:GitPathSet,statistics:GitPathMap<CommitFile> = [:],abbreviateRenames:Bool=false,label:(String)->String={$0})->String {
        entries.filter{checked.contains($0.path)}.map {entry in
            let caption=label(actionLabel(entry,statistics:statistics[entry.path])),padding=String(repeating:" ",count:max(0,10-caption.utf16.count))
            return caption+padding+" "+displayedPath(entry,statistics:statistics[entry.path],abbreviateRenames:abbreviateRenames)+"\n"
        }.joined()
    }
}
extension GitRepository {
    /// Explicit macOS adaptation of the declared legacy project policy. The
    /// pinned dialog computes langID but does not apply it to GetActionName.
    public func commitFileListReportInEnglish(cancellation:OperationCancellation?=nil)throws->Bool {
        let values=try projectConfiguration(pattern:"^tsvn[.]logfilelistenglish$",cancellation:cancellation)
        guard let raw=values["tsvn.logfilelistenglish"] else{return true}
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if ["true","yes","on",""].contains(value) {return true}
        if ["false","no","off"].contains(value) {return false}
        if let number=Int64(value) {return number != 0}
        throw GitConfigurationFailure.invalidValue
    }
}
