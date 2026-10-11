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
| Commit | Checked-file commits, optional staging, right-hand partial-staging window, amend, author/date controls, Commit / ReCommit / Commit & Push | Complete upstream controls, hook/editor/signing interactions and physical UI acceptance across all routes |
| History | Log with revision graph before the list, revision/file menus, Blame, Reflog, Browse References, references containing a commit, four Log ordering modes, notes and statistics | Complete upstream views, menus and behavior; see individual parity documents |
| Repository workflows | Clone/Create Repository, status, branch/tag, Switch, Fetch/Pull/Push, merge, Rebase, Stash, reset, patches, export, Submodule Add/Update/Sync and worktrees | Each workflow has remaining source/UI/sandbox checks; a working Git operation alone does not establish parity |
| Synchronization | Outgoing/incoming graph and files, reference changes, Pull/Fetch variants, separate checkout/merge progress, Fetch & Rebase choices and Shift full options | Push hooks/variants, Compare Tags, remaining controls, complete visual and signed acceptance; [source audit](docs/SYNCHRONIZATION-PARITY.md) |
| Remote settings | Native remote list, URL/Push URL, Rename/Add New-Save/Remove, tag policy, Push Default and three-state Prune; source prompts and Browse References entry | Native key selection and Clone/Fetch/Pull/Push auto-load exist; remaining SSH consumers, bundled OpenSSH, complete settings tree and physical/signed acceptance; legacy PuTTY keys are preserved for Windows interoperability |
| Comparison | Standalone Load Images, colored unified diff, two-file text comparison, native image panes with zoom/linked pan/alpha and XOR overlay, frame/page controls and playback, configurable transparency backgrounds and local Dark Mode, three-pane image conflict selection, and three-pane text conflict editor | Full upstream formats, format-specific animation and broader conflict controls, encodings, commands and layout parity |
| Appearance and icons | Light/dark palettes, original upstream artwork in native menus and status lists | All-dialog visual comparison and signed Finder rendering |
| Finder | Embedded Finder Sync extension, status snapshot/badges and selection-based context-menu routing | Signed end-to-end activation, independent background cache and invalidation |

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
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-issue-regex-runtime.py
python3 scripts/build-graph-layout-runtime.py
python3 scripts/build-openssh-runtime.py
swift test
./scripts/build.sh
open build/Build/Products/Debug/TurtleGitMac.app
```

The build script prepares the four helper runtimes before building the unsigned Debug app.
The explicit helper commands above prepare them for the preceding tests.
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

Signed activation and badge rendering remain unverified. Finder Sync controls
badge placement and menu insertion. Badges apply to registered repository
folders. Only the current repository refreshes every five seconds while the app
runs; inactive or closed repositories can retain stale cached status. Selections
spanning repositories are rejected before an operation runs. The independent
background cache, FSEvents invalidation, repository management and coexistence
with other Finder extensions still need implementation and testing.

See the [Finder parity documents](docs/README.md#finder-integration) for menu,
selection, icon and routing comparisons.

## App Store preparation

The `TurtleGitAppStore` scheme uses the separate sandboxed `AppStore`
configuration. It requires the pinned bundled Git runtime and refuses system-Git
fallback. Follow the complete helper/runtime build instructions in
[distribution engineering](docs/DISTRIBUTION.md); see also [privacy](docs/PRIVACY.md).
Signed sandbox acceptance and distribution clearance remain open. **This is not
an App Store-ready release.**

## Port tracking

The source baseline is `7338078f8ddd924b8cddee35f512f2286072136d`.
The [file inventory](docs/upstream-files.csv) tracks all 3,277 upstream entries,
with blob hashes and review status; the [dialog inventory](docs/upstream-dialogs.csv)
tracks resource dialogs. An inventoried file or dialog is not necessarily ported.

[Port tracking](docs/PORTING.md) explains replacements and inventory maintenance.
[UI parity](docs/UI-PARITY.md) records required source, layout and behavior
comparisons. These documents and individual workflow audits track the full-port
work that remains.

## Screenshots and website

[Project website](https://jfk-solutions.github.io/turtle-git-mac/).

![Native Log Messages window with revision graph](docs/site/assets/log-messages.png)

The Log and Commit [light](docs/site/assets/commit-light.png) /
[dark](docs/site/assets/commit-dark.png) captures were refreshed on 10 October
2026 using disposable sample data. See the
[capture record](docs/qa/dialog-captures-2026-10-10.json) for scope and limitations.
[Earlier Commit controls](docs/site/assets/commit-controls.png) and
[partial staging](docs/site/assets/partial-staging.png) document previous
checkpoints. Screenshots do not establish parity for every dialog.

The static site source is `docs/site`; `python3 scripts/build-site.py` builds
`build/site`. See [website and screenshot maintenance](docs/WEBSITE.md).

## License

GPL v2, matching upstream TortoiseGit; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
Native builds use Apple's frameworks and embed the pinned EditorConfig,
issue-matching, OGDF graph-layout and OpenSSH helpers. Development builds can use installed Git; the Store
configuration embeds its pinned Git runtime. Bundled dependencies and original
artwork are documented in NOTICE and the bundle's license resources.
Distribution clearance remains incomplete; see [distribution requirements](docs/DISTRIBUTION.md).

The native [Revision Graph](docs/REVISION-GRAPH.md) now has a separate colored
reference-box canvas and source-style Filter sheet. See the
[light/dark graph and filter captures](docs/site/index.html) and
[remaining parity work](docs/REVISION-GRAPH-PARITY.md).
