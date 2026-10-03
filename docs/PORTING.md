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
| Check for modifications | Native standalone Working Tree dialog; columns, scope/filters, statistics, dates, sorting, diff export and basic menus | Full menus, remote checks, progress/cancellation and persistent preferences; see STATUS-PARITY.md |
| Commit | Native checked-file dialog; optional three-state staging; amend, author, sign-off, statistics | Unsupported partial-stage file types, author date, message history/completion, hooks UI, issue trackers, full action menu |
| Log | Separate native three-pane window; graph, refs, message/files/line counts, search/date filters, load more, comparisons and revision actions | Working-tree row, actions column, branch/ref chooser, author search, walk/view controls, statistics, multi-revision file union, remaining context commands; see LOG-PARITY.md |
| Diff | Index/worktree/commit textual patches | Side-by-side, syntax highlighting, binary/image handling, external tools |
| Clone / init | Destination picker and Git operation | Branch, recursive submodules, bare repos, advanced options and progress |
| Fetch / pull / push | Git defaults; pull fast-forward only | Remote/ref pickers, tags, force-with-lease, progress, cancellation, authentication |
| Switch/Checkout | Native branch/tag/commit rows, create/force/merge/tracking/override options, real Git checkout tests | Complete choosers, progress and broader native QA; see SWITCH-PARITY.md |
| Branch / tag | Native name/revision/options/message controls; descriptions, annotated tags, optional checkout, force and tracking | Full choosers, push, signing prompts and broader native QA; see BRANCH-TAG-PARITY.md |
| Merge / rebase | Start operation | Conflict editor, continuation, abort, interactive rebase and commit editing |
| Stash | Save message and pop latest | List, inspect, apply selected, drop, include untracked, branch from stash |
| Finder | Original icons, cache badges, complete selection dispatch, scoped Diff/Log | Signed QA, remaining shell commands, watched-root management, cache daemon/FSEvents |
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

The current Swift package builds and 53 tests pass, including topological graph
continuity, root/merge/rename file statistics, annotated tag resolution, commit
search, and decoding all 32 original upstream icons. Finder source type-checks
with application-extension restrictions. The local Xcode bundle build is currently blocked
by a missing CoreSimulator.framework in the Xcode installation. GitHub's macOS CI
successfully compiled the app and embedded Finder extension in both Debug and
sandboxed AppStore configurations at `1b66080`. Bundle validation confirmed all
32 original icons, their hashes and license, the shared framework, and the embedded
Finder extension in both configurations. The [CI run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/37120088567)
also passed the 24 Swift tests. Signed Finder appearance remains unverified.

Finder requests now carry all selected paths as repeated URL fields, preserving
literal filename characters. One security grant must contain every item; each
item's containing repository is checked before replacing the current session or
running a command. Mixed and nested repository selections are rejected. Selected
folders expand to changed rows using path component boundaries. Finder Diff uses
the requested paths even when no status rows exist, and Log accepts multiple path
filters with a Show Whole Project checkbox. The commit dialog now keeps checked files separate from highlighted rows.
Checkbox mode commits selected working-tree files; staging mode commits the index.
Other upstream shell commands remain pending. New tests cover URL parsing, legacy requests, malformed input, directory
selection, literal multi-path history, and clean-file diff isolation.

The Commit window now follows the upstream message-above-file-list arrangement,
with category check links, original status icons, line counts, amend, author and
sign-off controls. Its optional staging support uses native three-state checkboxes
in the same file list. Git integration tests cover unchecked index preservation,
unborn commits, staged rename/deletion, amend with no checked files, custom author,
sign-off, partial index contents, and rejection by a pre-commit hook. A native UI
commit on disposable sample data committed only README.md and left the unchecked
Sources/Repository.swift change staged. Native staging checkboxes, mixed-state rendering, stage/unstage of an unversioned
file and an index commit preserving later working-tree edits were also exercised
on disposable sample data. The right-hand patch window now stages/unstages selected lines and hunks in
tracked UTF-8 text files, with native UI and real Git integration verification. See COMMIT-PARITY.md for remaining parity.
