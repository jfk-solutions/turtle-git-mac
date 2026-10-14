import XCTest
import Darwin
@testable import TurtleGitCore

final class BlameReadCancellationTests:XCTestCase {
    func testDirectBlobReaderAndEveryOwnedReadBoundary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitBlameRead-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo=GitRepository(root:root),path="雪:tab\tline\n.txt",bytes=Data("first\r\nsecond without LF".utf8)
        _ = try await repo.run(["init","-b","main"])
        _ = try await repo.run(["config","user.name","Blame Read"]);_ = try await repo.run(["config","user.email","read@example.invalid"])
        try bytes.write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.run(["-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","commit","-m","baseline"])
        _ = try await repo.run(["-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","commit","--allow-empty","-m","parent scan"] )
        let snapshot=try await repo.blame(path:path),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        XCTAssertEqual(snapshot.contents,bytes);XCTAssertEqual(snapshot.lines.count,2)
        // A failed whole-tree diff must not affect this single-file operation.
        func quote(_ value:String)->String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        let fast=root.appendingPathComponent("no-diff")
        try "#!/bin/sh\nfor arg in \"$@\"; do if [ \"$arg\" = diff ]; then exit 93; fi; done\nexec /usr/bin/git \"$@\"\n".write(to:fast,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:fast.path)
        let fastResult=try await GitRepository(root:root,executable:fast).blame(path:path);XCTAssertEqual(fastResult.contents,bytes)
        for phase in ["rev-parse","ls-tree","cat-file","blame","log","diff"] {
            let helper=root.appendingPathComponent("held-"+phase),marker=URL(fileURLWithPath:helper.path+".ready")
            let script="""
            #!/bin/sh
            for task_arg in "$@"; do
              if [ "$task_arg" = \(quote(phase)) ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
                /bin/mv "$0.ready.tmp" "$0.ready"
                wait "$task_child"
              fi
            done
            exec /usr/bin/git "$@"
            """
            try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let token=OperationCancellation(),slow=GitRepository(root:root,executable:helper)
            let work=Task {
                if phase=="diff" { _ = try await slow.blameHistoryParentComparisons(snapshot,revision:snapshot.revision,cancellation:token) }
                else if phase=="log" { _ = try await slow.blameHistory(snapshot,options:GitBlameOptions(),cancellation:token) }
                else { _ = try await slow.blame(path:path,cancellation:token) }
            }
            var pids:[Int32]=[]
            for _ in 0..<1000 {
                if let raw=try? String(contentsOf:marker) { pids=raw.split(whereSeparator:\.isWhitespace).compactMap { Int32($0) };if pids.count==2 { break } }
                try await Task.sleep(nanoseconds:5_000_000)
            }
            token.cancel()
            do { try await work.value;XCTFail("Cancelled \(phase) completed") } catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
            XCTAssertEqual(pids.count,2)
            for _ in 0..<500 { if pids.allSatisfy({ kill($0,0) != 0 }) { break };try await Task.sleep(nanoseconds:10_000_000) }
            for pid in pids { XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH) }
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(afterHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
    }
}
