import Foundation

/// Source action bits are a union; porcelain XY separately describes actual
/// index/worktree occupancy. In particular a detected copy can still have X=A.
public struct SourceStatusActions:OptionSet,Hashable,Codable,Sendable {
    public let rawValue:UInt16
    public init(rawValue:UInt16){self.rawValue=rawValue}
    public static let added=Self(rawValue:1<<0)
    public static let deleted=Self(rawValue:1<<1)
    public static let modified=Self(rawValue:1<<2)
    public static let renamed=Self(rawValue:1<<3)
    public static let copied=Self(rawValue:1<<4)
    public static let unmerged=Self(rawValue:1<<5)
    public static let missing=Self(rawValue:1<<6)
    public static let merged=Self(rawValue:1<<7)
}

extension StatusEntry {
    public var reportingActions:SourceStatusActions {
        if let sourceActions {return sourceActions}
        var result:SourceStatusActions=[]
        if state == .conflicted {result.insert(.unmerged)}
        else {
            for code in [index,worktree] {
                switch code {case "A":result.insert(.added);case "D":result.insert(.deleted)
                case "M","T":result.insert(.modified);case "R":result.insert(.renamed)
                case "C":result.insert(.copied);default:break}
            }
        }
        if worktree == "D" {result.insert(.missing)}
        return result
    }
    /// Cached raw output precedes whole-tree output; the first origin wins even
    /// when it is absent. Do not substitute a later porcelain pairing for it.
    public var reportingOriginalPath:String? {sourceActions == nil ? originalPath:sourceOriginalPath}
    public var isRenamed:Bool {reportingActions.contains(.renamed)}
    public var isCopied:Bool {reportingActions.contains(.copied)}
    public var comparisonAction:String {
        let flags=reportingActions
        if flags.contains(.unmerged) {return "M"}
        if flags.contains(.added) {return "A"}
        if flags.contains(.deleted) {return "D"}
        if flags.contains(.renamed) {return "R"}
        if flags.contains(.copied) {return "C"}
        return "M"
    }
    /// CTGitPath::GetActionName precedence; colors may use a different mask.
    /// These are stable English captions, localized only by native consumers.
    public var actionCaption:String {
        let flags=reportingActions
        let captions:[(SourceStatusActions,String)]=[(.unmerged,"Conflicted"),(.added,"Added"),(.missing,"Missing"),(.deleted,"Deleted"),(.merged,"Merged"),(.modified,"Modified"),(.renamed,"Renamed"),(.copied,"Copied")]
        for (flag,caption) in captions {
            if flags.contains(flag) {return caption}
        }
        if state == .untracked {return "Untracked"}
        if state == .ignored {return "Ignored"}
        return "Normal"
    }
}

enum SourceWorkingStatusFailure:Error {case malformedOutput,invalidBase}

/// Parse the real --raw --numstat -z stream, not display-quoted path text.
/// Empty records and numstat rename triplets must not become synthetic rows.
enum SourceWorkingStatus {
    struct Record {let path:String,origin:String?;var actions:SourceStatusActions}
    static func parse(_ data:Data)throws->[Record] {
        guard data.isEmpty || data.last==0 else{throw SourceWorkingStatusFailure.malformedOutput}
        let records=data.split(separator:0,omittingEmptySubsequences:false)
        var cursor=0,result:[Record]=[]
        func path(_ bytes:Data.SubSequence)throws->String? {
            guard !bytes.isEmpty else{throw SourceWorkingStatusFailure.malformedOutput}
            // The existing porcelain String API has no lossless invalid-UTF8
            // identity. Do not attach another raw file's metadata to U+FFFD.
            return String(bytes:bytes,encoding:.utf8)
        }
        while cursor<records.count {
            let record=records[cursor];cursor += 1
            if record.isEmpty {continue}
            if record.first == 58 {
                let fields=record.split(separator:32,omittingEmptySubsequences:false)
                guard fields.count==5,fields[0].count==7,fields[0].first==58,fields[1].count==6,
                      fields[0].dropFirst().allSatisfy({(48...55).contains($0)}),fields[1].allSatisfy({(48...55).contains($0)}),
                      !fields[2].isEmpty,!fields[3].isEmpty,fields[2].count<=64,fields[3].count<=64,
                      fields[2].allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),fields[3].allSatisfy({(48...57).contains($0) || (97...102).contains($0)}),
                      let code=fields[4].first,cursor<records.count else{throw SourceWorkingStatusFailure.malformedOutput}
                let suffix=fields[4].dropFirst()
                guard suffix.allSatisfy({(48...57).contains($0)}),suffix.isEmpty || Int(String(decoding:suffix,as:UTF8.self)).map({(0...100).contains($0)})==true else{throw SourceWorkingStatusFailure.malformedOutput}
                let flag:SourceStatusActions
                switch code {case 65:flag = .added;case 68,75:flag = .deleted;case 77,84:flag = .modified
                case 82:flag = .renamed;case 67:flag = .copied;case 85:flag = .unmerged
                default:throw SourceWorkingStatusFailure.malformedOutput}
                let first=try path(records[cursor]);cursor += 1
                let destination:String?,origin:String?
                if code==82 || code==67 {
                    guard cursor<records.count else{throw SourceWorkingStatusFailure.malformedOutput}
                    destination=try path(records[cursor]);cursor += 1;origin=first
                } else {destination=first;origin=nil}
                if let destination,!(code==82 || code==67) || origin != nil {result.append(Record(path:destination,origin:origin,actions:flag))}
            } else {
                let fields=record.split(separator:9,maxSplits:2,omittingEmptySubsequences:false)
                guard fields.count==3 else{throw SourceWorkingStatusFailure.malformedOutput}
                let binary=fields[0].elementsEqual([UInt8(45)]) && fields[1].elementsEqual([UInt8(45)])
                let numeric = !fields[0].isEmpty && !fields[1].isEmpty && fields[0].allSatisfy({(48...57).contains($0)}) && fields[1].allSatisfy({(48...57).contains($0)})
                guard binary || numeric else{throw SourceWorkingStatusFailure.malformedOutput}
                if fields[2].isEmpty {
                    guard cursor+1<records.count else{throw SourceWorkingStatusFailure.malformedOutput}
                    _=try path(records[cursor]);_=try path(records[cursor+1]);cursor += 2
                }
            }
        }
        return result
    }
    static func applying(_ records:[Record],to entries:[StatusEntry])->[StatusEntry] {
        // ParserFromLog's default MergeReplacedStatusKS maps both names of
        // a newly accepted R/C record to one row. Later source-path records
        // therefore update that destination; the first origin remains fixed.
        var positions=GitPathMap<Int>(),merged:[Record]=[]
        for record in records {
            if let position=positions[record.path] {
                if merged[position].actions == .renamed && (record.actions == .added || record.actions == .deleted) {continue}
                merged[position].actions.formUnion(record.actions)
            } else {
                let position=merged.count;merged.append(record);positions[record.path]=position
                if let origin=record.origin,!origin.isEmpty,positions[origin] == nil {positions[origin]=position}
            }
        }
        var accepted=GitPathMap<Record>()
        for record in merged {accepted[record.path]=record}
        return entries.compactMap {entry -> StatusEntry? in
            // Unversioned/ignored paths are a separate source inventory; an
            // old-name alias must not consume a recreated local file.
            if entry.state == .untracked || entry.state == .ignored {return entry}
            if let position=positions[entry.path],!GitReferenceName.equal(merged[position].path,entry.path) {
                if entry.hasUnversionedCopy,let local=entry.unversionedCopyState,local == .untracked || local == .ignored {
                    let code:Character = local == .ignored ? "!":"?"
                    return StatusEntry(path:entry.path,index:code,worktree:code)
                }
                if entry.hasUnversionedCopy {return entry} // Legacy caller did not capture ?? versus !!.
                return nil
            }
            guard let raw=accepted[entry.path] else{return entry}
            var value=entry,flags=raw.actions
            if entry.state == .conflicted {flags.insert(.unmerged)}
            if entry.worktree == "D" {flags.insert(.missing)}
            value.sourceActions=flags;value.sourceOriginalPath=raw.origin;return value
        }
    }
}

extension GitRepository {
    /// Nil is the existing whole-repository contract; an empty explicit scope
    /// reads nothing. Preserve literal names and caller order, including '.',
    /// without interpreting glob/pathspec magic or resolving spelling aliases.
    func workingStatusScope(_ paths:[String]?)throws->[String]? {
        guard let paths else{return nil}
        var seen=GitPathSet(),result:[String]=[]
        for path in paths {
            guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\0"),
                  !path.components(separatedBy:"/").contains(where:{$0==".." || $0.caseInsensitiveCompare(".git") == .orderedSame}) else{throw WorkingFileRestoreFailure.location}
            if path != "." {_=try restoreLocation(path)}
            if seen.insert(path).inserted {result.append(path)}
        }
        return result
    }
    func workingStatusPath(_ path:String,isWithin scope:[String]?)->Bool {
        guard let scope else{return true}
        func components(_ value:String)->[[UInt8]] {
            value.utf8.split(separator:47).filter{!$0.elementsEqual([UInt8(46)])}.map{Array($0)}
        }
        let candidate=components(path)
        return scope.contains {value in
            let prefix=components(value)
            return prefix.count<=candidate.count && zip(prefix,candidate).allSatisfy{pair in pair.0.elementsEqual(pair.1)}
        }
    }
    /// An explicit base enables an amend/status projection to reuse these same
    /// source rules. Global observers avoid extra scans unless an ordinary A/R/C
    /// candidate can introduce a pairing not represented in porcelain XY.
    public func sourceWorkingStatus(_ entries:[StatusEntry],base:ComparisonRevision?=nil,readPolicy:GitStatusReadPolicy = .automatic,paths:[String]?=nil,includedStaged:Bool=false,cancellation:OperationCancellation?=nil)throws->[StatusEntry] {
        try cancellation?.check()
        let scope=try workingStatusScope(paths)
        if scope?.isEmpty == true {return []}
        let tracked=entries.filter{$0.state != .untracked && $0.state != .ignored}
        guard !tracked.isEmpty else{return entries}
        if base == nil,!tracked.contains(where:{$0.state != .conflicted && [$0.index,$0.worktree].contains(where:{[Character("A"),"R","C"].contains($0)})}) {return entries}
        let environment=readPolicy == .automatic ? ["GIT_OPTIONAL_LOCKS":"0"]:[:]
        let hash:String
        switch base {
        case .workingTree?:throw SourceWorkingStatusFailure.invalidBase
        case .emptyTree?:return entries
        case .revision(let value)?:hash=value
        case nil:
            let head=try run(["rev-parse","--verify","--quiet","HEAD^{commit}"],environmentOverrides:environment,successfulExitCodes:0...1,cancellation:cancellation)
            guard head.exitCode==0 else{return entries};hash=head.text.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        guard [40,64].contains(hash.utf8.count),hash.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else{throw SourceWorkingStatusFailure.invalidBase}
        let prefix=["-c","diff.autoRefreshIndex=false","diff-index","--no-ext-diff","--no-color","--raw"]
        var records:[SourceWorkingStatus.Record]=[]
        // Upstream loops selected paths independently. Do not combine pathspecs:
        // cross-scope rename detection changes accepted Added/old-name operands.
        for path in scope.map({$0.map{Optional($0)}}) ?? [nil] {
            try cancellation?.check()
            let scoped=path.map{[$0]} ?? []
            let cachedScope=includedStaged ? []:scoped
            let cached=try run(prefix+["--cached",hash,"--numstat","-C","-M","-z","--"]+cachedScope,environmentOverrides:environment,cancellation:cancellation).stdout
            try cancellation?.check()
            let whole=try run(prefix+[hash,"--numstat",diffDetection.copyArgument,diffDetection.renameArgument,"-z","--"]+scoped,environmentOverrides:environment,cancellation:cancellation).stdout
            try cancellation?.check()
            records += try SourceWorkingStatus.parse(cached)+SourceWorkingStatus.parse(whole)
        }
        return SourceWorkingStatus.applying(records,to:entries)
    }
}
