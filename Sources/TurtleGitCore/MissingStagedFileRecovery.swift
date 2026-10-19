// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum MissingStagedFileAction: Equatable, Sendable { case restoreFromIndex, removeFromIndex, ignore }
public enum MissingStagedFileRecoveryFailure: LocalizedError, Sendable {
    case changed, location, indexLocked
    public var errorDescription: String? {
        switch self {
        case .changed: return "The missing file, its indexed contents or repository changed. Refresh before recovering it."
        case .location: return "Missing-file recovery must stay inside this working tree, outside nested repositories and Git administrative directories."
        case .indexLocked: return "Could not lock the Git index. Finish the other Git operation and retry."
        }
    }
}
public struct MissingStagedFile: Sendable {
    public let path: String
    public let indexStatus: Character
    fileprivate let root: URL
    fileprivate let head: Data
    fileprivate let indexEntry: Data
    fileprivate let ancestry: [MissingStagedAncestor]
}
fileprivate struct MissingStagedAncestor: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
}
public struct MissingStagedFileRecoveryResult: Sendable {
    public let path: String
    public let action: MissingStagedFileAction
    public let changed: Bool
    public let output: String
}
extension GitRepository {
    /// Candidates follow accepted list order. A pure unstaged deletion, conflict,
    /// gitlink or staged deletion is not the upstream Added/Modified condition.
    public func missingStagedFiles(in entries: [StatusEntry], cancellation: OperationCancellation? = nil) throws -> [MissingStagedFile] {
        var result = [MissingStagedFile](), seen = Set<Data>()
        let head = try missingRecoveryHead(cancellation)
        for entry in entries {
            try cancellation?.check()
            guard [Character("A"),"M","R","C","T"].contains(entry.index), entry.state != .conflicted,
                  seen.insert(Data(entry.path.utf8)).inserted else { continue }
            let location = try missingRecoveryLocation(entry.path)
            guard try missingRecoveryAbsent(location) else { continue }
            let index = try missingRecoveryIndexEntry(entry.path, cancellation)
            guard Self.missingRecoveryStageZero(index) else { continue }
            let ancestry = try missingRecoveryAncestry(entry.path)
            try missingRecoveryOwner(ancestry.last!.path, cancellation)
            result.append(.init(path:entry.path,indexStatus:entry.index,root:root,head:head,indexEntry:index,ancestry:ancestry))
        }
        try cancellation?.check(); return result
    }
    public func recoverMissingStagedFile(_ expected: MissingStagedFile, action: MissingStagedFileAction, cancellation: OperationCancellation? = nil) throws -> MissingStagedFileRecoveryResult {
        try cancellation?.check()
        guard expected.root == root else { throw MissingStagedFileRecoveryFailure.location }
        if case .ignore = action { return .init(path:expected.path,action:action,changed:false,output:"") }
        _ = try missingRecoveryLocation(expected.path)
        var indexPath = try run(["rev-parse","--git-path","index"], cancellation:cancellation).stdout
        if indexPath.last == 10 { indexPath.removeLast() }
        guard let name = String(data:indexPath,encoding:.utf8) else { throw MissingStagedFileRecoveryFailure.location }
        let index = name.hasPrefix("/") ? URL(fileURLWithPath:name) : root.appendingPathComponent(name)
        let lock = URL(fileURLWithPath:index.path + ".lock")
        let fd = open(lock.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw MissingStagedFileRecoveryFailure.indexLocked }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        var publishedLock = false
        defer {
            var held = stat(), named = stat()
            if !publishedLock, fstat(fd,&held) == 0, lstat(lock.path,&named) == 0, held.st_ino == named.st_ino, held.st_dev == named.st_dev { unlink(lock.path) }
            try? handle.close()
        }
        try missingRecoveryValidate(expected, cancellation)
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMissingStage-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let temporaryIndex = directory.appendingPathComponent("index")
        let originalIndex = try Data(contentsOf:index)
        try originalIndex.write(to:temporaryIndex,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporaryIndex.path)
        let environment = ["GIT_INDEX_FILE":temporaryIndex.path]
        _ = try run(["update-index","--no-split-index"],environmentOverrides:environment,cancellation:cancellation)
        let output: String
        switch action {
        case .ignore: output = "" // handled before acquiring a mutation lock
        case .removeFromIndex:
            output = try run(["rm","-f","--cached","--",expected.path],environmentOverrides:environment,cancellation:cancellation).text
            try missingRecoveryValidate(expected,cancellation)
            guard try Data(contentsOf:index) == originalIndex else { throw MissingStagedFileRecoveryFailure.changed }
            try handle.write(contentsOf:Data(contentsOf:temporaryIndex)); try handle.synchronize()
            if let permissions = try FileManager.default.attributesOfItem(atPath:index.path)[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:lock.path)
            }
            try cancellation?.check()
            guard Darwin.rename(lock.path,index.path) == 0 else { throw missingRecoveryPOSIX() }
            publishedLock = true
        case .restoreFromIndex:
            let export = directory.appendingPathComponent("checkout",isDirectory:true)
            try FileManager.default.createDirectory(at:export,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            output = try run(["checkout-index","--force","--prefix=" + export.path + "/","--",expected.path],environmentOverrides:environment,cancellation:cancellation).text
            // Clean/smudge drivers may run arbitrary processes. Revalidate after
            // they return; never replace a recreated leaf with the prepared copy.
            try missingRecoveryValidate(expected,cancellation)
            let parent = try missingRecoveryOpenParent(expected.path)
            defer { close(parent) }
            try cancellation?.check()
            let prepared = export.appendingPathComponent(expected.path)
            let leaf = (expected.path as NSString).lastPathComponent
            let sibling = ".TurtleGitMissing-" + UUID().uuidString
            var identity = stat()
            if (try FileManager.default.attributesOfItem(atPath:prepared.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath:prepared.path)
                guard symlinkat(target,parent,sibling) == 0 else { throw missingRecoveryPOSIX() }
            } else {
                let source = open(prepared.path,O_RDONLY|O_NOFOLLOW)
                guard source >= 0 else { throw missingRecoveryPOSIX() }; defer { close(source) }
                let target = openat(parent,sibling,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
                guard target >= 0 else { throw missingRecoveryPOSIX() }; defer { close(target) }
                guard fcopyfile(source,target,nil,copyfile_flags_t(COPYFILE_ALL)) == 0 else { unlinkat(parent,sibling,0); throw missingRecoveryPOSIX() }
            }
            guard fstatat(parent,sibling,&identity,AT_SYMLINK_NOFOLLOW) == 0 else { throw missingRecoveryPOSIX() }
            defer {
                var current = stat()
                if fstatat(parent,sibling,&current,AT_SYMLINK_NOFOLLOW) == 0, current.st_ino == identity.st_ino, current.st_dev == identity.st_dev { unlinkat(parent,sibling,0) }
            }
            try missingRecoveryValidate(expected,cancellation)
            guard try Data(contentsOf:index) == originalIndex else { throw MissingStagedFileRecoveryFailure.changed }
            var pinned = stat()
            let currentParent = try missingRecoveryAncestry(expected.path).last!
            guard fstat(parent,&pinned) == 0, UInt64(pinned.st_ino) == currentParent.inode,
                  UInt64(UInt32(bitPattern:pinned.st_dev)) == currentParent.device else { throw MissingStagedFileRecoveryFailure.changed }
            guard renameatx_np(parent,sibling,parent,leaf,UInt32(RENAME_EXCL)) == 0 else { throw missingRecoveryPOSIX() }
            // The real index is deliberately untouched (including stat/cache data).
        }
        return .init(path:expected.path,action:action,changed:true,output:output)
    }
    private func missingRecoveryValidate(_ expected: MissingStagedFile, _ cancellation: OperationCancellation?) throws {
        try cancellation?.check()
        guard try missingRecoveryHead(cancellation) == expected.head,
              try missingRecoveryIndexEntry(expected.path,cancellation) == expected.indexEntry,
              try missingRecoveryAbsent(missingRecoveryLocation(expected.path)),
              try missingRecoveryAncestry(expected.path).starts(with:expected.ancestry) else { throw MissingStagedFileRecoveryFailure.changed }
        try missingRecoveryOwner(try missingRecoveryAncestry(expected.path).last!.path,cancellation)
        try cancellation?.check()
    }
    private func missingRecoveryHead(_ token: OperationCancellation?) throws -> Data {
        try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:token).stdout
    }
    private func missingRecoveryIndexEntry(_ path:String,_ token:OperationCancellation?) throws -> Data {
        try run(["ls-files","--stage","-z","--",path],cancellation:token).stdout
    }
    private static func missingRecoveryStageZero(_ data:Data) -> Bool {
        let records = data.split(separator:0)
        guard records.count == 1,let tab = records[0].firstIndex(of:9),let header = String(data:records[0][..<tab],encoding:.utf8) else { return false }
        let fields = header.split(separator:" ")
        return fields.count == 3 && ["100644","100755","120000"].contains(fields[0]) && fields[2] == "0"
    }
    private func missingRecoveryLocation(_ path:String) throws -> URL {
        let parts = path.components(separatedBy:"/")
        guard !path.isEmpty,!path.hasPrefix("/"),!path.utf8.contains(0),!parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw MissingStagedFileRecoveryFailure.location }
        return try restoreLocation(path)
    }
    private func missingRecoveryAbsent(_ url:URL) throws -> Bool {
        var value = stat()
        if lstat(url.path,&value) == 0 { return false }
        guard errno == ENOENT else { throw missingRecoveryPOSIX() }
        return true
    }
    private func missingRecoveryAncestry(_ path:String) throws -> [MissingStagedAncestor] {
        var result = [MissingStagedAncestor](), url = root
        let parts = path.components(separatedBy:"/").dropLast()
        for part in [""] + Array(parts) {
            if !part.isEmpty { url.appendPathComponent(part) }
            var value = stat()
            if lstat(url.path,&value) != 0 {
                guard errno == ENOENT else { throw missingRecoveryPOSIX() }; break
            }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw MissingStagedFileRecoveryFailure.location }
            result.append(.init(path:url.path,device:UInt64(UInt32(bitPattern:value.st_dev)),inode:UInt64(value.st_ino)))
        }
        guard !result.isEmpty else { throw MissingStagedFileRecoveryFailure.location }; return result
    }
    private func missingRecoveryOwner(_ parent:String,_ token:OperationCancellation?) throws {
        var bytes = try run(["-C",parent,"rev-parse","--show-toplevel"],cancellation:token).stdout
        if bytes.last == 10 { bytes.removeLast() }
        guard let path=String(data:bytes,encoding:.utf8) else { throw MissingStagedFileRecoveryFailure.location }
        // URL equality also includes directory/trailing-slash metadata, which
        // differs when this repository actor predates creation of its folder.
        // Compare actual resolved directory identities; APFS aliases may also
        // have canonically equivalent but byte-distinct root spellings.
        let reported = URL(fileURLWithPath:path).resolvingSymlinksInPath().path
        let expected = root.resolvingSymlinksInPath().path
        var actualInfo = stat(), expectedInfo = stat()
        guard lstat(reported,&actualInfo) == 0, lstat(expected,&expectedInfo) == 0,
              actualInfo.st_mode & S_IFMT == S_IFDIR, expectedInfo.st_mode & S_IFMT == S_IFDIR,
              actualInfo.st_dev == expectedInfo.st_dev, actualInfo.st_ino == expectedInfo.st_ino else { throw MissingStagedFileRecoveryFailure.location }
    }
    /// Open/create components relative to pinned descriptors; a concurrent
    /// symlink substitution cannot redirect publication outside the worktree.
    private func missingRecoveryOpenParent(_ path:String) throws -> Int32 {
        var fd = open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard fd >= 0 else { throw missingRecoveryPOSIX() }
        do {
            for part in path.components(separatedBy:"/").dropLast() {
                if mkdirat(fd,part,0o755) != 0 && errno != EEXIST { throw missingRecoveryPOSIX() }
                let next = openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
                guard next >= 0 else { throw missingRecoveryPOSIX() }; close(fd); fd=next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func missingRecoveryPOSIX() -> NSError { NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
}
