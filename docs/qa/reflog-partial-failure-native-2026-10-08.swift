import AppKit
import TurtleGitCore

@main struct ReferenceLogPartialFailureVerification {
    @MainActor static func wait(_ model: ReferenceLogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), direct = GitRepository(root: root, executable: git)
        _ = try await direct.run(["init", "-b", "main"])
        _ = try await direct.run(["config", "user.name", "Failure QA"]); _ = try await direct.run(["config", "user.email", "qa@example.invalid"])
        _ = try await direct.run(["config", "commit.gpgsign", "false"]); _ = try await direct.run(["config", "core.hooksPath", "/dev/null"])
        var commitIDs=[String]()
        for n in 0..<4 { try Data("commit \(n)".utf8).write(to: root.appendingPathComponent("file")); try await direct.stage(["file"]); _ = try await direct.commit(message: "commit \(n)");commitIDs.append(try await direct.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)) }
        let named="refs/heads/partial-cafe\u{301}"
        let wrapper = root.appendingPathComponent("fail-delete.sh"), calls = root.appendingPathComponent("calls"), mode = root.appendingPathComponent("mode")
        let script = """
        #!/bin/sh
        task_receipt=$(/usr/bin/mktemp -d "$0.receipts/call.XXXXXX") || exit 78
        printf '%s\\0' "$@" > "$task_receipt/argv"
        task_parse() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --literal-pathspecs|--no-literal-pathspecs|--no-pager|--paginate|--no-optional-locks|--no-replace-objects|--no-lazy-fetch|--no-advice|--bare) shift ;;
              --version|--help|--exec-path|--html-path|--man-path|--info-path) break ;;
              -C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source)
                [ "$#" -ge 2 ] || return 2
                shift 2 ;;
              -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*|--attr-source=*) shift ;;
              --) shift; break ;;
              -*) printf 'Unexpected authored wrapper global option: %s\\n' "$1" >&2; return 2 ;;
              *) break ;;
            esac
          done
          if { [ "${1-}" = reflog ] && [ "${2-}" = delete ]; } || { [ "${1-}" = stash ] && [ "${2-}" = drop ]; }; then
            [ "${3-}" = -- ] && [ "$#" -eq 4 ] || return 2
            printf '%s\\n' "$4" >> \(quote(calls.path))
            if [ -f \(quote(mode.path)) ]; then
              if [ "$(/bin/cat \(quote(mode.path)))" = all ] || [ "$4" = 'HEAD@{2}' ] || [ "$4" = 'refs/stash@{2}' ] || [ "$4" = \(quote(named+"@{2}")) ]; then
                printf 'injected failure: 雪\\n' >&2; return 77
              fi
            fi
          fi
        }
        task_parse "$@"
        task_status=$?
        [ "$task_status" -eq 0 ] || exit "$task_status"
        exec \(quote(git.path)) "$@"
        """
        let receipts=URL(fileURLWithPath:wrapper.path+".receipts")
        try FileManager.default.createDirectory(at:receipts,withIntermediateDirectories:true)
        try script.write(to: wrapper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let suite="TurtleGit.RefLogPartial."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let model = ReferenceLogWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, reference: "HEAD",preferences:prefs)
        defer {model.invalidate()}
        model.confirmDelete = { _, _, proceed in proceed() }; model.reload(); try await wait(model); let rows = model.entries
        let head = try await direct.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        var refreshed = 0, failures: [String] = []
        model.onChanged = { _ in refreshed += 1 }
        model.presentDeletionFailure = { issue in
            await MainActor.run { precondition(model.busy && issue.details.contains("雪")); failures.append(issue.selector) }
            // Async per-error acknowledgement completes before the next deletion starts.
            try? await Task.sleep(nanoseconds: 10_000_000)
            let attempted = try! String(contentsOf: calls).split(separator: "\n").map(String.init)
            precondition(attempted == ["HEAD@{3}", "HEAD@{2}"])
        }
        try "middle".write(to: mode, atomically: true, encoding: .utf8)
        model.delete(Set(rows.map(\.id))); try await wait(model)
        precondition(model.error == nil && model.deletionReport?.contains("Deleted entries: 3. Failed entries: 1.") == true && failures == [rows[2].id] && refreshed == 1)
        precondition(model.entries.map(\.subject) == [rows[2].subject])
        let attempts = try String(contentsOf: calls).split(separator: "\n").map(String.init); precondition(attempts == rows.reversed().map(\.id))
        try FileManager.default.removeItem(at: mode); model.delete(Set(model.entries.map(\.id))); try await wait(model)
        precondition(model.error == nil && model.deletionReport == nil && model.entries.isEmpty && refreshed == 2)
        // All-failed batches still refresh and retain all rows; headless callers get the summary error.
        _ = try await direct.run(["reset", "--soft", "HEAD"]); _ = try await direct.run(["reset", "--soft", "HEAD"])
        model.reload(); try await wait(model); let allRows = model.entries
        model.presentDeletionFailure = nil; try "all".write(to: mode, atomically: true, encoding: .utf8)
        model.delete(Set(allRows.map(\.id))); try await wait(model)
        precondition(model.entries == allRows && model.error?.contains("Deleted entries: 0. Failed entries: 2.") == true && refreshed == 3)
        let afterHead = try await direct.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && index == afterIndex && config == afterConfig && file == afterFile)
        try FileManager.default.removeItem(at: mode)
        for n in 0..<4 { try Data("stash \(n)".utf8).write(to: root.appendingPathComponent("file")); _ = try await direct.saveStash(StashSaveOptions()) }
        model.reference = "refs/stash"; model.reload(); try await wait(model); let stashes = model.entries
        try "middle".write(to: mode, atomically: true, encoding: .utf8); model.delete(Set(stashes.map(\.id))); try await wait(model)
        precondition(model.entries.map(\.hash) == [stashes[2].hash] && model.error?.contains("Deleted entries: 3. Failed entries: 1.") == true && refreshed == 4)
        try FileManager.default.removeItem(at: mode); model.delete(Set(model.entries.map(\.id))); try await wait(model)
        precondition(model.entries.isEmpty && model.error == nil && model.deletionReport == nil && refreshed == 5)
        // A decomposed ordinary reference must retain its exact namespace and
        // selector spelling through reads, fault injection, retry and deletion.
        for hash in commitIDs {_ = try await direct.run(["-c","core.precomposeunicode=false","update-ref","--create-reflog",named,hash])}
        model.reference=named;model.reload();try await wait(model);let namedRows=model.entries
        precondition(namedRows.count==4 && namedRows.allSatisfy{$0.id.utf8.starts(with:(named+"@{").utf8)},"Named RefLog selectors changed namespace/Unicode spelling")
        try "middle".write(to:mode,atomically:true,encoding:.utf8);model.delete(Set(namedRows.map(\.id)));try await wait(model)
        precondition(model.entries.map(\.subject)==[namedRows[2].subject] && model.error?.contains("Deleted entries: 3. Failed entries: 1.")==true && refreshed==6)
        try FileManager.default.removeItem(at:mode);model.delete(Set(model.entries.map(\.id)));try await wait(model)
        precondition(model.entries.isEmpty && model.error==nil && refreshed==7)
        let namedAttempts=try String(contentsOf:calls).split(separator:"\n").map(String.init).filter{$0.utf8.starts(with:(named+"@{").utf8)}
        precondition(namedAttempts.map{Array($0.utf8)}==(namedRows.reversed().map(\.id)+[namedRows[2].id.replacingOccurrences(of:"@{2}",with:"@{0}")]).map{Array($0.utf8)},"Named deletion receipts changed order or selector bytes")
        let namedHead=try await direct.run(["-c","core.precomposeunicode=false","rev-parse","--verify",named]).stdout
        let currentHead=try await direct.run(["rev-parse","HEAD"]).stdout
        precondition(namedHead==head && currentHead==head,"Named reflog deletion moved its branch or HEAD")
        _ = try await direct.run(["-c","core.precomposeunicode=false","update-ref","-d",named])
        let invocations=try FileManager.default.contentsOfDirectory(at:receipts,includingPropertiesForKeys:nil).map {directory -> [String] in
            let bytes=try Data(contentsOf:directory.appendingPathComponent("argv"));precondition(bytes.last==0,"Wrapper argv receipt lost NUL termination")
            return bytes.split(separator:0,omittingEmptySubsequences:false).dropLast().map{String(decoding:$0,as:UTF8.self)}
        }
        for command in ["reflog","stash"] {
            let records=invocations.filter{let identity=GitCommandIdentity($0);return identity.command==command && ["delete","drop"].contains(identity.arguments.first ?? "")}
            precondition(!records.isEmpty && records.allSatisfy {arguments in arguments.indices.dropLast().contains{arguments[$0]=="-c" && arguments[$0+1]=="core.precomposeunicode=false"}},"Exact Unicode global configuration was not retained in deletion argv")
        }
        print("RefLog partial failure: real HEAD/stash/exact-Unicode named-reference batches continue after middle command failure, async per-error acknowledgement precedes next command, complete/failed selectors and Unicode diagnostics retained, partial/all-failed refresh and retry reset, semantic global-prefix/NUL argv receipts and ordinary HEAD/index/config/worktree preserved passed; no displayed UI")
    }
}
