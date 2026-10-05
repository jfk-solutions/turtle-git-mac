# Issue tracker integration audit

The pinned TortoiseGit baseline is
`7338078f8ddd924b8cddee35f512f2286072136d`. The audited files are
`src/TortoiseProc/ProjectProperties.cpp`, its header, and
`test/UnitTests/ProjectPropertiesTest.cpp`. Their Git blob hashes match the
repository inventory. This is a partial port; the native Commit issue field,
property loader, message insertion and warning controls are still pending.
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

## Remaining Commit behavior

- Load repository, working-tree `.tgitconfig`, global/XDG/system values with
  the upstream precedence, including linked worktrees and bare repositories.
- Show the configurable issue label and field when `bugtraq.message` exists;
  preserve numeric/comma/space validation and regex precedence.
- Extract/remove a template issue line when seeding a message; normalize IDs,
  avoid duplicate insertion and honor append/prepend behavior.
- Preserve `bugtraq.warnifnoissue`, signed-off-by and unedited-template warning
  order before any index mutation; support native cancellation.
- Add tracker links with exact URL-component escaping, natural ID ordering,
  message-history selection and native text highlighting.
- Audit Windows tracker-provider plugins and define the macOS equivalent.
- Compare native light/dark Commit layouts and all controls with upstream;
  exercise scoped and signed builds, hooks and message-only commits.

See [Commit parity](COMMIT-PARITY.md) for the broader dialog audit. Original
source references are [ProjectProperties.cpp](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/ProjectProperties.cpp)
and the [official integration manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-bugtracker.html).
