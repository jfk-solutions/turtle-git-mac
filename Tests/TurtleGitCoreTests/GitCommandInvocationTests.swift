import XCTest
@testable import TurtleGitCore

final class GitCommandInvocationTests:XCTestCase {
    private struct Record {let invocation:GitCommandInvocation;let before:Data?;let message:Data?}
    private final class Capture:@unchecked Sendable {
        private let lock=NSLock()
        private var records:[Record]=[],events:[String]=[]
        func command(_ invocation:GitCommandInvocation,before:URL){
            let message=invocation.arguments.firstIndex(of:"-F").flatMap {index in invocation.arguments.indices.contains(index+1) ? (try? Data(contentsOf:URL(fileURLWithPath:invocation.arguments[index+1]))):nil}
            let record=Record(invocation:invocation,before:try? Data(contentsOf:before),message:message)
            lock.lock();records.append(record);events.append("command");lock.unlock()
        }
        func output(_ chunk:GitOutputChunk){lock.lock();events.append("output");lock.unlock()}
        func snapshot()->([Record],[String]){lock.lock();defer{lock.unlock()};return(records,events)}
    }
    private struct Fixture {let root:URL;let repository:GitRepository;let arguments:URL}
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Command '雪 "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=root.appendingPathComponent("Git 'tool"),arguments=root.appendingPathComponent("actual-arguments")
        let git=GitRepository(root:root).executable
        func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="#!/bin/sh\n/usr/bin/printf '%s\\0' \"$@\" > "+quote(arguments.path)+"\nexec "+quote(git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        let repository=GitRepository(root:root,executable:executable)
        _=try await repository.run(["init","-b","main"])
        _=try await repository.run(["config","user.name","Invocation Tests"])
        _=try await repository.run(["config","user.email","invocation@example.invalid"])
        _=try await repository.run(["config","commit.gpgsign","false"])
        _=try await repository.run(["config","core.hooksPath","/dev/null"])
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file.txt"))
        try await repository.stage(["file.txt"]);_=try await repository.commit(message:"base")
        return Fixture(root:root,repository:repository,arguments:arguments)
    }
    private func assertActual(_ invocation:GitCommandInvocation,in fixture:Fixture,file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertEqual(invocation.executable.path,fixture.repository.executable.path,file:file,line:line)
        XCTAssertEqual(invocation.directory.path,fixture.root.path,file:file,line:line)
        XCTAssertEqual(Array(invocation.arguments.prefix(3)),["--literal-pathspecs","-C",fixture.root.path],file:file,line:line)
        let bytes=try Data(contentsOf:fixture.arguments)
        XCTAssertEqual(bytes,Data(invocation.arguments.map{$0+"\0"}.joined().utf8),"Receipt differs from argv delivered to the actual Git process",file:file,line:line)
    }
    func testQuotedDisplayPreservesControlAndUnicodeBytesAndExactIdentity() {
        let invocation=GitCommandInvocation(executable:URL(fileURLWithPath:"/tmp/Git tool's/雪"),directory:URL(fileURLWithPath:"/tmp/work tree"),arguments:["--literal-pathspecs","-C","/tmp/work tree","","a'b","line\n\tend","\u{1b}[31m","é","e\u{301}","$(touch PWNED)"])
        let expected="'/tmp/Git tool'\\''s/雪' --literal-pathspecs -C '/tmp/work tree' '' 'a'\\''b' 'line\n\tend' '\u{1b}[31m' 'é' 'e\u{301}' '$(touch PWNED)'\n"
        XCTAssertEqual(invocation.preamble,Data(expected.utf8))
        let common=URL(fileURLWithPath:"/tmp/git")
        let nfc=GitCommandInvocation(executable:common,directory:common,arguments:["é"])
        let nfd=GitCommandInvocation(executable:common,directory:common,arguments:["e\u{301}"])
        XCTAssertNotEqual(nfc,nfd)
        let nfcURL=URL(string:"file:///tmp/%C3%A9")!,nfdURL=URL(string:"file:///tmp/e%CC%81")!
        XCTAssertNotEqual(Data(nfcURL.path.utf8),Data(nfdURL.path.utf8),"Fixture URL paths must retain distinct original bytes")
        XCTAssertNotEqual(GitCommandInvocation(executable:nfcURL,directory:common,arguments:[]),GitCommandInvocation(executable:nfdURL,directory:common,arguments:[]))
        XCTAssertNotEqual(GitCommandInvocation(executable:common,directory:nfcURL,arguments:[]),GitCommandInvocation(executable:common,directory:nfdURL,arguments:[]))
    }
    func testMergeReceiptMatchesExecutedArgumentsAndPrecedesOutputAndMutation()async throws {
        let fixture=try await fixture();defer{try? FileManager.default.removeItem(at:fixture.root)}
        let repo=fixture.repository,root=fixture.root
        _=try await repo.run(["checkout","-b","feature"])
        try Data("feature\n".utf8).write(to:root.appendingPathComponent("feature.txt"));try await repo.stage(["feature.txt"]);_=try await repo.commit(message:"feature")
        _=try await repo.run(["checkout","main"])
        let reference=root.appendingPathComponent(".git/refs/heads/main"),before=try Data(contentsOf:reference),capture=Capture()
        var options=MergeOptions();options.revision="refs/heads/feature";options.noFastForward=true;options.message="Captured merge message\n";options.requireIdentity=false
        _=try await repo.merge(options,onOutput:capture.output,onCommand:{capture.command($0,before:reference)})
        let (records,events)=capture.snapshot();XCTAssertEqual(records.count,1);let record=try XCTUnwrap(records.first)
        try assertActual(record.invocation,in:fixture)
        XCTAssertEqual(Array(record.invocation.arguments.dropFirst(3).prefix(3)),["merge","--no-edit","--no-ff"])
        XCTAssertEqual(Array(record.invocation.arguments.suffix(2)),["--","refs/heads/feature"])
        XCTAssertEqual(record.before,before);XCTAssertNotEqual(try Data(contentsOf:reference),before)
        XCTAssertTrue(String(decoding:try XCTUnwrap(record.message),as:UTF8.self).contains("Captured merge message"))
        XCTAssertEqual(events.first,"command");XCTAssertTrue(events.contains("output"))
        let text=try await repo.run(["show","--format=%B","--no-patch","HEAD"]).text
        XCTAssertTrue(text.contains("Captured merge message"))
    }
    func testCheckoutReceiptIncludesActualGlobalConfigurationAndPrecedesMutation()async throws {
        let fixture=try await fixture();defer{try? FileManager.default.removeItem(at:fixture.root)}
        let repo=fixture.repository,root=fixture.root,branch="side'雪"
        _=try await repo.run(["branch",branch])
        let head=root.appendingPathComponent(".git/HEAD"),before=try Data(contentsOf:head),capture=Capture()
        var options=CheckoutOptions();options.revision="refs/heads/"+branch
        _=try await repo.checkout(options,onOutput:capture.output,onCommand:{capture.command($0,before:head)})
        let (records,events)=capture.snapshot();XCTAssertEqual(records.count,1);let record=try XCTUnwrap(records.first)
        try assertActual(record.invocation,in:fixture)
        XCTAssertEqual(Array(record.invocation.arguments.dropFirst(3)),["-c","core.precomposeunicode=false","switch","--no-guess","--",branch])
        XCTAssertEqual(record.before,before);XCTAssertNotEqual(try Data(contentsOf:head),before)
        XCTAssertEqual(events.first,"command");XCTAssertTrue(events.contains("output"))
        let current=try await repo.branch();XCTAssertEqual(current,branch)
    }
    func testResetReceiptMatchesActualPlanAndPrecedesWorkingTreeMutation()async throws {
        let fixture=try await fixture();defer{try? FileManager.default.removeItem(at:fixture.root)}
        let repo=fixture.repository,root=fixture.root,file=root.appendingPathComponent("file.txt")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("latest\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"latest")
        let plan=try await repo.prepareReset(to:base,mode:.hard),capture=Capture()
        _=try await repo.reset(plan,onOutput:capture.output,onCommand:{capture.command($0,before:file)})
        let (records,events)=capture.snapshot();XCTAssertEqual(records.count,1);let record=try XCTUnwrap(records.first)
        try assertActual(record.invocation,in:fixture)
        XCTAssertEqual(Array(record.invocation.arguments.dropFirst(3)),["reset","--hard",base,"--"])
        XCTAssertEqual(record.before,Data("latest\n".utf8));XCTAssertEqual(try Data(contentsOf:file),Data("base\n".utf8))
        XCTAssertEqual(events.first,"command");XCTAssertTrue(events.contains("output"))
    }
    func testInvalidCancelledAndStalePreflightsPublishNoCommand()async throws {
        let fixture=try await fixture();defer{try? FileManager.default.removeItem(at:fixture.root)}
        let repo=fixture.repository,root=fixture.root,file=root.appendingPathComponent("file.txt"),capture=Capture()
        let before=try Data(contentsOf:file),head=try Data(contentsOf:root.appendingPathComponent(".git/HEAD"))
        var merge=MergeOptions();merge.revision="refs/heads/missing";merge.requireIdentity=false
        do{_=try await repo.merge(merge,onCommand:{capture.command($0,before:file)});XCTFail("Invalid Merge accepted")}catch MergeFailure.revision{}
        var checkout=CheckoutOptions();checkout.revision="refs/heads/missing"
        do{_=try await repo.checkout(checkout,onCommand:{capture.command($0,before:file)});XCTFail("Invalid Checkout accepted")}catch CheckoutFailure.invalidRevision{}
        let plan=try await repo.prepareReset(to:"HEAD",mode:.hard),token=OperationCancellation();token.cancel()
        merge.revision="HEAD";checkout.revision="refs/heads/main"
        do{_=try await repo.merge(merge,cancellation:token,onCommand:{capture.command($0,before:file)});XCTFail("Cancelled Merge accepted")}catch OperationCancellationFailure.cancelled{}
        do{_=try await repo.checkout(checkout,cancellation:token,onCommand:{capture.command($0,before:file)});XCTFail("Cancelled Checkout accepted")}catch OperationCancellationFailure.cancelled{}
        do{_=try await repo.reset(plan,cancellation:token,onCommand:{capture.command($0,before:file)});XCTFail("Cancelled Reset accepted")}catch OperationCancellationFailure.cancelled{}
        XCTAssertEqual(try Data(contentsOf:file),before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/HEAD")),head)
        try Data("moved\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"moved")
        do{_=try await repo.reset(plan,onCommand:{capture.command($0,before:file)});XCTFail("Stale Reset accepted")}catch ResetFailure.changedHead{}
        XCTAssertTrue(capture.snapshot().0.isEmpty);XCTAssertEqual(try Data(contentsOf:file),Data("moved\n".utf8))
    }
}
