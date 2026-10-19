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
    var listRefs=false,listTags=false,listHeads=false
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
            guard ["clone","fetch","ls-remote","push"].contains(arg) else{try refuse("Unsupported libgit2 command or global option")};command=arg;break
        }
        guard !command.isEmpty else{try refuse("Expected clone, fetch, ls-remote or deletion push")}
        var operands:[String]=[],options=true
        while index<arguments.count{
            let arg=try next()
            if options && arg == "--"{options=false;continue}
            if options && arg.hasPrefix("-"){
                switch arg{
                case "--progress" where command != "ls-remote":break
                case "-v" where command != "ls-remote", "--verbose" where command != "ls-remote":verbose=true
                case "--bare" where command == "clone":bare=true
                case "--no-checkout" where command == "clone":noCheckout=true
                case "--recursive" where command == "clone", "--recurse-submodules" where command == "clone":recursive=true
                case "--branch" where command == "clone", "-b" where command == "clone":branch=try next()
                case "--origin" where command == "clone", "-o" where command == "clone":origin=try next()
                case "--depth" where command == "clone" || command == "fetch":depth=try depthValue(next())
                case "--config" where command == "clone":
                    let value=try next();guard value.hasPrefix("core.sshCommand=") else{try refuse("Unsupported persistent clone configuration")};ssh=String(value.dropFirst("core.sshCommand=".count))
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
                    if (command == "clone" || command == "fetch") && arg.hasPrefix("--depth="){depth=try depthValue(String(arg.dropFirst(8)))}else{try refuse("Unsupported libgit2 option: "+arg)}
                }
            }else{operands.append(arg)}
        }
        guard configs.count<=2048 else{try refuse("Too many command configuration values")}
        if command == "clone"{
            guard operands.count==2,!(bare && noCheckout),!(bare && recursive),origin?.isEmpty != true,branch?.isEmpty != true else{try refuse("Invalid clone option combination")}
            source=operands[0];destination=operands[1]
            guard !source.isEmpty,!destination.isEmpty else{try refuse("Missing clone source or destination")}
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
    init(directory:String,configs:[String]){self.directory=directory;self.configs=configs}
    var currentURL="",credentialRealm=Data(),credentials:(String,String)?,credentialUses=0,prompts=0
    var accepted:Set<Data>=[]
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
        func property(_ oid:CFString)->String?{guard let value=properties[oid as String] as? [String:Any],let content=value[kSecPropertyKeyValue as String] else{return nil};return String(describing:content)}
        let display=hostname.contains(":") ? "["+hostname+"]":hostname
        let prompt=GitSVNAuthenticationPrompt(kind:.trust,realm:display+":"+String(port),failures:failures,hostname:hostname,validFrom:property(kSecOIDX509V1ValidityNotBefore),validUntil:property(kSecOIDX509V1ValidityNotAfter),issuer:property(kSecOIDX509V1IssuerName) ?? details.subject,fingerprint:details.fingerprints,certificate:der.base64EncodedString())
        guard try ask(prompt).decision == .temporary,!cancelled(),accepted.count<128 else{try refuse("TLS certificate was rejected or cancelled")};accepted.insert(key)
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
        if args.command == "ls-remote"{return tg_list_remote(args.directory,args.remote,args.listRefs ? 1:0,args.listTags ? 1:0,args.listHeads ? 1:0,&options)}
        if args.command == "push"{return withStrings(args.refspecs){refs,count in tg_delete_remote(args.directory,args.remote,refs,count,&options)}}
        return withStrings(args.refspecs){refs,count in tg_fetch(args.directory,args.remote,refs,count,args.all ? 1:0,Int32(args.tags),Int32(args.prune),Int32(args.depth),&options)}
    }
    if result<0{output("libgit2: "+String(cString:tg_git_error())+"\n");return cancelled() ? 130:1}
    return 0
}
do{exit(try run())}catch{output("turtlegit-libgit2: "+error.localizedDescription+"\n");exit(cancelled() ? 130:2)}
