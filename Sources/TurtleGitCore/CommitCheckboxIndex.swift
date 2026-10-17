// SPDX-License-Identifier: GPL-2.0-or-later
// CommitDlg::PrepareIndexForCommitWithoutStagingSupport and post-progress restoration.
import Foundation

public struct CommitCheckboxIndexPolicy: Sendable, Equatable {
    public let paths:GitPathSet
    public let readdUnchecked:Bool
    public init(paths:some Sequence<String>,readdUnchecked:Bool=true) {self.paths=GitPathSet(paths);self.readdUnchecked=readdUnchecked}
    public init(paths:some Sequence<String>,defaults:UserDefaults) {
        self.init(paths:paths,readdUnchecked:((defaults.object(forKey:"ReaddUnselectedAddedFilesAfterCommit") as? NSNumber)?.uint32Value ?? 1)==1)
    }
}
extension GitRepository {
    func withCommitCheckboxIndex(_ policy:CommitCheckboxIndexPolicy,changes:[StatusEntry],checked:GitPathSet,parentMode:Bool,cancellation:OperationCancellation?,onOutput:(@Sendable(GitOutputChunk)->Void)?,commit:(String) throws -> String) throws -> String {
        try cancellation?.check()
        // The explicit Ignore-unresolved workflow retains its unmerged stages.
        // Only actual ordinary rows in this dialog's captured scope participate.
        let unchecked=changes.filter{policy.paths.contains($0.path) && !checked.contains($0.path) && ![.untracked,.ignored,.conflicted].contains($0.state)}
        let base:String
        if parentMode {base=try commitComparisonBase(amendToParent:true,cancellation:cancellation)}
        else {
            let head=try run(["rev-parse","--verify","--quiet","HEAD^{commit}"],successfulExitCodes:0...1,cancellation:cancellation)
            base=head.exitCode==0 ? head.text.trimmingCharacters(in:.newlines) : try run(["mktree"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        }
        guard !unchecked.isEmpty else{return try commit(base)}
        let baseline=GitPathSet(try run(["ls-tree","-r","--name-only","-z",base],cancellation:cancellation).stdout.split(separator:0).map{String(decoding:$0,as:UTF8.self)})
        var reset=GitPathSet(),readd=GitPathSet(),remove=GitPathSet()
        for entry in unchecked {
            reset.insert(entry.path)
            let renamed=entry.index=="R" || entry.worktree=="R"
            if renamed,let old=entry.originalPath {reset.insert(old);remove.insert(old)}
            if entry.index=="A" || entry.worktree=="A" || renamed {readd.insert(entry.path)}
            if entry.index=="D" {remove.insert(entry.path)}
        }
        // Exact NUL path packets preserve leading dashes, newlines and wildcard
        // characters. Neither preparation nor restoration rewrites working files.
        func packet(_ paths:GitPathSet)->Data {Data(paths.sorted().flatMap{Array($0.utf8)+[0]})}
        let restore=reset.intersection(baseline),absent=reset.subtracting(baseline)
        if !restore.isEmpty {_ = try run(["restore","--source="+base,"--staged","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:packet(restore))}
        if !absent.isEmpty {_ = try run(["update-index","--force-remove","-z","--stdin"],cancellation:cancellation,input:packet(absent))}
        func restoreUnchecked() throws {
            guard policy.readdUnchecked else{return}
            // Source restoration follows both success and failed/cancelled Git
            // progress. Do not reuse an already-cancelled commit token here.
            let cleanup=OperationCancellation()
            if !readd.isEmpty {_ = try run(["add","--ignore-errors","-f","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cleanup,input:packet(readd),onOutput:onOutput)}
            if !remove.isEmpty {_ = try run(["rm","--cached","--ignore-unmatch","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cleanup,input:packet(remove),onOutput:onOutput)}
        }
        let result:Result<String,Error>
        do {result = .success(try commit(base))} catch {result = .failure(error)}
        var warning=""
        do {try restoreUnchecked()} catch {
            warning="\nwarning: Restoring unchecked additions/deletions failed. Refresh the file list and inspect the index before another commit.\n"+error.localizedDescription+"\n"
            onOutput?(.init(stream:.stderr,data:Data(warning.utf8)))
        }
        switch result {
        case .success(let output):return output+warning
        case .failure(let error):throw error
        }
    }
}
