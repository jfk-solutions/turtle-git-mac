// SPDX-License-Identifier: GPL-2.0-or-later
// The only transfer implementation here is the pinned static libgit2 library.
import Foundation
import Darwin
import Security
import CLibgit2

struct HelperFailure: LocalizedError { let message:String; var errorDescription:String?{message} }
func refuse(_ text:String)throws->Never{throw HelperFailure(message:text)}
func output(_ text:String){FileHandle.standardError.write(Data(text.utf8))}
let environment=ProcessInfo.processInfo.environment
func cancelled()->Bool{environment["TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE"].map{FileManager.default.fileExists(atPath:$0)} ?? false}

/// Parse Git's quoted environment values, never evaluate shell text.
func quotedWords(_ input:String)throws->[String]{
    var words:[String]=[],word="",quote:Character?,escaped=false,started=false
    for c in input{
        if escaped{word.append(c);escaped=false;started=true;continue}
        if c == "\\",quote != "'"{escaped=true;started=true;continue}
        if let q=quote{if c == q{quote=nil}else{word.append(c)};continue}
        if c == "'" || c == "\""{quote=c;started=true;continue}
        if c.isWhitespace{if started{words.append(word);word="";started=false}}else{word.append(c);started=true}
    }
    guard quote == nil,!escaped else{try refuse("Invalid quoted command configuration")}
    if started{words.append(word)};return words
}
func configuration(_ value:String)throws->String{
    guard !value.contains("\0"),value.utf8.count<=1_048_576 else{try refuse("Invalid command configuration")}
    let parts=value.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
    guard let key=parts.first,!key.isEmpty,key.contains("."),!key.contains(where:{$0.isWhitespace}) else{try refuse("Invalid command configuration key")}
    return parts.count==1 ? value+"=true":value
}
struct Arguments{
    var command="",directory=FileManager.default.currentDirectoryPath,configs:[String]=[]
    var source="",destination="",branch:String?,origin:String?,ssh:String?,bare=false,noCheckout=false,recursive=false
    var listRefs=false,listTags=false,listHeads=false,filters=false,transferNotifications=false,sourceFetch=false
    var resetNotifications=false,resetMode:Int32=2,resetModeSpecified=false,revertNoCommit=false,revertNoEdit=false,mainline:UInt32=0,mainlineSpecified=false,revision=""
    var blobPath:String?,blobOID=""
    var privateIndex:String?,addMode:Int32=0,addModeSpecified=false,addStdin=false,addModeOnly=false
    var remote="origin",refspecs:[String]=[],all=false,tags=0,prune=0,depth=0,force=false,verbose=false
    init(_ arguments:[String])throws{
        if let old=environment["GIT_CONFIG_PARAMETERS"]{for value in try quotedWords(old){configs.append(try configuration(value))}}
        if let raw=environment["GIT_CONFIG_COUNT"]{
            guard let count=Int(raw),count>=0,count<=1024 else{try refuse("Invalid counted command configuration")}
            for i in 0..<count{guard let key=environment["GIT_CONFIG_KEY_\(i)"],let value=environment["GIT_CONFIG_VALUE_\(i)"] else{try refuse("Incomplete counted command configuration")};configs.append(try configuration(key+"="+value))}
        }
        var index=0
        func next()throws->String{guard index<arguments.count else{try refuse("Missing option value")};defer{index+=1};return arguments[index]}
        func depthValue(_ value:String)throws->Int{guard let number=Int(value),number>0,number<=Int(Int32.max) else{try refuse("Invalid shallow depth")};return number}
        while index<arguments.count{
            let arg=try next()
            if arg == "--literal-pathspecs" || arg == "--no-literal-pathspecs"{continue}
            if arg == "--turtlegit-transfer-notifications"{guard !transferNotifications else{try refuse("Repeated transfer notification request")};transferNotifications=true;continue}
            if arg == "--turtlegit-source-fetch"{guard !sourceFetch else{try refuse("Repeated source Fetch request")};sourceFetch=true;continue}
            if arg == "--turtlegit-reset-notifications"{guard !resetNotifications else{try refuse("Repeated Reset notification request")};resetNotifications=true;continue}
            if arg == "-C"{let path=try next();directory=URL(fileURLWithPath:path,relativeTo:URL(fileURLWithPath:directory,isDirectory:true)).standardizedFileURL.path;continue}
            if arg == "-c"{configs.append(try configuration(next()));continue}
            guard ["clone","fetch","ls-remote","push","cat-file","add","turtlegit-prepare-index","reset","revert","turtlegit-unified-diff","turtlegit-history-diff","turtlegit-history-diff-batch","turtlegit-local-refs","turtlegit-containing-refs","turtlegit-delete-local-ref","turtlegit-ref-names","turtlegit-checkout-refs","turtlegit-configured-remotes","turtlegit-tag-object","turtlegit-tag-objects","turtlegit-merge-base","turtlegit-check-clean","turtlegit-check-conflicts","turtlegit-conflict-info","turtlegit-single-commit","turtlegit-finder-status"].contains(arg) else{try refuse("Unsupported libgit2 command or global option")};command=arg;break
        }
        guard !command.isEmpty else{try refuse("Expected a supported libgit2 command")}
        guard !transferNotifications || command == "clone" || command == "fetch" else{try refuse("Transfer notifications require Clone or Fetch")}
        guard !sourceFetch || command == "fetch" else{try refuse("Source Fetch requires Fetch")}
        guard !resetNotifications || command == "reset" else{try refuse("Reset notifications require Reset")}
        guard environment["TURTLEGIT_RESET_RECYCLE_DIRECTORY"] == nil || (resetNotifications && command == "reset") else{try refuse("Recycle exchange requires explicit Reset notifications")}
        var operands:[String]=[],options=true
        while index<arguments.count{
            let arg=try next()
            if options && arg == "--"{options=false;continue}
            if options && arg.hasPrefix("-"){
                switch arg{
                case "--soft" where command == "reset", "--mixed" where command == "reset", "--hard" where command == "reset":
                    guard !resetModeSpecified else{try refuse("Repeated Reset mode")};resetModeSpecified=true;resetMode=arg == "--soft" ? 1:arg == "--mixed" ? 2:3
                case "--no-edit" where command == "revert":guard !revertNoEdit else{try refuse("Repeated Revert no-edit option")};revertNoEdit=true
                case "--no-commit" where command == "revert", "-n" where command == "revert":guard !revertNoCommit else{try refuse("Repeated Revert no-commit option")};revertNoCommit=true
                case "--mainline" where command == "revert", "-m" where command == "revert":
                    guard !mainlineSpecified,let value=UInt32(try next()),value>0 else{try refuse("Invalid Revert mainline")};mainlineSpecified=true;mainline=value
                case "--progress" where command == "clone" || command == "fetch" || command == "push":break
                case "-v" where command == "clone" || command == "fetch" || command == "push", "--verbose" where command == "clone" || command == "fetch" || command == "push":verbose=true
                case "--bare" where command == "clone":bare=true
                case "--no-checkout" where command == "clone":noCheckout=true
                case "--recursive" where command == "clone", "--recurse-submodules" where command == "clone":recursive=true
                case "--branch" where command == "clone", "-b" where command == "clone":branch=try next()
                case "--origin" where command == "clone", "-o" where command == "clone":origin=try next()
                case "--depth" where command == "clone" || command == "fetch":depth=try depthValue(next())
                case "--config" where command == "clone":
                    let value=try next();guard value.hasPrefix("core.sshCommand=") else{try refuse("Unsupported persistent clone configuration")};ssh=String(value.dropFirst("core.sshCommand=".count))
                case "--stdin" where command == "add" || command == "turtlegit-prepare-index":guard !addStdin else{try refuse("Repeated Add input option")};addStdin=true
                case "--turtlegit-mode-only" where command == "add":guard !addModeOnly else{try refuse("Repeated Add mode-only option")};addModeOnly=true
                case "--filters" where command == "cat-file":filters=true
                case "--refs" where command == "ls-remote":listRefs=true
                case "-t" where command == "ls-remote", "--tags" where command == "ls-remote":listTags=true
                case "-h" where command == "ls-remote", "--heads" where command == "ls-remote":listHeads=true
                case "--all" where command == "fetch":all=true
                case "--force" where command == "fetch", "-f" where command == "fetch":force=true
                case "--tags" where command == "fetch":tags=3
                case "--no-tags" where command == "fetch":tags=2
                case "--prune" where command == "fetch":prune=1
                case "--no-prune" where command == "fetch":prune=2
                default:
                    if (command == "add" || command == "turtlegit-prepare-index") && arg.hasPrefix("--turtlegit-index="){
                        guard privateIndex == nil else{try refuse("Repeated private Add index")};privateIndex=String(arg.dropFirst("--turtlegit-index=".count))
                    }else if command == "add" && arg.hasPrefix("--turtlegit-mode="){
                        guard !addModeSpecified else{try refuse("Repeated Add mode")};addModeSpecified=true
                        switch String(arg.dropFirst("--turtlegit-mode=".count)){case "normal":addMode=0;case "executable":addMode=1;case "symlink":addMode=2;default:try refuse("Unsupported Add mode")}
                    }else if command == "cat-file" && arg.hasPrefix("--path="){guard blobPath == nil else{try refuse("Repeated blob path")};blobPath=String(arg.dropFirst(7))}else if (command == "clone" || command == "fetch") && arg.hasPrefix("--depth="){depth=try depthValue(String(arg.dropFirst(8)))}else{try refuse("Unsupported libgit2 option: "+arg)}
                }
            }else{operands.append(arg)}
        }
        guard configs.count<=2048 else{try refuse("Too many command configuration values")}
        if command == "turtlegit-unified-diff" || (command == "turtlegit-history-diff" || command == "turtlegit-history-diff-batch") || PrivateLocalReferenceRequest.commands.contains(command) || PrivateInspectionRequest.commands.contains(command) || command=="turtlegit-single-commit" || command=="turtlegit-finder-status" {
            guard operands.isEmpty else{try refuse("Private diff command requires only a stdin request")}
        }else if command == "reset" || command == "revert" {
            guard operands.count==1,!operands[0].isEmpty,!operands[0].contains("\0"),operands[0].utf8.count<=1_048_576,command != "revert" || revertNoCommit else{try refuse("Reset/Revert requires one explicit revision; Revert requires --no-commit")};revision=operands[0]
            guard environment["TURTLEGIT_RESET_RECYCLE_DIRECTORY"] == nil || resetMode==3 else{try refuse("Recycle exchange requires Hard Reset")}
        }else if command == "clone"{
            guard operands.count==2,!(bare && noCheckout),!(bare && recursive),origin?.isEmpty != true,branch?.isEmpty != true else{try refuse("Invalid clone option combination")}
            source=operands[0];destination=operands[1]
            guard !source.isEmpty,!destination.isEmpty else{try refuse("Missing clone source or destination")}
        }else if command == "add"{
            guard addStdin,addModeSpecified,operands.isEmpty,let privateIndex,privateIndex.hasPrefix("/"),!privateIndex.contains("\0"),!addModeOnly || addMode != 0 else{try refuse("Add requires an explicit private index, mode and literal stdin packet")}
        }else if command == "turtlegit-prepare-index"{
            guard addStdin,operands.isEmpty,let privateIndex,privateIndex.hasPrefix("/"),!privateIndex.contains("\0") else{try refuse("Commit preparation requires an explicit private index and stdin plan")}
        }else if command == "cat-file"{
            guard filters,let path=blobPath,!path.isEmpty,!path.contains("\0"),!path.hasPrefix("/"),(path == "." || !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0 == ".." || $0 == "." || $0.isEmpty})),operands.count==1,operands[0].utf8.count==40,operands[0].utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{try refuse("Filtered blob requires one full object ID and literal repository-relative path")};blobOID=operands[0]
        }else if command == "ls-remote"{
            guard operands.count==1,!operands[0].isEmpty else{try refuse("Remote listing requires exactly one remote")};remote=operands[0]
        }else if command == "push"{
            guard operands.count>=2,operands.count<=4097,!operands[0].isEmpty else{try refuse("Remote deletion requires a remote and explicit deletion refspecs")}
            remote=operands[0];refspecs=Array(operands.dropFirst())
            guard refspecs.allSatisfy({$0.hasPrefix(":refs/") && !$0.dropFirst().contains(":") && !$0.contains("*") && !$0.contains("\0")}) else{try refuse("This helper accepts deletion-only push refspecs")}
        }else{
            guard !all || operands.isEmpty else{try refuse("--all cannot include a remote or refspec")}
            if let first=operands.first{
                remote=first;refspecs=Array(operands.dropFirst())
                if !sourceFetch {refspecs=refspecs.map{value in
                    let parts=value.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
                    guard parts.count==2 else{return value};let target=String(parts[1]);return String(parts[0])+":"+((target.hasPrefix("remotes/") || target.hasPrefix("heads/") || target.hasPrefix("tags/")) ? "refs/"+target:target)
                }}
            }
            guard !remote.isEmpty,refspecs.count<=4096 else{try refuse("Invalid fetch remote/refspec")}
            // FetchProgressCommand owns one raw CString refspec. Do not turn
            // its persistent configuration entry into a rewritten CLI spec.
            guard !sourceFetch || refspecs.count<=1 else{try refuse("Source Fetch accepts at most one refspec")}
        }
    }
}

struct PrivateDiffRequest {
    struct Unified:Decodable {let version:Int;let old:String;let new:String;let paths:[String];let noPrefix:Bool}
    struct History:Decodable {let version:Int;let revision:String;let simple:Bool;let threshold:UInt32}
    let unified:Unified?,history:History?
    var batch:[History]=[]
    static func fullOID(_ value:String)->Bool {value.utf8.count==40 && value.utf8.allSatisfy{(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}}
    init(command:String)throws {
        var data=Data()
        while let part=try FileHandle.standardInput.read(upToCount:65536),!part.isEmpty {guard !cancelled(),part.count<=2_097_152-data.count else{try refuse("Diff request exceeds bounds or was cancelled")};data.append(part)}
        guard let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{try refuse("Invalid diff request")}
        if command == "turtlegit-unified-diff" {
            guard Set(fields.keys)==Set(["version","old","new","paths","noPrefix"]) else{try refuse("Invalid unified diff request fields")}
            let value=try JSONDecoder().decode(Unified.self,from:data)
            guard value.version==1,(!value.old.isEmpty || !value.new.isEmpty),[value.old,value.new].allSatisfy({$0.isEmpty || $0=="WORKTREE" || Self.fullOID($0)}),value.paths.count<=100_000,
                  value.paths.allSatisfy({!$0.isEmpty && !$0.contains("\0") && $0.utf8.count<=1_048_576 && !$0.hasPrefix("/") && !$0.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0==".."})}) else{try refuse("Invalid unified diff endpoints or paths")}
            unified=value;history=nil
        }else if command == "turtlegit-history-diff-batch" {
            guard Set(fields.keys)==Set(["version","revisions","simple","threshold"]),let version=fields["version"] as? Int,version==1,
                  let revisions=fields["revisions"] as? [String],!revisions.isEmpty,revisions.count<=128,revisions.allSatisfy(Self.fullOID),
                  let simple=fields["simple"] as? Bool,let threshold=fields["threshold"] as? UInt32,threshold<=100 else{try refuse("Invalid batch history request")}
            batch=revisions.map{History(version:1,revision:$0,simple:simple,threshold:threshold)};unified=nil;history=batch.first
        }else {
            guard Set(fields.keys)==Set(["version","revision","simple","threshold"]) else{try refuse("Invalid history diff request fields")}
            let value=try JSONDecoder().decode(History.self,from:data)
            guard value.version==1,Self.fullOID(value.revision),value.threshold<=100 else{try refuse("Invalid history diff request")}
            unified=nil;history=value
        }
    }
}

struct PrivateLocalReferenceRequest {
    static let commands = ["turtlegit-local-refs", "turtlegit-containing-refs", "turtlegit-delete-local-ref", "turtlegit-ref-names","turtlegit-checkout-refs","turtlegit-configured-remotes","turtlegit-tag-object","turtlegit-tag-objects"]
    struct Contains: Decodable {let version:Int;let revision:String;let includeTags:Bool;let includeLocal:Bool;let includeRemote:Bool}
    struct Delete: Decodable {let version:Int;let reference:String;let expectedOID:String;let expectedSymbolicTarget:String?}
    let operation:String
    let scope:Int32
    let contains:Contains?
    let deletion:Delete?
    var tagObject:String?=nil
    var tagObjects:[String]=[]
    static func name(_ value:String)->Bool {
        value.hasPrefix("refs/") && value.utf8.count<=1_048_576 && !value.utf8.contains(where:{$0<32 || $0==127}) &&
        !value.contains(" ") && !value.contains("..") && !value.contains("@{") && !value.contains(where:{"~^:?*[\\".contains($0)}) &&
        !value.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock")}) && !value.hasSuffix(".")
    }
    init(command:String)throws {
        var data=Data()
        while let part=try FileHandle.standardInput.read(upToCount:65_536),!part.isEmpty {
            guard !cancelled(),part.count<=2_097_152-data.count else{try refuse("Local reference request exceeds bounds or was cancelled")};data.append(part)
        }
        guard let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any],let version=fields["version"] as? NSNumber,CFGetTypeID(version) != CFBooleanGetTypeID(),version.intValue==1,version.doubleValue==1 else{try refuse("Invalid local reference request")}
        switch command {
        case "turtlegit-local-refs":
            guard Set(fields.keys)==Set(["version","scope"]),let value=fields["scope"] as? String,let index=["all","heads","headsAndTags","excludingTags","remotes","labels"].firstIndex(of:value) else{try refuse("Invalid local reference request fields")}
            scope=Int32(index);operation="inventory";contains=nil;deletion=nil
        case "turtlegit-checkout-refs":
            guard Set(fields.keys)==Set(["version"]) else{try refuse("Invalid checkout catalog request")}
            scope=0;operation="choices";contains=nil;deletion=nil
        case "turtlegit-configured-remotes":
            guard Set(fields.keys)==Set(["version"]) else{try refuse("Invalid remote catalog request")}
            scope=0;operation="remotes";contains=nil;deletion=nil
        case "turtlegit-tag-objects":
            guard Set(fields.keys)==Set(["version","oids"]),let oids=fields["oids"] as? [String],!oids.isEmpty,oids.count<=128,oids.allSatisfy(PrivateDiffRequest.fullOID) else{try refuse("Invalid tag objects request")}
            scope=0;operation="tagObjects";contains=nil;deletion=nil;tagObjects=oids
        case "turtlegit-tag-object":
            guard Set(fields.keys)==Set(["version","oid"]),let oid=fields["oid"] as? String,PrivateDiffRequest.fullOID(oid) else{try refuse("Invalid tag object request")}
            scope=0;operation="tagObject";contains=nil;deletion=nil;tagObject=oid
        case "turtlegit-ref-names":
            guard Set(fields.keys)==Set(["version"]) else{try refuse("Invalid reference names request fields")}
            scope=0;operation="names";contains=nil;deletion=nil
        case "turtlegit-containing-refs":
            guard Set(fields.keys)==Set(["version","revision","includeTags","includeLocal","includeRemote"]) else{try refuse("Invalid containing reference request fields")}
            let value=try JSONDecoder().decode(Contains.self,from:data)
            guard value.version==1,PrivateDiffRequest.fullOID(value.revision) else{try refuse("Invalid containing reference object ID")}
            scope=0;operation="contains";contains=value;deletion=nil
        default:
            guard Set(fields.keys)==Set(["version","reference","expectedOID","expectedSymbolicTarget"]) else{try refuse("Invalid local deletion request fields")}
            let value=try JSONDecoder().decode(Delete.self,from:data)
            guard value.version==1,Self.name(value.reference),PrivateDiffRequest.fullOID(value.expectedOID),value.expectedSymbolicTarget.map(Self.name) ?? true else{try refuse("Invalid local deletion identity")}
            scope=0;operation="delete";contains=nil;deletion=value
        }
    }
}

struct PrivateFinderRequest: Decodable {
    let version:Int, full:Bool, caseSensitive:Bool, contentCheckLimitKiB:UInt32
    static func read() throws -> Self {
        var data=Data()
        while let bytes=try FileHandle.standardInput.read(upToCount:4096),!bytes.isEmpty {
            guard !cancelled(),data.count+bytes.count<=4096 else {try refuse("Finder policy request exceeds bounds")};data.append(bytes)
        }
        guard let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(fields.keys)==["version","full","caseSensitive","contentCheckLimitKiB"] else {try refuse("Invalid Finder policy fields")}
        let value=try JSONDecoder().decode(Self.self,from:data);guard value.version==1 else {try refuse("Invalid Finder policy version")};return value
    }
}
struct PrivateInspectionRequest {
    static let commands=["turtlegit-merge-base","turtlegit-check-clean","turtlegit-check-conflicts","turtlegit-conflict-info"]
    struct MergeBase:Decodable {let version:Int;let from:String;let to:String}
    struct Clean:Decodable {let version:Int;let stagedOK:Bool}
    struct Conflicts:Decodable {let version:Int}
    struct ConflictInfo:Decodable {let version:Int;let paths:[String]}
    let operation:String
    let mergeBase:MergeBase?
    let clean:Clean?
    let paths:[String]
    static func literalPath(_ value:String)->Bool {
        !value.isEmpty && value.utf8.count<=1_048_576 && !value.contains("\0") && !value.hasPrefix("/") &&
        !value.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".."})
    }
    init(command:String)throws {
        var data=Data()
        while let part=try FileHandle.standardInput.read(upToCount:65_536),!part.isEmpty {
            guard !cancelled(),part.count<=2_097_152-data.count else{try refuse("Inspection request exceeds bounds or was cancelled")};data.append(part)
        }
        guard let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{try refuse("Invalid inspection request")}
        switch command {
        case "turtlegit-merge-base":
            guard Set(fields.keys)==Set(["version","from","to"]) else{try refuse("Invalid merge-base request fields")}
            let value=try JSONDecoder().decode(MergeBase.self,from:data)
            guard value.version==1,PrivateDiffRequest.fullOID(value.from),PrivateDiffRequest.fullOID(value.to) else{try refuse("Invalid inspection object IDs")}
            operation="mergeBase";mergeBase=value;clean=nil;paths=[]
        case "turtlegit-check-clean":
            guard Set(fields.keys)==Set(["version","stagedOK"]) else{try refuse("Invalid clean inspection fields")}
            let value=try JSONDecoder().decode(Clean.self,from:data)
            guard value.version==1 else{try refuse("Invalid clean inspection version")}
            operation="clean";mergeBase=nil;clean=value;paths=[]
        case "turtlegit-check-conflicts":
            guard Set(fields.keys)==Set(["version"]) else{try refuse("Invalid conflict-presence fields")}
            let value=try JSONDecoder().decode(Conflicts.self,from:data)
            guard value.version==1 else{try refuse("Invalid conflict-presence version")}
            operation="conflicts";mergeBase=nil;clean=nil;paths=[]
        default:
            guard Set(fields.keys)==Set(["version","paths"]) else{try refuse("Invalid conflict-info fields")}
            let value=try JSONDecoder().decode(ConflictInfo.self,from:data)
            guard value.version==1,value.paths.count<=100_000,value.paths.allSatisfy(Self.literalPath),Set(value.paths.map{Data($0.utf8)}).count==value.paths.count else{try refuse("Invalid requested literal conflict paths")}
            operation="conflictInfo";mergeBase=nil;clean=nil;paths=value.paths
        }
    }
}

struct PrivateSingleCommitRequest:Decodable {
    let version:Int
    let revision:String
    let allowTree:Bool
    static func read()throws->Self {
        var data=Data()
        while let part=try FileHandle.standardInput.read(upToCount:65_536),!part.isEmpty {
            guard !cancelled(),part.count<=2_097_152-data.count else{try refuse("Single-commit request exceeds bounds or was cancelled")};data.append(part)
        }
        guard let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(fields.keys)==Set(["version","revision","allowTree"]) else{try refuse("Invalid single-commit request fields")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.version==1,!value.revision.isEmpty,!value.revision.contains("\0"),value.revision.utf8.count<=1_048_576 else{try refuse("Invalid single-commit revision or version")}
        return value
    }
}

final class CallbackContext{
    let directory:String,configs:[String]
    var httpConfiguration:HTTPConfiguration?
    init(directory:String,configs:[String]){
        self.directory=directory;self.configs=configs
        if let path=environment["TURTLEGIT_LIBGIT2_CERTIFICATE_ACCEPTANCES"]{
            let fd=open(path,O_RDWR|O_APPEND|O_NOFOLLOW|O_CLOEXEC)
            if fd>=0{let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);var info=stat()
                if fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==geteuid(),info.st_mode&0o777==0o600,info.st_nlink==1,info.st_size>=0,info.st_size<=GitRemoteCertificateAcceptance.maximumBytes{
                    do{
                        // A fresh source process legitimately seeds an empty
                        // exchange. Successful EOF is not a failed file read.
                        let data=try handle.read(upToCount:GitRemoteCertificateAcceptance.maximumBytes+1) ?? Data()
                        let values=try GitRemoteCertificateAcceptance.decode(data)
                        acceptanceHandle=handle;acceptanceCount=values.count;accepted=Set(values.map(\.key))
                    }catch{try? handle.close()}
                }else{try? handle.close()}
            }
        }
    }
    var acceptanceHandle:FileHandle?,acceptanceCount=0
    private let notificationLock=NSLock()
    private var notificationBytes=0,notificationCount=0,notificationFailed=false
    func notificationString(_ value:UnsafePointer<CChar>?)throws->String {
        guard let value else{try refuse("Invalid transfer metadata")}
        let count=strnlen(value,1_048_577)
        guard count<=1_048_576,let text=String(bytes:UnsafeBufferPointer(start:UnsafeRawPointer(value).assumingMemoryBound(to:UInt8.self),count:count),encoding:.utf8) else{try refuse("Invalid transfer metadata")}
        return text
    }
    func transferNotification(_ body:()throws->[String:Any]) {
        notificationLock.lock();defer{notificationLock.unlock()};guard !notificationFailed else{return}
        do {
            guard !cancelled() else{return}
            let data=try JSONSerialization.data(withJSONObject:body(),options:[.sortedKeys]),frame=Data(("TurtleGit Transfer v1:"+data.base64EncodedString()+"\n").utf8)
            guard frame.count<=2*1024*1024,notificationCount<100_000,frame.count<=64*1024*1024-notificationBytes else{try refuse("Transfer metadata budget exceeded")}
            try FileHandle.standardOutput.write(contentsOf:frame);notificationCount+=1;notificationBytes+=frame.count
        } catch {
            notificationFailed=true
            // Fixed invalid framing causes one local metadata issue after the
            // real operation settles, without aborting an already applied Git
            // mutation or exposing unsupported filename bytes in diagnostics.
            try? FileHandle.standardOutput.write(contentsOf:Data("TurtleGit Transfer unavailable\n".utf8))
        }
    }
    private var recycleID:UInt64=0
    func resetNotification(_ body:()throws->[String:Any],required:Bool=false)->Bool {
        notificationLock.lock();defer{notificationLock.unlock()}
        if notificationFailed && !required{return true}
        do {
            guard !cancelled() else{try refuse("Reset cancelled")}
            let data=try JSONSerialization.data(withJSONObject:body(),options:[.sortedKeys])
            let frame=Data(("TurtleGit Reset v1:"+data.base64EncodedString()+"\n").utf8)
            guard frame.count<=2*1024*1024,notificationCount<100_000,frame.count<=64*1024*1024-notificationBytes else{try refuse("Reset metadata budget exceeded")}
            try FileHandle.standardOutput.write(contentsOf:frame);notificationCount+=1;notificationBytes+=frame.count;return true
        } catch {
            if !notificationFailed {try? FileHandle.standardOutput.write(contentsOf:Data("TurtleGit Reset unavailable\n".utf8))}
            notificationFailed=true;return !required
        }
    }
    func resetFile(_ pointer:UnsafePointer<CChar>?)throws {
        func literalPath()throws->String {
            let path=try notificationString(pointer)
            guard !path.isEmpty,!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".." || $0.lowercased()==".git"}) else{try refuse("Invalid Reset path")}
            return path
        }
        guard let exchange=environment["TURTLEGIT_RESET_RECYCLE_DIRECTORY"] else {
            _=resetNotification({["kind":"file","path":try literalPath()]});return
        }
        let path=try literalPath()
        do {
            let fd=open(exchange,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else{try refuse("Cannot open Reset recycle exchange")};defer{close(fd)}
            var directoryInfo=stat()
            guard fstat(fd,&directoryInfo)==0,(directoryInfo.st_mode&S_IFMT)==S_IFDIR,directoryInfo.st_uid==geteuid(),directoryInfo.st_mode&0o777==0o700 else{try refuse("Unsafe Reset recycle exchange")}
            let target=URL(fileURLWithPath:directory,isDirectory:true).appendingPathComponent(path).path
            var witness=stat();let found=lstat(target,&witness)
            guard found==0 || errno==ENOENT else{try refuse("Cannot inspect Reset recycle target")}
            recycleID += 1;let id=recycleID
            var request:[String:Any]=["kind":"recycle","id":id,"path":path,"exists":found==0]
            if found==0 {request["device"]=UInt64(UInt32(bitPattern:witness.st_dev));request["inode"]=UInt64(witness.st_ino);request["mode"]=UInt32(witness.st_mode)}
            guard resetNotification({request},required:true) else{try refuse("Cannot deliver Reset recycle request")}
            let deadline=DispatchTime.now().uptimeNanoseconds+120_000_000_000
            while true {
                var abortInfo=stat(),currentDirectory=stat()
                guard !cancelled(),fstatat(fd,"abort",&abortInfo,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT,
                      lstat(exchange,&currentDirectory)==0,currentDirectory.st_dev==directoryInfo.st_dev,currentDirectory.st_ino==directoryInfo.st_ino else{try refuse("Reset recycle exchange cancelled or replaced")}
                let ack=openat(fd,"\(id).ack",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
                if ack>=0 {
                    let handle=FileHandle(fileDescriptor:ack,closeOnDealloc:true);defer{try? handle.close()}
                    var info=stat()
                    guard fstat(ack,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==geteuid(),info.st_mode&0o777==0o600,info.st_nlink==1,info.st_size>0,info.st_size<=4096 else{try refuse("Unsafe Reset recycle acknowledgment")}
                    let data=try handle.read(upToCount:4097) ?? Data()
                    struct Acknowledgment:Decodable {let id:UInt64;let accepted:Bool}
                    guard data.count==Int(info.st_size),data.count<=4096,let fields=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(fields.keys)==Set(["id","accepted"]) else{try refuse("Invalid Reset recycle acknowledgment")}
                    let value=try JSONDecoder().decode(Acknowledgment.self,from:data)
                    guard value.id==id,value.accepted,!cancelled(),fstatat(fd,"abort",&abortInfo,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else{try refuse("Reset recycle request refused")}
                    var replacement=stat()
                    guard lstat(target,&replacement) != 0,errno==ENOENT else{try refuse("Reset recycle target was not removed or was replaced")}
                    break
                }
                guard errno==ENOENT,DispatchTime.now().uptimeNanoseconds<deadline else{try refuse("Reset recycle acknowledgment unavailable")}
                usleep(10_000)
            }
        }
        _=resetNotification({["kind":"file","path":path]})
    }
    private var singleCommitCount=0,singleCommitBytes=0
    func singleCommitRecord(_ object:[String:Any],row:Bool=false)throws {
        guard !cancelled(),singleCommitCount<=128 else{try refuse("Single-commit request cancelled or exceeds bounds")}
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let frame=Data(("TurtleGit SingleCommit v1:"+data.base64EncodedString()+"\n").utf8)
        guard frame.count<=2_097_152,frame.count<=67_108_864-singleCommitBytes else{try refuse("Single-commit output exceeds bounds")}
        try FileHandle.standardOutput.write(contentsOf:frame);singleCommitBytes+=frame.count
        if row{singleCommitCount+=1}
    }
    private func singleCommitData(_ pointer:UnsafePointer<CChar>?,limit:Int)throws->Data {
        guard let pointer else{try refuse("Missing single-commit metadata")}
        let size=strnlen(pointer,limit+1)
        guard size<=limit else{try refuse("Single-commit metadata exceeds bounds")}
        return Data(bytes:pointer,count:size)
    }
    func singleCommit(_ pointer:UnsafePointer<tg_single_commit>?)throws {
        guard let value=pointer?.pointee else{try refuse("Missing single-commit result")}
        let oid=try notificationString(value.oid)
        guard PrivateDiffRequest.fullOID(oid) else{try refuse("Invalid single-commit object ID")}
        if value.object_type==1 {
            try singleCommitRecord(["kind":"tree","oid":oid,"objectType":"tree"],row:true);return
        }
        guard value.object_type==0,value.parent_count<=4096,value.parent_count==0 || value.parents != nil else{try refuse("Invalid single-commit type or parent count")}
        let tree=try notificationString(value.tree)
        let parents=try (0..<value.parent_count).map{try notificationString(value.parents![$0])}
        guard PrivateDiffRequest.fullOID(tree),parents.allSatisfy(PrivateDiffRequest.fullOID) else{try refuse("Invalid single-commit tree or parents")}
        let encoding=try value.encoding.map{try singleCommitData($0,limit:1_048_576)}
        let fields:[(String,Data)]=[
            ("authorName",try singleCommitData(value.author_name,limit:1_048_576)),
            ("authorEmail",try singleCommitData(value.author_email,limit:1_048_576)),
            ("committerName",try singleCommitData(value.committer_name,limit:1_048_576)),
            ("committerEmail",try singleCommitData(value.committer_email,limit:1_048_576)),
            ("message",try singleCommitData(value.message,limit:16_777_216))]
        var metadata:[String:Any]=["kind":"commit","oid":oid,"objectType":"commit","tree":tree,"parents":parents,
            "authorTime":value.author_time,"authorOffset":value.author_offset,"committerTime":value.committer_time,"committerOffset":value.committer_offset]
        metadata["encodingBytes"]=encoding.map{$0.count as Any} ?? NSNull()
        for (name,data) in fields{metadata[name+"Bytes"]=data.count}
        try singleCommitRecord(metadata,row:true)
        let payloads=encoding.map{[("encoding",$0)]} ?? []
        for (name,data) in payloads+fields {
            for start in stride(from:0,to:data.count,by:524_288) {
                guard !cancelled() else{try refuse("Single-commit request cancelled")}
                let part=data.subdata(in:start..<min(data.count,start+524_288))
                try singleCommitRecord(["kind":"bytes","field":name,"data":part.base64EncodedString()],row:true)
            }
        }
    }
    func finishSingleCommit()throws {try singleCommitRecord(["kind":"end","count":singleCommitCount])}
    private var finderCount=0,finderBytes=0,finderHeader=false
    func finderRecord(_ object:[String:Any]) throws {
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let frame=Data(("TurtleGit Finder v1:"+data.base64EncodedString()+"\n").utf8)
        guard !cancelled(),frame.count<=2_097_152,finderBytes+frame.count<=67_108_864 else {try refuse("Finder status output exceeds bounds")}
        finderBytes+=frame.count;FileHandle.standardOutput.write(frame)
    }
    func finder(path:UnsafePointer<CChar>?,state:Int32,skip:Int32,assume:Int32) throws {
        if let path {
            guard finderHeader,finderCount<200_000,let name=String(validatingCString:path),name.utf8.count<=1_048_576 else {try refuse("Invalid Finder path")}
            let literal=name.hasSuffix("/") ? String(name.dropLast()):name
            guard PrivateInspectionRequest.literalPath(literal),(0...6).contains(state) else {try refuse("Invalid Finder status")}
            try finderRecord(["kind":"entry","path":literal,"state":state,"skipWorktree":skip != 0,"assumeUnchanged":assume != 0]);finderCount+=1
        }else {
            guard !finderHeader,(0...1).contains(state) else {try refuse("Invalid Finder header")};finderHeader=true
            try finderRecord(["kind":"header","caseSensitive":state != 0])
        }
    }
    func finishFinder() throws {guard finderHeader else{try refuse("Missing Finder status header")};try finderRecord(["kind":"end","count":finderCount])}
    private var inspectionCount=0,inspectionBytes=0
    func inspectionRecord(_ object:[String:Any],row:Bool=false)throws {
        guard !cancelled(),inspectionCount<=100_000 else{try refuse("Inspection cancelled or exceeds bounds")}
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let frame=Data(("TurtleGit Inspection v1:"+data.base64EncodedString()+"\n").utf8)
        guard frame.count<=2_097_152,frame.count<=67_108_864-inspectionBytes else{try refuse("Inspection output exceeds bounds")}
        try FileHandle.standardOutput.write(contentsOf:frame);inspectionBytes+=frame.count
        if row{inspectionCount+=1}
    }
    func inspection(_ pointer:UnsafePointer<tg_inspection>?)throws {
        guard let value=pointer?.pointee,inspectionCount<100_000 else{try refuse("Invalid inspection result")}
        switch value.kind {
        case 0:
            let base=try value.base.map{try notificationString($0)}
            guard base.map(PrivateDiffRequest.fullOID) ?? true,(value.value==0 || value.value==1),base != nil || value.value==0 else{try refuse("Invalid merge-base result")}
            try inspectionRecord(["kind":"mergeBase","base":base.map{$0 as Any} ?? NSNull(),"fastForward":value.value != 0],row:true)
        case 1,2:
            guard value.value==0 || value.value==1 else{try refuse("Invalid inspection decision")}
            let key=value.kind==1 ? "clean":"conflicts"
            try inspectionRecord(["kind":key,key:value.value != 0],row:true)
        case 3:
            let path=try notificationString(value.path)
            guard PrivateInspectionRequest.literalPath(path),value.stage_count<=3,value.stage_count==0 || value.stages != nil else{try refuse("Invalid conflict inspection path/stages")}
            var stages=[[String:Any]](),previous:Int32=0
            for i in 0..<value.stage_count {
                let stage=value.stages![i],oid=try notificationString(value.stages![i].oid)
                guard stage.number>previous,stage.number<=3,[UInt32(0o100644),0o100755,0o120000,0o160000].contains(stage.mode),PrivateDiffRequest.fullOID(oid) else{try refuse("Invalid conflict stage")}
                previous=stage.number;stages.append(["number":stage.number,"mode":stage.mode,"oid":oid])
            }
            try inspectionRecord(["kind":"conflict","path":path,"stages":stages],row:true)
        default:try refuse("Unknown inspection result")
        }
    }
    func finishInspection()throws {try inspectionRecord(["kind":"end","count":inspectionCount])}
    var localReferenceOperation=""
    private var localReferenceCount=0,localReferenceBytes=0
    func localReferenceRecord(_ object:[String:Any],row:Bool=false)throws {
        guard !cancelled(),localReferenceCount<=100_000 else{try refuse("Local reference operation cancelled or exceeds bounds")}
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let frame=Data(("TurtleGit LocalRefs v1:"+data.base64EncodedString()+"\n").utf8)
        guard frame.count<=2_097_152,frame.count<=67_108_864-localReferenceBytes else{try refuse("Local reference output exceeds bounds")}
        try FileHandle.standardOutput.write(contentsOf:frame);localReferenceBytes+=frame.count
        if row {localReferenceCount+=1}
    }
    func localReference(_ pointer:UnsafePointer<tg_local_reference>?)throws {
        guard let row=pointer?.pointee,localReferenceCount<100_000 else{try refuse("Invalid local reference row")}
        let name=try notificationString(row.name)
        guard localReferenceOperation=="remotes" ? (!name.isEmpty && !name.utf8.contains(0)) : PrivateLocalReferenceRequest.name(name) else{try refuse("Invalid local reference name")}
        if localReferenceOperation=="choices" {
            let symbolic=try row.symbolic_target.map{try notificationString($0)}
            guard symbolic.map(PrivateLocalReferenceRequest.name) ?? true else{try refuse("Invalid symbolic target")}
            try localReferenceRecord(["kind":"choice","name":name,"symbolicTarget":symbolic.map{$0 as Any} ?? NSNull()],row:true);return
        }
        if localReferenceOperation=="contains" || localReferenceOperation=="names" || localReferenceOperation=="remotes" {
            try localReferenceRecord(["kind":"contains","name":name],row:true);return
        }
        let oid=try notificationString(row.oid),type=try notificationString(row.object_type)
        guard PrivateDiffRequest.fullOID(oid),["commit","tag","tree","blob"].contains(type) else{try refuse("Invalid local reference object")}
        let symbolic=try row.symbolic_target.map{try notificationString($0)}
        guard symbolic.map(PrivateLocalReferenceRequest.name) ?? true else{try refuse("Invalid symbolic reference target")}
        var subject=try notificationString(row.subject)
        if type=="tag",let newline=subject.firstIndex(of:"\n"){subject=String(subject[..<newline])}
        let authorName=try notificationString(row.author_name),authorEmail=try notificationString(row.author_email)
        let committerName=try notificationString(row.committer_name),committerEmail=try notificationString(row.committer_email)
        let upstream=try row.upstream.map{try notificationString($0)}
        var value:[String:Any] = ["kind":"reference","name":name,"oid":oid,"objectType":type,"subject":subject,
            "authorName":authorName,"authorEmail":authorEmail,"committerName":committerName,"committerEmail":committerEmail]
        let peeled=try row.peeled_oid.map{try notificationString($0)}
        value["peeledOID"]=peeled.map{$0 as Any} ?? NSNull()
        value["symbolicTarget"]=symbolic.map{$0 as Any} ?? NSNull()
        value["upstream"]=upstream.map{$0 as Any} ?? NSNull()
        value["authorTime"]=row.has_author != 0 ? row.author_time as Any:NSNull()
        value["committerTime"]=row.has_committer != 0 ? row.committer_time as Any:NSNull()
        try localReferenceRecord(value,row:true)
    }
    func finishLocalReferences(_ request:PrivateLocalReferenceRequest)throws {
        if let deletion=request.deletion {
            try localReferenceRecord(["kind":"deleted","name":deletion.reference,"oid":deletion.expectedOID,"symbolicTarget":deletion.expectedSymbolicTarget.map{$0 as Any} ?? NSNull()],row:true)
        }
        try localReferenceRecord(["kind":"end","count":localReferenceCount])
    }
    var historySimple=false
    private var historyCount=0,historyBytes=0,historyFailed=false
    private var historyPaths:[Data:String]=[:]
    private var historyPathBytes=0
    func historyRecord(_ object:[String:Any])throws {
        guard !cancelled(),!historyFailed else{try refuse("History diff cancelled or failed")}
        let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
        let frame=Data(("TurtleGit HistoryDiff v1:"+data.base64EncodedString()+"\n").utf8)
        guard frame.count<=2_097_152,historyCount<100_000,frame.count<=67_108_864-historyBytes else{historyFailed=true;try refuse("History diff output exceeds bounds")}
        try FileHandle.standardOutput.write(contentsOf:frame);historyCount+=1;historyBytes+=frame.count
    }
    func historyHeader(_ revision:UnsafePointer<CChar>?,parents:UnsafePointer<UnsafePointer<CChar>?>?,count:Int)throws {
        guard count>=0,count<=4096,count==0 || parents != nil else{try refuse("Invalid history parent metadata")}
        let revision=try notificationString(revision)
        let values=try (0..<count).map{try notificationString(parents![$0])}
        guard PrivateDiffRequest.fullOID(revision),values.allSatisfy(PrivateDiffRequest.fullOID) else{try refuse("Invalid history object IDs")}
        try historyRecord(["kind":"header","revision":revision,"parents":values])
    }
    func historyDelta(_ pointer:UnsafePointer<tg_history_delta>?)throws {
        guard let value=pointer?.pointee else{try refuse("Missing history delta")}
        let path=try notificationString(value.path)
        guard !path.isEmpty,!path.contains("\0"),!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".."}) else{try refuse("Invalid history path")}
        if historySimple {
            let key=Data(path.utf8)
            guard historyPaths.count<100_000 || historyPaths[key] != nil,key.count<=67_108_864-historyPathBytes else{try refuse("History simple paths exceed bounds")}
            if historyPaths[key]==nil {historyPaths[key]=path;historyPathBytes+=key.count};return
        }
        let statuses=[1:"A",2:"D",3:"M",4:"R",5:"C",8:"T"]
        guard let status=statuses[Int(value.status)] else{try refuse("Unsupported history delta status")}
        let oldPath=try notificationString(value.old_path),oldOID=try notificationString(value.old_hash),newOID=try notificationString(value.new_hash)
        guard PrivateDiffRequest.fullOID(oldOID),PrivateDiffRequest.fullOID(newOID) else{try refuse("Invalid history delta object IDs")}
        let none=NSNull()
        try historyRecord(["kind":"delta","parentIndex":value.parent_index,"status":status,"path":path,"oldPath":oldPath.utf8.elementsEqual(path.utf8) ? none:oldPath as Any,"oldOID":oldOID,"newOID":newOID,"oldMode":value.old_mode,"newMode":value.new_mode,"binary":value.binary != 0,"added":value.counts_known != 0 ? UInt64(value.additions) as Any:none,"deleted":value.counts_known != 0 ? UInt64(value.deletions) as Any:none])
    }
    func resetHistory(){historyCount=0;historyPaths=[:];historyPathBytes=0}
    func finishHistory()throws {
        if historySimple {
            let paths=historyPaths.values.sorted{$0.utf16.lexicographicallyPrecedes($1.utf16)}
            historyPaths=[:]
            for path in paths {try historyRecord(["kind":"path","path":path])}
        }
        // Exclude the header; end is a framing receipt, not a result row.
        try historyRecord(["kind":"end","count":max(0,historyCount-1)])
    }
    var currentURL="",credentialRealm=Data(),credentials:(String,String)?,credentialUses=0,prompts=0
    var accepted:Set<Data>=[]
    func externalFilter(command:String,path:String,directory:String,index privateIndex:String?,input:Data)throws->Data{
        guard !cancelled() else{try refuse("Filter cancelled")}
        // Adapt source %f expansion to POSIX shell quoting; path bytes never
        // become shell syntax. %% remains one literal percent.
        let quoted="'"+path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        var expanded="",index=command.startIndex
        while index<command.endIndex{let c=command[index];index=command.index(after:index)
            if c != "%"{expanded.append(c);continue}
            guard index<command.endIndex else{expanded.append("%");break}
            let token=command[index];index=command.index(after:index)
            if token == "f"{expanded+=quoted}else if token == "%"{expanded.append("%")}
        }
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-smudge-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temporary)}
        var handles:[FileHandle]=[];defer{for handle in handles{try? handle.close()}}
        for name in ["input","output","error"]{let fd=open(temporary.appendingPathComponent(name).path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600);guard fd>=0 else{try refuse("Cannot create private filter stream")};handles.append(FileHandle(fileDescriptor:fd,closeOnDealloc:true))}
        try handles[0].write(contentsOf:input);try handles[0].seek(toOffset:0)
        var options=callbacks(self)
        var childEnvironment=environment
        // The source repository, not an inherited caller GIT_DIR/index/object
        // override, owns checkout (especially recursive submodule/LFS smudges).
        for key in ["TURTLEGIT_LIBGIT2_CERTIFICATE_ACCEPTANCES","GIT_DIR","GIT_COMMON_DIR","GIT_WORK_TREE","GIT_INDEX_FILE","GIT_OBJECT_DIRECTORY","GIT_ALTERNATE_OBJECT_DIRECTORIES","GIT_GRAFT_FILE","GIT_SHALLOW_FILE","GIT_PREFIX","GIT_INTERNAL_SUPER_PREFIX","GIT_NAMESPACE","GIT_QUARANTINE_PATH","GIT_IMPLICIT_WORK_TREE"]{childEnvironment.removeValue(forKey:key)}
        for key in Array(childEnvironment.keys) where key == "GIT_CONFIG_PARAMETERS" || key == "GIT_CONFIG_COUNT" || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_"){childEnvironment.removeValue(forKey:key)}
        if let privateIndex{childEnvironment["GIT_INDEX_FILE"]=privateIndex}
        var search:[String]=[]
        if let git=environment["TURTLEGIT_LIBGIT2_GIT_EXECUTABLE"],git.hasPrefix("/"){search.append(URL(fileURLWithPath:git).deletingLastPathComponent().path)}
        if let exec=environment["GIT_EXEC_PATH"],exec.hasPrefix("/"){search.append(exec)}
        search.append(environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin");childEnvironment["PATH"]=search.joined(separator:":")
        childEnvironment["GIT_CONFIG_COUNT"]=String(configs.count)
        for (index,entry) in configs.enumerated(){let parts=entry.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false);childEnvironment["GIT_CONFIG_KEY_\(index)"]=String(parts[0]);childEnvironment["GIT_CONFIG_VALUE_\(index)"]=String(parts[1])}
        let status=withStrings(childEnvironment.map{$0.key+"="+$0.value}){values,count in
            var env=Array(UnsafeBufferPointer(start:values,count:count));env.append(nil)
            return env.withUnsafeBufferPointer{tg_run_filter(expanded,directory,handles[0].fileDescriptor,handles[1].fileDescriptor,handles[2].fileDescriptor,$0.baseAddress,&options)}
        }
        try handles[2].seek(toOffset:0)
        while let diagnostics=try handles[2].read(upToCount:65_536),!diagnostics.isEmpty{FileHandle.standardError.write(diagnostics)}
        guard status==0,!cancelled() else{try refuse("External smudge filter failed or was cancelled")}
        try handles[1].seek(toOffset:0);return try handles[1].readToEnd() ?? Data()
    }
    func ask(_ prompt:GitSVNAuthenticationPrompt)throws->GitSVNAuthenticationResponse{
        guard !cancelled(),let path=environment["TURTLEGIT_LIBGIT2_ASKPASS"],path.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:path) else{try refuse("Native Git transport authentication is unavailable")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-libgit2-prompt-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:directory)}
        let destination=directory.appendingPathComponent("response")
        let descriptor=open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard descriptor>=0 else{try refuse("Cannot create private authentication response")}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer{try? handle.close()}
        let process=Process();process.executableURL=URL(fileURLWithPath:path);process.arguments=[try GitRemoteAuthenticationPrompt.encoded(prompt)]
        var env=environment;env["TURTLEGIT_REMOTE_NATIVE_PROMPTS"]="1";process.environment=env
        process.standardInput=FileHandle.nullDevice;process.standardOutput=handle;process.standardError=FileHandle.standardError
        // The native askpass owns the cancellation lock through inspector/export
        // drain. Never terminate it here or return while that actual child lives.
        try process.run();process.waitUntilExit();try handle.synchronize()
        guard process.terminationReason == .exit,process.terminationStatus==0,!cancelled() else{try refuse("Native Git transport authentication was cancelled")}
        let attributes=try FileManager.default.attributesOfItem(atPath:destination.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_535 else{try refuse("Oversized native authentication response")}
        let data=try Data(contentsOf:destination);guard let text=String(data:data,encoding:.utf8),let decoded=Data(base64Encoded:text.trimmingCharacters(in:.whitespacesAndNewlines)) else{try refuse("Invalid native authentication response")}
        let response=try JSONDecoder().decode(GitSVNAuthenticationResponse.self,from:decoded);_=try response.encoded(for:prompt);return response
    }
    func credential(url:String,user:String?,allowed:UInt32)throws->(String,String){
        let actual=url
        let realm=Data(actual.utf8);if realm != credentialRealm{credentials=nil;credentialUses=0;prompts=0;credentialRealm=realm}
        if let cached=credentials,credentialUses==0{credentialUses+=1;return cached}
        guard prompts<3 else{try refuse("Native authentication retry limit reached")};prompts+=1
        var realmURL=URLComponents(string:actual);realmURL?.password=nil
        let response=try ask(GitSVNAuthenticationPrompt(kind:.credentials,realm:realmURL?.string ?? actual,username:user))
        guard let username=response.username,let password=response.password else{try refuse("Incomplete native credentials")}
        let pair=(username,password);credentials=pair
        // Username-only negotiation is followed by the full user/password callback.
        credentialUses=(allowed & 1)==0 ? 0:1;return pair
    }
    func certificate(authority:String,der:Data,valid:Bool)throws{
        let parts=authority.split(separator:"\t",omittingEmptySubsequences:false)
        guard parts.count==2,let port=UInt16(parts[1]),port>0,!parts[0].isEmpty else{try refuse("Invalid actual TLS certificate authority")}
        let hostname=String(parts[0]);let anchors=httpConfiguration?.caCertificates ?? []
        // Custom authorities augment system roots. Preserve a valid actual built-in
        // chain instead of reconstructing it from only the exposed leaf.
        if valid{return}
        guard der.count<=1_048_576 else{try refuse("Actual TLS certificate exceeds inspection bounds")}
        var key=Data(hostname.utf8);key.append(0);key.append(contentsOf:String(port).utf8);key.append(0);key.append(der)
        if accepted.contains(key){return}
        guard let certificate=SecCertificateCreateWithData(nil,der as CFData) else{try refuse("Invalid actual TLS certificate")}
        var trust:SecTrust?;guard SecTrustCreateWithCertificates(certificate,SecPolicyCreateSSL(true,hostname as CFString),&trust)==errSecSuccess,let trust else{try refuse("Cannot inspect actual TLS certificate")}
        SecTrustSetNetworkFetchAllowed(trust,false)
        if !anchors.isEmpty{
            let certificates=anchors.compactMap{SecCertificateCreateWithData(nil,$0 as CFData)}
            guard certificates.count==anchors.count,SecTrustSetAnchorCertificates(trust,certificates as CFArray)==errSecSuccess,SecTrustSetAnchorCertificatesOnly(trust,false)==errSecSuccess else{try refuse("Cannot inspect configured certificate authorities")}
        }
        var error:CFError?;let acceptedByPolicy=SecTrustEvaluateWithError(trust,&error)
        if !anchors.isEmpty && acceptedByPolicy{return}
        var failures:UInt32=0
        switch error.map({CFErrorGetCode($0)}){
        case Int(errSecCertificateExpired):failures=2
        case Int(errSecCertificateNotValidYet):failures=1
        case Int(errSecHostNameMismatch):failures=4
        case Int(errSecNotTrusted),Int(errSecInvalidRoot),Int(errSecCreateChainFailed):failures=8
        default:failures=0x40000000
        }
        guard der.count<=36_000 else{try refuse("Actual TLS certificate exceeds native review bounds")}
        let details=try GitCertificateDetails(base64DER:der.base64EncodedString())
        var ignored:Unmanaged<CFError>?
        let properties=SecCertificateCopyValues(certificate,[kSecOIDX509V1IssuerName,kSecOIDX509V1ValidityNotBefore,kSecOIDX509V1ValidityNotAfter] as CFArray,&ignored) as? [String:Any] ?? [:];_=ignored?.takeRetainedValue()
        func property(_ oid:CFString)->String?{
            guard let value=properties[oid as String] as? [String:Any],let content=value[kSecPropertyKeyValue as String] else{return nil}
            func fields(_ value:Any)->[(String,String)]{
                if let rows=value as? [[String:Any]]{return rows.flatMap{row in
                    if let text=row[kSecPropertyKeyValue as String] as? String{return [(row[kSecPropertyKeyLabel as String] as? String ?? "",text)]}
                    return row[kSecPropertyKeyValue as String].map{fields($0)} ?? []
                }}
                if let text=value as? String{return [("",text)]};return []
            }
            let values=fields(content)
            for names in [["2.5.4.3","common name","cn"],["2.5.4.11","organizational unit","ou"],["2.5.4.10","organization","o"],["1.2.840.113549.1.9.1","email address","email"]]{
                if let match=values.first(where:{names.contains($0.0.lowercased())}){return match.1}
            }
            return values.isEmpty ? nil:values.map{$0.1}.joined(separator:", ")
        }
        let diagnostic=error.map{CFErrorCopyDescription($0) as String} ?? "The actual TLS certificate did not pass validation."
        let boundedDiagnostic=String(String.UnicodeScalarView(diagnostic.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"})).utf8.prefix(4096)
        var diagnosticBytes=Data(boundedDiagnostic)
        while String(data:diagnosticBytes,encoding:.utf8)==nil,!diagnosticBytes.isEmpty{diagnosticBytes.removeLast()}
        let validationError=String(data:diagnosticBytes,encoding:.utf8).flatMap{$0.isEmpty ? nil:$0}
        let display=hostname.contains(":") ? "["+hostname+"]":hostname
        let prompt=GitSVNAuthenticationPrompt(kind:.trust,realm:display+":"+String(port),failures:failures,hostname:hostname,validFrom:property(kSecOIDX509V1ValidityNotBefore),validUntil:property(kSecOIDX509V1ValidityNotAfter),issuer:property(kSecOIDX509V1IssuerName) ?? "",fingerprint:details.fingerprints,certificate:der.base64EncodedString(),validationError:validationError)
        guard try ask(prompt).decision == .temporary,!cancelled(),accepted.count<GitRemoteCertificateAcceptance.maximumRecords else{try refuse("TLS certificate was rejected or cancelled")}
        accepted.insert(key)
        if acceptanceCount<GitRemoteCertificateAcceptance.maximumRecords,let acceptanceHandle,
           let record=try? GitRemoteCertificateAcceptance(hostname:hostname,port:port,certificateDER:der),let bytes=try? record.encodedLine(){
            // Only an actual successful native acceptance is returned to the
            // source process; CA/system validation and rejects never enter it.
            do{try acceptanceHandle.write(contentsOf:bytes);acceptanceCount+=1}catch{}
        }
    }
}
func context(_ raw:UnsafeMutableRawPointer?)->CallbackContext{Unmanaged<CallbackContext>.fromOpaque(raw!).takeUnretainedValue()}
func callbacks(_ owner:CallbackContext)->tg_callbacks{
    var value=tg_callbacks();value.payload=Unmanaged.passUnretained(owner).toOpaque()
    value.cancelled={_ in cancelled() ? 1:0}
    value.output={bytes,count,_ in if let bytes,count>0{FileHandle.standardError.write(Data(bytes:bytes,count:count))}}
    value.result={bytes,count,_ in if let bytes,count>0{FileHandle.standardOutput.write(Data(bytes:bytes,count:count))}}
    value.credentials={url,username,allowed,user,password,raw in
        do{let pair=try context(raw).credential(url:url.map{String(cString:$0)} ?? "",user:username.map{String(cString:$0)},allowed:allowed);user?.pointee=strdup(pair.0);password?.pointee=strdup(pair.1);return 0}catch{output("Authentication: "+error.localizedDescription+"\n");return -1}
    }
    value.certificate={authority,bytes,count,valid,raw in
        guard let authority,let bytes else{return -1}
        do{try context(raw).certificate(authority:String(cString:authority),der:Data(bytes:bytes,count:count),valid:valid != 0);return 0}catch{output("TLS: "+error.localizedDescription+"\n");return -1}
    }
    value.url={url,raw in context(raw).currentURL=url.map{String(cString:$0)} ?? ""}
    value.http={url,directory,headers,count,proxy,raw in
        guard let url,let headers,let count,let proxy else{return -1}
        let owner=context(raw)
        do{
            let actual=String(cString:url);let configuration=try HTTPConfiguration.load(url:actual,directory:directory.map{String(cString:$0)} ?? owner.directory,configs:owner.configs,environment:environment)
            owner.currentURL=actual;owner.httpConfiguration=configuration
            if !configuration.headers.isEmpty{
                guard let array=calloc(configuration.headers.count,MemoryLayout<UnsafeMutablePointer<CChar>?>.stride) else{return -1}
                let pointers=array.bindMemory(to:UnsafeMutablePointer<CChar>?.self,capacity:configuration.headers.count)
                for (index,value) in configuration.headers.enumerated(){guard let copy=strdup(value) else{for previous in 0..<index{free(pointers[previous])};free(array);return -1};pointers[index]=copy}
                headers.pointee=pointers;count.pointee=configuration.headers.count
            }
            proxy.pointee=configuration.proxy.flatMap{strdup($0)};return 0
        }catch{output("HTTP configuration: "+error.localizedDescription+"\n");return -1}
    }
    value.filter={command,path,directory,index,input,count,result,length,raw in
        guard let command,let path,let directory,let result,let length else{return -1}
        do{let bytes=try context(raw).externalFilter(command:String(cString:command),path:String(cString:path),directory:String(cString:directory),index:index.map{String(cString:$0)},input:count>0 ? Data(bytes:input!,count:count):Data())
            guard let copy=malloc(bytes.count+1) else{return -1};bytes.copyBytes(to:copy.assumingMemoryBound(to:UInt8.self),count:bytes.count);copy.assumingMemoryBound(to:UInt8.self)[bytes.count]=0;result.pointee=copy.assumingMemoryBound(to:UInt8.self);length.pointee=bytes.count;return 0
        }catch{output("External filter: "+error.localizedDescription+"\n");return -1}
    }
    value.added={path,_ in if let path{let bytes=Data(String(cString:path).utf8);FileHandle.standardOutput.write(Data(("TurtleGit Add v1:"+bytes.base64EncodedString()+"\n").utf8))}}
    return value
}
func withStrings<T>(_ values:[String],_ body:(UnsafePointer<UnsafePointer<CChar>?>?,Int)->T)->T{
    let copies=values.map{strdup($0)};defer{copies.forEach{free($0)}}
    let immutable=copies.map{$0.map{UnsafePointer($0)}}
    return immutable.withUnsafeBufferPointer{body($0.baseAddress,$0.count)}
}
func withOptionalString<T>(_ value:String?,_ body:(UnsafePointer<CChar>?)->T)->T{if let value{return value.withCString(body)};return body(nil)}
func run()throws->Int32{
    if CommandLine.arguments.dropFirst().elementsEqual(["--version"]){print("turtlegit-libgit2 "+String(cString:tg_git_version()));return 0}
    let args=try Arguments(Array(CommandLine.arguments.dropFirst()))
    guard FileManager.default.changeCurrentDirectoryPath(args.directory) else{try refuse("Cannot enter requested repository directory")}
    guard tg_git_init()>=0 else{try refuse("Cannot initialize libgit2")};defer{tg_git_shutdown()}
    var addPaths:[String]=[],prepareOperations:[String]=[],prepareModes:[UInt32]=[]
    if args.command == "add" || args.command == "turtlegit-prepare-index"{
        var packet=Data()
        while let chunk=try FileHandle.standardInput.read(upToCount:65_536),!chunk.isEmpty{guard !cancelled(),packet.count+chunk.count<=33_554_432 else{try refuse("Index packet was cancelled or exceeds bounds")};packet.append(chunk)}
        guard packet.last==0 else{try refuse("Index operation requires a terminated NUL packet")}
        let fields=packet.dropLast().split(separator:0,omittingEmptySubsequences:false)
        func path(_ bytes:Data)throws->String{
            guard !bytes.isEmpty,bytes.count<=1_048_576,let path=String(data:bytes,encoding:.utf8),!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0 == "." || $0 == ".."}) else{try refuse("Index packet contains an invalid literal path")};return path
        }
        if args.command == "add"{
            guard !fields.isEmpty,fields.count<=100_000 else{try refuse("Invalid Add path count")}
            addPaths=try fields.map{try path(Data($0))}
        }else{
            guard !fields.isEmpty,fields.count%3==0,fields.count<=300_000 else{try refuse("Invalid Commit preparation tuple count")}
            for offset in stride(from:0,to:fields.count,by:3){
                guard let operation=String(data:Data(fields[offset]),encoding:.utf8),let mode=String(data:Data(fields[offset+2]),encoding:.utf8) else{try refuse("Invalid Commit preparation tuple")}
                let value:UInt32
                switch (operation,mode){
                case ("add","normal"),("remove","-"):value=0
                case ("add","100644"):value=0o100644
                case ("add","100755"):value=0o100755
                case ("add","120000"):value=0o120000
                default:try refuse("Unsupported Commit preparation operation or mode")
                }
                prepareOperations.append(operation);addPaths.append(try path(Data(fields[offset+1])));prepareModes.append(value)
            }
        }
    }
    let diffRequest=try (args.command == "turtlegit-unified-diff" || args.command == "turtlegit-history-diff" || args.command == "turtlegit-history-diff-batch") ? PrivateDiffRequest(command:args.command):nil
    let localRequest=try PrivateLocalReferenceRequest.commands.contains(args.command) ? PrivateLocalReferenceRequest(command:args.command):nil
    let inspectionRequest=try PrivateInspectionRequest.commands.contains(args.command) ? PrivateInspectionRequest(command:args.command):nil
    let finderRequest=try args.command=="turtlegit-finder-status" ? PrivateFinderRequest.read():nil
    let singleCommitRequest=try args.command=="turtlegit-single-commit" ? PrivateSingleCommitRequest.read():nil
    let owner=CallbackContext(directory:args.directory,configs:args.configs);var options=callbacks(owner);options.verbose=args.verbose ? 1:0;options.force_fetch=args.force ? 1:0
    if finderRequest != nil {
        options.finder_status={path,state,skip,assume,raw in
            do{try context(raw).finder(path:path,state:state,skip:skip,assume:assume);return 0}catch{output("Finder status: "+error.localizedDescription+"\n");return -1}
        }
    }
    if singleCommitRequest != nil {
        try owner.singleCommitRecord(["kind":"header"])
        options.single_commit={row,raw in
            do{try context(raw).singleCommit(row);return 0}
            catch{output("Single commit: "+error.localizedDescription+"\n");return -1}
        }
    }
    if let inspectionRequest {
        try owner.inspectionRecord(["kind":"header","operation":inspectionRequest.operation])
        options.inspection={row,raw in
            do{try context(raw).inspection(row);return 0}
            catch{output("Inspection: "+error.localizedDescription+"\n");return -1}
        }
    }
    if let localRequest,!["tagObject","tagObjects"].contains(localRequest.operation) {
        owner.localReferenceOperation=localRequest.operation
        try owner.localReferenceRecord(["kind":"header","operation":localRequest.operation])
        options.local_reference={row,raw in
            do {try context(raw).localReference(row);return 0}
            catch {output("Local reference: "+error.localizedDescription+"\n");return -1}
        }
    }
    if args.transferNotifications {
        options.reference_updated={repository,name,old,new,change,count,raw in
            let owner=context(raw)
            owner.transferNotification {
                let changes=["unclassified","same","new","deleted","forward","rewind","newerTime","olderTime","sameTime"]
                guard change>=0,Int(change)<changes.count,count>=0 else{try refuse("Invalid transfer metadata")}
                var event:[String:Any]=["kind":"reference","repositoryPath":try owner.notificationString(repository),"reference":try owner.notificationString(name),"oldHash":try owner.notificationString(old),"newHash":try owner.notificationString(new),"change":changes[Int(change)]]
                if change==4 || change==5 {event["count"]=UInt64(count)}
                return event
            }
        }
        options.checked_out={repository,path,completed,total,raw in
            let owner=context(raw)
            owner.transferNotification {
                guard completed>=0,total>0,completed<=total else{try refuse("Invalid transfer metadata")}
                return ["kind":"checkout","repositoryPath":try owner.notificationString(repository),"path":try owner.notificationString(path),"completed":UInt64(completed),"total":UInt64(total)]
            }
        }
    }
    if args.resetNotifications {
        options.reset_file={path,raw in
            do{try context(raw).resetFile(path);return 0}catch{output("Reset: "+error.localizedDescription+"\n");return -1}
        }
        options.reset_progress={completed,total,raw in
            let owner=context(raw)
            _=owner.resetNotification {
                guard completed>=0,total>=0,completed<=total else{try refuse("Invalid Reset progress")}
                return ["kind":"progress","completed":UInt64(completed),"total":UInt64(total)]
            }
        }
    }
    if let request=diffRequest?.history {
        owner.historySimple=request.simple
        options.history_header={revision,parents,count,raw in
            do{try context(raw).historyHeader(revision,parents:parents,count:count);return 0}catch{output("History diff: "+error.localizedDescription+"\n");return -1}
        }
        options.history_delta={delta,raw in
            do{try context(raw).historyDelta(delta);return 0}catch{output("History diff: "+error.localizedDescription+"\n");return -1}
        }
    }
    let result:Int32=withStrings(args.configs){config,count in
        options.config_values=config;options.config_count=count
        if let request=finderRequest{return tg_finder_status(args.directory,request.full ? 1:0,request.caseSensitive ? 1:0,request.contentCheckLimitKiB,&options)}
        if let request=singleCommitRequest{return tg_read_single_commit(args.directory,request.revision,request.allowTree ? 1:0,&options)}
        if let request=inspectionRequest {
            if let merge=request.mergeBase{return tg_inspect_merge_base(args.directory,merge.from,merge.to,&options)}
            if let clean=request.clean{return tg_inspect_clean(args.directory,clean.stagedOK ? 1:0,&options)}
            if request.operation=="conflicts"{return tg_inspect_conflicts(args.directory,&options)}
            return withStrings(request.paths){paths,count in tg_inspect_conflict_info(args.directory,paths,count,&options)}
        }
        if let request=localRequest {
            if request.operation=="choices"{return tg_checkout_references(args.directory,&options)}
            if request.operation=="remotes"{return tg_configured_remotes(args.directory,&options)}
            if let oid=request.tagObject{return tg_tag_object(args.directory,oid,0,&options)}
            if request.operation=="tagObjects" {for oid in request.tagObjects{let result=tg_tag_object(args.directory,oid,1,&options);if result<0{return result}};return 0}
            if request.operation=="inventory"{return tg_local_references(args.directory,request.scope,&options)}
            if request.operation=="names"{return tg_local_reference_names(args.directory,&options)}
            if let contains=request.contains{return tg_containing_references(args.directory,contains.revision,contains.includeTags ? 1:0,contains.includeLocal ? 1:0,contains.includeRemote ? 1:0,&options)}
            if let deletion=request.deletion{return withOptionalString(deletion.expectedSymbolicTarget){target in tg_delete_local_reference(args.directory,deletion.reference,deletion.expectedOID,target,&options)}}
        }
        if let request=diffRequest?.unified {return withStrings(request.paths){paths,count in tg_unified_diff(args.directory,request.old,request.new,paths,count,request.noPrefix ? 1:0,&options)}}
        if let batch=diffRequest?.batch,!batch.isEmpty {
            for request in batch {
                owner.resetHistory()
                let result=tg_history_diff(args.directory,request.revision,request.simple ? 1:0,request.threshold,&options)
                if result<0{return result}
                do{try owner.finishHistory()}catch{output("Batch history: "+error.localizedDescription+"\n");return -1}
            }
            return 0
        }
        if let request=diffRequest?.history {return tg_history_diff(args.directory,request.revision,request.simple ? 1:0,request.threshold,&options)}
        if args.command == "reset"{return tg_reset(args.directory,args.revision,args.resetMode,&options)}
        if args.command == "revert"{return tg_revert(args.directory,args.revision,args.mainline,&options)}
        if args.command == "turtlegit-prepare-index"{return withStrings(prepareOperations){operations,count in withStrings(addPaths){paths,_ in prepareModes.withUnsafeBufferPointer{modes in tg_prepare_index(args.directory,args.privateIndex!,operations,paths,modes.baseAddress,count,&options)}}}}
        if args.command == "add"{return withStrings(addPaths){paths,count in tg_add(args.directory,args.privateIndex!,args.addMode,args.addModeOnly ? 1:0,paths,count,&options)}}
        if args.command == "clone"{
            return withOptionalString(args.branch){branch in withOptionalString(args.origin){origin in withOptionalString(args.ssh){ssh in tg_clone(args.source,args.destination,args.bare ? 1:0,args.noCheckout ? 1:0,args.recursive ? 1:0,branch,origin,Int32(args.depth),ssh,&options)}}}
        }
        if args.command == "cat-file"{return tg_materialize_blob(args.directory,args.blobOID,args.blobPath!,&options)}
        if args.command == "ls-remote"{return tg_list_remote(args.directory,args.remote,args.listRefs ? 1:0,args.listTags ? 1:0,args.listHeads ? 1:0,&options)}
        if args.command == "push"{return withStrings(args.refspecs){refs,count in tg_delete_remote(args.directory,args.remote,refs,count,&options)}}
        return withStrings(args.refspecs){refs,count in tg_fetch(args.directory,args.remote,refs,count,args.all ? 1:0,Int32(args.tags),Int32(args.prune),Int32(args.depth),args.sourceFetch ? 1:0,&options)}
    }
    if result<0{output("libgit2: "+String(cString:tg_git_error())+"\n");return cancelled() ? 130:1}
    if diffRequest?.history != nil,diffRequest?.batch.isEmpty == true {try owner.finishHistory()}
    if let localRequest,!["tagObject","tagObjects"].contains(localRequest.operation) {try owner.finishLocalReferences(localRequest)}
    if inspectionRequest != nil{try owner.finishInspection()}
    if singleCommitRequest != nil{try owner.finishSingleCommit()}
    if finderRequest != nil{try owner.finishFinder()}
    return 0
}
do{exit(try run())}catch{output("turtlegit-libgit2: "+error.localizedDescription+"\n");exit(cancelled() ? 130:2)}
