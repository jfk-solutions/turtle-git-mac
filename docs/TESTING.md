# Testing TurtleGit for Mac

Run commands from the repository root. The checked-in
[macOS workflow](../.github/workflows/macos.yml) defines the hosted CI sequence.
Local success does not establish that a hosted run passed, that dialogs match
TortoiseGit visually, or that the app is ready for distribution.

## Current full-suite checkpoint

At source checkpoint `3f76591`, a fresh local `swift test` passed all **866 tests**
with zero failures on October 10, 2026. The run used Apple Git 2.50.1 and Swift
6.3.3 and finished normally after 514.5 seconds of test execution. This is the
complete SwiftPM suite, separate from the focused Send Mail checks and native
receivers. See [the full-suite record](qa/full-core-2026-10-10.json).

The latest run listed on the public Actions page when inspected was
[macOS #135](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/37274118557),
which reports Success for `44d3e52` on October 5. It covers that older hosted
checkpoint; the current local source has not been verified by that run. GitHub
requires sign-in to read its full logs. Local success does not resolve a failure
in a different hosted run or prove the remaining native workflow steps.

## Core and native receivers

Build the required helpers, run the Git integration suite, then check the native
historical item provider:

```sh
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-issue-regex-runtime.py
swift test
scripts/verify-browser-item-provider.sh
```

Keep these commands sequential. SwiftPM holds a lock on `.build` during tests;
the provider script also builds in that directory. A lock-wait message means
another build or test owns it, and is not evidence that the provider failed.

Revision Graph's separate history query and ordered reduction have a focused
repository suite. Run it with system and packaged Git sequentially:

```sh
swift test --filter 'RevisionGraphTests|HistoryRangeTests'
TURTLEGIT_GROUP_TEST_GIT="$PWD/build/git-runtime/Git/bin/git" \
  swift test --filter 'RevisionGraphTests|HistoryRangeTests'
```

These checks cover graph scopes, tag hiding, merge/branch structure, terminal
excluded parents, unborn/detached/bare repositories and superproject index
pointers, including conflicts. They check unchanged repository bytes and do not
launch native windows. See [Revision Graph parity](REVISION-GRAPH-PARITY.md);
the native graph window and its acceptance checks remain outstanding.

Build Debug before running receivers that link its TurtleGitCore framework:

```sh
xcodebuild -quiet -project TurtleGitMac.xcodeproj -scheme TurtleGitMac \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/validate-app-bundle.py build/Build/Products/Debug/TurtleGitMac.app
python3 scripts/test-worktree-dialog.py
python3 scripts/test-advanced-settings.py
python3 scripts/test-add-dialog.py
python3 scripts/test-finder-menu.py
```

These receivers create temporary executables and repository fixtures. They use
AppKit with activation prohibited and do not display app windows or enable the
Finder extension. Worktree and Add perform real repository mutations in owned
fixtures; Advanced Settings uses isolated defaults; Finder exercises its actual
menu builder and captured routing. Worktree fixture commits explicitly disable
signing so a developer's signing configuration cannot launch a signing agent.
The scripts remove their temporary directories on exit.

Keep native sources unchanged while a receiver compiles or runs. Run native
receivers sequentially: some larger replay fixtures use shared preferences.
Do not repeatedly launch the main app to substitute for these checks. If a
manual interaction test needs a window, close the owned window and app when
finished and record which gestures and results were actually observed.

## Git compatibility and the Store configuration

The workflow builds bundled Git, compiles a separate unsigned Store bundle in
`build-store`, and validates it with `--require-git`. Follow its exact commands
when reproducing those jobs; a Debug bundle audit does not cover the Store bundle.
Store validation checks packaging and the bundled runtime, not signed sandbox
execution or App Store acceptance. See [distribution engineering](DISTRIBUTION.md).

For native replay and menu coverage, the workflow runs:

```sh
python3 scripts/build-replay-test-git.py --version 2.37.1
python3 scripts/build-replay-test-git.py --version 2.39.5
python3 scripts/check-cherry-pick-native.py \
  --git /usr/bin/git \
  --git build/replay-test-git/2.37.1/bin/git \
  --git build/replay-test-git/2.39.5/bin/git \
  --git build-store/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git
```

The last path requires the Store build first. `--menus-only` and
`--references-only` select focused coverage and must not be reported as the full
replay check. The receiver also requires the SwiftPM executable and Debug
framework built above. Do not rebuild or replace those dependencies during a run.

## Evidence and failures

Retain complete command output under ignored `build/qa/<scope>/`, including the
first failure and any subsequent successful reproduction. Record the checkpoint,
source hashes, Git versions, command scope and limitations in `docs/qa`.
Check the final exit status; an output timeout while observing a live process is
not a test result. Continue observing the same process rather than starting a
second copy.

For GitHub failures, identify the failing workflow step and read its complete
output. Reproduce that exact script with matching dependencies before changing
app behavior. The native provider's compiler/output-command defect was repaired
in `cec56b1`; the local native dialog audit and signing-fixture regression are
recorded in [the CI receiver record](qa/ci-native-dialogs-2026-10-07.json).
Hosted workflow results still require separate inspection.

Model and transport checks do not replace light/dark screenshots, keyboard and
mouse acceptance, VoiceOver checks, activated Finder testing, or signed sandbox
tests. Track those separately in [UI parity](UI-PARITY.md).

## Pinned upstream inventory

Run `python3 scripts/check-inventory-pin.py` for an isolated temporary Git fixture.
It verifies that dirty resource files and newer HEAD commits cannot silently
change the recorded inventory, and that explicit repinning invalidates changed
review decisions while preserving unchanged mappings. This runs in the macOS
workflow before native builds. No upstream clone, network or app launch is needed.
Actual inventory regeneration still requires the recorded commit to be present
in `.upstream/TortoiseGit`; see [the UI audit](UI-PARITY.md).

## Saved progress action log checkpoint

The [Action log guide](ACTION-LOG.md) tracks source retention and Saved Data
Show/Clear parity, headless verification, covered progress windows and remaining
physical/signed and wider Saved Data gaps.

## Saved Data history and decisions checkpoint

The [Saved Data guide](SAVED-DATA.md) maps URL/input-message history and stored
decision controls to the source and documents reset scope and remaining groups.
Core reset-scope tests and private native model checks are recorded in
[the checkpoint](qa/saved-data-2026-10-08.json).

## Temporary files checkpoint

The [temporary-file guide](TEMPORARY-FILES.md) maps shared private temporary
storage and Saved Data's confirmed cleanup to the pinned source.
[Checkpoint evidence](qa/temporary-files-2026-10-08.json) distinguishes Core/native
checks from remaining physical, live-operation and signed acceptance.

## Dialog geometry checkpoint

[Dialog sizes and positions](DIALOG-GEOMETRY.md) maps native frame persistence
and Saved Data reset to the source, with Core/headless verification and physical,
mode-specific and signed gaps. Evidence: [checkpoint](qa/dialog-geometry-2026-10-08.json).


## Log history limit checks

After the Debug build, use the compiled-source scope oracle and the hidden
native scope/defaults receiver:

```sh
swift test --filter 'HistoryLimitTests|CommitHistoryTests|WorkingTreeHistoryTests'
python3 scripts/test-history-limit-oracle.py
python3 scripts/test-log-history-limits.py --git /usr/bin/git \
  --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git
```

The bundled executable must exist from a prior Store build. Keep that build
terminal before rebuilding Debug for the receiver; do not rebuild Store until
all Debug receivers are terminal. The oracle extracts the pinned GetLogCmd
filter body and supplies local-midnight epochs through a portable CTime adapter.
It verifies scope arithmetic and arguments, not Windows time APIs. The native
receiver uses a private 205-commit repository and preference domain, an owned
hidden Settings window, actual native Apply/Cancel buttons and real history
reads. It checks exact repository bytes after reading and closes its window.
Physical menu/sheet gestures and signed sandbox execution require separate
acceptance.


## Shared Log message-line checks

After the Debug build, run:

```sh
swift test --filter LogMessageLineTests
python3 scripts/test-log-message-line.py --log-blame-only --git /usr/bin/git \
  --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git
```

The native receiver constructs source-default, disabled and enabled models with
private preferences. It inspects actual hidden Log/Blame message text and Rebase
row/selection/action data from real multiline-message history and a read-only
Rebase plan. Actual Subjects/Messages menu selectors also write source-formatted text to an
owned private pasteboard, which is released afterwards. The system clipboard is
not touched. The focused flag does not claim Rebase rendered-text acceptance.
Omit it for the strict three-view check, which currently fails at Rebase text
observation; the same absence is reproduced by a minimal SwiftUI Table. This
full UI gate remains pending, rather than being counted as passed. Its temporary Blame source copy only appends a same-file view access
function; production private table code is unchanged. No main app or replay
operation runs. Owned windows, temporary fixtures and preference domains close
and remove on successful exit. As with other native receivers, do not edit
sources or replace linked Debug products during execution.

The focused message-line receiver also exercises real Log reloads and inspects
actual attributed message cells for literal/ECMAScript match foregrounds,
reference-label/full-message field gates, invalid regexes and same-identity
range refresh. Build the updated IssueRegex runtime before Core/Debug checks:
`python3 scripts/build-issue-regex-runtime.py`. Focused Core coverage is
`swift test --filter 'HistoryHighlightTests|IssueRegexTests|CommitHistoryTests|LogMessageLineTests'`.
See [highlight QA](qa/log-match-highlights-2026-10-09.json); these checks do not
replace the pending physical or signed acceptance gates.

Reference-label coverage adds
`swift test --filter 'HistoryReferenceLabelTests|HistoryHighlightTests|CommitHistoryTests|LogMessageLineTests'`.
The existing focused native receiver creates only a private remote/config/ref
fixture (no fetch/network operation), verifies actual left/right message-cell
order, shortened names/marker attachments, captured preference state and label
visibility match repaint without an extra history read. It also invokes actual
AppKit preference checkbox actions on the owned Dialogs page and verifies their
private UserDefaults values in both directions. Private repository bytes
remain unchanged after setup. See
[reference-label QA](qa/log-reference-labels-2026-10-09.json).

Reference-name/classification checks, including annotated tags and configured bisect terms, are recorded in [reference-kind QA](qa/log-reference-kinds-2026-10-09.json). Physical rendering and full dialog parity remain unverified.

Log reference badges now use native TextKit glyph drawing with source bevels, tracking shadows and annotated-tag tips. See [painter QA](qa/log-reference-painter-2026-10-09.json) and `python3 scripts/test-log-reference-painter-oracle.py` for the independent geometry/color check. It does not establish physical screenshot or full UI parity.

The focused Log receiver also checks label-context Push/Checkout callback arguments and Branches/Tags output using a private pasteboard; it performs no network push or checkout. Scope and remaining menu gaps: [reference-menu QA](qa/log-reference-menus-2026-10-09.json).

Packed NFC/NFD refs, raw tracking-config bytes, leading combining marks and native same-hash label refresh are checked in [reference identity QA](qa/log-reference-identity-2026-10-09.json). Config setters may normalize argv under core.precomposeunicode, so fixtures preserve distinct stored bytes explicitly. This does not verify every named Git operation.

Log express switch checkpoint: `docs/qa/log-express-switch-2026-10-09.json`; native menu selectors are exercised by `scripts/test-log-message-line.py --log-blame-only`.

Pointed Log reference presets: `docs/qa/log-reference-presets-2026-10-09.json`, using the focused hidden native receiver and a private real-Git non-HEAD fixture.

Log deletion: `HistoryReferenceDeletionTests` (Apple/bundled Git via `TURTLEGIT_QA_GIT`) and the focused owned native receiver; checkpoint `docs/qa/log-reference-deletion-2026-10-09.json`. Remote mutation tests use a private local bare repository.

Commit caret: `MessageCaretPositionTests`, `scripts/test-message-caret-oracle.py` and the extended hidden native message-font receiver; checkpoint `docs/qa/commit-caret-2026-10-09.json`.

### Commit new-branch focus

After the unsigned Debug build, run `python3 scripts/test-commit-branch-focus.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. This receiver hosts the full Commit dialog in an unordered window with activation prohibited and isolated preferences/repositories. It checks native first responder and whole-draft selection when enabling new branch, replacement typing, caret preservation on ordinary updates and draft retention/reselection after off/on. It does not prove physical toggle/tab/default-button behavior, signed execution or full dialog parity.

### Commit read-only author identity

After unsigned Debug and AppStore builds, run `python3 scripts/test-commit-author-field.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The receiver hosts the full Commit dialog without ordering or activating its window. It verifies the actual read-only field/editor remains selectable and copies a Unicode configured identity to a private pasteboard, then checks enabled editing, model binding, selection retention, unchecked-identity reseeding and inherited busy lock. All repositories, preferences, pasteboards and windows are privately owned and cleaned on exit. This is not physical keyboard/IME or signed/full-dialog acceptance.

### Commit asynchronous metadata transitions

After unsigned Debug and AppStore builds, run `python3 scripts/test-commit-metadata.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. Actual hidden Commit dialogs read a private repository's configured identity and HEAD author/date/message, then verify date restoration when Amend is unchecked. Controlled continuation-backed loaders exercise superseded replies/errors, byte-distinct author drafts, pending Commit/native editor/date-picker gating and first-load/cached on/off/on amend messages. Supplied Replay Split control-state fixtures check identity/date preservation against old replies and automatic installation notifications, then verify later checkbox changes still refresh defaults; they are not real rebase executions. No Commit action is executed; HEAD and config remain unchanged after fixture setup. Windows, preferences, private pasteboard and fixtures are owned and cleaned on normal or throwing exit. Physical input, close/cancellation and signed/full-dialog acceptance remain unverified.

### Commit Amend focus

After unsigned Debug and AppStore builds, run `python3 scripts/test-commit-amend-focus.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The receiver verifies native message first responder after both Amend transitions, ordinary focus/selection/Undo retention, Quit/error gates, one-shot consumption across editor recreation, removal and late replies to a closed real controller. An injected attached-sheet property and manual `didEndSheet` notification exercise deferral/retry without ordering a sheet. Error gates use editor-only hosts to avoid showing the full dialog's alert. Repositories, defaults and windows are private; HEAD/config remain unchanged after setup. Physical input, real sheet/alert presentation and signed acceptance remain unverified.

### Reset modified-files preview

After unsigned Debug and AppStore builds, run `python3 scripts/test-reset-modified-files.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The receiver constructs actual Reset and Changed Files controllers without ordering windows and injects sheet presentation with parent keyboard focus released. It checks the private repository's HEAD-to-working-tree list (mixed/staged/unstaged/add/delete/Unicode paths), exclusions, retained Reset target, parent reset/apply/close/Quit and duplicate gates, configured callback delivery, close/reopen/stale/rejected/bare/busy/forced-parent cleanup. HEAD, staged tree, config and working bytes remain unchanged after fixture setup; index stat-cache bytes are not asserted. `scripts/test-reset-progress.py` remains the real Soft/Mixed/Hard/cancellation/retry regression. Hidden ownership checks do not prove physical sheet interaction, focus or signed App Store behavior.

### Reset initial focus and Log picker

After unsigned Debug and AppStore builds, run `python3 scripts/test-reset-picker.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. Hidden native Reset windows verify chosen-type first responder, once-only focus and bare Soft behavior. An owned full Log controller uses injected presentation that releases parent focus, and private defaults with column autosave disabled; its real table checks single selection and its real history checks typed-revision ancestry, graph and selection. Accept/cancel, stale/late callbacks, rejected presentation, duplicate/cross-route/reset/apply/close/Quit locks and ordinary/multiple Log selection are covered. No windows are ordered; no sheet is physically presented. Physical keyboard/focus/layout and signed acceptance remain unverified.

### Reference browser and Reset handoff

After an unsigned Debug build, run `python3 scripts/test-reference-browser.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The hidden native receiver hosts real reference browser, Reset and owned Reflog controllers with private preferences/repositories, activation prohibited and injected presentation releasing parent focus. It checks namespace/tree selection, nine columns, single selection, logical sort, scope/text/merge filters, current branch, original context icons and canonical callbacks, annotated-tag/blob/bare command gates, Unicode references, Reset fresh-catalog handoff and input focus, draft/cancel/stale/rejected/competing-route/reset/apply/close/Quit locks and unchanged repository bytes. It does not order windows or physically present sheets and does not establish visual/keyboard/signed/full-dialog acceptance. `ReferenceBrowserTests` and `CheckoutTests` cover the Core regression with each Git engine via `TURTLEGIT_QA_GIT`.

### Switch full reference and commit pickers

After an unsigned Debug build, run `python3 scripts/test-switch-pickers.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The hidden native receiver exercises actual Switch, reference browser and full single-selection Log controllers, namespace handoff/defaults, draft and force/Merge retention, strict actual revision first responder, typed ancestry/graph, cancel/stale/reject/competing-target/Checkout/reload/close/Quit/forced-parent locks and unchanged repository invariants. Windows remain unordered and presentation is injected with parent focus released; repositories and preferences are private. `scripts/test-switch-progress.py` remains the real checkout/retry/tracking/force/conflict/cancellation regression. These checks do not establish physical or signed/full-dialog parity.

### Branch, Tag and Worktree full revision pickers

After an unsigned Debug build, run `python3 scripts/test-creation-pickers.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. Private hidden native Branch/Tag/Worktree controllers exercise full browser and typed Log routes, graph/single selection, canonical/Unicode base handoff and strict control focus, option/draft retention, Worktree suggestions and parent locks/lifecycle. Picker read-only invariants precede real private creation at the Log-selected base. Presenters release parent focus without ordering windows or actual sheets. Use the same Git arguments with `scripts/test-worktree-dialog.py` for real worktree/list/scope-policy/cancellation regression; it now compiles all Mac sources in shipping Swift 5 mode. `scripts/test-branch-tag-handoff.py` and `scripts/test-switch-pickers.py` remain relevant regressions. Physical and signed/full-dialog acceptance remain unverified.

Branch-description input and browser ownership: run
`python3 scripts/test-reference-description.py` after the Debug build, optionally
with repeated `--git` for Apple and bundled Git. This receiver prohibits activation
and uses private repositories/preferences; it does not display windows or establish
physical sheet/layout or App Store acceptance. Core description coverage is in
`ReferenceBrowserTests` and existing `ReferenceCreationTests`.

Inline branch rename: `python3 scripts/test-reference-rename.py` after Debug,
optionally with repeated `--git` arguments. It hosts actual menu/F2/native
field-editor command routes in private repositories/preferences, without displayed
windows. Core `ReferenceBrowserTests` includes config/reflog/current HEAD, bare,
invalid/collision/cancellation and packed NFC/NFD source-identity cases. No
physical keyboard/focus-change/IME or signed acceptance is established.

Tracked branches: `python3 scripts/test-reference-tracking.py` after Debug,
optionally with repeated `--git` arguments. The hidden receiver uses actual
parent/remote-only browser controllers and private repositories/preferences; it
checks canonical set/unset, fetch mapping, retained branch settings, cancel,
parent/Quit/type/bare/reject/stale/forced-close gates without ordering windows.
Core coverage is in `ReferenceBrowserTests`. No physical/signed or network
tracking/fetch acceptance is claimed.

Reference-browser Switch route: `python3 scripts/test-reference-switch.py` after
Debug, optionally with repeated `--git`. It checks owned native Switch presets,
actual revision controls, private defaults, canonical Unicode, bare/type gates,
Cancel/reject/parent/Quit locks and forced nested picker cleanup without ordered
windows. Keep `test-switch-progress.py` and `test-switch-pickers.py` regressions
for real checkout/progress and full chooser behavior. No physical/signed acceptance
or production RepositoryModel construction is claimed by the route receiver.

The reference-browser receiver additionally checks Current Branch acceptance and
close against live HEAD after loading a stale catalog, filtered-out choices,
detached/unborn/bare HEAD, duplicate/refresh/close/owned-child gates, forced close
before query execution and a non-remote Current Branch result from the owned
tracking picker. Core tests include linked worktrees and exact Unicode HEAD
spelling. This is hidden controller coverage, not physical button/sheet acceptance.

The expanded `scripts/test-reference-switch.py` receiver also performs real
checkout through the browser-owned Switch and native progress controllers in a
separate private repository. It checks captured options, all three close policies,
acknowledgement/close/Quit locks, a post-action's previous branch, duplicate
completion, live Current Branch after checkout and rejected progress presentation.
Owned slow wrappers pause each initial catalog/branch read; forced browser close
must terminate both recorded processes and leave the closed child's fields/error
unchanged. Physical sheet presentation remains unverified. The subsequent
forced-checkout receiver expansion below covers hidden owner/process cleanup.

`test-reference-switch.py` now pauses every checkout-validation command
(for-each-ref, revision resolution, branch-name and branch/tag existence probes),
the progress previous-branch read, Git switch and its follow-up status read.
Forced browser close must terminate both recorded processes, release controllers
and suppress late error/conflict/change/post callbacks. A separate forced-progress
close checks pending cancellation answers, fresh retry and stale completion
identity. The post-switch pause confirms cancellation retains completed HEAD
changes. Nine CheckoutTests include pre-cancelled validation and checkout with
unchanged repository bytes; the native paused commands cover running cancellation.

After Debug build, `python3 scripts/test-reference-merge.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`
checks the actual reference-browser Merge menu/icon/order, live HEAD/current/type/
bare/linked-worktree gates, exact native canonical local/remote/symbolic/tag/notes/
Unicode presets, owned close/Quit/competing/cancel/reject/forced-load cleanup and
a real fast-forward merge/progress acknowledgement. Private preferences are passed
through Merge hosting/history/progress; all windows remain unordered. Production
RepositoryModel configuration is inspected without constructing its shared-Finder
settings writer. Full source preflight, picker/physical/signed parity remain pending.

### Merge forced lifetime cleanup

After a Debug build, run `python3 scripts/test-merge-cleanup.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The receiver uses hidden shipping controllers, private repositories/preferences
and recorded owned process IDs. It verifies closure during metadata, validation,
execution, failure inspection, dismissal and branch deletion, including late
confirmation answers and frozen result state. It does not launch the main app or
establish physical/signed UI acceptance. Keep the existing Merge stream and
reference-browser Merge receivers as regression gates for normal completion.

### Merge revision pickers

After Debug build, run `python3 scripts/test-merge-pickers.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
This exercises shipping Merge controls, full reference browser and Log in hidden
windows, private repositories and preferences. Its native presenter releases the
parent's editor focus before disabling it. It verifies real responder state but
uses no physical sheets and does not launch the main app. Run Switch and creation
picker receivers after changes to the shared `VersionPickerCoordinator`.

### Reference browser Create Branch

After Debug build, run `python3 scripts/test-reference-create-branch.py --git
/usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The hidden receiver checks original menu artwork, immutable hash handoff despite
a moved remote, actual private branch creation and catalog refresh, ownership and
recorded live process cleanup. Private preferences and fixtures are removed after
the receiver. This does not establish physical/signed UI acceptance. Run
`ReferenceCreationTests`, creation-picker and browser-Merge receiver regressions
when changing the shared creation factory or context menu.

### Reference browser Fetch

After Debug build, run `python3 scripts/test-reference-fetch.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The receiver uses hidden shipping controllers, private preferences and local
producer/client repositories. It verifies original menu/icon/order, remote preset,
real fetch and retained acknowledgement/catalog refresh, ownership/rejection,
standalone Quit and recorded live metadata/transport cleanup. It checks unchanged
local HEAD/index/worktree and does not launch the main app or use the network.
Retain Fetch/Pull streaming, Fetch/Rebase decisions, cancellation and submodule
defaults as regression gates. Physical/signed acceptance remains separate.


### Pull forced lifetime cleanup

After a Debug build, run `python3 scripts/test-pull-cleanup.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The hidden shipping-controller receiver pauses initial HEAD, config, remote,
branch validation, Pull transport, failure status, post-success HEAD and Reset
defaults. Forced owner closure must release progress, terminate recorded live
leader/helper PIDs and freeze result/callback state, including a held late Cancel
answer. Both late No and Yes answers after successful completion are checked separately
with automatic close enabled. A completed Pull retains its HEAD mutation. Private fixtures/preferences
are removed; no main app or ordered windows are used. Keep
`test-fetch-pull-stream.py` and `test-pull-progress.py` as normal-output,
cancellation and recovery/post-action regressions. These checks do not establish
physical sheets or signed/full-dialog acceptance.


### Reference-browser deletion

After an unsigned Debug build, run `python3 scripts/test-reference-delete.py
--git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The receiver invokes actual hidden native menus, captures Yes/No confirmations
and uses private repositories/preferences. It verifies original Delete icons,
unmerged/tag/remote warning semantics, real local and local-remote deletion,
Refresh, parent/close/Quit and late-answer gates, and forced preflight/local/Push
leader-helper termination. HEAD/index/worktree remain unchanged. Core
`ReferenceBrowserTests` additionally cover checked-out failure, bare repositories,
packed canonical-equivalent refs and cancellation. Run existing browser and
tracking receivers as regressions. These checks do not establish physical sheets,
batch commands, real authentication or signed acceptance.


### Standalone reference browser

After a Debug build run `python3 scripts/test-reference-standalone.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The private hidden receiver checks actual multi-selection table/menu actions,
last-selected `..`/`...` Log direction, real Git range query, intercepted clipboard
text, sorting/filter selection, tree/other double-click, empty/duplicate close and
owned-child gates. Existing picker mode stays single-selection. Keep
`test-reference-browser.py`, `test-reference-delete.py` and
`test-finder-menu.py` as regressions. Finder requests and all 42 implemented source
command rules are covered by Core tests. No installed main app/Finder or
physical input is activated; complete standalone/batch menus remain pending.


### Batch reference deletion

After a Debug build, run `python3 scripts/test-reference-batch-delete.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The private hidden receiver checks actual batch menus/icons, count and merge/remote
warnings, No/Yes/Refresh, branch/tag/local-remote effects, mixed namespaces, pending
confirmation/close/Quit and late answers. Paused validation/local/Push leader-helper
processes must exit on forced owner closure. HEAD/index/worktree stay unchanged.
`ReferenceBrowserTests` covers one Push per configured remote and stop-on-first
local failure with earlier deletion retained. Keep single deletion and standalone
range receivers as regressions; physical/signed/full menus remain unverified.


### Reference comparisons

After a Debug build run `python3 scripts/test-reference-comparison.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The hidden receiver checks actual two-reference menu order and source icons, an
owned Changed Files controller using canonical names, displayed-order comparisons
versus last-selected Log direction, captured patch bytes after a ref moves,
Shift's alternative-viewer request, duplicate/F5/close/Quit gates and recorded
revision/patch process-group termination on forced browser close. Viewer launch
is intercepted; no main app or external application opens. Run ReferenceBrowserTests
and RevisionComparisonTests plus standalone/batch receiver regressions. Complete
physical comparison/viewer/child-editor and signed acceptance remain pending.


### Reference folder commands

After a Debug build run `python3 scripts/test-reference-folders.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
This hidden shipping-controller receiver checks heads/tag folder menu order and
original icons, empty folder clipboard interception, actual HEAD branch/tag
creation with owned defaults, filtered/scoped Delete all tags No/Yes/Refresh,
empty result/duplicate/F5/close/Quit and late-answer gates, rejected creation,
single-picker multi-row deletion and bare tag creation. It never orders a window,
constructs RepositoryModel or uses a shared clipboard. Run ReferenceBrowser,
ReferenceCreation and RevisionComparison Core tests, plus standalone/batch and
comparison native regressions. Standalone Copy now expects source-short names.
Remote folder dialogs and physical/signed/complete creation variants remain pending.


### Remote tag dialog

After a Debug build run `python3 scripts/test-remote-tags.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The hidden receiver exercises actual folder menu icons/presets and native tag
list selection, tri-state state changes, captured names/remote, Abort/Delete/Refresh,
owned progress, duplicate/F5/close/Quit and late confirmation gates. It records live
process groups and forces closure during ls-remote, check-ref-format and Push.
Progress/confirmation presentation is intercepted; no window is ordered. Run
RemoteTagTests/ReferenceBrowserTests and existing folder/Fetch native regressions.
Physical confirmation/default focus, all failures/timings, real authentication and
signed App Store/Finder acceptance remain pending.

### Remote settings backend

Run `swift test --filter 'RemoteSettingsTests|PushTests|ReferenceBrowserTests'`
with system Git and with `TURTLEGIT_QA_GIT` pointing to the bundled Git executable.
Private fixtures exercise raw versus alias-expanded URLs, changed-field isolation,
slash names, tri-state/tag clearing, legacy key preservation, inherited-value
failure after partial writes, multivalued config refusal, unrelated Push Default,
own/boundary/SVN/Unicode collision checks, explicit overwrite, rename tracking/ref
updates, removal and pre-cancellation. This is backend evidence only; native
OpenSSH identity transport remains pending. See
[Manage Remotes parity](REMOTE-SETTINGS-PARITY.md).

### Native Manage Remotes

After a Debug build run `python3 scripts/test-remote-settings.py --git /usr/bin/git
--git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`.
The hidden shipping page receiver exercises fields/options, three-state Prune,
origin prefill, Save/Rename, dirty Save/Discard, overwrite No/Yes, captured Remove,
Fetch-offer callback, actual Browse References ownership, native alert defaults,
Close/Quit and late confirmations. Live helper/child process groups are forced
closed during config reads, remote add, rename and removal. Native physical focus,
all presentation/error races, OpenSSH identity and signed acceptance remain pending.

### Private SSH agent primitive

Run `swift test --filter SSHAgentSessionTests`. Tests use macOS OpenSSH, private
fixture keys and a private foreground agent. They verify two identities, literal
punctuation paths, encrypted-key failure without prompting, earlier-key retention,
pre-cancellation, startup failure, release/deinit cleanup and live key-loader
helper/child termination during forced close. No login agent or SSH server is
used. App wiring and bundled/signed OpenSSH helpers remain pending; see
[SSH agent parity](SSH-AGENT-PARITY.md).

### Encrypted SSH key response

Run `swift test --filter 'SSHAskpassTests|SSHAgentSessionTests'`. Without
`TURTLEGIT_QA_ASKPASS`, tests compile the shipping CLI in a private fixture. To
exercise the actual Debug product, set that variable to the absolute path of
`TurtleGitMac.app/Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass`. After Debug
building, run `python3 scripts/test-ssh-passphrase.py` for the hidden secure-field
and one-shot OK/Cancel/forced-close checks. Bundle audits include the response
CLI provenance, architecture/linkage and replay probe. Real authentication,
physical UI and signed sandbox acceptance remain pending; see
[SSH response parity](SSH-PASSPHRASE-PARITY.md).

### Native SSH identity grants

Run `swift test --filter 'SSHIdentityAccessTests|RemoteSettingsTests'` for private
bookmark-provider and actual Git configuration tests. The existing
`python3 scripts/test-remote-settings.py` receiver now checks the native identity
selection callback, separate Windows/native paths, saved grant, PPK refusal,
typed-path nonauthorization, busy/child controls and late close fences using
private fixture grants. These are not displayed picker or signed sandbox tests.
See [native identity parity](SSH-IDENTITY-PARITY.md).

### SSH transport preparation

Run `SSH_AGENT_PID=999999 swift test --filter
'SSHTransportPreparationTests|FetchTests|PullTests|PushTests'`. The sentinel is
scoped to the test process; it does not modify a login agent. Six private-agent
preparation tests verify actual local Git effects, callback order, agent lifetime,
actor reentry, late cancellation and live process-group cleanup. They use no SSH
server. See [transport parity](SSH-TRANSPORT-PARITY.md).

### Native SSH coordinator

After the Debug build, run `python3 scripts/test-ssh-coordinator.py`. Repeat
`--git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`
for both engines. The hidden receiver uses private preferences, generated
encrypted keys and owned agents. It checks prompt retry/cancellation, changed-key
reload, CRLF headers, shipping Fetch/Pull/Push/browse auto-load and forced Push
controller closure. It executes local Git effects; it does not prove network SSH,
physical sheet interaction or signed security-scoped bookmark acceptance.

## Read-only MX probe

The SMTP MX decoder/input/pre-cancel tests run with `swift test --filter SMTPMXTests`.
The system query test is skipped unless explicitly enabled:

```sh
TURTLEGIT_MX_DNS_PROBE=1 swift test --filter SMTPMXTests
TURTLEGIT_MX_DNS_PROBE=1 python3 scripts/test-configured-smtp.py
```

The first command reads public MX records and checks repeated post-open query
cancellation/descriptor cleanup. The second requires the current Debug frameworks;
it reads the same records and submits only to its owned loopback SMTP fixture.
Neither command sends mail to the queried domain or reads user credentials.
Default CI does not enable the public DNS probe. Its observed results and limits
are recorded in [MX QA](qa/send-patch-mx-2026-10-10.json).

### Commit refresh cancellation

After a Debug build, run `python3 scripts/test-commit-refresh.py --git /usr/bin/git
--git build/git-runtime/Git/bin/git` (as one command). The hidden native receiver
uses private repositories and preferences, controls a status reply that ignores
cancellation, and blocks the production status query in an owned sleeping child.
It checks controller-close fencing, cooperative Cancel, duplicate requests, draft
confirmation, reload after declining, and exact HEAD/index/working contents. This
is separate from displayed Cancel/Escape acceptance and signed sandbox testing.
`CommitReadCancellationTests` also checks that pre-cancelled Core read APIs throw
cancellation instead of treating it as missing configuration or an unborn HEAD.

### Native image comparison

After a Debug build, run:

```sh
python3 scripts/test-image-comparison.py --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The receiver compiles current application sources into a private headless
executable, uses a disposable repository and hidden native hosting windows,
and checks image routing without an image filename extension, actual pane
raster colors, fit/manual zoom, linked/unlinked scrolling, vertical/overlay
transitions, alpha endpoints/midpoint, XOR changed/unchanged pixels and switching
back to alpha. Unequal-image checks measure actual colored pixel extents for
linked widths/heights/both, source stepped zoom and Original Size, including
retained per-picture zoom. Input checks exercise native slider click/drag/release,
knob direction, accessibility actions, Control-Shift wheel in Alpha/XOR and
the real comparison window’s keyboard bridge and close retirement.
It compares HEAD, raw index and file
bytes before and after. Each engine runs serially; the runner removes its
private executable and repository. This does not exercise physical mouse or
keyboard gestures, signed Finder activation or App Store distribution.

### Native image conflict selection

After a Debug build, run:

```sh
python3 scripts/test-image-conflict.py --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The disposable real-Git fixture contains different Mine/Base/Theirs PNG bytes
under a non-image extension. The private receiver checks actual native pane
pixels/order, independent fit/zoom, vertical layout, AppKit Select buttons and
production Yes/No confirmation sheets. No leaves selected working bytes and
unmerged stages; Yes rejects changes made while confirmation is pending, then
Reload permits a fresh selection and resolution. Close/Quit fencing and final
HEAD/index contents are checked. AppKit can order a sheet parent, so the receiver
keeps its window transparent and offscreen, then hides the sheet and parent.
All owned windows, executable and fixtures are removed. This does not establish
physical gestures, VoiceOver, signed sandbox or Finder activation acceptance.

## Image frame/page controls and playback

After building the Debug app and Core framework, run:

```sh
python3 scripts/test-image-frames.py --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The private native receiver exercises actual Previous/Next and Play/Stop buttons
with unequal GIF frame counts, linked and independent navigation, wrapping,
rendered frame colors, TIFF page dimensions and ICO variants without Play.
It checks timer cancellation on overlay, source replacement and window close,
and verifies unchanged HEAD, index and original encoded image bytes. A real
multi-frame conflict exercises independent Mine controls and the actual Select
and No sheet buttons: selecting at a later visible frame copies the original
whole GIF and leaves unmerged stages intact; closing cancels the pane's player. Its windows
stay transparent/offscreen and its temporary receiver and fixtures are removed.
This does not establish physical gesture, VoiceOver, all-format or signed Finder
acceptance. See [frame parity](IMAGE-FRAMES-PARITY.md).

## Image transparent colors and local appearance

After the Debug build, run:

```sh
python3 scripts/test-image-colors.py --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The private native receiver exercises actual color wells and OK/Cancel sheet
buttons, rendered transparent pixels in both comparison panes and all three
conflict panes, alpha/XOR background composition, native-window D key routing,
appearance reset and independence from other windows and NSApp. It checks
close/Quit fencing, pending-sheet retirement, chooser survival across native
view updates and retention of the selected color across source reload. Color checks
use same-window native reference swatches to account for the display profile.
It verifies unchanged comparison HEAD/index/image bytes and unchanged conflict
index/working bytes. Owned windows remain transparent/offscreen and are closed;
temporary receivers and fixtures are removed. Physical color-picker gestures,
VoiceOver, high contrast and signed acceptance remain pending.

## Load Images and standalone viewer inputs

After the Debug build, run:

```sh
python3 scripts/test-image-open.py --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The private receiver uses actual Cmd+O routing, native path fields, OK/Cancel
buttons and a native file-authorization picker. It checks left-only prefill,
invalid paths retaining the dialog, identical/single/empty inputs, fit/title and
view-mode retention, picker cancellation before acceptance, modal close/Quit
fences, and unchanged Git HEAD/index/file bytes. An injected grant provider
checks standalone acceptance and retained/released lease ownership; it does not
prove signed OS grant acceptance. Picker factories keep owned
native windows transparent/offscreen; fixtures and receivers are removed.
Physical file-selection/text-entry gestures and signed grants remain pending.

Run `python3 scripts/test-commit-history.py --git /usr/bin/git --git
build/git-runtime/Git/bin/git` after a Debug build for the integrated Commit
Recent Messages workflow. The receiver uses an actual AppKit event loop with
activation prohibited, transparent private windows and the production editor,
context-menu target/action, sheet, table and native Return/Escape/Delete actions. It checks Cancel, multiple
selection/template replacement, prefix suppression, caret insertion/focus,
Delete persistence, modal ownership and forced-parent cleanup without committing
or changing working files. A final completion marker is mandatory for each Git
engine. This is native programmatic acceptance, not physical-input, VoiceOver or
signed sandbox acceptance.

The Commit history receiver also checks configured issue-label/template behavior,
real naturally sorted duplicate IDs, no-match preservation and controlled delayed
queries that ignore cancellation. It verifies rejection after issue/message/config
edit-and-restore, superseding requests and parent closure. Run `swift test --filter
'IssueMessageStyleTests|IssueTrackerTests|IssueRegexTests'` for the matching Core
checks. The native receiver uses template-based extraction; complete native
ECMAScript-helper and physical issue-field acceptance remain unverified.

Commit history native fixtures now include a template with UTF-8 BOM, a malformed
byte and CRLF. The receiver checks the exact loaded editor/model text and source
bytes across history Cancel/replacement. `CommitMessageTests` covers repaired
UTF-8 template/operation input, output-encoding independence, empty files, actual
unreadable/missing paths and linked-worktree separation. Every malformed Windows
subsequence and embedded-NUL UI behavior remain unverified.
