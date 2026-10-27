import Foundation
import Darwin

public enum CommitStagingState: Sendable, Equatable {
    case unstaged, partial, staged
}

extension GitRepository {
    /// COMMIT_UPDATE_INDEX is distinct from Add and from staging-area commits.
    /// Build checked blobs once, then copy their index metadata without invoking
    /// a second clean driver through `git add` or `commit --only`.
    func commitLibrarySelection(message: String, checked: [StatusEntry], changes: [StatusEntry], options: CommitOptions, base: String, fileModes: GitPathMap<String>, executor: URL, cancellation: OperationCancellation?, onOutput: (@Sendable (GitOutputChunk) -> Void)?) throws -> String {
        try cancellation?.check()
        var indexBytes = try run(["rev-parse", "--git-path", "index"], cancellation: cancellation).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let realIndex = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: realIndex.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["commit"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? FileManager.default.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let originalIndex=try commitIndexBytes(at:realIndex)
        if let expected=options.expectedIndex,expected.bytes != originalIndex {throw commitIndexChanged()}
        let permissions = (try? FileManager.default.attributesOfItem(atPath: realIndex.path))?[.posixPermissions]
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-commit-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = directory.appendingPathComponent("selected"), reconciled = directory.appendingPathComponent("index")
        let selectionEnvironment = ["GIT_INDEX_FILE": prepared.path], indexEnvironment = ["GIT_INDEX_FILE": reconciled.path]
        if FileManager.default.fileExists(atPath: realIndex.path) { try FileManager.default.copyItem(at: realIndex, to: reconciled) }
        else { _ = try run(["read-tree", "--empty"], environmentOverrides: indexEnvironment, cancellation: cancellation) }
        _ = try run(["read-tree", base], environmentOverrides: selectionEnvironment, cancellation: cancellation)
        var affected = GitPathSet(), operations: [(String, String, String)] = []
        let conflictActions=try commitConflictIndexActions(checked,base:base,cancellation:cancellation)
        for entry in checked {
            _ = try restoreLocation(entry.path)
            affected.insert(entry.path)
            if entry.state == .deleted || entry.index == "D" && entry.hasUnversionedCopy || conflictActions[entry.path]?.deleted == true {
                operations.append(("remove", entry.path, "-"))
            } else {
                operations.append(("add", entry.path, fileModes[entry.path] ?? "normal"))
            }
            if let old = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                _ = try restoreLocation(old); affected.insert(old); operations.append(("remove", old, "-"))
            }
        }
        // Seed exact stage-zero identities before adding current file bytes.
        // This retains canonical Unicode peers on aliasing filesystems.
        let seed = try commitIndexRecords(paths: GitPathSet(checked.filter { $0.state != .deleted && !($0.index == "D" && $0.hasUnversionedCopy) }.map(\.path)), environment: [:], cancellation: cancellation)
        if !seed.isEmpty { _ = try run(["update-index", "-z", "--index-info"], environmentOverrides: selectionEnvironment, cancellation: cancellation, input: seed) }
        try prepareLibraryCommitIndex(operations, environment: selectionEnvironment, executor: executor, cancellation: cancellation)
        try cancellation?.check()

        // Unchecked checkbox rows reset only this reconciliation copy. A failed
        // clean/preparation above has never modified the actual repository index.
        var readd = GitPathSet(), remove = GitPathSet()
        if let policy = options.checkboxIndexPolicy {
            let selected = GitPathSet(checked.map(\.path))
            let unchecked = changes.filter { policy.paths.contains($0.path) && !selected.contains($0.path) && ![.untracked, .ignored].contains($0.state) }
            let conflictActions=try commitConflictIndexActions(unchecked,base:base,cancellation:cancellation)
            let baselinePaths=GitPathSet(try run(["ls-tree","-r","--name-only","-z",base],cancellation:cancellation).stdout.split(separator:0).map{String(decoding:$0,as:UTF8.self)})
            for entry in unchecked where entry.state == .conflicted && !baselinePaths.contains(entry.path) && conflictActions[entry.path]?.added != true {
                throw GitFailure(arguments:["commit"],code:1,message:"Could not reset "+entry.path+" to its old index entry: the path is absent from the comparison tree.")
            }
            var reset = GitPathSet()
            for entry in unchecked {
                reset.insert(entry.path)
                let renamed = entry.index == "R" || entry.worktree == "R"
                if renamed, let old = entry.originalPath { reset.insert(old); remove.insert(old) }
                let added=entry.state == .conflicted ? conflictActions[entry.path]?.added == true : entry.index == "A" || entry.worktree == "A"
                let deleted=entry.state == .conflicted ? conflictActions[entry.path]?.deleted == true : entry.index == "D"
                if added || renamed {readd.insert(entry.path)}
                if deleted {remove.insert(entry.path)}
            }
            if !reset.isEmpty {
                _ = try run(["update-index", "--force-remove", "-z", "--stdin"], environmentOverrides: indexEnvironment, cancellation: cancellation, input: literalPathPacket(reset.sorted()))
                let baseline = try run(["ls-tree", "-r", "--full-tree", "-z", base], cancellation: cancellation).stdout
                var records = Data()
                for record in baseline.split(separator: 0) {
                    guard let tab = record.firstIndex(of: 9) else { continue }
                    let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
                    guard reset.contains(path) else { continue }
                    let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                    guard fields.count == 3 else { continue }
                    records.append(contentsOf: (String(fields[0]) + " " + String(fields[2]) + "\t" + path + "\0").utf8)
                }
                if !records.isEmpty { _ = try run(["update-index", "-z", "--index-info"], environmentOverrides: indexEnvironment, cancellation: cancellation, input: records) }
            }
            if !policy.readdUnchecked { readd = []; remove = [] }
        }
        if !affected.isEmpty {
            _ = try run(["update-index", "--force-remove", "-z", "--stdin"], environmentOverrides: indexEnvironment, cancellation: cancellation, input: literalPathPacket(affected.sorted()))
            let records = try commitIndexRecords(paths: affected, environment: selectionEnvironment, cancellation: cancellation)
            if !records.isEmpty { _ = try run(["update-index", "-z", "--index-info"], environmentOverrides: indexEnvironment, cancellation: cancellation, input: records) }
        }
        // The real index lock remains ours while checkout creates the branch;
        // use the already reconciled private index for its ordinary bookkeeping.
        if let branch = options.newBranch { _ = try run(["checkout", "-b", branch], environmentOverrides: indexEnvironment, cancellation: cancellation) }
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        var arguments = ["commit", "-F", messageFile.url.path]
        if options.amend { arguments.append("--amend") }
        if options.messageOnly { arguments.append("--allow-empty") }
        if options.signOff { arguments.append("--signoff") }
        if let author = options.author, !author.isEmpty { arguments.append("--author=" + author) }
        if options.resetAuthorDate { arguments.append("--date=now") }
        else if let date = options.authorDate { arguments.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        let result: Result<String, Error>
        do { result = .success(try run(arguments, environmentOverrides: selectionEnvironment, cancellation: cancellation, onOutput: onOutput).text) }
        catch { result = .failure(error) }
        // Source restores queued checkbox additions/deletions after failed as
        // well as successful Git progress, with a fresh cancellation lifetime.
        var warning = ""
        do {
            let restoration = readd.sorted().map { ("add", $0, "normal") } + remove.sorted().map { ("remove", $0, "-") }
            try prepareLibraryCommitIndex(restoration, environment: indexEnvironment, executor: executor, cancellation: OperationCancellation())
        } catch {
            warning = "\nwarning: Restoring unchecked additions/deletions failed. Refresh the file list and inspect the index before another commit.\n" + error.localizedDescription + "\n"
            onOutput?(.init(stream: .stderr, data: Data(warning.utf8)))
        }
        guard try commitIndexBytes(at:realIndex)==originalIndex else {throw commitIndexChanged()}
        try handle.write(contentsOf: Data(contentsOf: reconciled)); try handle.close()
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
        guard Darwin.rename(lock.path, realIndex.path) == 0 else { throw GitFailure(arguments: ["commit"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno))) }
        ownsLock = false
        switch result { case .success(let output): return output + warning; case .failure(let error): throw error }
    }

    func commitIndexRecords(paths: GitPathSet, environment: [String: String], cancellation: OperationCancellation?) throws -> Data {
        var result = Data()
        let ordered = paths.sorted()
        for offset in stride(from: 0, to: ordered.count, by: 64) {
            let batch = Array(ordered[offset..<min(offset + 64, ordered.count)])
            let bytes = try run(["-c", "core.precomposeunicode=false", "ls-files", "--stage", "-z", "--"] + batch, environmentOverrides: environment, cancellation: cancellation).stdout
            for record in bytes.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9), paths.contains(String(decoding: record[record.index(after: tab)...], as: UTF8.self)) else { continue }
                let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard fields.count == 3, fields[2] == "0" else { continue }
                result.append(contentsOf: record); result.append(0)
            }
        }
        return result
    }

    private func prepareLibraryCommitIndex(_ operations: [(String, String, String)], environment: [String: String], executor: URL, cancellation: OperationCancellation?) throws {
        guard !operations.isEmpty else { try cancellation?.check(); return }
        _ = try run(["update-index", "--no-split-index"], environmentOverrides: environment, cancellation: cancellation)
        let index = environment["GIT_INDEX_FILE"]!
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index)
        var packet = Data()
        for (operation, path, mode) in operations { for value in [operation, path, mode] { packet.append(contentsOf: value.utf8); packet.append(0) } }
        _ = try run(["-c", "core.precomposeunicode=false", "turtlegit-prepare-index", "--turtlegit-index=" + index, "--stdin"], cancellation: cancellation, input: packet, executorOverride: executor)
    }

    public func commitComparisonBase(amendToParent: Bool, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard amendToParent else { return "HEAD" }
        _ = try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation)
        if let parent = try? run(["rev-parse", "--verify", "HEAD^1^{commit}"], cancellation: cancellation).text {
            return parent.trimmingCharacters(in: .newlines)
        }
        // Compute the empty tree in the repository's object format (including SHA-256).
        return try run(["mktree"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
    }

    public func commitDialogStatus(amendToParent: Bool, cancellation: OperationCancellation? = nil, refreshIndex: Bool = true) throws -> [StatusEntry] {
        try cancellation?.check()
        let current=try status(readPolicy:refreshIndex ? .refreshIndex:.automatic,includeIgnored:false,cancellation:cancellation)
        let indexed:[CommitFile],working:[CommitFile]
        if amendToParent {
            let base=try commitComparisonBase(amendToParent:true,cancellation:cancellation)
            indexed=try stagingFiles(staged:true,base:base,cancellation:cancellation)
            working=try workingTreeFiles(amendToParent:true,cancellation:cancellation)
        } else {indexed=[];working=[]}
        return try commitDialogEntries(current:current,amendToParent:amendToParent,indexed:indexed,working:working,cancellation:cancellation)
    }
    /// Shared projection for legacy/preflight readers and a captured display read.
    func commitDialogEntries(current input:[StatusEntry],amendToParent:Bool,indexed:[CommitFile],working:[CommitFile],cancellation:OperationCancellation?)throws->[StatusEntry] {
        var current=input
        // Omitting the ignored inventory must not hide a staged deletion's
        // recreated local copy. Porcelain would otherwise report a second !!
        // record and the parser would merge that fact into this versioned row.
        // Inspect only existing deletion candidates, without walking ignored trees.
        for index in current.indices where current[index].index == "D" && !current[index].hasUnversionedCopy {
            try cancellation?.check()
            guard let location=try? restoreLocation(current[index].path) else {continue}
            var attributes=stat()
            if lstat(location.path,&attributes)==0 {
                let type=attributes.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) {current[index].hasUnversionedCopy=true}
            }
        }
        try cancellation?.check()
        guard amendToParent else { return current }
        let indexedByPath = GitPathMap(indexed.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let currentByPath = GitPathMap(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var result = current.filter { $0.state == .untracked || $0.state == .ignored || $0.state == .conflicted }
        for file in working {
            if currentByPath[file.path]?.state == .conflicted { continue }
            let staged = indexedByPath[file.path]
            let old = staged?.oldPath ?? file.oldPath
            var entry = StatusEntry(path: file.path, originalPath: old,
                                      index: staged?.action.first ?? " ",
                                      worktree: currentByPath[file.path]?.worktree ?? " ")
            entry.hasUnversionedCopy = currentByPath[file.path]?.hasUnversionedCopy ?? false
            result.append(entry)
        }
        // Include an index-only change cancelled out by the working tree, so the
        // staging checkbox can still unstage or retain it.
        let paths = Set(result.map { GitReferenceName($0.path) })
        for file in indexed where !paths.contains(GitReferenceName(file.path)) {
            var entry = StatusEntry(path: file.path, originalPath: file.oldPath,
                                      index: file.action.first ?? "M",
                                      worktree: currentByPath[file.path]?.worktree ?? " ")
            entry.hasUnversionedCopy = currentByPath[file.path]?.hasUnversionedCopy ?? false
            result.append(entry)
        }
        return GitPathMap(result.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    /// Read the index independently of rename pairing. Git may choose a
    /// different identical source after staging a deletion; retained Commit rows
    /// must still show that original deletion as staged.
    public func commitStagingStates(for entries: [StatusEntry], base: String? = nil, cancellation: OperationCancellation? = nil) throws -> GitPathMap<CommitStagingState> {
        try cancellation?.check()
        let cached = try run(["diff", "--cached", "--no-renames", "--name-only", "-z"] + (base.map { [$0] } ?? []) + ["--"], cancellation: cancellation)
        let working = try run(["diff", "--no-renames", "--name-only", "-z", "--"], cancellation: cancellation)
        func paths(_ bytes: Data) -> Set<Data> { Set(bytes.split(separator: 0).map { Data($0) }) }
        let stagedPaths = paths(cached.stdout), workingPaths = paths(working.stdout)
        let current=try status(readPolicy:.refreshIndex,includeIgnored:false,cancellation:cancellation)
        let unversioned=Set(current.filter{$0.state == .untracked}.map{Data($0.path.utf8)})
        let conflicts=GitPathSet(current.filter{$0.state == .conflicted}.map(\.path))
        try cancellation?.check()
        return GitPathMap(entries.map { entry in
            if conflicts.contains(entry.path) {return (entry.path,CommitStagingState.unstaged)}
            var targets = [Data(entry.path.utf8)]
            if (entry.index == "R" || entry.worktree == "R"), let old = entry.originalPath { targets.append(Data(old.utf8)) }
            let staged = targets.contains { stagedPaths.contains($0) }
            let unstaged = targets.contains { workingPaths.contains($0) || unversioned.contains($0) }
            return (entry.path, staged ? (unstaged ? CommitStagingState.partial : .staged) : .unstaged)
        }, uniquingKeysWith: { _, new in new })
    }

    /// Whole-file Commit checkboxes operate on both sides of a retained rename.
    /// Copies retain their source in the index; staging a copy must not stage
    /// unrelated changes in that source file.
    public func setCommitFilesStaged(_ entries: [StatusEntry], staged: Bool, amendToParent: Bool = false, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        // GitStatusListCtrl::GitStageEntry always invokes Git add, independently
        // of the explicit Add command's backend setting. Preserve symlink leaves
        // and missing conflict resolutions through Git's own add semantics.
        // A Commit row survives checkbox operations. Porcelain may subsequently
        // split its rename, or pair identical blobs with a different deletion.
        // Its captured paths remain the authorization boundary; fresh status is
        // used for live conflict semantics, never for acquiring another source.
        var captured=GitPathSet(),locations=GitPathMap<URL>()
        for entry in entries {
            locations[entry.path]=try restoreLocation(entry.path)
            captured.insert(entry.path)
            if entry.index == "R" || entry.worktree == "R",let old=entry.originalPath {
                locations[old]=try restoreLocation(old);captured.insert(old)
            }
        }
        guard !captured.isEmpty else{return}
        let current=try status(refreshIndex:false,cancellation:cancellation)
        let conflicts=current.filter{captured.contains($0.path) && $0.state == .conflicted}
        func insertMembership(_ path:String,into names:inout GitPathSet) {
            names.insert(path)
            var ancestor=path[...]
            while let slash=ancestor.lastIndex(of:"/") {
                ancestor=ancestor[..<slash]
                if !ancestor.isEmpty {names.insert(String(ancestor))}
            }
        }
        var indexed=GitPathSet()
        // Read membership without passing the selection through argv limits.
        // Only captured, validated paths below may become mutation operands.
        let indexNames=try run(["-c","core.precomposeunicode=false","ls-files","--cached","-z"],cancellation:cancellation).stdout
        for path in indexNames.split(separator:0) {insertMembership(String(decoding:path,as:UTF8.self),into:&indexed)}
        if staged {
            var paths=GitPathSet()
            for path in captured {
                var info=stat()
                if indexed.contains(path) || lstat(locations[path]!.path,&info)==0 {paths.insert(path)}
                else if errno != ENOENT && errno != ENOTDIR {throw POSIXError(.init(rawValue:errno) ?? .EIO)}
            }
            try cancellation?.check()
            try stage(paths.sorted(),cancellation:cancellation)
            return
        }
        let base:String?
        if amendToParent {base=try commitComparisonBase(amendToParent:true,cancellation:cancellation)}
        else {
            let head=try run(["rev-parse","--verify","--quiet","HEAD^{tree}"],successfulExitCodes:0...1,cancellation:cancellation)
            base=head.exitCode==0 ? head.text.trimmingCharacters(in:.newlines):nil
        }
        let actions:GitPathMap<CommitConflictIndexActions> = try base.map{try commitConflictIndexActions(conflicts,base:$0,cancellation:cancellation)} ?? [:]
        let conflictPaths=GitPathSet(conflicts.map(\.path))
        var baseline=GitPathSet()
        if let base {
            let bytes=try run(["-c","core.precomposeunicode=false","ls-tree","-r","--full-tree","--name-only","-z",base],cancellation:cancellation).stdout
            for path in bytes.split(separator:0) {insertMembership(String(decoding:path,as:UTF8.self),into:&baseline)}
        }
        var paths=GitPathSet(),remove=GitPathSet()
        for path in captured {
            if conflictPaths.contains(path) {
                let flags=actions[path] ?? CommitConflictIndexActions()
                if flags.added {remove.insert(path);continue}
                if !flags.deleted && !flags.modified {continue}
            }
            if indexed.contains(path) || baseline.contains(path) {paths.insert(path)}
        }
        try cancellation?.check()
        if !remove.isEmpty {_ = try run(["rm","-f","--cached","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:literalPathPacket(remove.sorted()))}
        try unstageCommitPaths(paths.sorted(),amendToParent:amendToParent,cancellation:cancellation)
    }

    public func unstageCommitPaths(_ paths: [String], amendToParent: Bool, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard amendToParent else { try unstage(paths, cancellation: cancellation); return }
        guard !paths.isEmpty else { return }
        let base = try commitComparisonBase(amendToParent: true, cancellation: cancellation)
        _ = try run(["restore","--source=" + base,"--staged","--pathspec-from-file=-","--pathspec-file-nul"],cancellation:cancellation,input:literalPathPacket(paths))
    }

    func commitParentSelection(message: String, checked: [StatusEntry], options: CommitOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let base = try commitComparisonBase(amendToParent: true)
        return try commitSeparateSelection(message: message, checked: checked, options: options, base: base, fileModes: selectedStagedFileModes(checked), cancellation: cancellation, onOutput: onOutput)
    }
    private func populateCommitSelectionIndex(checked: [StatusEntry], base: String, fileModes: GitPathMap<String>, environment: [String: String], cancellation: OperationCancellation? = nil, sourcePrepared:Bool=false, preparedIndexBytes:Data?=nil) throws -> [String] {
        try cancellation?.check()
        if sourcePrepared {
            // Keep selected entries' complete stat metadata and REUC instead of
            // rebuilding them through --index-info (which would force another
            // clean-filter read when Git refreshes the commit index).
            if let preparedIndexBytes {
                let url=URL(fileURLWithPath:environment["GIT_INDEX_FILE"]!)
                try preparedIndexBytes.write(to:url)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            }else{_ = try run(["read-tree",base],environmentOverrides:environment,cancellation:cancellation)}
            var affected=GitPathSet(checked.map(\.path))
            for entry in checked where entry.index == "R" || entry.worktree == "R" {if let old=entry.originalPath {affected.insert(old)}}
            let indexed=try run(["ls-files","--cached","-z"],environmentOverrides:environment,cancellation:cancellation).stdout
            let tree=try run(["ls-tree","-r","--name-only","-z",base],cancellation:cancellation).stdout
            let all=GitPathSet((indexed+tree).split(separator:0).map{String(decoding:$0,as:UTF8.self)})
            let reset=all.subtracting(affected)
            if !reset.isEmpty {_ = try run(["restore","--source="+base,"--staged","--pathspec-from-file=-","--pathspec-file-nul"],environmentOverrides:environment,cancellation:cancellation,input:literalPathPacket(reset.sorted()))}
            return affected.sorted()
        }
        let tracked = GitPathSet(try trackedPaths())
        let retainedDeletes = GitPathSet(checked.filter { $0.index == "D" && $0.hasUnversionedCopy }.map(\.path))
        var paths = checked.filter { !retainedDeletes.contains($0.path) }.map(\.path)
        var realStage = checked.filter { !retainedDeletes.contains($0.path) && ($0.state != .deleted || tracked.contains($0.path) || FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path)) }.map(\.path)
        for entry in checked {
            if let old = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                paths.append(old)
                if tracked.contains(old) { realStage.append(old) }
            }
        }
        _ = try run(["read-tree", base], environmentOverrides: environment, cancellation: cancellation)
        // Git discovers only the filesystem's spelling when adding a new path.
        // Seed checked stage-zero identities first: on normalization-aliasing
        // volumes two distinct index paths can refer to one physical payload.
        // Subsequent add still applies current content, clean filters and modes.
        let selected = GitPathSet(checked.map(\.path)), selectedPaths = Array(selected)
        var seed = Data(), seeded = GitPathSet()
        for offset in stride(from: 0, to: selectedPaths.count, by: 64) {
            let batch = Array(selectedPaths[offset..<min(offset + 64, selectedPaths.count)])
            for record in try run(["-c","core.precomposeunicode=false","ls-files","--stage","-z","--"] + batch, cancellation: cancellation).stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9) else { continue }
                let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
                guard fields.count == 3, fields[2] == "0", selected.contains(path), !retainedDeletes.contains(path), seeded.insert(path).inserted else { continue }
                seed.append(contentsOf: record); seed.append(0)
            }
        }
        if !seed.isEmpty { _ = try run(["update-index","-z","--index-info"], environmentOverrides: environment, cancellation: cancellation, input: seed) }
        if !paths.isEmpty {
            _ = try run(["add","--all","--pathspec-from-file=-","--pathspec-file-nul"],environmentOverrides:environment,cancellation:cancellation,input:literalPathPacket(Array(GitPathSet(paths))))
        }
        if !retainedDeletes.isEmpty {
            _ = try run(["update-index","--force-remove","-z","--stdin"],environmentOverrides:environment,cancellation:cancellation,input:literalPathPacket(Array(retainedDeletes)))
        }
        try applySelectedFileModes(fileModes, environment: environment, cancellation: cancellation)
        return realStage
    }
    func commitSelectionIsEmpty(checked: [StatusEntry], base: String, fileModes: GitPathMap<String>) throws -> Bool {
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        _ = try populateCommitSelectionIndex(checked: checked, base: base, fileModes: fileModes, environment: environment)
        let tree = try run(["write-tree"], environmentOverrides: environment).text
        return tree == (try run(["rev-parse", base + "^{tree}"]).text)
    }
    func commitSeparateSelection(message: String, checked: [StatusEntry], options: CommitOptions, base: String, fileModes: GitPathMap<String> = [:], preservedAuthorDate: String? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, sourcePrepared:Bool=false, preparedIndexBytes:Data?=nil, reusingMessageFrom:String?=nil,usePreparedRealIndex:Bool=false, willCommit:() -> Void = {}) throws -> String {
        try cancellation?.check()
        var selectedIndexBytes=preparedIndexBytes
        if !sourcePrepared {selectedIndexBytes=try prepareCLICommitIndex(changes:checked,checked:GitPathSet(checked.map(\.path)),policy:nil,base:base,cancellation:cancellation,onOutput:onOutput,expectedIndex:options.expectedIndex,fileModes:fileModes).index}
        let messageFile = reusingMessageFrom == nil ? try makeCommitMessageFile(message):nil; defer { messageFile?.remove() }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-amend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        if let preservedAuthorDate { environment["GIT_AUTHOR_DATE"] = preservedAuthorDate }
        _ = try populateCommitSelectionIndex(checked:checked,base:base,fileModes:fileModes,environment:environment,cancellation:cancellation,sourcePrepared:true,preparedIndexBytes:selectedIndexBytes)
        try prepareCommitBranch(options.newBranch,cancellation:cancellation)
        var args:[String]
        if let reusingMessageFrom {args=["commit","--allow-empty-message","-C",reusingMessageFrom]}
        else {args=["commit","-F",messageFile!.url.path]}
        if options.amend { args.append("--amend") }
        if options.messageOnly { args.append("--allow-empty") }
        if options.signOff { args.append("--signoff") }
        if let author = options.author, !author.isEmpty { args.append("--author=" + author) }
        if options.resetAuthorDate { args.append("--date=now") }
        else if let date = options.authorDate { args.append("--date=" + ISO8601DateFormatter().string(from: date)) }
        if usePreparedRealIndex {
            // Only the source conflict queues opt in. The independent selected
            // tree must equal the real prepared index before source hooks may
            // mutate that real index; unchecked entries cannot enter by accident.
            guard sourcePrepared,reusingMessageFrom != nil,
                  try run(["write-tree"],cancellation:cancellation).stdout == run(["write-tree"],environmentOverrides:environment,cancellation:cancellation).stdout else {throw commitIndexChanged()}
            environment.removeValue(forKey:"GIT_INDEX_FILE")
        }
        try cancellation?.check();willCommit()
        return try run(args, environmentOverrides: environment, cancellation: cancellation, onOutput: onOutput).text
    }
}
