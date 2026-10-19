// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

/// Source checkout notifications precede the actual write. They are not a
/// transactional receipt that every notified path was ultimately checked out.
public enum GitResetNotification:Sendable,Equatable {
    case file(path:String)
    case progress(completed:UInt64,total:UInt64)
    case issue(GitTransferNotificationIssue)
    public static func ==(a:Self,b:Self)->Bool {
        switch (a,b) {
        case (.file(let a),.file(let b)):return a.utf8.elementsEqual(b.utf8)
        case (.progress(let a,let b),.progress(let c,let d)):return a==c && b==d
        case (.issue(let a),.issue(let b)):return a==b
        default:return false
        }
    }
}
struct GitResetRecycleRequest:Decodable,Sendable {
    let id:UInt64,path:String,exists:Bool
    let device:UInt64?,inode:UInt64?,mode:UInt32?
}
enum GitResetWireRecord {
    case notification(GitResetNotification),recycle(GitResetRecycleRequest)
}
enum GitResetNotificationFailure:Error,LocalizedError {
    case framing,safety
    var errorDescription:String? {
        switch self {
        case .framing:return "Reset notifications could not be read completely. Reset may already have changed files; inspect its result before retrying."
        case .safety:return "Reset stopped because its pre-overwrite recycling request could not be completed safely. Earlier recycled files remain recoverable."
        }
    }
}
final class GitResetNotificationDecoder {
    static let prefix=Data("TurtleGit Reset v1:".utf8)
    private var pending=Data(),bytes=0,events=0
    func append(_ data:Data,deliver:(GitResetWireRecord)throws->Void)throws {
        guard data.count<=64*1024*1024-bytes else {throw GitResetNotificationFailure.framing}
        bytes+=data.count;pending.append(data)
        while let newline=pending.firstIndex(of:10) {
            let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
            guard line.count<=2*1024*1024,events<100_000,line.starts(with:Self.prefix),
                  let payload=Data(base64Encoded:line.dropFirst(Self.prefix.count)),payload.base64EncodedData()==Data(line.dropFirst(Self.prefix.count)),
                  let object=try? JSONSerialization.jsonObject(with:payload) as? [String:Any],let kind=object["kind"] as? String else {throw GitResetNotificationFailure.framing}
            events+=1
            func path()->String? {guard let value=object["path"] as? String,GitTransferNotificationDecoder.validPath(value) else{return nil};return value}
            switch kind {
            case "file":
                guard Set(object.keys)==["kind","path"],let path=path() else{throw GitResetNotificationFailure.framing}
                try deliver(.notification(.file(path:path)))
            case "progress":
                struct Progress:Decodable {let completed:UInt64,total:UInt64}
                guard Set(object.keys)==["kind","completed","total"],let value=try? JSONDecoder().decode(Progress.self,from:payload),value.completed<=value.total else{throw GitResetNotificationFailure.framing}
                try deliver(.notification(.progress(completed:value.completed,total:value.total)))
            case "recycle":
                guard let value=try? JSONDecoder().decode(GitResetRecycleRequest.self,from:payload),value.id>0,path() != nil,
                      Set(object.keys)==(value.exists ? ["kind","id","path","exists","device","inode","mode"] : ["kind","id","path","exists"]),
                      !value.exists || value.device != nil && value.inode != nil && value.mode != nil else {throw GitResetNotificationFailure.safety}
                try deliver(.recycle(value))
            default:throw GitResetNotificationFailure.framing
            }
        }
        guard pending.count<=2*1024*1024 else{throw GitResetNotificationFailure.framing}
    }
    func finish()throws {guard pending.isEmpty else{throw GitResetNotificationFailure.framing}}
}

/// Private parent-side exchange: the helper cannot overwrite a notified path
/// until its particular witnessed disk item has been recycled successfully.
final class GitResetRecycleExchange {
    let directory:URL
    private var next:UInt64=1
    private let device:dev_t,inode:ino_t
    init()throws {
        directory=try TurtleGitTemporaryStorage.root.appendingPathComponent("ResetRecycle-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var info=stat();guard lstat(directory.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR else{throw GitResetNotificationFailure.safety}
        device=info.st_dev;inode=info.st_ino
    }
    deinit {try? FileManager.default.removeItem(at:directory)}
    var environment:[String:String] {["TURTLEGIT_RESET_RECYCLE_DIRECTORY":directory.path]}
    private func validate()throws {
        var info=stat();guard lstat(directory.path,&info)==0,info.st_dev==device,info.st_ino==inode,info.st_mode & S_IFMT == S_IFDIR,info.st_mode & 0o777 == 0o700,info.st_uid==geteuid() else{throw GitResetNotificationFailure.safety}
    }
    private func write(_ data:Data,name:String)throws {
        try validate()
        let temporary=directory.appendingPathComponent("."+UUID().uuidString)
        let fd=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600))
        guard fd>=0 else{throw GitResetNotificationFailure.safety}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer{try? handle.close();try? FileManager.default.removeItem(at:temporary)}
        try handle.write(contentsOf:data);try handle.close();try validate()
        guard rename(temporary.path,directory.appendingPathComponent(name).path)==0 else{throw GitResetNotificationFailure.safety}
    }
    func serve(_ request:GitResetRecycleRequest,operation:()throws->Void)throws {
        try validate();guard request.id==next,next<=100_000 else{throw GitResetNotificationFailure.safety};next+=1
        do {try operation();try acknowledge(request.id,accepted:true)}
        catch {try? acknowledge(request.id,accepted:false);throw error}
    }
    private func acknowledge(_ id:UInt64,accepted:Bool)throws {
        try write(JSONSerialization.data(withJSONObject:["id":id,"accepted":accepted],options:.sortedKeys),name:String(id)+".ack")
    }
    func abort() {try? write(Data("abort\n".utf8),name:"abort")}
}

final class GitResetNotificationReceiver {
    private let decoder=GitResetNotificationDecoder()
    private let cancellation:OperationCancellation,exchange:GitResetRecycleExchange?
    private let callback:(@Sendable(GitResetNotification)->Void)?,recycle:(GitResetRecycleRequest)throws->Void
    private var failed=false,finished=false,safetyFailed=false,failureMessage:String?
    init(cancellation:OperationCancellation,exchange:GitResetRecycleExchange?,callback:(@Sendable(GitResetNotification)->Void)?,recycle:@escaping(GitResetRecycleRequest)throws->Void) {
        self.cancellation=cancellation;self.exchange=exchange;self.callback=callback;self.recycle=recycle
    }
    func consume(_ chunk:GitOutputChunk) {
        guard case .stdout=chunk.stream,!chunk.data.isEmpty,!finished,!failed else{return}
        do {
            try decoder.append(chunk.data) {record in
                guard !cancellation.isCancelled else{exchange?.abort();return}
                switch record {
                case .notification(let value):callback?(value)
                case .recycle(let request):
                    guard let exchange else{throw GitResetNotificationFailure.safety}
                    do {try exchange.serve(request){try recycle(request)}}
                    catch {
                        failureMessage=String(decoding:Data(("Could not move “"+request.path+"” to Trash.\n"+error.localizedDescription).utf8.prefix(4096)),as:UTF8.self)
                        throw error
                    }
                }
            }
        } catch {failed=true;safetyFailed=exchange != nil;exchange?.abort()}
    }
    func finish(commandSucceeded:Bool) {
        guard !finished else{return};finished=true
        if !failed {do{try decoder.finish()}catch{failed=true}}
        if failed,!cancellation.isCancelled {callback?(.issue(.init(message:failureMessage ?? (safetyFailed ? GitResetNotificationFailure.safety:GitResetNotificationFailure.framing).localizedDescription,commandSucceeded:commandSucceeded)))}
    }
}

extension GitRepository {
    func recycleResetPath(_ request:GitResetRecycleRequest,cancellation:OperationCancellation,recycler:(URL)throws->URL?)throws {
        try cancellation.check()
        let location=try restoreLocation(request.path)
        var info=stat()
        let found=lstat(location.path,&info)==0
        if !found {guard errno==ENOENT else{throw GitResetNotificationFailure.safety}}
        guard found==request.exists else{throw GitResetNotificationFailure.safety}
        if !found {return} // Recreated missing file: source Delete failure is not useful on macOS.
        let kind=info.st_mode & S_IFMT
        guard [mode_t(S_IFREG),mode_t(S_IFLNK),mode_t(S_IFDIR)].contains(kind),
              UInt64(UInt32(bitPattern:info.st_dev))==request.device,UInt64(info.st_ino)==request.inode,UInt32(info.st_mode)==request.mode else{throw GitResetNotificationFailure.safety}
        try cancellation.check()
        // Recheck containment and identity immediately before the filesystem move.
        guard try restoreLocation(request.path)==location else{throw GitResetNotificationFailure.safety}
        var current=stat();guard lstat(location.path,&current)==0,current.st_dev==info.st_dev,current.st_ino==info.st_ino,current.st_mode==info.st_mode else{throw GitResetNotificationFailure.safety}
        _ = try recycler(location)
        var after=stat();guard lstat(location.path,&after) != 0,errno==ENOENT else{throw GitResetNotificationFailure.safety}
        try cancellation.check()
    }
    func runReset(_ arguments:[String],executor:URL,cancellation:OperationCancellation,recycle:Bool,onOutput:(@Sendable(GitOutputChunk)->Void)?,onNotification:(@Sendable(GitResetNotification)->Void)?,recycler:@escaping(URL)throws->URL?)throws->GitResult {
        guard recycle || onNotification != nil else{return try run(arguments,cancellation:cancellation,onOutput:onOutput,executorOverride:executor)}
        let exchange=try recycle ? GitResetRecycleExchange():nil
        let receiver=GitResetNotificationReceiver(cancellation:cancellation,exchange:exchange,callback:onNotification) {request in
            try self.recycleResetPath(request,cancellation:cancellation,recycler:recycler)
        }
        var succeeded=false;defer{receiver.finish(commandSucceeded:succeeded);withExtendedLifetime(exchange){}}
        do {
            let result=try run(["--turtlegit-reset-notifications"]+arguments,environmentOverrides:exchange?.environment ?? [:],cancellation:cancellation,retainStandardOutput:false,consumeOutput:{receiver.consume($0)},onOutput:{chunk in if case .stderr=chunk.stream{onOutput?(chunk)}},executorOverride:executor)
            succeeded=result.exitCode==0;return result
        } catch let error as GitFailure {throw GitFailure(arguments:arguments,code:error.code,message:error.message,outputWasDelivered:error.outputWasDelivered,standardError:error.standardError)}
    }
}
