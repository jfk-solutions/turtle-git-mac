import Foundation
@testable import TurtleGitCore

enum GitSVNFixture {
    static func create() async throws -> (URL, GitRepository, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitSVN-雪\n-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = GitRepository(root: root)
        _ = try await real.run(["init", "-b", "main"])
        _ = try await real.run(["config", "user.name", "SVN QA"]); _ = try await real.run(["config", "user.email", "qa@example.invalid"])
        _ = try await real.run(["config", "commit.gpgsign", "false"]); _ = try await real.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await real.stage(["file"]); _ = try await real.commit(message: "base")
        let old = try await real.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: root.appendingPathComponent("file")); try await real.stage(["file"]); _ = try await real.commit(message: "next")
        let next = try await real.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await real.run(["reset", "--hard", old])
        _ = try await real.run(["update-ref", "refs/remotes/git-svn", old])
        _ = try await real.run(["config", "svn-remote.svn.fetch", "trunk:refs/remotes/git-svn"])
        _ = try await real.run(["config", "svn-test.next", next])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/svn"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git/svn/.metadata"))
        let wrapper = root.appendingPathComponent(".git/svn-qa-git")
        let script = #"""
        #!/usr/bin/python3
        import sys,os,json,pathlib,subprocess
        args=sys.argv[1:]; offset=args.index('-C'); root=pathlib.Path(args[offset+1]); command=args[offset+2:]
        if not command or command[0]!='svn': os.execv('/usr/bin/git',['/usr/bin/git']+args)
        with (root/'.git/svn-qa-log').open('a') as log: log.write(json.dumps(command)+'\n')
        def config(key):
            return subprocess.run(['/usr/bin/git','-C',str(root),'config','--get',key],stdout=subprocess.PIPE).stdout.decode().strip()
        if command==['svn','--version']: print('git-svn version 2.55.0 (svn 1.14.5)'); sys.exit(0)
        if command==['svn','fetch']:
            subprocess.run(['/usr/bin/git','-C',str(root),'update-ref','refs/remotes/git-svn',config('svn-test.next')],check=True)
            print('Fetched r2');sys.exit(0)
        if command[1]=='dcommit': print('Committed r3');sys.exit(0)
        if command==['svn','show-ignore']:
            print('ignored*\n雪*')
            if config('svn-test.fail')=='true': print('private failure',file=sys.stderr);sys.exit(1)
            sys.exit(0)
        if command==['svn','create-ignore']: (root/'.gitignore').write_text('created*\n');sys.exit(0)
        sys.exit(2)
        """#
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return (root, GitRepository(root: root, executable: wrapper), old, next)
    }
}
