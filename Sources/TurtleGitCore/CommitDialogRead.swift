import Foundation
import Darwin

/// One display-read lifetime, never a commit/preflight authority or cross-call cache.
public struct CommitDialogRead: Sendable {
    public let operation:CommitOperation?
    public let branch:String
    public let hasLFS:Bool,conflictIsRebase:Bool
    public let hasHead:Bool,hasParent:Bool
    public let comparisonBase:String?
    public let entries:[StatusEntry]
    public let working:[CommitFile],staged:[CommitFile],unstaged:[CommitFile]
    public let submodules:GitPathSet
    public let indexFlags:[WorkingTreeFile]
}

public enum CommitDialogReadFailure:LocalizedError {
    case malformedDiff,malformedIndex,malformedRepositoryLayout
    public var errorDescription:String? {
        switch self {
        case .malformedDiff:return "Git returned an invalid Commit difference record. Refresh the file list."
        case .malformedIndex:return "Git returned an invalid Commit index record. Refresh the file list."
        case .malformedRepositoryLayout:return "Git returned an invalid Commit repository directory. Refresh the file list."
        }
    }
}

/// Read-only, operation-local layout. Git resolves separate/linked worktrees and
/// environment overrides; no .git-file parsing or cross-refresh path cache is
/// involved. Marker names below are per-worktree even when Git shares objects.
private struct CommitDisplayRepositoryLayout {
    let directory:URL,common:URL
    func operation(cancellation:OperationCancellation?)throws->CommitOperation? {
        for (name,value) in [("MERGE_HEAD",CommitOperation.merge),("CHERRY_PICK_HEAD",.cherryPick),("REVERT_HEAD",.revert)] {
            try cancellation?.check()
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path) {try cancellation?.check();return value}
        }
        try cancellation?.check();return nil
    }
    func hasDirectory(_ name:String,under root:URL,cancellation:OperationCancellation?)throws->Bool {
        try cancellation?.check()
        var directory:ObjCBool=false
        let exists=FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path,isDirectory:&directory)
        try cancellation?.check();return exists && directory.boolValue
    }
    func isRebase(cancellation:OperationCancellation?)throws->Bool {
        try hasDirectory("rebase-merge",under:directory,cancellation:cancellation) || hasDirectory("rebase-apply",under:directory,cancellation:cancellation)
    }
}

/// Git diff.c diff_flush emits the complete raw section followed by numstat.
/// In -z form filenames are separate NUL packets; tabs/newlines/colon-leading
/// names are not separators. NAME_STATUS must not be requested: it disables RAW.
enum CommitCombinedDiff {
    static func parse(_ bytes:Data,cancellation:OperationCancellation? = nil)throws->[CommitFile] {
        guard bytes.isEmpty || bytes.last==0 else {throw CommitDialogReadFailure.malformedDiff}
        let packets=bytes.split(separator:0,omittingEmptySubsequences:false)
        var cursor=0,names=Data(),raw=Data(),statistics=Data()
        struct Pair:Hashable {let old:Data?;let new:Data}
        var rawPairs=[Pair:Int](),statPairs=[Pair:Int]()
        func append(_ value:Data.SubSequence,to destination:inout Data) {destination.append(contentsOf:value);destination.append(0)}
        func path()throws->Data.SubSequence {
            guard cursor<packets.count,!packets[cursor].isEmpty else {throw CommitDialogReadFailure.malformedDiff}
            defer{cursor += 1};return packets[cursor]
        }
        while cursor<packets.count,packets[cursor].first==58 {
            try cancellation?.check()
            let header=packets[cursor],fields=header.split(separator:32);cursor += 1
            guard fields.count==5,fields[0].count==7,fields[1].count==6,
                  fields[0].dropFirst().allSatisfy({(48...55).contains($0)}),fields[1].allSatisfy({(48...55).contains($0)}),
                  [40,64].contains(fields[2].count),fields[3].count==fields[2].count,
                  fields[2].allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),fields[3].allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                  let action=fields[4].first,"ACDMRTUXB".utf8.contains(action),fields[4].dropFirst().allSatisfy({(48...57).contains($0)}) else {throw CommitDialogReadFailure.malformedDiff}
            if fields[4].count>1 {
                guard [UInt8(77),82,67].contains(action),fields[4].count==4,let score=Int(String(decoding:fields[4].dropFirst(),as:UTF8.self)),score<=100 else {throw CommitDialogReadFailure.malformedDiff}
            }
            append(header,to:&raw);append(fields[4],to:&names)
            let first=try path();append(first,to:&raw);append(first,to:&names)
            let pair:Pair
            if action==82 || action==67 {let second=try path();append(second,to:&raw);append(second,to:&names);pair=Pair(old:Data(first),new:Data(second))}
            else {pair=Pair(old:nil,new:Data(first))}
            rawPairs[pair,default:0] += 1
        }
        while cursor<packets.count {
            try cancellation?.check()
            let packet=packets[cursor];cursor += 1
            if packet.isEmpty,cursor==packets.count {break}
            let fields=packet.split(separator:9,maxSplits:2,omittingEmptySubsequences:false)
            func number(_ field:Data.SubSequence)->Bool {!field.isEmpty && field.allSatisfy{(48...57).contains($0)} && Int(String(decoding:field,as:UTF8.self)) != nil}
            guard fields.count==3 else {throw CommitDialogReadFailure.malformedDiff}
            let binary=fields[0]==Data([45])[...] && fields[1]==Data([45])[...]
            guard binary || number(fields[0]) && number(fields[1]) else {throw CommitDialogReadFailure.malformedDiff}
            append(packet,to:&statistics)
            let pair:Pair
            if fields[2].isEmpty {let old=try path(),new=try path();append(old,to:&statistics);append(new,to:&statistics);pair=Pair(old:Data(old),new:Data(new))}
            else {pair=Pair(old:nil,new:Data(fields[2]))}
            statPairs[pair,default:0] += 1
            guard statPairs[pair,default:0]<=rawPairs[pair,default:0] else {throw CommitDialogReadFailure.malformedDiff}
        }
        try cancellation?.check()
        return CommitFile.parse(names:names,statistics:statistics,raw:raw).filter{$0.action != "M" || $0.hasStatistics}
    }
}

private struct CommitDisplayIndex {
    var submodules:GitPathSet=[]
    var flags:GitPathMap<(Bool,Bool)>=[:]
    init(_ bytes:Data,cancellation:OperationCancellation?)throws {
        guard bytes.isEmpty || bytes.last==0 else {throw CommitDialogReadFailure.malformedIndex}
        for record in bytes.split(separator:0) {
            try cancellation?.check()
            guard let tab=record.firstIndex(of:9) else {throw CommitDialogReadFailure.malformedIndex}
            let fields=record[..<tab].split(separator:32),path=String(decoding:record[record.index(after:tab)...],as:UTF8.self)
            guard fields.count==4,fields[0].count==1,let tag=fields[0].first,"HhSsMm".utf8.contains(tag),
                  fields[1].count==6,fields[1].allSatisfy({(48...55).contains($0)}),
                  [40,64].contains(fields[2].count),fields[2].allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),!path.isEmpty,
                  let stage=Int(String(decoding:fields[3],as:UTF8.self)),(0...3).contains(stage) else {throw CommitDialogReadFailure.malformedIndex}
            if fields[1]==Data("160000".utf8)[...] {submodules.insert(path)}
            flags[path]=(tag>=97 && tag<=122,tag==83 || tag==115)
        }
    }
}

extension GitRepository {
    public func commitDialogRead(amend:Bool,amendDiffToLastCommit:Bool,cancellation:OperationCancellation? = nil)throws->CommitDialogRead {
        try cancellation?.check()
        func directory(_ argument:String)throws->URL {
            var bytes=try run(["rev-parse",argument],cancellation:cancellation).stdout
            try cancellation?.check()
            // Remove exactly Git's output LF, not whitespace belonging to the
            // directory. Separate results avoid ambiguous embedded-LF framing.
            if bytes.last==10 {bytes.removeLast()}
            guard !bytes.isEmpty,!bytes.contains(0) else {throw CommitDialogReadFailure.malformedRepositoryLayout}
            let path=String(decoding:bytes,as:UTF8.self)
            return path.hasPrefix("/") ? URL(fileURLWithPath:path,isDirectory:true):root.appendingPathComponent(path,isDirectory:true)
        }
        let layout=try CommitDisplayRepositoryLayout(directory:directory("--absolute-git-dir"),common:directory("--git-common-dir"))
        let operation=try layout.operation(cancellation:cancellation)
        func revision(_ value:String)throws->String? {
            let result=try run(["rev-parse","--verify","--quiet",value],successfulExitCodes:0...1,cancellation:cancellation)
            try cancellation?.check()
            guard result.exitCode==0 else{return nil}
            let value=result.text.trimmingCharacters(in:.newlines)
            guard GitLocalReferenceProtocol.validOID(value) else {throw CommitDialogReadFailure.malformedDiff}
            return value
        }
        let head=try revision("HEAD^{commit}")
        let parent:String?
        if let head {parent=try revision(head+"^1^{commit}")} else {parent=nil}
        let compareParent=operation==nil && amend && parent != nil && !amendDiffToLastCommit
        let base=compareParent ? parent:nil
        // One repository actor call owns this read. External processes may
        // still change Git/index/worktree state: this is display data, never a
        // substitute for fresh mutation preflight/index bytes at Commit time.
        let current=try status(readPolicy:.automatic,includeIgnored:false,cancellation:cancellation)
        func diff(_ arguments:[String])throws->[CommitFile] {
            let args=["-c","diff.autoRefreshIndex=false","diff","--no-ext-diff","--no-color","--no-abbrev"]+diffDetection.comparisonArguments+arguments+["--raw","--numstat","-z","--"]
            return try CommitCombinedDiff.parse(run(args,environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout,cancellation:cancellation)
        }
        let working=try diff(base.map{[$0]} ?? head.map{[$0]} ?? ["--cached"])
        let staged=try diff(["--cached"]+(base.map{[$0]} ?? head.map{[$0]} ?? []))
        let unstaged=try diff([])
        let entries=try commitDialogEntries(current:current,amendToParent:compareParent,indexed:staged,working:working,cancellation:cancellation)
        let inventory=try CommitDisplayIndex(run(["-c","core.precomposeunicode=false","ls-files","--stage","-v","-z"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout,cancellation:cancellation)
        let flags=entries.filter{$0.state != .ignored}.map{WorkingTreeFile(entry:$0,assumeUnchanged:inventory.flags[$0.path]?.0 ?? false,skipWorktree:inventory.flags[$0.path]?.1 ?? false,modificationDate:nil)}
        let branch=try branch(cancellation:cancellation)
        let hasLFS=try layout.hasDirectory("lfs",under:layout.common,cancellation:cancellation)
        let conflictIsRebase=try layout.isRebase(cancellation:cancellation)
        try cancellation?.check()
        return .init(operation:operation,branch:branch,hasLFS:hasLFS,conflictIsRebase:conflictIsRebase,hasHead:head != nil,hasParent:parent != nil,comparisonBase:base,entries:entries,working:working,staged:staged,unstaged:unstaged,submodules:inventory.submodules,indexFlags:flags)
    }
}
