// SPDX-License-Identifier: GPL-2.0-or-later
// CommitDlg::PrepareIndexForCommitWithoutStagingSupport and post-progress restoration.
import Foundation
import Darwin

public struct CommitCheckboxIndexPolicy: Sendable, Equatable {
    public let paths:GitPathSet
    public let readdUnchecked:Bool
    public init(paths:some Sequence<String>,readdUnchecked:Bool=true) {self.paths=GitPathSet(paths);self.readdUnchecked=readdUnchecked}
    public init(paths:some Sequence<String>,defaults:UserDefaults) {
        self.init(paths:paths,readdUnchecked:((defaults.object(forKey:"ReaddUnselectedAddedFilesAfterCommit") as? NSNumber)?.uint32Value ?? 1)==1)
    }
}
extension GitRepository {
    func withCommitCheckboxIndex(_ policy:CommitCheckboxIndexPolicy,changes:[StatusEntry],checked:GitPathSet,parentMode:Bool,cancellation:OperationCancellation?,onOutput:(@Sendable(GitOutputChunk)->Void)?,expectedIndex:CommitIndexSnapshot?,fileModes:GitPathMap<String>,commit:(String,Data?,() -> Void) throws -> String) throws -> String {
        try cancellation?.check()
        let base:String
        if parentMode {base=try commitComparisonBase(amendToParent:true,cancellation:cancellation)}
        else {
            let head=try run(["rev-parse","--verify","--quiet","HEAD^{commit}"],successfulExitCodes:0...1,cancellation:cancellation)
            base=head.exitCode==0 ? head.text.trimmingCharacters(in:.newlines) : try run(["mktree"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        }
        let restoration=try prepareCLICommitIndex(changes:changes,checked:checked,policy:policy,base:base,cancellation:cancellation,onOutput:onOutput,expectedIndex:expectedIndex,fileModes:fileModes)
        var attempted=false
        let result:Result<String,Error>
        do {result = .success(try commit(base,restoration.index,{attempted=true}))}catch{result = .failure(error)}
        var warning=""
        if attempted,policy.readdUnchecked {
            do {
                // Only Git progress invokes the source post-progress queues.
                // A preparation/branch failure does not perform restoration.
                let cleanup=OperationCancellation()
                if !restoration.readd.isEmpty {_ = try run(["add","--ignore-errors","-f","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cleanup,input:literalPathPacket(restoration.readd.sorted()),onOutput:onOutput)}
                if !restoration.remove.isEmpty {_ = try run(["rm","--cached","--ignore-unmatch","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cleanup,input:literalPathPacket(restoration.remove.sorted()),onOutput:onOutput)}
            }catch{
                warning="\nwarning: Restoring unchecked additions/deletions failed. Refresh the file list and inspect the index before another commit.\n"+error.localizedDescription+"\n"
                onOutput?(.init(stream:.stderr,data:Data(warning.utf8)))
            }
        }
        switch result {case .success(let output):return output+warning;case .failure(let error):throw error}
    }
}

struct CommitConflictIndexActions {
    var added=false
    var deleted=false
    var modified=false
}
extension GitRepository {
    /// Source GetCommitDiffList merges cached/worktree raw action flags. Porcelain
    /// AA/AU/UA codes alone do not imply LOGACTIONS_ADDED or a restoration queue.
    func commitConflictIndexActions(_ entries:[StatusEntry],base:String,cancellation:OperationCancellation?) throws -> GitPathMap<CommitConflictIndexActions> {
        let conflicts=GitPathSet(entries.filter{$0.state == .conflicted}.map(\.path))
        guard !conflicts.isEmpty else{return [:]}
        var result=GitPathMap<CommitConflictIndexActions>()
        for cached in [true,false] {
            let records=try run(["diff-index"]+(cached ? ["--cached"]:[])+["--raw","--no-renames","-z",base,"--"],cancellation:cancellation).stdout.split(separator:0)
            var index=0
            while index<records.count {
                let header=records[index];index += 1
                guard header.first == 58,index<records.count else{continue}
                let path=String(decoding:records[index],as:UTF8.self);index += 1
                guard conflicts.contains(path),let action=header.split(separator:32).last?.first else{continue}
                var value=result[path] ?? CommitConflictIndexActions()
                value.added = value.added || action == 65
                value.deleted = value.deleted || action == 68
                value.modified = value.modified || action == 77
                result[path]=value
            }
        }
        return result
    }
}

struct CommitIndexSnapshot:Sendable {
    let location:URL
    let bytes:Data?
}
struct CommitCheckboxRestoration {
    var index:Data?
    var readd=GitPathSet()
    var remove=GitPathSet()
}
extension GitRepository {
    func captureCommitIndex(cancellation:OperationCancellation?) throws -> CommitIndexSnapshot {
        var bytes=try run(["rev-parse","--git-path","index"],cancellation:cancellation).stdout
        if bytes.last == 10 {bytes.removeLast()}
        let path=String(decoding:bytes,as:UTF8.self),url=path.hasPrefix("/") ? URL(fileURLWithPath:path):root.appendingPathComponent(path)
        return try CommitIndexSnapshot(location:url,bytes:commitIndexBytes(at:url))
    }
    func commitIndexChanged() -> GitFailure {
        GitFailure(arguments:["commit"],code:1,message:"The Git index changed during commit preparation. Refresh the file list before committing.")
    }
    func commitIndexBytes(at url:URL) throws -> Data? {
        var info=stat()
        if lstat(url.path,&info) != 0 {
            if errno == ENOENT {return nil}
            throw GitFailure(arguments:["commit"],code:1,message:"Could not inspect the Git index: "+String(cString:strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {throw commitIndexChanged()}
        return try Data(contentsOf:url)
    }
    /// Preserve the six source CMassiveGitTask boundaries, while copying exact
    /// prepared stage-zero identities into the later selected commit tree.
    /// Each finished Git command's index effects survive a later failure/cancel;
    /// a clean filter is never run a second time merely to publish those blobs.
    @discardableResult
    func prepareCLICommitIndex(changes:[StatusEntry],checked:GitPathSet,policy:CommitCheckboxIndexPolicy?,base:String,cancellation:OperationCancellation?,onOutput:(@Sendable(GitOutputChunk)->Void)?,expectedIndex:CommitIndexSnapshot?=nil,fileModes:GitPathMap<String>=[:]) throws -> CommitCheckboxRestoration {
        try cancellation?.check()
        let conflictActions=try commitConflictIndexActions(changes,base:base,cancellation:cancellation)
        var add=GitPathSet(),forceRemove=GitPathSet(),update=GitPathSet(),renameRemove=GitPathSet(),uncheckedRemove=GitPathSet(),reset=GitPathSet(),restoration=CommitCheckboxRestoration()
        for entry in changes {
            let renamed=entry.index == "R" || entry.worktree == "R"
            let added=entry.state == .conflicted ? conflictActions[entry.path]?.added == true : entry.index == "A" || entry.worktree == "A"
            let deleted=entry.state == .conflicted ? conflictActions[entry.path]?.deleted == true : entry.state == .deleted
            if checked.contains(entry.path) {
                let location=try restoreLocation(entry.path);var info=stat()
                let directory=lstat(location.path,&info)==0 && info.st_mode & S_IFMT == S_IFDIR
                if entry.state == .untracked || directory && !deleted {add.insert(entry.path)}
                else if deleted {forceRemove.insert(entry.path)}
                else {update.insert(entry.path)}
                if renamed,let old=entry.originalPath {renameRemove.insert(old)}
            }else if policy?.paths.contains(entry.path)==true {
                if added || renamed {
                    uncheckedRemove.insert(entry.path);restoration.readd.insert(entry.path)
                    if renamed,let old=entry.originalPath {reset.insert(old);restoration.remove.insert(old)}
                }else if ![.untracked,.ignored].contains(entry.state) {
                    reset.insert(entry.path)
                    let stagedDeletion=entry.state == .conflicted ? conflictActions[entry.path]?.deleted == true : entry.index == "D"
                    if stagedDeletion {restoration.remove.insert(entry.path)}
                }
            }
        }
        let operations:[([String],GitPathSet)]=[
            (["add","-f","--pathspec-from-file=-","--pathspec-file-nul"],add),
            (["update-index","--force-remove","-z","--stdin"],forceRemove),
            (["update-index","-z","--stdin"],update),
            (["rm","--ignore-unmatch","--pathspec-from-file=-","--pathspec-file-nul"],renameRemove),
            (["rm","-f","--cached","--pathspec-from-file=-","--pathspec-file-nul"],uncheckedRemove),
            (["reset",base,"--pathspec-from-file=-","--pathspec-file-nul"],reset)
        ]
        guard operations.contains(where:{!$0.1.isEmpty}) else {
            if let expectedIndex,try commitIndexBytes(at:expectedIndex.location) != expectedIndex.bytes {throw commitIndexChanged()}
            restoration.index=try captureCommitIndex(cancellation:cancellation).bytes
            return restoration
        }
        var indexPath=try run(["rev-parse","--git-path","index"],cancellation:cancellation).stdout
        if indexPath.last == 10 {indexPath.removeLast()}
        let path=String(decoding:indexPath,as:UTF8.self),realIndex=path.hasPrefix("/") ? URL(fileURLWithPath:path):root.appendingPathComponent(path)
        let lock=URL(fileURLWithPath:realIndex.path+".lock"),descriptor=open(lock.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor>=0 else {throw GitFailure(arguments:["commit"],code:1,message:"Could not lock the Git index: "+String(cString:strerror(errno)))}
        defer {
            var owned=stat(),current=stat()
            if fstat(descriptor,&owned)==0,lstat(lock.path,&current)==0,owned.st_dev==current.st_dev,owned.st_ino==current.st_ino {try? FileManager.default.removeItem(at:lock)}
            Darwin.close(descriptor)
        }
        var expected=try commitIndexBytes(at:realIndex)
        if let expectedIndex,expectedIndex.bytes != expected {throw commitIndexChanged()}
        let permissions=(try? FileManager.default.attributesOfItem(atPath:realIndex.path))?[.posixPermissions]
        let directory=try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-commit-cli-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        let privateIndex=directory.appendingPathComponent("index"),environment=["GIT_INDEX_FILE":privateIndex.path]
        if let expected {try expected.write(to:privateIndex);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:privateIndex.path)}
        else {_ = try run(["read-tree","--empty"],environmentOverrides:environment,cancellation:cancellation)}
        // A copied split-index must not retain a dependency on a shared index
        // written inside the owned temporary directory and removed on return.
        _ = try run(["-c","core.splitIndex=false","update-index","--no-split-index"],environmentOverrides:environment,cancellation:cancellation)
        func publishCompletedCommand(previous:Data) throws {
            let bytes=try Data(contentsOf:privateIndex)
            guard try commitIndexBytes(at:realIndex)==expected else{throw commitIndexChanged()}
            guard bytes != previous else{return}
            let temporary=realIndex.deletingLastPathComponent().appendingPathComponent(".turtlegit-index-"+UUID().uuidString)
            let output=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard output>=0 else {throw GitFailure(arguments:["commit"],code:1,message:"Could not publish the prepared Git index.")}
            let handle=FileHandle(fileDescriptor:output,closeOnDealloc:true)
            defer{try? handle.close();try? FileManager.default.removeItem(at:temporary)}
            try handle.write(contentsOf:bytes);try handle.close()
            if let permissions {try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:temporary.path)}
            guard try commitIndexBytes(at:realIndex)==expected else{throw commitIndexChanged()}
            guard Darwin.rename(temporary.path,realIndex.path)==0 else {throw GitFailure(arguments:["commit"],code:1,message:"Could not replace the Git index: "+String(cString:strerror(errno)))}
            expected=bytes
        }
        for (arguments,paths) in operations where !paths.isEmpty {
            try cancellation?.check()
            guard try commitIndexBytes(at:realIndex)==expected else{throw commitIndexChanged()}
            let previous=try Data(contentsOf:privateIndex)
            let result:Result<Void,Error>
            do {_ = try run(["-c","core.splitIndex=false"]+arguments,environmentOverrides:environment,cancellation:cancellation,input:literalPathPacket(paths.sorted()),onOutput:onOutput);result = .success(())}
            catch{result = .failure(error)}
            // Preserve explicit macOS executable/symlink index overrides after
            // a successful (or partially written) source checked Add/Update
            // command. This copies blob identities without a second clean pass.
            let modeResult:Result<Void,Error>
            do {
            if !fileModes.isEmpty,(arguments.first == "add" || arguments == ["update-index","-z","--stdin"]),try Data(contentsOf:privateIndex) != previous {
                let candidates=GitPathSet(fileModes.keys).intersection(paths)
                let records=try commitIndexRecords(paths:candidates,environment:environment,cancellation:nil)
                let present=GitPathSet(records.split(separator:0).compactMap {record -> String? in
                    guard let tab=record.firstIndex(of:9) else{return nil}
                    return String(decoding:record[record.index(after:tab)...],as:UTF8.self)
                })
                var modes=GitPathMap<String>()
                for path in present {modes[path]=fileModes[path]}
                try applySelectedFileModes(modes,environment:environment,cancellation:OperationCancellation())
                _ = try run(["-c","core.splitIndex=false","update-index","--no-split-index"],environmentOverrides:environment,cancellation:OperationCancellation())
            }
            modeResult = .success(())
            }catch{modeResult = .failure(error)}
            // Git itself decides whether an unsuccessful command wrote its index.
            // Publish that completed receipt even after token cancellation or
            // a failed mode correction, before surfacing the command error.
            try publishCompletedCommand(previous:previous)
            try result.get();try modeResult.get()
        }
        guard try commitIndexBytes(at:realIndex)==expected else{throw commitIndexChanged()}
        restoration.index=try Data(contentsOf:privateIndex)
        return restoration
    }
}
