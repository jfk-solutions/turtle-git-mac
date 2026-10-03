# TurtleGit for Mac

*A macOS fork of TortoiseGit*

A native macOS port in progress, based on the workflows and source inventory of
[TortoiseGit](https://github.com/TortoiseGit/TortoiseGit). This is an independent,
unofficial project. **The complete application has not been ported yet.**

SwiftUI and AppKit replace Windows/MFC windows. Git runs directly through Foundation
Process with argument arrays, literal pathspecs, and a serial repository actor.
A sandboxed Finder Sync extension uses shared cached status and opens native dialogs
through the `turtlegit:` URL scheme. Minimum deployment target: macOS 13.

## Build and run

Requires Xcode with its macOS SDK and command-line tools, plus Git. The generated
Xcode project is checked in; XcodeGen is optional unless changing `project.yml`.

```sh
swift test
./scripts/build.sh
open build/Build/Products/Debug/TurtleGitMac.app
```

For a quick app-only build: `swift run TurtleGitMac`. That does not bundle or
activate the Finder extension. The unsigned Xcode build verifies compilation and
bundle structure; it is not a signed distribution.

## Implemented first pass

- Open normal repositories and linked worktrees; show branch and status.
- Remember recent repositories with security-scoped bookmarks; renew stale permissions
  and hold access for the session. Finder requests require an existing grant or a picker.
- Standalone Working Tree status window with upstream column/filter/action layout,
  original status icons, staged state, file statistics, dates, sorting and context menus.
  Scope, ignored/unversioned and index-flag filters; unified diff export.
- Stage / unstage selected paths, including before the first commit.
- Separate native Commit window with checked-file selection, message, amend, author,
  sign-off, file statistics and icon context menus. Enable staging area switches to
  three-state staging checkboxes and commits the index, preserving unstaged edits.
  An attached right-hand patch window stages/unstages selected lines or hunks in
  ordinary tracked UTF-8 text files.
- Separate three-pane Log Messages window: compact branch/merge graph, refs, full
  commit message, changed paths and added/removed line counts; search/date filters,
  all-branches and loading older commits; revision and working-tree comparisons.
- Original TortoiseGit command icons in app context menus and the Finder submenu;
  original XPStyle status artwork for Finder badges and app file status.
- Log revision actions for branch/tag, Switch/Checkout, reset, revert without commit,
  cherry-pick, and copying hashes/messages/details. Advanced options remain pending.
- Working-tree and index diffs, with selectable, monospaced operation output.
- Native confirmation dialogs for merge, rebase, stash save/pop, clone, and repository creation.
- Native New Branch/Tag windows with HEAD/branch/tag/commit selectors, descriptions,
  annotated tag messages, force, remote tracking and optional branch checkout.
  Tag Push opens native Push options scoped to the new tag.
  [Branch/tag parity](docs/BRANCH-TAG-PARITY.md) tracks remaining options.
- Separate native Pull dialog with remote/branch selectors, squash, no commit,
  fast-forward controls, Tags/Prune and shallow depth.
  [Pull parity](docs/PULL-PARITY.md) records pending rebase and recovery workflows.
- Separate native Fetch dialog with named remote/all remotes or URL, remote branch
  browsing, three-state Tags/Prune overrides and shallow depth.
  [Fetch parity](docs/FETCH-PARITY.md) records remaining work.
- Separate native Push dialog with reference/destination selectors, force with lease,
  tags, upstream tracking, per-branch defaults, submodule recursion and server option.
  [Push parity](docs/PUSH-PARITY.md) records remaining work.
- Separate native Switch/Checkout dialog with branch/tag/commit selectors and
  create-branch, force, merge, three-state remote tracking and branch override.
  [Switch parity details](docs/SWITCH-PARITY.md) document pending chooser and UI work.
- Finder extension target with status badges, directory status aggregation,
  TurtleGit context submenu, and complete multi-selection URL dispatch. File/folder
  selections scope Diff and Log; Show Whole Project restores unfiltered history.
- Upstream file and dialog inventories pinned to an exact commit.

These are initial workflows, not full upstream parity. The operation dialogs expose
only the options shown. [Log parity details](docs/LOG-PARITY.md) track the upstream
controls and context commands still missing. Checkbox mode commits the current
whole-file contents of checked paths; staging mode commits **all** staged changes,
including files outside the current view. Highlighted rows do not select commit
contents. [Commit parity details](docs/COMMIT-PARITY.md) track remaining options. Authentication uses existing credential helpers / SSH configuration; there is
no native credential prompt yet. Interactive hooks, Git editors, signing prompts,
cancellation and live streaming progress are not implemented. Conflicts remain
visible in the status list, but must currently be resolved with another tool.

## App Store target

The `TurtleGitAppStore` scheme provides a separate sandboxed configuration.
It requires a bundled Git runtime and never falls back to system Git. Runtime
packaging, signed sandbox tests and GPL/App Store terms clearance remain open.
See [distribution engineering](docs/DISTRIBUTION.md) and [privacy](docs/PRIVACY.md).
This is not an App Store-ready release.

## Finder extension

Open `TurtleGitMac.xcodeproj` in Xcode. Configure your signing team on the app,
framework and extension targets. Register an App Group supported by your signing
team; replace `group.org.turtlegit.macos` in **both** entitlements and
`FinderIntegration.group` if necessary. Keep the containing app and extension
signed with matching group access. Build and launch the app, then enable
**TurtleGit Finder** in System Settings' extension controls (location depends on
macOS version). Open a repository in the app to register its monitored folder.

The extension compiles and is embedded in the application. End-to-end activation
and badge rendering require a signed install and have not been verified here.
Finder Sync controls badge placement and menu insertion; it cannot reproduce
Explorer's shell extension APIs directly. Badges apply to registered repository
folders rather than the entire disk. Repositories are cached when opened, and only
the current repository refreshes every five seconds while the app is running.
Cached inactive/closed repository statuses can be stale. Selections spanning repositories are rejected before an operation runs.
The independent background cache, FSEvents invalidation, repository management and conflict
with other Finder extensions still need implementation and testing.

## Complete port tracking

[`docs/UI-PARITY.md`](docs/UI-PARITY.md) records the required source, layout and
behavior comparisons for every native replacement.

[`docs/PORTING.md`](docs/PORTING.md) describes component replacements and remaining
work. [`docs/upstream-files.csv`](docs/upstream-files.csv) includes every tracked
upstream entry with its blob hash and review status.
[`docs/upstream-dialogs.csv`](docs/upstream-dialogs.csv) inventories native dialog
resources. Being listed does not mean being ported.

```sh
git clone --depth 1 https://github.com/TortoiseGit/TortoiseGit.git .upstream/TortoiseGit
git -C .upstream/TortoiseGit fetch origin 7338078f8ddd924b8cddee35f512f2286072136d
git -C .upstream/TortoiseGit checkout 7338078f8ddd924b8cddee35f512f2286072136d
python3 scripts/inventory-upstream.py
```

The upstream checkout is ignored, not vendored. Regeneration preserves existing
file decisions and marks changed blobs for review. External libraries and gitlinks
are inventoried but their nested repositories are not recursively audited.

## License

GPL v2, matching upstream TortoiseGit; see `LICENSE` and `NOTICE`. The development application
currently uses Apple's frameworks and the installed Git executable, with no copied
upstream binaries or bundled third-party libraries.

## Screenshots and project website

[Visit the project website](https://jfk-solutions.github.io/turtle-git-mac/).

![Native Log Messages window with revision graph](docs/site/assets/log-messages.png)

Screenshots use only disposable sample data. The static GitHub Pages source is in
`docs/site`; `python3 scripts/build-site.py` builds `build/site`. The deployment
workflow uses the current repository name for source links, including after a rename.
See [website and screenshot maintenance](docs/WEBSITE.md).
