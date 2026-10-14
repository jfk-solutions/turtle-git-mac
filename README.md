# TurtleGit for Mac

*A macOS fork of TortoiseGit*

A native macOS port in progress, based on the workflows and source of
[TortoiseGit](https://github.com/TortoiseGit/TortoiseGit). This is an independent,
unofficial project. **The complete application has not been ported yet.**

The goal is the same functionality, recognizable dialog layouts and context
menus, with native macOS windows and Finder integration. SwiftUI and AppKit
replace Windows/MFC. Git operations use argument arrays, literal pathspecs, a
serial repository actor and owned child processes. Minimum deployment target:
macOS 13.

## Current capabilities and limits

| Area | Native implementation | Remaining acceptance work |
| --- | --- | --- |
| Commit | Checked-file commits, optional staging, right-hand partial-staging window, same-repository file/folder drops, amend, author/date controls, Commit / ReCommit / Commit & Push | Complete upstream controls, hook/editor/signing interactions and physical UI acceptance across all routes |
| History | Log with incremental Git record ingestion, live read count and rows shown as metadata batches finish, revision graph before the list, revision/file menus, Blame, Reflog, Browse References, references containing a commit, four Log ordering modes, notes, statistics, SVN-aware columns and dialog-owned column layouts | Complete upstream views, menus and behavior; see individual parity documents |
| Repository Browser | Pinned tree/blob browsing, historical Open/Save/drag, submodule handoffs, retained folder navigation, multi-file Revert, owned cancellation, saved native columns and multiple historical file/folder promises | Physical drag interoperability, tree-object command handoffs and complete physical/signed acceptance; [source audit](docs/REPOSITORY-BROWSER-PARITY.md) |
| Repository workflows | Clone/Create Repository, status, branch/tag, Switch, Fetch/Pull/Push, merge, Rebase, Stash, reset, patches, export, Submodule Add/Update/Sync and worktrees | Each workflow has remaining source/UI/sandbox checks; a working Git operation alone does not establish parity |
| Working Tree | Scoped status, saved columns and source filter choices, F5, retained selection, cancellable refresh/Stage/Unstage/index flags/diff preparation, captured history/Blame/Open/editor/export/delete menus, shared status/changelist groups, separate parent/child submodule history and retired-window protection | Remote status, remaining menus and physical/signed acceptance; [source audit](docs/STATUS-PARITY.md) |
| Synchronization | Outgoing/incoming graph and files, reference changes, Pull/Fetch/Push variants, separate checkout/merge progress, Fetch & Rebase choices, owned Shift full options, a six-column Compare Tags tab with tag actions and Submodule Update/Init/Sync and Stash Save/Pop/Apply split commands; Manage opens Remote settings and refreshes results on dismissal; local/remote branch browse buttons use scoped native pickers | Direct Push/tags/notes and full-dialog hooks are implemented; remaining controls, complete visual and signed acceptance; [source audit](docs/SYNCHRONIZATION-PARITY.md) |
| Remote settings | Native remote list, URL/Push URL, Rename/Add New-Save/Remove, tag policy, Push Default and three-state Prune; source prompts and Browse References/Sync Manage entries | Native key selection and Clone/Fetch/Pull/Push auto-load exist; remaining SSH consumers, real authentication, complete settings tree and physical/signed acceptance; legacy PuTTY keys are preserved for Windows interoperability |
| Comparison | Standalone Load Images, colored unified diff, Subversion-backed two-file text comparison with named ECMAScript regex filters, native image panes with zoom/linked pan/alpha and XOR overlay, frame/page controls and playback, configurable transparency backgrounds and local Dark Mode, three-pane image conflict selection, and Subversion-backed three-pane text conflict editor with regex filters, standalone one/two/three-file Open, and native pane-local Find/Replace with Count and modified-line filtering | Full upstream formats, complete conflict segmentation acceptance, format-specific animation and broader conflict controls, encodings, commands and layout parity |
| Appearance and icons | Light/dark palettes, original upstream artwork in native menus and status lists | All-dialog visual comparison and signed Finder rendering |
| Single-patch review | Native before/after review, checked-file application, edited saves, exact-byte clipboard copy/review and confirmed target matching against plain directories or Git subfolders; app/Finder entry | Full TortoiseGitMerge behavior, Open/Finder clipboard integration and signed acceptance; [source audit](docs/REVIEW-PATCH-PARITY.md) |
| SVN integration | DCommit choices/stash flow, Fetch comparisons, fetch-then-Rebase and Ignore destinations; private universal Perl/Subversion runtime | Native/signed authentication, full physical UI acceptance and distribution review; [source audit](docs/SVN-PARITY.md) |
| Git daemon | Native warning/progress, server URLs, owned cancellation and app/Finder entry | Signed sandbox, firewall and LAN/IPv6 acceptance; [source audit](docs/DAEMON-PARITY.md) |
| Finder | Embedded Finder Sync extension, status snapshot/badges, selection-based context-menu routing and event-driven active-workspace refresh and persistent watched repositories while the app runs | User-approved signed service/Finder activation and App Store acceptance (embedded agent, private grant handoff and runtime are implemented) |

[Getting started](docs/GETTING-STARTED.md) explains the first workflows, including
how checked-file commits differ from staging mode. The checkbox is named
**Staging support (EXPERIMENTAL)**. Enabling it keeps the file list and changes
its checkbox semantics; the partial-staging patch window opens to the right.

[The documentation index](docs/README.md) links the workflow guides, source
comparisons, dated verification records and remaining work. Older development
updates are retained in [historical implementation notes](docs/IMPLEMENTATION-NOTES.md).
Local build and receiver results do not establish signed sandbox behavior, full
physical UI acceptance or passing hosted GitHub CI.

## Build and run

Requires Xcode with its macOS SDK and command-line tools, Python 3, CMake and Git.
The generated Xcode project is checked in; XcodeGen is optional unless changing
`project.yml`.

```sh
python3 scripts/build-git-runtime.py
python3 scripts/build-merge-diff-runtime.py
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-issue-regex-runtime.py
python3 scripts/build-lexilla-runtime.py
python3 scripts/build-graph-layout-runtime.py
python3 scripts/build-openssh-runtime.py
swift test
./scripts/build.sh
open build/Build/Products/Debug/TurtleGitMac.app
```

The build script prepares the editor, regex, graph, SSH and PuTTY key-conversion helpers, plus the merge
adapter when the Git/SVN runtime is present, before building the unsigned Debug
app. The explicit commands above prepare the dependencies for the preceding
tests. The initial pinned Git/SVN build can take substantially longer than app
builds; it caches its components. Build its universal SVN payload on Apple Silicon
with Rosetta, or restore the universal payload produced by CI.
`swift run TurtleGitMac` is an alternative development launch; it does not embed
the Finder extension or the EditorConfig, issue-matching, graph-layout and OpenSSH helpers.

See [testing](docs/TESTING.md) for scoped checks, native receivers, compatibility
coverage and process cleanup. Close app instances after manual testing.
An unsigned build verifies compilation and bundle structure, not distribution
acceptance.

## Finder integration

Configure your signing team in `TurtleGitMac.xcodeproj`. Register an App Group
supported by your team and, if necessary, replace `group.org.turtlegit.macos` in
both entitlements and `FinderIntegration.group`. The app and extension need
matching group access. Build and launch the app, enable **TurtleGit Finder** in
System Settings' extension controls, then open a repository in the app to
register its monitored folder. The settings location depends on macOS version.

Settings → General → **Context Menu** controls which commands appear directly
in Finder's menu. **Context Menu 2** chooses commands that require Shift.
The first page also supports path exclusions and hiding outside-repository menus.
Unavailable commands remain disabled. See the
[source comparison and validation](docs/CONTEXT-MENU-SETTINGS-PARITY.md).

Initialized LFS repositories have a nested **LFS** menu for locked-file lists and
file Lock/Unlock operations. **Send Mail…** opens the native patch composer for
Finder files, including files outside a repository; opening it does not send mail.
See the [LFS/mail handoff notes](docs/FINDER-LFS-MAIL-PARITY.md) for permissions
and remaining acceptance work.

Signed activation and badge rendering remain unverified. Finder Sync controls
badge placement and menu insertion. Badges apply to registered repository
folders. The implementation includes watched-repository management, FSEvents invalidation
and an independent background cache service. Its signed service registration and
physical Finder coexistence still require acceptance checks; cached badges are
not evidence of current repository state. Selections spanning repositories are
rejected before an operation runs. See the [service deployment audit](docs/FINDER-SERVICE-DEPLOYMENT.md).

See the [Finder parity documents](docs/README.md#finder-integration) for menu,
selection, icon and routing comparisons.

## App Store preparation

The `TurtleGitAppStore` scheme uses the separate sandboxed `AppStore`
configuration. It requires the pinned bundled Git runtime and refuses system-Git
fallback. Follow the complete helper/runtime build instructions in
[distribution engineering](docs/DISTRIBUTION.md); see also [privacy](docs/PRIVACY.md).
The [Finder cache agent](docs/FINDER-SERVICE-DEPLOYMENT.md) is embedded and
managed from Watched Repositories. Enabling background refresh requires a signed
build and macOS approval; unsigned development builds fail closed.
The unsigned universal build/audit command is `python3 scripts/build-distribution.py --configuration AppStore --derived-data build-store` after preparing the pinned runtimes. See [distribution instructions](docs/DISTRIBUTION.md) for its architecture/hash report and remaining acceptance work.

Signed sandbox acceptance and distribution clearance remain open. **This is not
an App Store-ready release.**

## Port tracking

The source baseline is `7338078f8ddd924b8cddee35f512f2286072136d`.
The [file inventory](docs/upstream-files.csv) tracks all 3,277 upstream entries,
with blob hashes and review status; the [dialog inventory](docs/upstream-dialogs.csv)
tracks resource dialogs. An inventoried file or dialog is not necessarily ported.

[Port tracking](docs/PORTING.md) explains replacements and inventory maintenance.
The [complete dialog audit](docs/DIALOG-COVERAGE.md) separates partial family
reviews from unmapped controls and links recorded parity evidence.
[UI parity](docs/UI-PARITY.md) records required source, layout and behavior
comparisons. These documents and individual workflow audits track the full-port
work that remains.

## Screenshots and website

Blame embedded-language fonts and line-tail fills now retain the source style
intervals. Reviewed [light](docs/site/assets/blame-embedded-light.png) /
[dark](docs/site/assets/blame-embedded-dark.png) captures and
[acceptance limits](docs/BLAME-EMBEDDED-STYLES.md) describe this batch.

Blame syntax coloring now uses the pinned upstream Lexilla engines and keyword
lists. Reviewed [light](docs/site/assets/blame-lexilla-light.png) /
[dark](docs/site/assets/blame-lexilla-dark.png) captures and
[batch evidence](docs/qa/blame-lexilla-2026-10-13.json) include remaining limits.

Blame now has a continuous native source editor with multi-line selection,
synchronized annotations and the source View switches. Actual
[light](docs/site/assets/blame-source-editor-light.png) /
[dark](docs/site/assets/blame-source-editor-dark.png) captures and
[verification limits](docs/qa/blame-source-editor-2026-10-13.json) document the
October 13 batch. Full Blame layout/menu and signed acceptance remain open.

[Project website](https://jfk-solutions.github.io/turtle-git-mac/).

![Native Log Messages window with revision graph](docs/site/assets/log-messages.png)

The Log and Commit [light](docs/site/assets/commit-light.png) /
[dark](docs/site/assets/commit-dark.png) captures were refreshed on 10 October
2026 using disposable sample data. See the
[capture record](docs/qa/dialog-captures-2026-10-10.json) for scope and limitations.
[Earlier Commit controls](docs/site/assets/commit-controls.png) and
[partial staging](docs/site/assets/partial-staging.png) document previous
checkpoints. Screenshots do not establish parity for every dialog.

The new Issue Tracker Config [light](docs/site/assets/issue-tracker-config-light.png) /
[dark](docs/site/assets/issue-tracker-config-dark.png) page and Regex Tester
[light](docs/site/assets/issue-regex-tester-light.png) /
[dark](docs/site/assets/issue-regex-tester-dark.png) captures use dedicated private
native hosts. See [their source comparison and capture scope](docs/qa/issue-tracker-captures-2026-10-12.json).
The Settings page capture includes its shared footer, not the full navigation tree.

The native [Autotext Tester](docs/AUTOTEXT-TESTER-PARITY.md) now provides the
source content/regex/Scan/results/timing workflow through File and Commit settings.
Full visual and signed acceptance remain open.

The native [Hook Scripts settings and runtime](docs/CLIENT-HOOKS-PARITY.md) now
connect the six Commit/Push/Rebase hook points, including repository approval and
owned background execution. Alternate routes and visual/signed acceptance remain
open.

Reviewed native [Hook Scripts](docs/site/assets/hook-settings-dark.png),
[Configure Hook Scripts](docs/site/assets/hook-config-dark.png) and
[Autotext Tester](docs/site/assets/autotext-tester-dark.png) screenshots now include
both themes. See [their source comparison and scope](docs/qa/utility-captures-2026-10-12.json).

The static site source is `docs/site`; `python3 scripts/build-site.py` builds
`build/site`. See [website and screenshot maintenance](docs/WEBSITE.md).

## License

GPL v2, matching upstream TortoiseGit; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Native builds use Apple's frameworks and embed the pinned EditorConfig,
issue-matching, OGDF graph-layout, OpenSSH and PuTTY key-conversion helpers. Development builds can use installed Git; the Store
configuration embeds its pinned Git runtime. Bundled dependencies and original
artwork are documented in NOTICE and the bundle's license resources.
Distribution clearance remains incomplete; see [distribution requirements](docs/DISTRIBUTION.md).

The native [Revision Graph](docs/REVISION-GRAPH.md) now has a separate colored
reference-box canvas and source-style Filter sheet. See the
[light/dark graph and filter captures](docs/site/index.html) and
[remaining parity work](docs/REVISION-GRAPH-PARITY.md).

The [working-copy revision utility](docs/WORKING-COPY-REVISION.md) generates version
files from TortoiseGit-style templates and exposes repository status as JSON for
macOS build scripts. Build it with `swift build --product TurtleGitWCRev`.
