# TurtleGit for Mac — full port tracking

*A macOS fork of TortoiseGit*

The target is complete behavioral parity, with native macOS windows and Finder
integration. This first implementation establishes the architecture and common
workflows. It does **not** represent the complete port or reproduce all upstream
windows. No item is complete merely because its underlying Git command runs.

## Audited baseline

Upstream: https://github.com/TortoiseGit/TortoiseGit

Commit: `7338078f8ddd924b8cddee35f512f2286072136d`.

The checked-in inventory covers 3,277 tracked entries and 129 dialog resources.
`upstream-files.csv` maps paths, blob hashes, review status, replacement and notes.
`upstream-dialogs.csv` lists dialog resources and captions, including the settings
pages and helper applications. Gitlinks must be recursively audited before using
those dependencies. Resources such as menus, icons, accelerators and strings also
require review; a dialog count is not a count of all upstream UI.

## Architecture replacements

| Upstream component | macOS replacement | Current state |
| --- | --- | --- |
| TortoiseProc / MFC | SwiftUI windows, AppKit text views and file dialogs | First status, commit, log and operation views |
| src/Git | TurtleGitCore repository actor and installed Git | Basic status, mutation and patch operations |
| TortoiseShell / COM | Finder Sync extension and URL routing | Compiles; signed end-to-end behavior unverified |
| TGitCache | App Group snapshot, directory badge aggregation | Active repository polling; independent daemon pending |
| TortoiseMerge | Native side-by-side and three-way merge windows | Pending |
| TortoiseGitBlame | Native annotated source window | Pending |
| TortoiseIDiff | Native image comparison window | Pending |
| TortoiseUDiff | Native syntax-highlighted patch window | Plain patch output only |
| SshAskPass / TortoisePlink | Git helpers, Keychain and OpenSSH | Existing helper configuration only |
| GitWCRev / COM | Portable revision/template CLI and macOS automation | Pending; COM must be replaced |
| TortoiseGitSetup | Signed app, extension registration, notarized distribution | Development and sandboxed AppStore configurations compile; runtime packaging/signing pending |
| Languages / ResText | String catalogs and native localized resources | Pending |

## Behavioral parity backlog

| Workflow | First-pass implementation | Remaining upstream behavior |
| --- | --- | --- |
| Check for modifications | NUL-safe porcelain parsing; conflicts, renames, ignored files | Remote status, changelists, locks, filters, stats, detailed actions |
| Commit | Stage/unstage, commit message, entire staged index | Amend, selection-aware commits, hooks UI, completion, issue trackers, history |
| Log | Separate native three-pane window; graph, refs, message/files/line counts, search/date filters, load more, comparisons and revision actions | Working-tree row, actions column, branch/ref chooser, author search, walk/view controls, statistics, multi-revision file union, remaining context commands; see LOG-PARITY.md |
| Diff | Index/worktree/commit textual patches | Side-by-side, syntax colors, hunk staging, binary/image handling, external tools |
| Clone / init | Destination picker and Git operation | Branch, recursive submodules, bare repos, advanced options and progress |
| Fetch / pull / push | Git defaults; pull fast-forward only | Remote/ref pickers, tags, force-with-lease, progress, cancellation, authentication |
| Branch / tag / switch | Name or revision entry | Annotated/signed tags, tracking, orphan branches, force choices, ref browsing |
| Merge / rebase | Start operation | Conflict editor, continuation, abort, interactive rebase and commit editing |
| Stash | Save message and pop latest | List, inspect, apply selected, drop, include untracked, branch from stash |
| Finder | Monitored-root submenu and cache badge source | Signed QA, multi-selection, watched-root management, cache daemon/FSEvents |
| Settings | Not yet implemented | Git identity, tools, overlays, dialogs, hooks, credentials, networking, localization |
| Other commands | Log-selected reset, revert without commit and cherry-pick | Full options, conflict continuation/abort, remove, rename, ignore, resolve, bisect, clean, export |
| Patch workflows | Not yet implemented | Format/apply patches, am continuation/abort, review, email integration |
| Advanced repositories | Linked-worktree discovery | Submodule, worktree management, git-svn, LFS, repository browser, reflog |
| Helper apps | Not yet implemented | Blame, image diff, merge, revision graph, askpass, revision/template tools |

## Porting method

1. Review a file and its related call sites, resource IDs, tests and documentation.
2. Record whether it is portable, requires a framework replacement, is an external
   dependency, or is Windows infrastructure with a documented macOS equivalent.
3. Implement its behavior in the named macOS module. Shared upstream logic can be
   retained as C/C++ where that reduces divergence; Windows UI is rewritten.
4. Compare native dialogs against upstream controls, options, defaults, shortcuts,
   error behavior and selection semantics. Preserve familiar workflow ordering and
   status colors while using macOS layout, menus and accessibility.
5. Exercise real Git fixtures for expected results and failure/conflict cases.
6. Mark a feature parity-complete only after all relevant source/resource mappings,
   behavior tests and UI acceptance checks pass. Platform exclusions need explicit
   rationale and a replacement or an acknowledged gap.

Every unreviewed file remains pending. The initial mapped command and dialog rows
are marked **partial**, not complete. A broad Swift rewrite still needs this
source-by-source audit; copying C++ files alone would not establish parity.

## Validation so far

`swift test` covers raw path parsing, renames/conflicts, stage/unstage including an
unborn branch, multiline commits and log parsing, working-tree diffs, literal
wildcard filenames, ignored files, linked worktrees, large output without deadlock,
failure propagation, blank message rejection, directory badge aggregation and
branch/tag/switch/merge/rebase argument compatibility with Git.

Manual UI checks on a disposable repository verified the branding, status list,
selected-file diff and history. They also caught and fixed an absent shared-cache
directory failure and a commit-layout issue that squeezed the file list.

The application, shared framework and embedded Finder extension compile using
`xcodebuild` with signing disabled. These checks do not establish Finder activation,
signed App Group access, accessibility, full UI correctness, credential prompts,
Intel compatibility or upstream parity.

## App Store preparation

Saved security-scoped repository permissions and a separate sandboxed AppStore
configuration have been added. The runtime selector requires a bundled Git engine
for that configuration. See `DISTRIBUTION.md` for the unresolved runtime, signing,
worktree permissions and license gates. These changes do not narrow the full-port
objective or establish App Store readiness.

The current Swift package builds and 24 tests pass, including topological graph
continuity, root/merge/rename file statistics, annotated tag resolution, commit
search, and decoding all 32 original upstream icons. Finder source type-checks
with application-extension restrictions. The local Xcode bundle build is currently blocked
by a missing CoreSimulator.framework in the Xcode installation. GitHub's macOS CI
successfully compiled the app and embedded Finder extension at `c97f030`.
Signed Finder appearance remains unverified.
