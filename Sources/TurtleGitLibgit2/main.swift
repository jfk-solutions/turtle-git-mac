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
    var listRefs=false,listTags=false,listHeads=false,filters=false
    var blobPath:String?,blobOID=""
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
            if arg == "-C"{let path=try next();directory=URL(fileURLWithPath:path,relativeTo:URL(fileURLWithPath:directory,isDirectory:true)).standardizedFileURL.path;continue}
            if arg == "-c"{configs.append(try configuration(next()));continue}
            guard ["clone","fetch","ls-remote","push","cat-file"].contains(arg) else{try refuse("Unsupported libgit2 command or global option")};command=arg;break
        }
        guard !command.isEmpty else{try refuse("Expected a supported libgit2 command")}
        var operands:[String]=[],options=true
        while index<arguments.count{
            let arg=try next()
            if options && arg == "--"{options=false;continue}
            if options && arg.hasPrefix("-"){
                switch arg{
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
                    if command == "cat-file" && arg.hasPrefix("--path="){guard blobPath == nil else{try refuse("Repeated blob path")};blobPath=String(arg.dropFirst(7))}else if (command == "clone" || command == "fetch") && arg.hasPrefix("--depth="){depth=try depthValue(String(arg.dropFirst(8)))}else{try refuse("Unsupported libgit2 option: "+arg)}
                }
            }else{operands.append(arg)}
        }
        guard configs.count<=2048 else{try refuse("Too many command configuration values")}
        if command == "clone"{
            guard operands.count==2,!(bare && noCheckout),!(bare && recursive),origin?.isEmpty != true,branch?.isEmpty != true else{try refuse("Invalid clone option combination")}
            source=operands[0];destination=operands[1]
            guard !source.isEmpty,!destination.isEmpty else{try refuse("Missing clone source or destination")}
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
            if let first=operands.first{remote=first;refspecs=Array(operands.dropFirst()).map{value in
                let parts=value.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)
                guard parts.count==2 else{return value};let target=String(parts[1]);return String(parts[0])+":"+((target.hasPrefix("remotes/") || target.hasPrefix("heads/") || target.hasPrefix("tags/")) ? "refs/"+target:target)
            }}
            guard !remote.isEmpty,refspecs.count<=4096 else{try refuse("Invalid fetch remote/refspec")}
        }
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
    var currentURL="",credentialRealm=Data(),credentials:(String,String)?,credentialUses=0,prompts=0
    var accepted:Set<Data>=[]
    func smudge(command:String,path:String,directory:String,input:Data)throws->Data{
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
    value.filter={command,path,directory,input,count,result,length,raw in
        guard let command,let path,let directory,let result,let length else{return -1}
        do{let bytes=try context(raw).smudge(command:String(cString:command),path:String(cString:path),directory:String(cString:directory),input:count>0 ? Data(bytes:input!,count:count):Data())
            guard let copy=malloc(bytes.count+1) else{return -1};bytes.copyBytes(to:copy.assumingMemoryBound(to:UInt8.self),count:bytes.count);copy.assumingMemoryBound(to:UInt8.self)[bytes.count]=0;result.pointee=copy.assumingMemoryBound(to:UInt8.self);length.pointee=bytes.count;return 0
        }catch{output("Smudge filter: "+error.localizedDescription+"\n");return -1}
    };return value
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
    let owner=CallbackContext(directory:args.directory,configs:args.configs);var options=callbacks(owner);options.verbose=args.verbose ? 1:0;options.force_fetch=args.force ? 1:0
    let result:Int32=withStrings(args.configs){config,count in
        options.config_values=config;options.config_count=count
        if args.command == "clone"{
            return withOptionalString(args.branch){branch in withOptionalString(args.origin){origin in withOptionalString(args.ssh){ssh in tg_clone(args.source,args.destination,args.bare ? 1:0,args.noCheckout ? 1:0,args.recursive ? 1:0,branch,origin,Int32(args.depth),ssh,&options)}}}
        }
        if args.command == "cat-file"{return tg_materialize_blob(args.directory,args.blobOID,args.blobPath!,&options)}
        if args.command == "ls-remote"{return tg_list_remote(args.directory,args.remote,args.listRefs ? 1:0,args.listTags ? 1:0,args.listHeads ? 1:0,&options)}
        if args.command == "push"{return withStrings(args.refspecs){refs,count in tg_delete_remote(args.directory,args.remote,refs,count,&options)}}
        return withStrings(args.refspecs){refs,count in tg_fetch(args.directory,args.remote,refs,count,args.all ? 1:0,Int32(args.tags),Int32(args.prune),Int32(args.depth),&options)}
    }
    if result<0{output("libgit2: "+String(cString:tg_git_error())+"\n");return cancelled() ? 130:1}
    return 0
}
do{exit(try run())}catch{output("turtlegit-libgit2: "+error.localizedDescription+"\n");exit(cancelled() ? 130:2)}
