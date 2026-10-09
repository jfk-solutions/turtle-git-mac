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
Rebase plan. The focused flag does not claim Rebase rendered-text acceptance.
Omit it for the strict three-view check, which currently fails at Rebase text
observation; the same absence is reproduced by a minimal SwiftUI Table. This
full UI gate remains pending, rather than being counted as passed. Its temporary Blame source copy only appends a same-file view access
function; production private table code is unchanged. No main app or replay
operation runs. Owned windows, temporary fixtures and preference domains close
and remove on successful exit. As with other native receivers, do not edit
sources or replace linked Debug products during execution.
