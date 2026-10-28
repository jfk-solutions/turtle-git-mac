import XCTest
import Darwin
@testable import TurtleGitCore

final class NativeIssueProviderSessionTests:XCTestCase {
    private final class Server:@unchecked Sendable {
        let directory:URL,endpoint:URL,log:URL
        private let pid:pid_t
        private let stopLock=NSLock()
        private var stopped=false
        init() async throws {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-provider-"+UUID().uuidString,isDirectory:true)
            var child:pid_t=0,retained=false
            defer {if !retained {if child>0 {XCTAssertTrue(Self.terminateAndWait(child))};try? FileManager.default.removeItem(at:directory)}}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let log=directory.appendingPathComponent("requests.jsonl")
            let script=directory.appendingPathComponent("server.py"),ready=directory.appendingPathComponent("ready")
            try Data(Self.script.utf8).write(to:script)
            child=try Self.spawn(script:script,directory:directory)
            // The first system Python launch can cold-start more slowly than
            // later fixture servers. Wait for a complete valid receipt, not
            // merely a file that write_text has opened but not yet filled.
            let deadline=ContinuousClock.now.advanced(by:.seconds(10))
            var receivedPort:Int?,exitStatus:Int32?
            while ContinuousClock.now<deadline {
                if let bytes=try? Data(contentsOf:ready),let value=Int(String(decoding:bytes,as:UTF8.self)),(1...65535).contains(value) {receivedPort=value;break}
                var status:Int32=0
                if waitpid(child,&status,WNOHANG)==child {exitStatus=status;break}
                try await Task.sleep(nanoseconds:10_000_000)
            }
            guard let port=receivedPort else {
                let diagnostic=Self.startupDiagnostic(directory)
                throw NSError(domain:"TurtleGit.ProviderTestServer",code:1,userInfo:[NSLocalizedDescriptionKey:"Provider server startup failed (status \(exitStatus.map{String($0)} ?? "no ready receipt within 10 seconds")). "+diagnostic])
            }
            self.directory=directory;self.log=log;self.pid=child
            endpoint=URL(string:"http://127.0.0.1:\(port)")!;retained=true
        }
        func stop(){
            stopLock.lock();guard !stopped else{stopLock.unlock();return};stopped=true;stopLock.unlock()
            let reaped=Self.terminateAndWait(pid)
            XCTAssertTrue(reaped,"Owned issue-provider server did not retire: PID \(pid)")
            if reaped {try? FileManager.default.removeItem(at:directory)}
        }
        private static func spawn(script:URL,directory:URL)throws->pid_t {
            func checked(_ code:Int32)throws {if code != 0 {throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))}}
            func strings<T>(_ values:[String],_ body:(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)throws->T)throws->T {
                var pointers=values.map{strdup($0)};defer{pointers.forEach{free($0)}}
                guard pointers.allSatisfy({$0 != nil}) else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOMEM))}
                pointers.append(nil);return try pointers.withUnsafeMutableBufferPointer{try body($0.baseAddress!)}
            }
            var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
            try checked(posix_spawn_file_actions_init(&actions));defer{posix_spawn_file_actions_destroy(&actions)}
            try checked(posix_spawnattr_init(&attributes));defer{posix_spawnattr_destroy(&attributes)}
            for fd in [STDIN_FILENO,STDOUT_FILENO] {try checked(posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",fd==STDIN_FILENO ? O_RDONLY:O_WRONLY,0))}
            try checked(posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,directory.appendingPathComponent("server.stderr").path,O_WRONLY|O_CREAT|O_TRUNC,0o600))
            var mask=sigset_t(),defaults=sigset_t();sigemptyset(&mask);sigemptyset(&defaults);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT)
            try checked(posix_spawnattr_setsigmask(&attributes,&mask));try checked(posix_spawnattr_setsigdefault(&attributes,&defaults))
            try checked(posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT)))
            var pid:pid_t=0
            try strings(["/usr/bin/python3","-I","-u",script.path,directory.path]) {argv in
                try strings(["PATH=/usr/bin:/bin","HOME="+directory.path,"TMPDIR="+directory.path]) {environment in
                    try checked(posix_spawn(&pid,"/usr/bin/python3",&actions,&attributes,argv,environment))
                }
            }
            return pid
        }
        private static func startupDiagnostic(_ directory:URL)->String {
            guard let file=try? FileHandle(forReadingFrom:directory.appendingPathComponent("server.stderr")) else{return "No server stderr."}
            defer{try? file.close()}
            let bytes=(try? file.read(upToCount:8192)) ?? Data()
            return bytes.isEmpty ? "No server stderr.":String(decoding:bytes,as:UTF8.self)
        }
        private static func terminateAndWait(_ pid:pid_t)->Bool {
            var status:Int32=0
            func reaped()->Bool {let result=waitpid(pid,&status,WNOHANG);return result==pid || result<0 && errno==ECHILD}
            if reaped(){return true}
            _=Darwin.kill(pid,SIGTERM)
            for _ in 0..<100 {if reaped(){return true};usleep(10_000)}
            _=Darwin.kill(pid,SIGKILL)
            for _ in 0..<200 {if reaped(){return true};usleep(10_000)}
            return false
        }
        func session(_ path:String="normal",token:String?=nil)throws->NativeIssueProviderSession {
            let data=try JSONSerialization.data(withJSONObject:["endpoint":endpoint.appendingPathComponent(path).absoluteString,"linkText":"Private test issues"])
            return try .init(identifier:NativeIssueProviderSession.httpIdentifier,parameters:String(decoding:data,as:UTF8.self),bearerToken:token)
        }
        func records()throws->[[String:Any]] {
            guard FileManager.default.fileExists(atPath:log.path) else{return []}
            return try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
        }
        func awaitRequests(_ count:Int) async throws {
            for _ in 0..<400 {if try records().count>=count{return};try await Task.sleep(nanoseconds:5_000_000)}
            throw NSError(domain:"Provider did not receive expected request",code:count)
        }
        static let script=#"""
import http.server,json,pathlib,sys,time,threading
root=pathlib.Path(sys.argv[1]);lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with lock:
   with (root/'requests.jsonl').open('a') as f:f.write(json.dumps({'path':self.path,'body':body,'authorization':self.headers.get('Authorization'),'cookie':self.headers.get('Cookie')})+'\n');f.flush()
  path=self.path;action=body['action'];value={'version':1};status=200;mime='application/json'
  if path=='/hold':
   for _ in range(1000):
    if (root/'release').exists():break
    time.sleep(.01)
  if path=='/redirect':
   self.send_response(302);self.send_header('Location','/leaked');self.send_header('Content-Length','0');self.end_headers();return
  if path=='/status':status=503
  if path=='/reject':value['error']='Policy rejected '+(self.headers.get('Authorization') or '')
  elif action=='listIssues':value['issues']=[{'id':'2','summary':'Second'},{'id':'1','summary':'First 雪'}]
  elif action=='commitMessage':value['message']=body['context']['message']+'\nProvider prepared'
  elif action=='commitFinished':value['warning']='Tracker notification accepted'
  if path=='/empty-id':value['issueID']=''
  if path=='/null-id':value['issueID']=None
  if path=='/warning':value['warning']=(self.headers.get('Authorization') or '')+'x'*6000
  if path=='/duplicate':value['issues']=[{'id':'café','summary':'NFC'},{'id':'cafe\u0301','summary':'NFD'}]
  if path=='/version-bool':value['version']=True
  if path=='/version':value['version']=2
  if path=='/error-empty':value['error']=''
  if path=='/error-number':value['error']=7
  if path=='/error-null':value['error']=None
  if path=='/error-nul':value['error']='Policy\u0000malformed'
  if path=='/reject-long':value['error']='Policy rejected '+(self.headers.get('Authorization') or '')+'x'*6000
  if path=='/version-error':value={'version':2,'error':'Not a valid veto'}
  if path=='/status-error':status=503;value['error']='Not a successful veto'
  payload=json.dumps(value,ensure_ascii=False).encode()
  if path=='/bad-json':payload=b'{wrong'
  if path=='/mime':mime='text/plain'
  if path=='/oversize':payload=b'x'*1048577
  if path=='/stream':
   self.send_response(200);self.send_header('Content-Type',mime);self.end_headers()
   try:
    for _ in range(257):self.wfile.write(b'x'*4096);self.wfile.flush()
   except (BrokenPipeError,ConnectionResetError):pass
   return
  self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Set-Cookie','private=never-persist');self.send_header('Content-Length',str(len(payload)));self.end_headers()
  try:self.wfile.write(payload)
  except (BrokenPipeError,ConnectionResetError):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
(root/'ready').write_text(str(server.server_port));server.serve_forever()
"""#
    }
    private var context:NativeIssueProviderContext {.init(repositoryRoot:URL(fileURLWithPath:"/private/provider repo 雪"),paths:["folder/a[*]\n.txt","folder/cafe\u{301}.txt"],message:"raw draft\n",issueID:"retained")}
    func testRegistryAndCatalogSessionPreserveEstablishedLocalContract() async throws {
        XCTAssertEqual(Set(NativeIssueProviderRegistry.descriptors.map(\.identifier)),[NativeIssueCatalogProvider.identifier,NativeIssueProviderSession.httpIdentifier])
        XCTAssertNotNil(NativeIssueProviderRegistry.descriptor(identifier:NativeIssueProviderSession.httpIdentifier))
        XCTAssertNil(NativeIssueProviderRegistry.descriptor(identifier:"arbitrary.plugin"))
        let catalog=try NativeIssueCatalogProvider(parameters:NativeIssueCatalogProvider.exampleParameters),session=NativeIssueProviderSession(catalog:catalog)
        XCTAssertFalse(session.isRemote);XCTAssertNil(session.endpoint);XCTAssertEqual(session.selectedIDs(in:"1,unknown"),["1"])
        let items=try await session.issues(context:context);XCTAssertEqual(items,catalog.issues)
        let prepared=try await session.commitMessage(context:context,selected:["1"])
        XCTAssertEqual(prepared,try catalog.commitMessage(context:context,selected:["1"]))
        try await session.checkCommit(context:context)
        let completion=try await session.commitFinished(context:context,revision:"local adapter preserves existing semantics")
        XCTAssertNil(completion)
        let token=OperationCancellation();token.cancel()
        do {_ = try await session.issues(context:context,cancellation:token);XCTFail("Cancelled local operation succeeded")}catch is OperationCancellationFailure {}
    }
    func testHTTPConfigurationRejectsSecretsAuthorityAndUnsafeSchemesWithoutNetwork() throws {
        for endpoint in ["http://example.invalid/api","file:///tmp/issues","https://user:secret@example.invalid/api","https://host/api?token=secret","https://host/api#fragment","relative","https://host:0/api"] {
            let bytes=try JSONSerialization.data(withJSONObject:["endpoint":endpoint])
            XCTAssertThrowsError(try NativeIssueProviderSession(identifier:NativeIssueProviderSession.httpIdentifier,parameters:String(decoding:bytes,as:UTF8.self)),endpoint)
        }
        for field in ["token","bearerToken","authorization","headers","password","unknown"] {
            let bytes=try JSONSerialization.data(withJSONObject:["endpoint":"https://example.invalid/api",field:"plaintext secret"])
            XCTAssertThrowsError(try NativeIssueProviderSession(identifier:NativeIssueProviderSession.httpIdentifier,parameters:String(decoding:bytes,as:UTF8.self)))
        }
        for token in ["","with space","line\r\nInjected: x",String(repeating:"a",count:8193)] {
            XCTAssertThrowsError(try NativeIssueProviderSession(identifier:NativeIssueProviderSession.httpIdentifier,parameters:#"{"endpoint":"https://example.invalid/api"}"#,bearerToken:token))
        }
        for endpoint in ["http://localhost:1234/api","http://127.0.0.1:1234/api","http://[::1]:1234/api","https://example.invalid/api"] {
            let bytes=try JSONSerialization.data(withJSONObject:["endpoint":endpoint])
            XCTAssertTrue(try NativeIssueProviderSession(identifier:NativeIssueProviderSession.httpIdentifier,parameters:String(decoding:bytes,as:UTF8.self)).isRemote)
        }
    }
    func testRealHTTPCallbacksPreserveContextOrderOptionalIDsAndCredentialPrivacy() async throws {
        let server=try await Server();defer{server.stop()}
        let provider=try server.session(token:"private-fixture-token"),captured=context
        XCTAssertFalse(String(reflecting:provider).contains("private-fixture-token"))
        let issues=try await provider.issues(context:captured);XCTAssertEqual(issues.map(\.id),["2","1"])
        let prepared=try await provider.commitMessage(context:captured,selected:["2","1"])
        XCTAssertEqual(prepared.message,"raw draft\n\nProvider prepared");XCTAssertEqual(prepared.issueID,"retained")
        let checked=NativeIssueProviderContext(repositoryRoot:captured.repositoryRoot,paths:captured.paths,message:prepared.message,issueID:prepared.issueID)
        try await provider.checkCommit(context:checked)
        let revision=String(repeating:"a",count:40),warning=try await provider.commitFinished(context:checked,revision:revision)
        XCTAssertEqual(warning,"Tracker notification accepted")
        let records=try server.records(),bodies=records.map{$0["body"] as! [String:Any]}
        XCTAssertEqual(bodies.map{$0["action"] as! String},["listIssues","commitMessage","checkCommit","commitFinished"])
        XCTAssertEqual(bodies[1]["selectedIDs"] as? [String],["1","2"]);XCTAssertEqual(bodies[3]["revision"] as? String,revision)
        for record in records {XCTAssertEqual(record["authorization"] as? String,"Bearer private-fixture-token");XCTAssertTrue(record["cookie"] is NSNull)}
        let serialized=try JSONSerialization.data(withJSONObject:bodies)
        XCTAssertFalse(String(decoding:serialized,as:UTF8.self).contains("private-fixture-token"))
        let sent=bodies[0]["context"] as! [String:Any]
        XCTAssertEqual(sent["repositoryRoot"] as? String,captured.repositoryRoot.path)
        XCTAssertEqual(sent["commonRoot"] as? String,captured.repositoryRoot.path+"/folder")
        XCTAssertEqual((sent["paths"] as! [String]).map{Data($0.utf8)},captured.paths.map{Data($0.utf8)})
        let explicitEmpty=try await server.session("empty-id").commitMessage(context:captured,selected:["1"])
        XCTAssertEqual(explicitEmpty.issueID,"")
    }
    func testRealHTTPResponseBoundsMalformedSchemasRedirectsAndRedactedErrors() async throws {
        let server=try await Server();defer{server.stop()}
        for route in ["status","redirect","oversize","stream","bad-json","mime","version-bool","version","duplicate"] {
            do {_ = try await server.session(route).issues(context:context);XCTFail("Accepted "+route)}catch {XCTAssertLessThan(error.localizedDescription.count,5000,route)}
        }
        XCTAssertFalse(try server.records().contains{($0["path"] as? String)=="/leaked"})
        do {try await server.session("reject",token:"private-fixture-token").checkCommit(context:context);XCTFail("Policy refusal accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("Policy rejected"));XCTAssertFalse(error.localizedDescription.contains("private-fixture-token"))}
        let warning=try await server.session("warning",token:"private-fixture-token").commitFinished(context:context,revision:String(repeating:"b",count:64))
        XCTAssertEqual(warning?.count,4096);XCTAssertFalse(warning?.contains("private-fixture-token") ?? true)
        do {_ = try await server.session("null-id").commitMessage(context:context,selected:["1"]);XCTFail("Invalid explicit ID accepted")}catch{}
    }
    func testRealHTTPTokenAndTaskCancellationDrainBeforeReturning() async throws {
        let server=try await Server();defer{server.stop()}
        let provider=try server.session("hold"),captured=context,token=OperationCancellation()
        let first=Task {try await provider.issues(context:captured,cancellation:token)}
        defer{token.cancel();first.cancel()}
        try await server.awaitRequests(1);token.cancel()
        do {_ = try await first.value;XCTFail("Token cancelled response published")}catch is OperationCancellationFailure {}
        let second=Task {try await provider.issues(context:captured)}
        defer{second.cancel()}
        try await server.awaitRequests(2);second.cancel()
        do {_ = try await second.value;XCTFail("Task cancelled response published")}catch is OperationCancellationFailure {}
        try Data().write(to:server.directory.appendingPathComponent("release"))
        let healthy=try await server.session().issues(context:captured)
        XCTAssertEqual(healthy.count,2,"A retired request must not poison another owned session")
    }
    func testOversizedRequestRefusesBeforeSendingAndAssociationValidationUsesRegistry() async throws {
        let server=try await Server();defer{server.stop()}
        let provider=try server.session(),large=NativeIssueProviderContext(repositoryRoot:context.repositoryRoot,paths:[],message:String(repeating:"x",count:1_048_576),issueID:"")
        do {_ = try await provider.issues(context:large);XCTFail("Oversized request sent")}catch{}
        XCTAssertTrue(try server.records().isEmpty)
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await provider.issues(context:context,cancellation:cancelled);XCTFail("Precancelled request sent")}catch is OperationCancellationFailure {}
        XCTAssertTrue(try server.records().isEmpty)
        let parameters=try JSONSerialization.data(withJSONObject:["endpoint":server.endpoint.absoluteString])
        try NativeIssueAssociations.validate(.init(path:server.directory.path,provider:NativeIssueProviderSession.httpIdentifier,parameters:String(decoding:parameters,as:UTF8.self)))
        XCTAssertTrue(try server.records().isEmpty,"Options validation must not contact the server")
    }
    func testCheckCommitDistinguishesExplicitVetoFromProviderInvocationFailure() async throws {
        let server=try await Server();defer{server.stop()}
        try await server.session().checkCommit(context:context)
        try await server.session("error-empty").checkCommit(context:context)
        do {try await server.session("reject",token:"private-fixture-token").checkCommit(context:context);XCTFail("Explicit provider veto accepted")}
        catch let rejection as NativeIssueProviderCommitRejection {
            XCTAssertTrue(rejection.message.contains("Policy rejected"))
            XCTAssertTrue(rejection.message.contains("[redacted]"))
            XCTAssertFalse(rejection.message.contains("private-fixture-token"))
            XCTAssertEqual(rejection.localizedDescription,rejection.message)
        } catch {XCTFail("Valid provider veto lost its dedicated type: \(error)")}
        do {try await server.session("reject-long",token:"private-fixture-token").checkCommit(context:context);XCTFail("Long explicit veto accepted")}
        catch let rejection as NativeIssueProviderCommitRejection {
            XCTAssertEqual(rejection.message.count,4096)
            XCTAssertFalse(rejection.message.contains("private-fixture-token"))
        } catch {XCTFail("Long valid veto lost its dedicated type: \(error)")}
        for route in ["status","status-error","redirect","bad-json","mime","version","version-bool","version-error","error-number","error-null","error-nul","oversize"] {
            do {try await server.session(route).checkCommit(context:context);XCTFail("Invalid CheckCommit response accepted: \(route)")}
            catch {
                XCTAssertFalse(error is NativeIssueProviderCommitRejection,"Invocation failure became an explicit veto: \(route)")
                XCTAssertFalse(error is OperationCancellationFailure,"Invocation failure became cancellation: \(route)")
                XCTAssertLessThan(error.localizedDescription.count,5000,route)
            }
        }
        XCTAssertFalse(try server.records().contains{($0["path"] as? String)=="/leaked"})
    }
    func testCommitVetoTypeDoesNotChangePickerOrCompletionErrorContracts() async throws {
        let server=try await Server();defer{server.stop()}
        let provider=try server.session("reject",token:"private-fixture-token")
        do {_ = try await provider.issues(context:context);XCTFail("Issue-list error accepted")}
        catch {XCTAssertFalse(error is NativeIssueProviderCommitRejection);XCTAssertTrue(error is NativeIssueProviderFailure);XCTAssertFalse(error.localizedDescription.contains("private-fixture-token"))}
        do {_ = try await provider.commitMessage(context:context,selected:["1"]);XCTFail("Message error accepted")}
        catch {XCTAssertFalse(error is NativeIssueProviderCommitRejection);XCTAssertTrue(error is NativeIssueProviderFailure);XCTAssertFalse(error.localizedDescription.contains("private-fixture-token"))}
        do {_ = try await provider.commitFinished(context:context,revision:String(repeating:"a",count:40));XCTFail("Completion error accepted")}
        catch {XCTAssertFalse(error is NativeIssueProviderCommitRejection);XCTAssertTrue(error is NativeIssueProviderFailure);XCTAssertFalse(error.localizedDescription.contains("private-fixture-token"))}
        let catalog=try NativeIssueCatalogProvider(parameters:#"{"requireIssue":true,"issues":[{"id":"1","summary":"Required"}]}"#)
        let local=NativeIssueProviderSession(catalog:catalog)
        let missing=NativeIssueProviderContext(repositoryRoot:context.repositoryRoot,paths:context.paths,message:context.message,issueID:"")
        do {try await local.checkCommit(context:missing);XCTFail("Required catalog issue did not veto")}
        catch let rejection as NativeIssueProviderCommitRejection {XCTAssertEqual(rejection.message,NativeIssueProviderFailure.selection.localizedDescription)}
        catch {XCTFail("Catalog veto lost its dedicated type: \(error)")}
        try await local.checkCommit(context:NativeIssueProviderContext(repositoryRoot:context.repositoryRoot,paths:context.paths,message:context.message,issueID:"1"))
    }
    func testCheckCommitCancellationRemainsCancellationBeforeAndDuringProviderCall() async throws {
        let server=try await Server();defer{server.stop()}
        let provider=try server.session("hold"),captured=context,token=OperationCancellation()
        let before=OperationCancellation();before.cancel()
        do {try await provider.checkCommit(context:captured,cancellation:before);XCTFail("Pre-cancelled CheckCommit succeeded")}
        catch is OperationCancellationFailure {} catch {XCTFail("Pre-cancelled CheckCommit changed error type: \(error)")}
        XCTAssertTrue(try server.records().isEmpty)
        let first=Task {try await provider.checkCommit(context:captured,cancellation:token)}
        defer{token.cancel();first.cancel()}
        try await server.awaitRequests(1);token.cancel()
        do {try await first.value;XCTFail("Cancelled CheckCommit succeeded")}
        catch is OperationCancellationFailure {} catch {XCTFail("Token cancellation became veto/runtime failure: \(error)")}
        let second=Task {try await provider.checkCommit(context:captured)}
        defer{second.cancel()}
        try await server.awaitRequests(2);second.cancel()
        do {try await second.value;XCTFail("Task-cancelled CheckCommit succeeded")}
        catch is OperationCancellationFailure {} catch {XCTFail("Task cancellation became veto/runtime failure: \(error)")}
        try Data().write(to:server.directory.appendingPathComponent("release"))
        try await server.session().checkCommit(context:captured)
    }

}
