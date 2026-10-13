# Working-copy revision utility

`TurtleGitWCRev` ports the pinned `GitWCRev` command-line and template workflow to
macOS. It is available as a SwiftPM executable and is embedded at
`TurtleGitMac.app/Contents/MacOS/TurtleGitWCRev`. Source references are
`src/GitWCRev/GitWCRev.cpp`, `status.cpp`, `GitWCRev.h`, and the two unchanged
upstream test templates at commit `7338078f8ddd924b8cddee35f512f2286072136d`.

```sh
swift build --product TurtleGitWCRev
.build/debug/TurtleGitWCRev /path/to/repository Version.in Version.out -mUq
.build/debug/TurtleGitWCRev --json /path/to/repository
```

The source invocation shape is retained: Path, optionally template and output,
then one combined switch argument. `-m` fails on file modifications or changed
submodule HEAD; `-M` also includes submodule file modifications. `-u` fails on
unversioned/staged-added files; `-U` also includes submodule unversioned files.
As upstream, either capital switch enables the recursive error mode for both
requested checks. `-s` omits submodules, `-q` suppresses normal status output,
`-d` rejects an existing destination, and `-e` writes UTF-16 LE console output.
Default macOS output is UTF-8. Error diagnostics use UTF-8 stderr.

The exit codes are 1 for syntax, 2 for a missing path/template, 3 for template
open/exclusive destination creation failures, 5 for write failures, 6 for other
Git failures, 7 for requested modification rejection, 9 for an existing `-d`
destination, 10 for a non-working-tree/bare path, and 11 for requested unversioned
rejection. The source's allocation-specific code 4 is not synthesized by Swift.

Repository reads use literal selected paths and disable optional index writes.
The utility returns HEAD hash, symbolic branch or detached hash, author time,
mailmap author/email, first-parent commit count, lightweight/annotated tag state,
and scoped file/submodule flags. An unborn branch returns a zero hash/count and
its symbolic branch. The repository root is versioned; directories inside it
are not versioned; staged-added files are unversioned in this source contract.
`.GitWCRevignore` at the working-tree root supplies extra exclusion patterns.
These are passed as Git CLI exclusion pathspecs; exact libgit2 wildcard differences
and unusual ignore encodings remain to be compared.

All source placeholders are supported:

- `$WCREV$` and `$WCREV=N$`, with base-0 length parsing.
- `$WCBRANCH$`.
- `$WCLOGCOUNT$`, `$WCLOGCOUNT&N$`, `$WCLOGCOUNT+N$`, `$WCLOGCOUNT-N$`.
- `$WCDATE$`, `$WCDATEUTC$`, `$WCNOW$`, `$WCNOWUTC$`, and their `=strftime` forms.
- `$WCMODS?yes:no$`, `$WCUNVER?yes:no$`, `$WCISTAGGED?yes:no$`,
  `$WCINGIT?yes:no$`, `$WCFILEMODS?yes:no$`, `$WCSUBMODULE?yes:no$`,
  `$WCSUBMODULEUP2DATE?yes:no$`, `$WCMODSINSUBMODULE?yes:no$`,
  `$WCUNVERINSUBMODULE?yes:no$`, `$WCUNVERFULL?yes:no$`,
  `$WCMODSFULL?yes:no$`.

Several source names are surprising: `WCSUBMODULE` is set while processing a
changed submodule status entry, so a clean submodule does not set it. Within a
submodule, changed HEAD takes precedence over modified files, which take
precedence over untracked files. `WCMODSFULL` includes file modifications,
submodule modifications and submodule untracked files, but excludes changed
submodule HEAD. These source rules are preserved rather than silently corrected.

Byte templates preserve unrelated bytes and use UTF-8 for inserted branch names.
UTF-16 LE templates (with BOM or an ASCII initial prefix) and BOM-marked UTF-16 BE
are supported. Existing line endings remain unchanged. Unknown/malformed tokens
remain literal. Numeric/date format specifications are bounded to 1024 bytes;
date output is bounded to a 1024-byte buffer. Date names/local timezone come from
macOS, and Windows `#` modifiers map to native `-` modifiers; exact Windows locale
and every format variant remain unverified. Templates do not execute code.
Unchanged output is not rewritten, preserving its timestamp. `-d` uses exclusive
creation so a destination created after preflight cannot be overwritten.

`--json` exposes the Codable status fields as native automation, replacing the
Windows COM status-reading role. Windows COM registration and binary interfaces
are not provided on macOS. In non-App-Store tools, `TURTLEGIT_WCREV_GIT` can select
an absolute executable Git path. App Store builds ignore that override and use
the containing app's bundled Git. The embedded tool receives inherited sandbox
entitlements when signed in the AppStore configuration; execution from a sandboxed
parent requires that parent's file grants. Standalone SwiftPM builds are intended
for shell/build-system use. Signed App Store helper invocation and external
Terminal use of the sandboxed embedded tool remain acceptance work.

Five focused Core checks pass for templates, malformed/binary/legacy/UTF-16
input, scoped tracked/staged/unborn/ignored paths, tags/detachment, submodule
precedence/skip and index preservation. The initial index fixture failure was
fixed to compare around the utility read rather than across its own Git reset.
Four grouped CLI checks pass across standalone/packaged products and system/
bundled Git, including both unchanged upstream templates. SwiftPM and Debug
builds, the unsigned bundle audit and two documentation checks pass. No GUI
instances were launched. [QA evidence](qa/wcrev-2026-10-13.json) records the scope;
this is not full source or signed distribution certification.

WCRev now honors the saved UseMailmap setting and its reader accepts an explicit
policy for isolated callers. See [identity display parity](IDENTITY-DISPLAY-PARITY.md).
