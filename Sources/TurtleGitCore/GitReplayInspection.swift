// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

public struct ReplayMergeBaseInspection: Equatable, Sendable {
    public let base: String?
    public let fastForward: Bool
    public init(base:String?,fastForward:Bool) {self.base=base;self.fastForward=fastForward}
}
public enum GitReplayInspectionFailure: LocalizedError {
    case output
    public var errorDescription:String? {"The selected inspection engine returned invalid or incomplete repository metadata."}
}
struct GitReplayInspectionReply {
    var mergeBase:ReplayMergeBaseInspection?
    var clean:Bool?
    var conflicts:Bool?
    var entries:[ConflictEntry]=[]
}
enum GitReplayInspectionProtocol {
    static let prefix=Data("TurtleGit Inspection v1:".utf8)
    static func decode(_ data:Data,operation:String,paths:[String]=[],cancellation:OperationCancellation?=nil) throws -> GitReplayInspectionReply {
        guard data.count<=64*1024*1024,data.last==10 else {throw GitReplayInspectionFailure.output}
        var reply=GitReplayInspectionReply(),header=false,end=false,count=0
        func string(_ object:[String:Any],_ key:String) throws -> String {
            guard let value=object[key] as? String,value.utf8.count<=1024*1024,!value.utf8.contains(0) else {throw GitReplayInspectionFailure.output};return value
        }
        func boolean(_ object:[String:Any],_ key:String) throws -> Bool {
            guard let value=object[key] as? NSNumber,CFGetTypeID(value)==CFBooleanGetTypeID() else {throw GitReplayInspectionFailure.output};return value.boolValue
        }
        for line in data.split(separator:10,omittingEmptySubsequences:false).dropLast() {
            try cancellation?.check()
            guard !end,line.count<=2*1024*1024,line.starts(with:prefix),let payload=Data(base64Encoded:Data(line.dropFirst(prefix.count))),payload.base64EncodedData()==Data(line.dropFirst(prefix.count)),let object=try JSONSerialization.jsonObject(with:payload) as? [String:Any],let kind=object["kind"] as? String else {throw GitReplayInspectionFailure.output}
            switch kind {
            case "header":
                guard !header,count==0,Set(object.keys)==["kind","operation"],object["operation"] as? String==operation else {throw GitReplayInspectionFailure.output};header=true
            case "mergeBase":
                guard header,operation==kind,count==0,Set(object.keys)==["kind","base","fastForward"] else {throw GitReplayInspectionFailure.output}
                let base:String?
                if object["base"] is NSNull {base=nil} else {let oid=try string(object,"base");guard GitLocalReferenceProtocol.validOID(oid) else {throw GitReplayInspectionFailure.output};base=oid}
                let forward=try boolean(object,"fastForward");guard base != nil || !forward else {throw GitReplayInspectionFailure.output};reply.mergeBase = .init(base:base,fastForward:forward);count=1
            case "clean", "conflicts":
                guard header,operation==kind,count==0,Set(object.keys)==["kind",kind] else {throw GitReplayInspectionFailure.output}
                if kind=="clean" {reply.clean=try boolean(object,kind)} else {reply.conflicts=try boolean(object,kind)};count=1
            case "conflict":
                guard header,operation=="conflictInfo",count<paths.count,count<100000,Set(object.keys)==["kind","path","stages"] else {throw GitReplayInspectionFailure.output}
                let path=try string(object,"path")
                guard Data(path.utf8)==Data(paths[count].utf8),let values=object["stages"] as? [[String:Any]],values.count<=3 else {throw GitReplayInspectionFailure.output}
                var stages=[ConflictStage](),previous=0
                for value in values {
                    guard Set(value.keys)==["number","mode","oid"],let number=value["number"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let mode=value["mode"] as? NSNumber,CFGetTypeID(mode) != CFBooleanGetTypeID(),number.doubleValue==Double(number.intValue),mode.doubleValue==Double(mode.uint32Value),number.intValue>previous,(1...3).contains(number.intValue),[UInt32(0o100644),0o100755,0o120000,0o160000].contains(mode.uint32Value) else {throw GitReplayInspectionFailure.output}
                    let oid=try string(value,"oid");guard GitLocalReferenceProtocol.validOID(oid) else {throw GitReplayInspectionFailure.output}
                    stages.append(.init(number:number.intValue,mode:String(mode.uint32Value,radix:8),object:oid));previous=number.intValue
                }
                reply.entries.append(.init(path:path,stages:stages));count+=1
            case "end":
                guard header,Set(object.keys)==["kind","count"],let total=object["count"] as? NSNumber,CFGetTypeID(total) != CFBooleanGetTypeID(),total.doubleValue==Double(count),(operation=="conflictInfo" ? count==paths.count : count==1) else {throw GitReplayInspectionFailure.output};end=true
            default:throw GitReplayInspectionFailure.output
            }
        }
        guard header,end else {throw GitReplayInspectionFailure.output};try cancellation?.check();return reply
    }
}
extension GitRepository {
    private func replayInspection(verb:String,operation:String,request:[String:Any],paths:[String]=[],command:GitLibGit2Operation,backend:GitLibGit2Configuration,cancellation:OperationCancellation?) throws -> GitReplayInspectionReply {
        guard let helper=try backend.executor(for:command) else {throw GitReplayInspectionFailure.output}
        let packet=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys]);guard packet.count<=2*1024*1024 else {throw GitReplayInspectionFailure.output}
        var output=Data()
        _ = try run([verb],cancellation:cancellation,input:packet,retainStandardOutput:false,consumeOutput:{chunk in
            if case .stdout=chunk.stream {guard output.count+chunk.data.count<=64*1024*1024 else {throw GitReplayInspectionFailure.output};output.append(chunk.data)}
        },executorOverride:helper)
        return try GitReplayInspectionProtocol.decode(output,operation:operation,paths:paths,cancellation:cancellation)
    }
    public func replayMergeBase(from:String,to:String,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> ReplayMergeBaseInspection {
        let token=cancellation ?? replayCancellation;try token?.check()
        let selected=backend ?? libgit2Configuration ?? .load()
        func commit(_ value:String) throws -> String? {
            let result=try run(["rev-parse","--verify","--quiet","--end-of-options",value+"^{commit}"],successfulExitCodes:0...1,cancellation:token)
            guard result.exitCode==0,let hash=String(data:result.stdout,encoding:.utf8)?.trimmingCharacters(in:.newlines),GitLocalReferenceProtocol.validOID(hash) else{return nil};return hash
        }
        guard let a=try commit(from),let b=try commit(to) else {return .init(base:nil,fastForward:false)}
        if selected.requests(.mergeBase) {
            let result=try replayInspection(verb:"turtlegit-merge-base",operation:"mergeBase",request:["version":1,"from":a,"to":b],command:.mergeBase,backend:selected,cancellation:token).mergeBase!
            guard result.fastForward == (result.base==a) else {throw GitReplayInspectionFailure.output};return result
        }
        let result=try run(["merge-base","--",b,a],successfulExitCodes:0...1,cancellation:token)
        if result.exitCode != 0{return .init(base:nil,fastForward:false)}
        let base=result.text.trimmingCharacters(in:.newlines);guard GitLocalReferenceProtocol.validOID(base) else {throw GitReplayInspectionFailure.output}
        return .init(base:base,fastForward:base==a)
    }
    public func replayWorktreeIsClean(stagedOK:Bool=false,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> Bool {
        let token=cancellation ?? replayCancellation;try token?.check();let selected=backend ?? libgit2Configuration ?? .load()
        if selected.requests(.checkCleanWorktree) {return try replayInspection(verb:"turtlegit-check-clean",operation:"clean",request:["version":1,"stagedOK":stagedOK],command:.checkCleanWorktree,backend:selected,cancellation:token).clean!}
        for args in [["rev-parse","--verify","HEAD"],["update-index","--ignore-submodules","--refresh"],["diff-files","--quiet","--ignore-submodules"]] {
            if try run(args,successfulExitCodes:0...255,cancellation:token).exitCode != 0{return false}
        }
        if !stagedOK {if try run(["diff-index","--cached","--quiet","HEAD","--ignore-submodules","--"],successfulExitCodes:0...255,cancellation:token).exitCode != 0 {return false}}
        try token?.check();return true
    }
    public func hasWorkingTreeConflicts(cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> Bool {
        let token=cancellation ?? replayCancellation;try token?.check();let selected=backend ?? libgit2Configuration ?? .load()
        if selected.requests(.checkConflicts) {return try replayInspection(verb:"turtlegit-check-conflicts",operation:"conflicts",request:["version":1],command:.checkConflicts,backend:selected,cancellation:token).conflicts!}
        return try !run(["ls-files","-u"],cancellation:token).stdout.isEmpty
    }
    func requestedConflictStages(paths:[String],backend:GitLibGit2Configuration,cancellation:OperationCancellation?) throws -> [ConflictEntry] {
        guard paths.count<=100000,GitPathSet(paths).count==paths.count else {throw ResolveFailure.selection}
        if !paths.isEmpty {do {_ = try RemovalRequest(paths:paths,keepLocal:true)}catch{throw ResolveFailure.outsideWorkingTree}}
        if backend.requests(.getConflictInfo) {return try replayInspection(verb:"turtlegit-conflict-info",operation:"conflictInfo",request:["version":1,"paths":paths],paths:paths,command:.getConflictInfo,backend:backend,cancellation:cancellation).entries}
        let current=GitPathMap(try conflicts(paths:paths,cancellation:cancellation).map{($0.path,$0)},uniquingKeysWith:{_,last in last})
        return paths.map {current[$0] ?? .init(path:$0,stages:[])}
    }
}
