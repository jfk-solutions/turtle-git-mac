# Testing TurtleGit for Mac

## Development batch cadence

Implement a complete related feature group across Core, native dialogs, Finder
routing where relevant, resources and documentation before validating it. Do not
run the full suite on a timer or after each file/control edit. Run one grouped
set of relevant Core checks, one app build and one combined native receiver at
the end of the batch. Broaden validation only for a concrete failure or unresolved
cross-feature risk; use focused repairs for failures. The full suite belongs to
CI and release milestones. Close every test-owned window/process after its checks,
and reuse compiled native receivers when sources have not changed.


Run commands from the repository root. The checked-in
[macOS workflow](../.github/workflows/macos.yml) defines the hosted CI sequence.
Local success does not establish that a hosted run passed, that dialogs match
TortoiseGit visually, or that the app is ready for distribution.

## GitHub CI repair, 12 October 2026

Run 38199319588 reached 1,063 Core tests and reported ten failures: stale Finder
catalog/empty-selection/icon assertions and a real SVN fast-forward reset parser
incompatibility. The contracts now reflect the implemented command set and
intentional source-icon aliases; reset uses a validated full object ID without
the unnecessary `--end-of-options`. The focused repair passed 25 tests with system
Git and four SVN tests with packaged Git. CI now checks the SVN commands with both
executables. Hosted success is still pending. See
[the repair record](qa/ci-contract-repairs-2026-10-12.json).

## Prepared runtime caches

CI now caches the remaining expensive pinned helper builds with exact toolchain/
source/transitive keys and unconditional validation. Valid packages are saved
before app tests, so later failures do not discard dependency build work. Full
Core/native/embedding checks still run. See [runtime reuse](CI-RUNTIME-CACHES.md).

## Native LFS transition checkpoints

The grouped LFS/mail receiver now has a `--lfs-only` diagnosis mode using its
same source/framework/toolchain cache. LFS sort checks wait for the native row-ID
projection and selected rows; Commit's LFS-owner column width check waits for
native column visibility/settings and saved width. Assertions retain their
selection/checkbox/width requirements, with diagnostics on failure. The final
focused receiver passed locally. The hosted line-111 failure has not been
reproduced locally or confirmed repaired by a new hosted run. See
[the repair record](qa/ci-lfs-transitions-2026-10-12.json).

## Hosted Core checkpoint, 12 October 2026

Commit `98038f7` passed the hosted full Core suite: **1,083 tests, zero failures,
one skipped**, in 1,458.882 seconds, plus four packaged-Git SVN checks. The job
later failed in the native LFS/mail receiver's selection assertion, so this is
not a green full workflow. Later port batches need their own hosted checks. See
[the authoritative checkpoint](qa/ci-core-checkpoint-2026-10-12.json).

## Latest complete local Core checkpoint

On October 11, 2026, `swift test` completed **980 tests, zero failures, one
optional MX probe skipped**, in 874.897 seconds with Swift 6.3.3 and system Git
2.50.1. The process exited with status zero. This includes the generated change-set
comparison helper and the existing Core integration tests. No Core sources or
Core tests changed while the suite ran; simultaneous native app work is verified
separately. See [the checkpoint record](qa/core-full-range-log-checkpoint-2026-10-11.json).
The later Sync Find icon/resource addition passed all three `MenuIconTests`;
it is outside that complete-suite checkpoint.
This result does not establish native UI parity, hosted CI, signed Finder or
App Store acceptance. The earlier dated checkpoints below retain their original
scope and limitations.

## Current compatibility checkpoint

On October 10, 2026, the current compatibility changes passed a complete local
`swift test`: **925 tests, zero failures**, with one optional system-DNS probe
skipped. The Apple Git 2.50.1 / Swift 6.3.3 run finished normally in 535.358 seconds.
The two nested-tag tests also check the real Revision Graph reader and copied
outer-tag annotation. Eleven focused tests passed with isolated Git 2.39.5 and
again with packaged Git 2.55.0; 68 broader tests passed with system Git.

These changes repair nested-tag metadata using the pinned upstream
`show-ref --dereference` CLI route, atomically publish private SMTP fixture JSON,
and verify legacy rebase messages against exact raw Git state rather than a
version-specific count of trailing blank lines. Production SMTP and Rebase
message decoding are unchanged. See [the compatibility record](qa/ci-compatibility-2026-10-10.json)
for source hashes, engine reproduction and remaining verification.

At source checkpoint `c5dac22`, unsigned Debug/Store builds and both bundle audits
passed, as did native Log Find with system and packaged Git. The first native
Graph run passed system Git but failed a menu invocation assertion with packaged
Git. A diagnostic rerun retained all assertions and passed both engines; the
initial failure's root cause is unproven. Action diagnostics remain in the
receiver. Existing SwiftUI cycle warnings during hidden Log reloads also remain.
Neither receiver establishes physical-input, installed Finder or signed sandbox
acceptance.

The previous published [macOS run for `110c364`](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38077950409)
completed its 925-test suite with five failures in the two nested-tag cases and
the legacy rebase expectation. That run predates these fixes; passing local
checks do not establish a passing hosted run.

For a bounded reproduction of intermittent Graph receiver failures, use:

```sh
python3 scripts/test-revision-graph-window.py \
  --git /usr/bin/git --git build/git-runtime/Git/bin/git --repeat 3
```

The runner compiles once and runs fresh fixtures sequentially, stopping at the
first failure. `--repeat` accepts 1–10; the default remains one run per engine.
Three runs per engine passed locally with 30 validated deletion-menu activations.
This did not reproduce or explain the earlier failure. See
[the repeat record](qa/graph-menu-repeat-2026-10-10.json).

The subsequent [macOS run for `f9521c9`](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38080574877)
passed **925 Core tests, zero failures**, with one optional skip, on the hosted
older-Git/Swift toolchain. The job then failed compiling the historical
item-provider receiver because its standalone build omitted Core's SMTP module.
The corrected command exposes the generated Clang module map and links the C
objects with libcurl; the unchanged receiver passes locally. The hosted retry for `a806f22` passed both the integration-test and repaired
item-provider steps in [run 38084063632](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38084063632).
Later native/packaging gates are still running; the job has not yet passed. See
[the build diagnosis](qa/ci-browser-smtp-module-2026-10-10.json).

## References containing a commit

At source checkpoint `1769e2c738e9b078e6c377205f5124b23bd010db`, the new
containment reader passes three real-repository tests with system Git, isolated
Git 2.39.5 and packaged Git. Six system-Git tests including menu-icon checks pass.
The native receiver passes with system and packaged Git, including menu dispatch,
comparison direction, filtering, all three picker routes, stale reply rejection,
bare repositories and the parent Log close route. Latest unsigned Debug/Store
builds and both package audits pass, with 120 original icons verified.

```sh
python3 scripts/test-commit-containing-refs.py \
  --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The receiver owns hidden windows, private preferences and disposable repositories,
and cleans up after terminal completion. Actual native content captures were
inspected in light and dark mode and included on the Pages site. Physical input,
VoiceOver, installed Finder and signed sandbox acceptance remain pending. The
complete local suite passed **928 tests, one skipped, zero failures** in
526.670 seconds. The process exited normally; this result does not establish
the new hosted CI result.
See [the verification record](qa/commit-containing-refs-2026-10-10.json).

## Log commit ordering

At source checkpoint `900aaf82550e616fa4a79bfd876e2740696f487f`, three ordering
tests pass with Apple Git 2.50.1, isolated Git 2.39.5 and packaged Git 2.55.0.
A broader system-Git history/ordering/Revision Graph run passes 62 tests. The
fixture deliberately skews author/committer dates across a merge, distinguishes
at least three actual walks and compares all four choices to direct Git. Limits,
path filtering, search, ranges, graph input and repository bytes are covered.

```sh
python3 scripts/test-log-ordering.py \
  --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The hidden native receiver passes on both engines: actual header delegate entry,
four-choice draft, Cancel/OK, Return/Escape, retained selection, busy/close/Quit
fences, an already-open modeless reference child and forced parent close. Actual
light/dark content captures were inspected. Latest unsigned Debug/Store builds
and both package audits pass. The previous full 928-test run predates the ordering
change; these targeted results do not establish a full 931-test run. Physical,
VoiceOver, localization, installed Finder and signed sandbox acceptance remain
pending. See [the ordering record](qa/log-ordering-2026-10-10.json).

## Commit-reference completion cache follow-up

At Core checkpoint `9400d1d`, four containment/completion tests pass on system,
Git 2.39.5 and packaged Git. Native checkpoint `dc2d8d5` passes the extended
receiver on both engines: initial empty/invalid completion; real new references
in containment while completion stays cached; F5 reload preserving entered text;
read counters; simulated nonfatal completion failure and retry; controlled late
completion replies after supersession and close. Existing menu/picker/stale
commit-data/parent close routes still pass. Builds and package audits are recorded
in [the follow-up evidence](qa/commit-refs-completion-2026-10-10.json).

These focused checks do not establish the full new 932-test suite, physical input,
installed Finder, localization or signed sandbox acceptance. The Abort Merge
owner audit maps nine existing controls and records missing modal comparison,
separate progress, Quit and forced-close/preflight cancellation behavior; see
[the audit](qa/merge-abort-owner-audit-2026-10-10.json).

## Previous full-suite checkpoint

At Core source checkpoint `c4bd370`, a fresh local `swift test` passed **921 tests,
zero failures**, with one optional DNS probe skipped, on October 10, 2026. The run
used Apple Git 2.50.1 and Swift 6.3.3 and finished normally after 527.3 seconds.
The initial run found two stale Finder Revision Graph expectations; they were
corrected against the pinned upstream source before this complete rerun.

The native Finder receiver then exposed a real menu-order mismatch. At
`a88d8c2`, Revision Graph follows Browse References, matching the source menu.
The receiver passed all 45 implemented root-entry projections, and unsigned
Debug/Store builds and both bundle audits passed. Core sources and tests were
unchanged after the full-suite checkpoint. See
[the current integration record](qa/current-full-suite-2026-10-10.json).
The [previous 866-test record](qa/full-core-2026-10-10.json) remains historical.

The published [macOS run for `23240f5`](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38071049130)
failed before executing tests: the hosted Swift 6.1.2 compiler timed out on two
Cleanup error-description expressions. `a0c630e` replaces their long chained
expressions with equivalent sequential string construction. All 25 focused
Cleanup tests pass locally on Swift 6.3.3. The
[hosted retry](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38072143453)
completed with the Cleanup expressions compiling, then failed on two further
Log expressions. The [subsequent Log Find run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38073496620)
confirmed those same failures in `RepositoryModel.showLog` and the revision-table
signature. No integration tests executed in that step. See
[the Cleanup diagnosis](qa/ci-clean-typecheck-2026-10-10.json).

At `8da3f2f`, both Log expressions use equivalent sequential string construction.
Local SwiftPM and unsigned Debug/Store builds, both bundle audits and the native
Log Find receiver with system and packaged Git pass. The hosted graph runtime
now uses an exact source/toolchain cache key, validates every restored package,
and saves only a validated finished package. A relocated package passed locally;
a modified copy was rejected by its binary digest. Hosted compiler success and
cache save/hit behavior still require a new run. See
[the Log compiler/cache evidence](qa/ci-log-typecheck-2026-10-10.json).
The [first cache-enabled hosted run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38074852815)
subsequently completed graph-package validation and cache saving successfully.
The Cleanup/Log compiler failures were resolved; the integration step then failed
compiling two DNS wire fixtures in `SMTPMXTests.swift`, before executing tests.
At `23214de`, equivalent sequential construction and explicit byte types preserve
the fixtures and assertions. All five focused tests pass locally with one existing
optional DNS probe skipped. Hosted acceptance of that fix still requires a new run.
See [the DNS fixture diagnosis](qa/ci-mx-typecheck-2026-10-10.json).

The [next hosted run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38075760736)
at `afe5691` confirms an exact graph-cache hit: the builder is skipped, the package
validator passes and saving is skipped on the hit. It was building OpenSSH helpers
at inspection and precedes the DNS fixture correction; complete hosted success
remains unverified.

The subsequent [run at `4e2bb70`](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38075922507)
resolved those compiler errors and executed **925 tests, one skipped, seven
failures (two unexpected)** in 741.8 seconds. Four cases failed: nested-tag
reference/tag-info searches, an empty SMTP fixture readiness file and extra
trailing blank lines in a legacy-encoded rebase edit message. These failures are
unresolved; native and package steps after the integration gate did not run.
See [the observed regressions and next checks](qa/ci-core-regression-2026-10-10.json).

The subsequent Log Find implementation has four focused Core tests and a native
receiver, both passing with system and packaged Git. Its unsigned Debug/Store
builds, package audits, inventory regression and local website generation pass.
These results are separate from the last complete 921-test checkpoint above.
See [Log Find evidence](qa/log-find-2026-10-10.json).

The subsequent parent-position correction follows both source headers' initial
zero and keeps the numeric Find index in the Log/Graph parent. Native receivers
with both Git engines verify initial Graph row exclusion, successful match/ref
updates, Shift selection preservation, close/reopen and reload retention, Log
context-menu positioning and bounded Log search with a stale index. The Graph
fixture's older first-query assumption was corrected against the pinned source.
The Log reload check emitted SwiftUI AttributeGraph cycle warnings; its assertions
passed, but physical rendering remains unverified. See
[Find position evidence](qa/find-position-2026-10-10.json).

The subsequent open-Find reference refresh maps pinned Log `Refresh` and
`CFindDlg::RefreshList`: accepted Log reloads replace the reference read, preserve
filter/query/index and cancel older searches/reads. Critical-sheet acknowledgment
drains a queued refresh. Natural reference ordering follows native Finder
collation, and the name filter now compares literal UTF-16 rather than merging
canonically equivalent Unicode spellings. Native Log checks with both Git engines
verify real numeric tag ordering, NFC/NFD and case-sensitive filtering, rapid
reloads, an actual Log tag-deletion completion, deferred-error refresh and parent
close. Both full native Graph receivers also pass with the shared implementation.
The existing Log SwiftUI reload cycle warnings remain; these hidden checks do not
prove physical rendering or full dialog parity. See
[reference refresh evidence](qa/log-find-refresh-2026-10-10.json).

## Core and native receivers

Build the required helpers, run the Git integration suite, then check the native
historical item provider:

```sh
python3 scripts/build-editorconfig-runtime.py
python3 scripts/build-issue-regex-runtime.py
python3 scripts/build-graph-layout-runtime.py
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
launch native windows. See [Revision Graph parity](REVISION-GRAPH-PARITY.md)
for the native window, Filter and modeless Find checks. The workflow runs their headless receiver with
both system and packaged Git after both app builds:

```sh
python3 scripts/test-revision-graph-window.py \
  --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

That receiver checks native controls, reference navigation, Find initialization,
Return/Shift-Return routing and owned error-sheet cleanup. It does not establish
physical mouse/keyboard, accessibility or signed sandbox acceptance.

The layout bridge's focused suite uses the built OGDF runtime and a private
cancelled worker:

```sh
swift test --filter 'RevisionGraphLayoutTests|RevisionGraphTests'
python3 scripts/validate-graph-layout-runtime.py \
  build/graph-layout-runtime/GraphLayout --all-architectures
python3 scripts/test-graph-layout-cpu-baseline.py
python3 scripts/test-graph-layout-embedding.py
python3 scripts/test-graph-layout-bundles.py
```

The optional all-architectures command requires Rosetta on Apple Silicon. It
checks actual layouts with both executable slices, not just Mach-O metadata.
The Swift suite checks clipping, invalid geometry, ownership, cancellation,
private file permissions and removal after the child is reaped. It launches no
native app windows. See [layout runtime](GRAPH-LAYOUT-RUNTIME.md).
The bundle receiver requires completed unsigned Debug and AppStore builds. It
compiles against their product modules and loads the byte-identical embedded
Core framework, then locates and executes each app's own layout helper. Ad-hoc
embedding checks signature/entitlement branches; signed sandbox parent execution
remains separate acceptance.

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
python3 scripts/test-context-menu-settings.py
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

## Shared Log Find receiver

After building Debug, run:

```sh
swift test --filter 'CommitHistoryTests.testFindHistory'
TURTLEGIT_GROUP_TEST_GIT="$PWD/build/git-runtime/Git/bin/git" \
  swift test --filter 'CommitHistoryTests.testFindHistory'
python3 scripts/test-log-find.py \
  --git /usr/bin/git --git build/git-runtime/Git/bin/git
```

The four Core tests cover the complete field corpus, all merge parents/root and
rename paths, working-tree rows, cancellation, invalid hashes, finite wrap and
first-result termination before an unreadable later row. The hidden native
receiver checks Command-F reuse, startup exclusion, notes/path searches,
reference navigation, Shift/plain Return, critical Return recovery, Cancel and
parent-close cleanup. It uses private preferences, disables saved Log geometry
and column layout, displays no app windows and cleans up its owned fixtures.
Physical input, installed Finder and signed sandbox acceptance remain separate.

## Reference-browser Switch receiver handshake (2026-10-11)

Hosted macOS run [38124517913](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38124517913)
failed the reference-browser Switch receiver at “Expected checkout stage not live:
switch-progress”. Its assertion combined PID count/liveness, busy state and owned
progress presence without recording which condition failed. The precise hosted
root cause is unproven.

The two injected Git stall scripts now atomically publish their complete PID
markers. A failure records parsed PIDs, liveness, busy state and actual/expected
progress presence. All assertions remain. The driver links the freshly built
Debug app objects instead of recompiling all app sources, runs the fixture on
NSApplication's event loop and applies bounded receiver cleanup on every exit.

The unchanged lifecycle requirements passed locally with system and bundled Git,
including real captured checkout, all three acknowledgement policies, forced
owner/progress closure at metadata/validation/switch/post-checkout stages and late
callback rejection. Both receivers were reaped. Hidden zero-size split-view layout
warnings were emitted; this does not prove displayed geometry, signed acceptance
or a successful hosted retry.

Sync revision Export now has actual owned options/progress checks in the same
revision-list command, including captured root/tag targets, ZIP bytes and startup
Cancel/forced-owner child-process cleanup. See
[the Export record](qa/synchronization-export-2026-10-11.json). Both receivers are
reaped; physical file-panel and signed acceptance remain open.

Git runtime deployment regression:
`python3 scripts/test-git-runtime-deployment.py --runtime build/git-runtime/Git`.
Synthetic universal/legacy/malformed/platform/high-target fixtures verify strict
per-architecture rejection; actual Git/LFS slices are cross-checked against
explicit `otool -arch`. The validator's full local Git and provenance audit passed;
see [the deployment record](qa/ci-git-deployment-2026-10-11.json).

Export's shared native version pickers are included in the Sync revision-list
fixture: actual nested reference/Log sheets, fresh-catalog tag selection, Cancel
refresh, guarded competing actions, forced child closure and startup/selection
read process cleanup. The two-engine run passed;
[the record](qa/export-version-pickers-2026-10-11.json) keeps physical/signed and
full-dialog acceptance separate.


## Grouped native LFS, Email settings and mail checkpoint

After a Debug framework build, run `python3 scripts/test-native-lfs-mail-batch.py`
for the combined section. It compiles all Mac receiver sources once, then runs
the existing LFS, Email settings and Send Patch verification drivers in one
process. The LFS responses are injected. The private SMTP server starts only
after LFS and Email settings complete, with a bounded acceptance timeout and
independent MIME assertions. Email uses private preferences and simulated
Security calls; no live Keychain is accessed. The process,
server and private fixtures are cleaned on success or failure. The individual
`test-lfs-locks.py` and `test-send-patch-dialog.py` scripts remain available for
focused debugging; the CI native-mail slot now uses the grouped runner.

The receivers cover standalone LFS progress ownership/duplicates/Close and the
actual outside-repository Finder Send Mail composer/Cancel path. They do not
establish physical Finder, signed file permissions or target-chooser gestures.
See FINDER-LFS-MAIL-PARITY.md and its QA checkpoint for the exact proof scope.

The combined compiler uses whole-module `-Onone` mode to avoid repeated per-file
whole-program type checks. It caches the executable by Mac source, receiver,
Core framework, architecture, flags and Swift toolchain hashes; changed inputs
rebuild it. LFS fixture author variables are isolated from the subsequent mail
fixture's intentional empty-author setup. The legacy unhosted Commit reload
cancellation test explicitly approves the same production confirmation used by
a hosted dialog and checks it is requested once.


## Development batching and native compilation reuse

Follow the implementation-first workflow in [AGENTS.md](../AGENTS.md): finish a
related feature family before grouped validation; repeat only an affected check
when a failure needs repair. There is no scheduled five-minute test cycle.

`test-email-settings.py` now delegates to
`test-native-reference-batch.py --only email-settings` after a Debug build. It
links the actual app objects/settings dependencies into the existing cache. CI
runs Email once in this group; the LFS/mail default group no longer repeats it.
Its legacy `--email-only` focus remains available, and `--lfs-only` remains
available for an actual LFS failure.

After building Debug, `test-native-merge-regex.py` links QA to the existing app
objects instead of recompiling the SwiftUI app. Its cache includes objects, app
and Core modules/framework, fixtures, target/compiler and flags. The options
batch and focused modes (including `--patch-only`) share a binary. Receivers
have bounded process-group cleanup/reaping on every exit. No app assertions or
receiver coverage are skipped by these caches.


## Merge Find/Replace batch

After the framework build, run `swift test --filter MergeFindTests` and
`python3 scripts/test-native-merge-regex.py --find-only` for this family. The
native receiver is also included in the grouped LFS/mail CI receiver. It uses
private two-pane files and a private three-pane Git conflict, keeps original
files/index unchanged and closes all owned Find/editor windows. No installed
app, public server or live Keychain is used. See [Find parity](MERGE-FIND-PARITY.md).


## Merge Open family

Run `swift test --filter MergeOpenTests` after implementation, then
`python3 scripts/test-native-merge-regex.py --open-only` after the Debug framework
build. The native receiver is included in the shared CI compilation. Checks use
private source files, clipboard/preferences and injected picker replies; the
standalone three-pane editor loads/saves without Git initialization. See
[Open parity](MERGE-OPEN-PARITY.md).

The Open follow-up batch adds private native drop-pasteboard, completion and
clipboard-metadata checks to the same receiver, plus Core input/output aliases,
hard-link replacement, delete/recreation, Reload and permission-change fences.
Run those with `MergeOpenTests` and `--open-only` after implementing the batch.


## Merge Encoding and Go To

Run `swift test --filter MergeFormatSelectionTests`, then the shared native
`--options-batch` after the Debug framework build. `--format-only` isolates the
format sheet/two-pane receiver after an actual failure. The Open receiver also
checks three-pane format acceptance. See [format parity](MERGE-FORMAT-PARITY.md).

## Grouped reference-family native receivers

Build Debug once, then run `python3 scripts/test-native-reference-batch.py` for
folders, comparisons, batch/single deletion, Switch/Fetch/Create Branch/Merge
routes and Merge reference/Log pickers. The driver links the existing app objects
and nineteen receiver families, including Network, Credential, Tool settings, Overlays, Email, Commit progress, SVN, issue settings/tester and external Merge lifecycle, in one compilation. It uses an explicit native AppKit run loop and
caches by object files, imported modules/framework, fixtures and compiler/flags.
It does not recompile the whole SwiftUI app for each case.

Receivers run serially with independent private repositories/preferences. Each
has a 300-second timeout and owned process-group cleanup/reaping on every exit.
Compilation also has a 300-second limit. `--only batch-delete` (or another case)
is for an actual failure; `--git` remains repeatable for engine-specific checks.
The older `test-reference-*.py` commands delegate to the same cache and retain
all original fixture assertions. Batch deletion now publishes helper PID markers
atomically, matching the already-repaired single-deletion fixture.

The grouped Merge options and LFS/mail receivers include
`merge-line-diff-native-2026-10-12.swift`: saved visibility, UTF-16 hover mapping,
Base/Mine ordering, independent inline/whitespace display, original EOL markers,
light/dark TextKit rendering, unchanged text/selection/history/files, and
exit/single-file/rebuild/retired guards. QA images are written under `build/qa`.

`MergeUnifiedPatchTests` checks applicable quoted Unicode/control-character
paths, CRLF/non-UTF-8 hunk bytes, context range/default/zero, mode-only changes,
add/delete, symlink targets, binary diagnostic and cancellation semantics.
The grouped native Merge/LFS-mail receivers include `merge-patch-native-2026-10-12.swift`
for actual General context Apply/Cancel and invalid values, light/dark layout,
File menu ownership/icon/gates, save cancellation, saved-file export with an
unsaved draft, unchanged inputs/history and retired replies.

The Merge picker fixture retains its ancestry, graph, native row-count and single
selection assertions, but waits for the native table to render after the model
publishes its entries. Hosted job `114802897011` failed the immediate row-count
assertion. A bounded wait now reports actual model/native/graph counts on failure.
`test-merge-pickers.py` delegates to the reference cache, and CI runs it once in
that group rather than compiling a separate app-source receiver.

The grouped Merge options and LFS/mail receivers include
`merge-colors-native-2026-10-12.swift`. It exercises all 17 source channels,
native dropdown/default swatches and RGB custom actions, alpha exclusion,
independent palette drafts, selective Restore Default, Settings Apply/Cancel,
actual light/dark control bounds and shared-panel ownership/retirement. Private
preferences and owned windows/panels isolate the check from the user's app.
Use `--colors-only` only for an actual Colors failure; it shares the built-app
object cache with the options batch. No new Core tests mirror these controls.

`OnePaneFileComparisonTests` checks ordered regions/source-row mappings, removed
payload edits excluding untouched removals, original CRLF/nonterminated Unicode
results, multi-match replacement and filtered case/whitespace projection.
The grouped Merge/LFS-mail receivers include `merge-one-pane-native-2026-10-12.swift`
for saved default, one actual editor, locator/navigation, removed selection,
native typing/Undo/Redo, exact BOM/EOL Save with Base retained, mode Save/Cancel/Discard, combined Replace All/Tab with single Undo,
and roundtrip/persistence/retired guards. `--one-pane-only` shares the object cache.

The Merge/LFS-mail batch includes `merge-one-pane-context-native-2026-10-12.swift`:
actual left-role menus, hidden-opposite/model guards, source command ordering,
removed Copy, private pasteboard capture across menus, real Cut/Paste/Undo,
nine encoding order/action identity, readonly omission and retired clipboard/
editing guards with saved inputs unchanged. `--one-pane-context-only` uses the
same app-object receiver cache for an actual context failure. No user clipboard
or installed app is used.

`MergeDefaultEncodingTests` exercises the source ASCII/short-file classifier,
Unicode BOMs/non-ASCII UTF-8, legacy/binary/malformed bytes, metadata-preserving
adaptation, exact CP1252 save and canonical/legacy preference precedence.
`merge-default-encoding-native-2026-10-12.swift` joins the Merge/LFS-mail batch
for actual checkbox Apply/Cancel, open-versus-reload format behavior, legacy
two/three-pane decoding and exact standalone output with inputs retained.
`--default-encoding-only` shares the app-object cache for an actual failure.

`merge-wrapping-native-2026-10-12.swift` joins the grouped Merge/LFS-mail receiver
for actual TextKit wrapping, shared source-row height geometry, resizing,
scrollbar gates/persistence, unchanged text/selection/history/comparison/files,
combined/three-pane reflow and retirement. `--wrapping-only` shares the built-app
object cache for an actual wrapping failure. Native-only changes do not trigger
a full Core rerun.


The reference-object group includes `network-settings`, using a private
`GIT_CONFIG_GLOBAL` and XDG folder for each engine. Its native fixture covers
actual Git proxy writes/scoped override preservation, private credential-store
failure/retention, Settings validation/Cancel, hidden light/dark layout, captured
SSH Apply after forced close and late read/cache fencing. No user global config,
network or live Keychain is touched. Use `--only network-settings` for an actual
Network failure; the complete group uses the same object/fixture/module cache.


Credential settings use the same object-linked reference receiver cache. Run
`python3 scripts/test-native-reference-batch.py --only credential-settings` after
a Debug build. Each Git executable gets private global/XDG configuration and a
private repository. The receiver checks helper chains, destination-only saves,
Cancel and confirmation decisions, removal, simple None, retired read/save
responses and light/dark hosting. Password-manager routing is injected; no user
Keychain or credential helper is launched. This is not signed or physical UI
acceptance.

The Credential receiver additionally checks the shared Settings transaction's
Apply/Cancel/validation, external-edit stale-snapshot refusal, and exclusive
selection confirmation ownership across retirement/reactivation.


The `tool-settings` case checks Advanced association draft behavior, native
columns/selection/Edit wiring, source-style selection after Remove, and both
parent pages' shared Settings Apply/Cancel/validation with private preferences.
Run `python3 scripts/test-native-reference-batch.py --only tool-settings` after a
Debug build. It uses the existing object cache and one owned process; no actual
tool app is launched. Physical sheets/gestures and signed receiving-app acceptance
remain separate.


The `external-merge-lifecycle` case uses mock termination notifications and
private Git conflicts to check caller-close/task cancellation, exactly-once
observer cleanup, late completion/prompt fencing, No index preservation, exact
working-file staging and stale-stage refusal. It closes owned windows and uses
the same object-linked cache. Run with `--only external-merge-lifecycle`; add
`--git` for each desired engine. No external app is launched or killed.


The `overlay-settings` case hosts all three shared Overlay pages in light/dark
and exercises Settings Apply/Cancel/validation, private atomic policy publication,
notification ordering, rule readback, publication failure and unsigned local-save
notice behavior. Use `--only overlay-settings` after a Debug build. It injects a
private preferences domain/publication URL/notification counter and never changes
the user's App Group or activates Finder. Signed/live refresh acceptance is open.


The Email receiver additionally holds credential work while checking shared
Settings busy validation and app Quit refusal, then verifies Apply and Cancel
after completion. Private preferences and simulated Security APIs are retained;
there is no live Keychain/mail/network or full-suite acceptance claim.


`test-commit-progress.py` now delegates to the object-linked group with
`--only commit-progress`; `--git` arguments are forwarded. CI runs it once in the
group. Its private real commit cases include conditional SVN DCommit ordering and
once-only callback, plus the existing output/cancellation/owned-helper checks.
Fake SVN metadata enables the menu case without submitting to an SVN server.
Physical menu and scoped native SVN receiver acceptance remain separate.


Reference Comparison, Fetch and Create Branch forced-close fixtures atomically
publish complete PID pairs before readiness. Their failure paths close the owner
and recover/reap only private fixture helpers with bounded cleanup. The existing
assertions remain. Focus actual failures with repeatable `--only comparison`,
`--only fetch` and `--only create-branch` plus desired `--git` paths; this does not
require recompiling app sources or running Core.


The `svn-workflow` case links the existing native SVN receiver and private Core
SVN fixture into the app-object cache, setting its selected Git from `--git`. It
checks Fetch/DCommit/Ignore/Rebase, retirement and owned questions/Cancel, plus
captured repository/executable/lease and window reuse. Workspace startup
monitoring/publication is disabled only in this private receiver. CI runs SVN
once in this group; legacy LFS/mail no longer compiles or runs its fixture. No
public SVN server or signed grant is exercised.


The SVN receiver now also checks its actual native progress text view: injected
warning/link output, Aqua/Dark Aqua warning RGB/bold styling and successful footer
color, source copy menu icons/order, private Copy/Copy All preserving selection,
disabled timing footer, error completion and Retry state. It keeps the existing
private workflow/lifecycle/scope assertions. Neither the general pasteboard nor
a public SVN transport is used.


`--only issue-regex-tester` hosts the new native Bugtraq tester using the embedded
Debug C++ helper, private preferences/pasteboard and no Git configuration writes.
It verifies sample highlighting, actual Cut/Copy/Paste and context icons,
single/two-expression matching/UTF-16 positions, invalid fallback and recovery,
expression return and stale/retired provider/Quit fences. Core, physical menu
entry/field focus and signed helper/grants remain separate acceptance scopes.


`swift test --filter IssueTrackerSettingsTests` checks scoped Issue Tracker values
and the shared project-config helper regression. After a Debug build, use
`--only issue-tracker-settings` in the object-linked group, with desired `--git`
paths. It uses private global/XDG config, a repository and context injection;
checks shared Apply/Cancel, inheritance, owned tester draft flow, icon decode and
late confirmation/Quit fences. Tracker plugins and physical/signed access are not
exercised.
