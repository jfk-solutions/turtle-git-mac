# Testing TurtleGit for Mac

Run commands from the repository root. The checked-in
[macOS workflow](../.github/workflows/macos.yml) defines the hosted CI sequence.
Local success does not establish that a hosted run passed, that dialogs match
TortoiseGit visually, or that the app is ready for distribution.

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

After unsigned Debug and AppStore builds, run `python3 scripts/test-reset-modified-files.py --git /usr/bin/git --git build/Build/Products/AppStore/TurtleGitMac.app/Contents/Helpers/Git/bin/git`. The receiver constructs actual Reset and Changed Files controllers without ordering windows and injects sheet presentation. It checks the private repository's HEAD-to-working-tree list (mixed/staged/unstaged/add/delete/Unicode paths), exclusions, retained Reset target, parent reset/apply/close/Quit and duplicate gates, configured callback delivery, close/reopen/stale/rejected/bare/busy/forced-parent cleanup. HEAD, staged tree, config and working bytes remain unchanged after fixture setup; index stat-cache bytes are not asserted. `scripts/test-reset-progress.py` remains the real Soft/Mixed/Hard/cancellation/retry regression. Hidden ownership checks do not prove physical sheet interaction, focus or signed App Store behavior.
