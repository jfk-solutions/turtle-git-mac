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
| Commit | Checked-file commits, optional staging, byte-preserving UTF-8/legacy-text partial staging in a right-hand window, same-repository file/folder drops, amend, author/date controls, Commit / ReCommit / Commit & Push | Complete upstream controls, hook/editor/signing interactions and physical UI acceptance across all routes |
| History | Log with source command rows and integrated native filtering, incremental Git record ingestion, live read count and rows shown as metadata batches finish, revision graph before the list, revision/file menus, Blame with saved docked/tabbed/floating panes, Reflog, Browse References, references containing a commit, four Log ordering modes, notes, statistics, SVN-aware columns, saved revision/changed-file layouts and parent-group file sorting | Complete upstream views, menus and behavior; see individual parity documents |
| Repository Browser | Pinned tree/blob browsing, historical Open/Save/drag, submodule handoffs, retained folder navigation, multi-file Revert, owned cancellation, saved native columns and multiple historical file/folder promises | Physical drag interoperability and complete physical/signed acceptance; [source audit](docs/REPOSITORY-BROWSER-PARITY.md) |
| Repository workflows | Clone/Create Repository, status, branch/tag, Switch, Fetch/Pull/Push, merge, Rebase, Stash, reset, patches, export, Submodule Add/Update/Sync and worktrees | Each workflow has remaining source/UI/sandbox checks; a working Git operation alone does not establish parity |
| Working Tree | Scoped status, saved columns and source filter choices, F5, retained selection, cancellable refresh/Stage/Unstage/index flags/diff preparation, captured history/Blame/Open/editor/export/delete menus, shared status/changelist groups, separate parent/child submodule history and retired-window protection | Remaining menus and physical/signed acceptance; [source audit](docs/STATUS-PARITY.md) |
| Issue tracker integration | Native association list/editor with Enable/Add/Edit/Copy/Remove, project fallback, embedded searchable issue catalog and Commit message/ID selection, validation and completion interfaces | Windows COM providers require native vendor implementations; external discovery/network-backed providers and physical/signed acceptance remain open; [guide](docs/ISSUE-PROVIDERS.md), [source audit](docs/NATIVE-ISSUE-PROVIDER-PARITY.md) |
| Synchronization | Outgoing/incoming graph and files, reference changes, Pull/Fetch/Push variants, separate checkout/merge progress, Fetch & Rebase choices, owned Shift full options, a six-column Compare Tags tab with tag actions and Submodule Update/Init/Sync and Stash Save/Pop/Apply split commands; Manage opens Remote settings and refreshes results on dismissal; local/remote branch browse buttons use scoped native pickers | Direct Push/tags/notes and full-dialog hooks are implemented; remaining controls, complete visual and signed acceptance; [source audit](docs/SYNCHRONIZATION-PARITY.md) |
| Remote settings | Native remote list, URL/Push URL, Rename/Add New-Save/Remove, tag policy, Push Default and three-state Prune; source prompts and Browse References/Sync Manage entries | Native key selection and Clone/Fetch/Pull/Push auto-load exist; remaining SSH consumers, real authentication, complete settings tree and physical/signed acceptance; legacy PuTTY keys are preserved for Windows interoperability |
| Comparison | Native customizable Compare/Merge command toolbars with original artwork and saved layouts; standalone Load Images, colored unified diff, Subversion-backed two-file text comparison and shared in-process inline matching/navigation with source repeated-token ties, named ECMAScript regex filters, native image panes with DIB/CUR/SVGZ decoding, zoom/linked pan/alpha and XOR overlay, frame/page controls and playback, configurable transparency backgrounds and local Dark Mode, three-pane image conflict selection, and Subversion-backed three-pane text conflict editor with regex filters, standalone one/two/three-file Open, and native pane-local Find/Replace with Count and modified-line filtering | Full upstream formats, complete conflict segmentation acceptance, format-specific animation and broader conflict controls, encodings, commands and layout parity |
| Appearance and icons | Light/dark palettes, original upstream artwork in native menus and status lists | All-dialog visual comparison and signed Finder rendering |
| Single-patch review | Native before/after review, checked-file application, edited saves, exact-byte clipboard copy/review and confirmed target matching against plain directories or Git subfolders; app/Finder entry | Full TortoiseGitMerge behavior, Open/Finder clipboard integration and signed acceptance; [source audit](docs/REVIEW-PATCH-PARITY.md) |
| SVN integration | DCommit choices/stash flow, Fetch comparisons, fetch-then-Rebase and Ignore destinations; private universal Perl/Subversion runtime; native credentials, explicit certificate trust, dual fingerprints/read-only certificate details and private client-certificate selection | Public server/TLS, signed Keychain/grants, physical UI and distribution acceptance; [guide](docs/SVN-AUTHENTICATION.md), [source audit](docs/SVN-PARITY.md) |
| Git daemon | Native warning/progress, server URLs, owned cancellation and app/Finder entry | Signed sandbox, firewall and LAN/IPv6 acceptance; [source audit](docs/DAEMON-PARITY.md) |
| Moving and copying | Guarded Move/Rename, native Copy/Add and captured clipboard transfers; workspace/Working Tree drops offer active source transfer choices with owned preparation, same-worktree destinations and existing progress/recovery | Physical Finder drag menus and signed permission acceptance; [guide](docs/MOVING-AND-COPYING.md), [source audit](docs/FILE-DROP-TRANSFER-PARITY.md) |
| Repository folder access | Saved workspace folder/metadata grants, automatic linked-worktree/submodule/shared-object discovery, native access manager with renewal, replacement and confirmed removal | Signed sandbox/powerbox and Finder-service acceptance; [guide](docs/REPOSITORY-FOLDER-ACCESS.md) |
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
TURTLEGIT_CORE_ONLY=1 swift test
./scripts/build.sh
open build/Build/Products/Debug/TurtleGitMac.app
```

The Core test mode keeps the same tests, resources and revision utility while skipping a duplicate SwiftPM build of the app. The full app and Finder extension are built separately by `build.sh`; ordinary `swift run TurtleGitMac` remains available without that environment variable.

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

## Local preview package

To produce a universal Release preview from this checkout:

```sh
python3 scripts/build-distribution.py --configuration Release
python3 scripts/package-local-preview.py --audit build-distribution/distribution-audit.json --output build/local-preview
```

The fresh output directory contains the app, a ZIP, checksum, license notices and
installation notes. Packaging preserves the audited build and finalized runtime
payloads, seals a separate copy ad hoc, and does not install, launch or upload it.
The preview is not notarized or App Store signed. See the
[release blockers](docs/RELEASE-BLOCKERS.md) for the remaining acceptance work.

## Finder integration

Watched Repositories includes a separate Background status column, publication
times, failure details and a retry action for the embedded cache service.
[Service setup and current limits](docs/FINDER-SERVICE-DEPLOYMENT.md).

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

Notes, Merge and Rebase now share Commit's source-style issue/URL links and
message formatting, preserving plain-text drafts and Undo. Reviewed Notes
[light](docs/site/assets/notes-message-styles-light.png) /
[dark](docs/site/assets/notes-message-styles-dark.png) captures show the native
form with private font preferences. [Scope and limits](docs/SHARED-MESSAGE-STYLES.md).

Image comparison and conflict selection now use native source-ordered toolbars
with original artwork and common menu/keyboard guards. Reviewed
[comparison light](docs/site/assets/image-toolbar-comparison-light.png) /
[dark](docs/site/assets/image-toolbar-comparison-dark.png) and
[selection light](docs/site/assets/image-toolbar-selection-light.png) /
[dark](docs/site/assets/image-toolbar-selection-dark.png) captures show the current
windows. [Source scope and remaining limits](docs/IMAGE-COMMAND-PARITY.md).

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
reference-box canvas and source-style Filter sheet. It follows the shared Log
commit ordering and font family, with graph zoom sizing and matching export fonts. See the
[light/dark graph and filter captures](docs/site/index.html) and
[remaining parity work](docs/REVISION-GRAPH-PARITY.md).

The [working-copy revision utility](docs/WORKING-COPY-REVISION.md) generates version
files from TortoiseGit-style templates and exposes repository status as JSON for
macOS build scripts. Build it with `swift build --product TurtleGitWCRev`.

Compare and Review source panes support Save As to a new working file, including
subsequent Save and Reload. See [Save As behavior and limitations](docs/SAVE-AS-TARGETS.md).

Conflict editors and external merge tools share [operation-aware side identities](docs/CONFLICT-IDENTITIES.md),
including merge/rebase branch names and the Advanced branch-guessing preference.

Existing Advanced settings now control [Fetch verbosity and native progress animation](docs/TRANSPORT-PRESENTATION.md),
with captured request policy and shared bounded visible-output settings.

Finder context now shares normalized selections, nearest repository ownership and
explicit ignore inheritance; see [selection context](docs/FINDER-SELECTION-CONTEXT.md).

[Git Properties](docs/GIT-PROPERTIES-PARITY.md) exposes repository metadata and
index flags, including live registered-parent/submodule pages and captured
Log/Settings actions. Last Modified uses bounded history object queries while
retaining the source's mode-only and merge-parent rules.

Standalone [Unified Diff documents](docs/UNIFIED-DIFF-VIEWER-PARITY.md#editable-documents-file-actions-and-source-find--october-15-2026)
support native editing/Undo, Open, Save/Save As, unsaved-change decisions and the
source-style bottom Find bar. Editing a patch document does not stage or apply
its changes to a repository.

Unified Diff's Apply Patch command opens TurtleGitMerge review for the saved
patch or loaded generated comparison; unsaved editor text is excluded until
saved. Its Settings command opens the UDiff page directly. Comparison replacement
keeps the document and its labels/paths together through unsaved-change decisions.


External Unified Diff viewers accept app bundles or executables and `%1`/`%title`
argument templates. Alternative Editor also supports executable tools, with one
literal filename argument. See [external tool configuration](docs/UNIFIED-DIFF-VIEWER-PARITY.md#external-viewer-arguments-and-executable-tools--october-15-2026).
