# Issue tracker integration audit

The pinned TortoiseGit baseline is
`7338078f8ddd924b8cddee35f512f2286072136d`. The audited files are
`src/TortoiseProc/ProjectProperties.cpp`, its header, and
`test/UnitTests/ProjectPropertiesTest.cpp`. Their Git blob hashes match the
repository inventory. The native Commit field, configuration loader, template
line handling and warning sequence are implemented, with broader integration
and signed sandbox acceptance still pending.
Build, process, source reconstruction and signing evidence is recorded in
[runtime acceptance](qa/issue-regex-runtime-2026-10-05.json).

## Matching engine

Upstream `FindBugIDPositions` uses C++ `std::wregex` with its default ECMAScript
grammar. One expression extracts capture group 1. Two expressions use the
complete second-expression matches inside each complete first-expression match.
A captureless first expression can satisfy `HasBugID` while extracting no IDs.
`HasBugID` searches only the first expression. UTF-16 character positions are
required by the Windows source and by native `NSString` ranges.

TurtleGit retains this C++ algorithm in `Sources/TurtleGitIssueRegex/main.cpp`.
macOS has 32-bit `wchar_t`, so the transport stores one UTF-16 code unit per
wide character. A private helper process receives three UTF-16LE files and
returns match presence and UTF-16 ranges. The Swift reader validates those
ranges. Inputs are argument arrays without a shell; diagnostic text is limited
to 1024 bytes. A shared runner bounds execution to five seconds plus a
one-second termination grace and forcibly reaps its own unresponsive process.
EditorConfig now uses the same runner. Excessive helper output is rejected.

The helper reports malformed expressions as an explicit failure. Upstream
silently catches compilation failures and may retain previously compiled
expressions. This error-state behavior is not yet mapped in the native property
loader. Matching grammar and UTF-16 positions are retained; libc++ versus MSVC
locale, character-class, pathological-expression and exception differences
still need cross-platform acceptance. No Foundation/ICU regex substitution is
used.

## Build and distribution

Run `python3 scripts/build-issue-regex-runtime.py` before Swift tests or a direct
Xcode build. CI and `scripts/build.sh` prepare it automatically. All Xcode
configurations embed `build/issue-regex-runtime/IssueRegex` at
`Contents/Helpers/IssueRegex`. The generated project includes the new Swift
reader and shared runner. The package contains the complete helper source,
GPL license, reconstruction and validation scripts, and source/binary hashes.
Only system dynamic libraries are linked; no Homebrew C++ runtime is required.

The validator checks both architecture slices and their macOS 13 load commands,
source correspondence, licenses and functional protocol examples. Add
`--all-architectures` to execute arm64 and x86_64 explicitly; Apple Silicon
requires Rosetta for the latter. This does not prove execution on an actual
Intel Mac or macOS 13 host.

AppStore signing applies only App Sandbox and sandbox inheritance to this
helper. Debug/Release use ordinary hardened-runtime signing. The unsigned
package is executed before signing; inherited sandbox signatures and
entitlements are inspected afterwards. Running an inherited helper directly
from unsandboxed Python does not prove signed app invocation and is skipped.
Debug preview signing updates both text-helper hashes and reseals the app.
Signed native App Store execution and scoped configuration access remain
unverified.

## Native Commit controls

`IssueTrackerProperties` reads Git's system/global/XDG values, overlays the
working tree's `.tgitconfig`, then overlays repository configuration. Native
Git worktree and command scopes remain higher priority on macOS. Includes use
Git's parser and relative file paths. A bare repository reads `HEAD:.tgitconfig`.
The configured label and issue field appear in the upper-right branch row, as
in the upstream resource at x=177/249, y=6/3; absent `bugtraq.message` hides them.
Initial issue focus and template-line extraction were verified in dark mode.

Numeric IDs accept only ASCII digits, commas and spaces. Template extraction
uses UTF-16 positions and trims only LF, including leaving CR from CRLF intact.
Message insertion trims the field, performs the upstream comma-space
replacement, avoids duplicate IDs and honors append/prepend. URL component
escaping is implemented and tested, but clickable native links remain pending.
Foundation supplies numeric comparison for natural ID ordering; full
`StrCmpLogicalW` locale/punctuation/equivalent-ID behavior is not proven.

Commit checks missing issue ID, exact unedited template, and missing identity
sign-off in that order. Each warning completes before committing or modifying
the index. Add Signed-off-by and the warning use the same identity and trailer
placement. Template comparison retains the upstream exact-text behavior:
extracting a template line trims trailing LF, which can change equality with
the original template. This source quirk is not normalized away.

Native No/Abort and numeric rejection retained HEAD and raw index bytes. A
real checked-file commit added the exact configured sign-off and `Refs: 42`
line, committed the latest selected contents, and preserved unchecked staged
and working versions. The field seeded `73` from a template and received
initial focus in dark mode. All QA apps were closed. Twenty-eight focused
Commit/issue/message tests and both unsigned app builds/resource audits passed.
See [control acceptance](qa/commit-issue-controls-2026-10-05.json).

![Actual native issue field](site/assets/commit-issue.png)
![Actual native seeded issue field in dark mode](site/assets/commit-issue-dark.png)

## Remaining Commit behavior

- Validate XDG/system includes, conditional includes and scoped ancestor access
  in a signed app, and review CLI versus libgit2 precedence differences.
- Complete clickable tracker links, exact Windows natural ID ordering,
  history-selection field updates and native message highlighting.
- Audit Windows tracker-provider plugins and define the macOS equivalent.
- Compare native light/dark Commit layouts and all controls with upstream;
  exercise scoped/signed builds, hooks, message-only and ReCommit/Push combinations.

See [Commit parity](COMMIT-PARITY.md) for the broader dialog audit. Original
source references are [ProjectProperties.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/ProjectProperties.cpp)
and the [official integration manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-bugtracker.html).
