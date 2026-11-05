# Local testing and release gates

The goal remains the full native macOS port of TortoiseGit. Implemented screens,
resource mappings and focused checks do not establish complete application parity.
This page identifies current gates; dated implementation detail is in
[the port tracker](PORTING.md) and the linked family records.

## Current acceptance queue

The [November 5 document-command acceptance continuation](qa/document-command-acceptance-2026-11-05.json)
corrects image Reload readiness after physical sheet detachment, keeps public AX
self-queries on MainActor, and updates the integrated Log consumer to refuse a
moved preferred reference before accepting a freshly refreshed target. Production
command gates and target precedence remain intact. Its focused native results
and initial environment failures are recorded separately from complete hosted
acceptance. Image and Log combinations pass locally, but the AX positive control
still fails local window discovery; its candidate requires independent hosted
confirmation. Installed52 is unchanged.

The [November 5 exact-name operation batch](qa/operation-identity-retry-2026-11-05.json)
repairs scoped Revert/Retry spelling, physical unversioned-file ownership, native
Push chooser receipts and late Stash diagnostics/result-log retention. It passes
39 distinct Core methods cumulatively and twelve native case/engine combinations;
the affected two Revert combinations also pass against the rebuilt final Core.
The filesystem guard refuses shared directory-entry aliases while retaining
distinct hardlinks and mixed-selection recovery. Initial failures and fixture
backend corrections remain recorded. Installed52 is unchanged. These source
checks do not replace a new complete hosted or signed/physical checkpoint.

The [November 5 ordinary metafile quality batch](qa/metafile-quality-2026-11-05.json)
has a successful independent 53-case Windows capture and a reconstructed universal
Mac helper. Connected coverage, brush, fixed-point geometry and thin-line repairs
pass 31 distinct Core methods cumulatively and eight native case/engine checks.
Initial failures and texture-fixture repairs remain recorded; independent Windows
pixels remain unchanged controls. The native checks verify current helper identity.
This source batch is not installed52 and establishes no signed/hosted release
acceptance. Its explicit remaining rendering profiles are in
[ordinary paint quality](METAFILE-QUALITY-PARITY.md).

The subsequent [hosted source `57cd45de` observation](qa/hosted-ci-57cd45de-2026-11-05.json)
is terminal failure: SVN and Pages pass; all eight validation lanes stop. Core
now reaches 3,418 tests with one unexpected Revert/Retry decomposed-name failure;
History separately loses native Push NFD selection. Other stops concern injected
image reload, system accessibility, a preparation gate, progress failure display,
action-log line expectations and a moved-tag merge fixture. These are distinct
diagnostics awaiting source-versus-consumer repairs. The preceding `490d99bf` macOS
run was cancelled after the newer push; it is no longer pending. Neither local
image-quality checks nor the independent Windows oracle replace hosted acceptance.

The [signed build52 checkpoint](qa/signed-consolidation-build52-2026-11-03.json)
is built, installed and locally packaged, including the connected cache/readiness
repair. Build51 is preserved for rollback. Strict signatures, universal components,
resources, source archive and the candidate-specific signed-parent Git probe pass.
The guarded installation uses its own source/static/runtime manifest; ZIP
compression/round-trip checks follow bounded physical acceptance. No binary
publication or App Store submission occurred.

The earlier [build51 check](qa/signed-consolidation-build51-2026-11-03.json) retains a startup failure: the workspace's changed rows
appear while commands still wait for shared Finder cache publication. A worker
sample identifies full snapshot JSON key sorting and queued publication writers
against a roughly 78 MB live cache. The first ready observation was 76 seconds after Open;
this is an observation bound, not a precise load time. Classic Commit subsequently
showed the two expected rows within the first successful five-second observation, and its
visible headers remained stable through selection and message typing. The owned
app quit normally. The [connected source batch](qa/finder-readiness-publication-2026-11-03.json)
addresses cache encoding and foreground readiness together. Its 69 focused Core,
Debug build and eight native case/engine checks pass, including a held real cache
writer and actual retirement drainage. Installed build52 now verifies usable workspace
commands at the first 1.225s observation against the same private 34,304-path fixture
and a 106.6 MB warm cache; publication continues independently and later completes.
Commit shows the two correct rows at the first successful 5.569s observation.
Those observations include tool overhead and do not establish cold filesystem,
every-repository or cold Finder command latency.
Physical Finder command/grant/badge acceptance remains open. A later bounded Add
attempt invokes the nested-folder menu, but capture/Space/reopen behavior prevents
visual access-picker or completed-registration proof. No permission was accepted;
the owned app/window are closed and private saved/watch/registered records absent.

The older hosted `3a6f425c` run is terminal: Core and SVN pass, seven native lanes
fail. Its later Settings Alternative Editor and image Reload failures match the
already retained repairs. The later replay failure is an unmounted Log fixture;
the [label/history projection continuation](qa/log-history-projection-native-2026-11-03.json)
now passes with both engines, preserving the full default assertion sequence.
These bounded passes do not establish a complete corrected-source hosted pass.

The later completed `ff4b6085` run ([41560015333](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41560015333))
collects independent failures across all validation lanes; SVN passes. Core runs
3,409 tests with three skipped and two failed assertions in one supplementary
Commit-read test: its clean-repository fixture still expects an index query that
the candidate-only reader intentionally skips. The repair must retain a second,
changed-candidate case and exact query framing, rather than remove that coverage.
Native failures include a Commit command fixture's `Native None` assertion and
a report-row geometry timeout. These are distinct diagnostics; their common cause
and remaining failures are not yet established. This run predates the connected
readiness and Log-projection continuations above. Current-source hosted success
remains a release gate; local passes cannot replace it.

The current `839406e5` run ([41649018044](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41649018044))
is also terminal failure; Pages and SVN pass, all eight validation lanes fail.
Core now runs 3,413 tests with the same two supplementary-read assertions.
Distribution advances past the repaired Log labels and reaches a later fixture
that reuses a permanently invalidated Log model. Other verified stops concern
Commit menu invocation readiness, a heterogeneous snapshot fixture compile error,
optional LFS warning ownership, regex child ownership, a zero-sized editor
viewport, an AppKit accessibility timeout, bookmark creation, About reopen and
a later Switch tracking choice. These distinct diagnostics do not establish one
shared cause or demonstrate every affected product workflow is broken. Their
source-versus-fixture/platform distinctions remain explicit work; a complete
corrected-source hosted pass is still required.

The subsequent [direct Revert batch](qa/revert-direct-selection-2026-11-03.json)
connects source-style list invocation, confirmation, complete mixed selections,
Retry, captured recovery policy and actual cancellation/retirement drainage.
It also repairs the identified supplementary-read, Commit invocation and retired
Log fixtures without weakening their behavior checks. Its 43 distinct Core
methods, bundled subset, Debug build and eight native case/engine combinations
pass cumulatively after documented targeted repairs. This source continuation
is not installed52 and has no complete hosted or signed physical acceptance yet.

The [November 4–5 read-feedback/file-action batch](qa/commit-file-actions-feedback-2026-11-04.json)
retains accepted optional warnings in Commit's fixed feedback area, retires their
specific ownership through hide/reset/retry, and makes regex list/editor sizing
explicit. One Debug build and nine native cases/engine combinations pass; Core
code is unchanged and its suite was not repeated. Current `f7a0a97f` CI run
[41927023904](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41927023904)
has seven completed lanes stopped at the app build, where the older compiler
rejects a discarded function-valued result; distribution was still running at
the observation. This batch fixes the call with an explicit discard. A new
complete hosted pass is still required; the earlier consumer failures remain
separate from this compile failure.

The [November 5 Compare/Merge checkpoint](qa/compare-document-owners-2026-11-05.json)
passes complete document-history scenarios with both Git engines and six
pane-header Compare/Merge/ownership cases. Replacement hosts now match production
native sizing; zero-viewport caret deferral remains explicitly checked. A focused
AX diagnostic initially returned an immediate root-children failure rather than
a timeout. Public array paging and bounded root-publication diagnosis preserve
the complete system AX oracle; passing local cases do not explain the earlier
hosted stall. The exact failed consumer now retains bounded diagnostics in CI.
No product/Core source or installed build changes belong to this checkpoint.
The latest source's macOS run41931678755 was queued at observation; Pages
run41931678672 passed. A complete corrected-source hosted pass remains required.

The [November 5 Switch/Finder checkpoint](qa/finder-switch-owners-2026-11-05.json)
fixes the real Switch tracking reset on unchanged native name write-back. One
Debug build and fourteen native case-and-engine combinations pass, retaining
complete source-form, picker, checkout/progress, cold/warm launch and cache
Settings/lifecycle/root assertions. Finder fixtures now discover their private
Settings owner, await captured asynchronous Service Open, retain window close
ownership and use consistent temporary-root spelling. Foundation app-scoped
bookmarks run in a private identified ad-hoc app host without weakening scope
options. Initial failures and AppKit/sandbox-extension output remain explicit;
these local checks do not establish hosted or signed physical acceptance.
Installed build52 remains unchanged; no public binary distribution occurred.

The [November 5 Reference filter checkpoint](qa/reference-filter-publication-2026-11-05.json)
connects source-timed input, accepted/native projection caching, live selection,
captured menus and real cancellation/Quit drainage. One Debug build and eight
native case-and-engine combinations pass cumulatively after a range-picker
fixture awaited its actual release; its original-pair/once-only assertion stays.
The completed filter cases were not repeated after that fixture-only repair.
AppKit split-view warnings remain in passing output. No Core suite, installed
app or signed/public distribution changed. At the final observation, preceding
source490d99bf's macOS run41934758431 remains pending and Pages run41934758395
passes; neither establishes hosted acceptance of this subsequent source family.

The [November 3 Finder registration batch](qa/finder-root-grants-2026-11-03.json)
adds directory-only menu admission and an owned containing-root grant recovery
for nested folder selection. Core permission, Debug build and actual menu/context
checks pass. The [registration/retirement runtime checkpoint](qa/finder-root-grants-runtime-2026-11-03.json)
now passes with both Git engines. Signed deployment and physical Finder
acceptance remain pending.

The [November 3 Commit index-read batch](COMMIT-STARTUP-READS.md) removes
full clean-index output from Commit refresh and fallback flags, skips auxiliary
index reads for wholly untracked lists, and reuses the identical unborn-branch
diff. Focused Core checks pass, including exact filenames, conflicts, gitlinks,
embedded repositories and unchanged index bytes. This is a source improvement;
representative large-repository timing and installed signed acceptance remain
open. Installed build52 contains this continuation. The subsequent
[native scale checkpoint](qa/commit-native-scale-2026-11-03.json) measures the
34,303-path private checkout: first load10.56s, other initial loads2.23–2.39s,
refresh1.65–1.77s. The slow first settings/change-read phase is not isolated;
first-load and full cold/signed acceptance remain open.

The [November 3 Settings/Compare ownership batch](qa/settings-compare-owners-2026-11-03.json)
protects General-page controls from stale edits and retains regex-editor sessions
through native sheet detachment. Related image, Switch and standalone-reference
receivers preserve production focus/ownership rules. The subsequent
[native recovery checkpoint](qa/native-pending-recovery-2026-11-03.json) passes
the scoped families below, fixes Alternative Editor presentation ownership and
strengthens pane-header custom-action checks. Complete corrected-source hosted
and signed/physical acceptance remain pending.

The preceding `aaca482a` hosted run passed Core, SVN and Pages. It also passed the
Unified Diff command families, native release-download/App Store workflows,
grouped LFS/Send Mail and RefLog workflows that had stopped earlier. Retain those
bounded passes. Six lanes stopped later; distribution was still in progress at
the recorded observation. This does not establish complete hosted success.

| Family | Current bounded evidence and remaining scope |
| --- | --- |
| General / Alternative Editor Settings | General source and navigation pass with system Git, including real native edit, cached Apply/Cancel and Alternative presentation receipts; wider SDK/signed/physical acceptance remains |
| Regex filter editors | Source/comparison/INI native families pass, including sheet/session drainage; full hosted and signed acceptance remains |
| Image commands | Conflict/routing and complete standalone selection pass with both engines, preserving bytes/pixels/leases and stale-event refusal; other unexecuted metafile/conflict variants remain scoped separately |
| Switch/reference ownership | Picker and standalone-reference checks pass with both engines, including real F5 and exactly-once closure; physical/signed acceptance remains |
| Compare/Merge pane headers | Compare/Merge/ownership pass with both engines and strengthened nonempty menu-derived AX action checks; earlier hosted timeout cause is unproven, current hosted acceptance remains |
| History feedback languages / remote catalog | German/French history and remote metadata/lifetime checks [pass with both engines](qa/history-remote-acceptance-2026-11-03.json); broader translation, signed/physical and complete hosted acceptance remain |
| Later unexecuted cases | Retain engine/case boundaries from failed grouped commands; a prior case pass does not establish unexecuted later cases |

The [November 2 repairs](qa/native-workflow-continuation-2026-11-02.json) and
[earlier recovery](qa/hosted-native-continuation-2026-11-01.json) retain original
failures and source evidence. A matching later pass supersedes only its scoped
pending entry. The first November 3 source checkpoint deferred native receivers
after the earlier exact external Quit interruption. The subsequent Finder and
pending-family runtime checkpoints completed without external interruption. This
does not establish that the external application's closing preference changed.
Independent hosted validation can continue. Installed build52 now includes these
source continuations; the bounded physical observation above retains the newly
identified shared-cache readiness failure and its bounded installed correction.

## Finish line for the first locally accepted release

This is the current release checklist. Historical checkpoints below are evidence,
not additional implementation milestones. A new batch must address a concrete
missing source behavior, reported defect or failing check.

- [x] Finish and validate the [Clone/Init/Submodule Add/Switch/Reset batch](qa/repository-setup-transitions-2026-10-29.json).
- [x] Verify the reported installed Commit selection/typing/staging, Log inspection,
  Remote list and Settings OK/Cancel paths in a private repository. The
  [build41 checkpoint](qa/signed-consolidation-build41-2026-10-30.json) records
  the actual gestures, exact bytes and cleanup, including bounded startup
  observations rather than a general latency claim.
- [ ] Complete current first-use Finder grants/registration/badges/cold commands
  and representative large-repository latency acceptance. The owner
  [accepted build38 Finder registration, badges and cold Commit](qa/owner-acceptance-build38-2026-10-30.json);
  that feedback remains scoped to its tested version/repository. Build41 carries
  the later permission-picker targeting and cache improvements; its private
  workspace check does not establish every Finder/grant combination.
- [ ] Obtain a complete hosted macOS CI pass on the release source and repair
  concrete failures without repeatedly running unrelated local suites.
- [x] Implement and locally validate the [text-editor Open transaction](qa/text-open-transaction-2026-10-31.json): Save question, Open, nested Browse and replacement retain ownership through actual sheet/worker drainage. Installed build48 contains this family; physical and signed UI acceptance remain separate.
- [ ] Close the explicit source/layout gaps in the family records and establish
  the remaining dialog states, keyboard and accessibility acceptance. Resource
  counts alone do not complete this requirement.
- [x] Verify the build49 documentation/source package and public screenshot delivery.
  The [signed package record](qa/signed-consolidation-build49-2026-11-01.json)
  binds its Help, notices and complete source archive; the
  [published guide check](qa/hosted-published-manual-2026-11-01.json) confirms the
  updated guide and four current Commit screenshots are reachable and exact.
  The source review found author/support/Impressum placement consistent.
- [ ] Complete owner acceptance of bundled Help and screenshots against the
  remaining native dialog states and accessibility behavior.
- [x] Deliver and install the [signed local testing build52](qa/signed-consolidation-build52-2026-11-03.json).
  Build51 is preserved for rollback. Build52 adds the connected cache/readiness
  repair and retains the prior consumer, translation and guide fixes. Universal
  signing, compiled resources, source/install inventories, its own signed Git
  probe and post-acceptance ZIP round trip pass. The bounded large-cache workspace
  and Commit checks are recorded above. The app is left closed; physical Finder,
  complete hosted CI, broader platform/parity and later publication remain separate.

The [installed build39 attempt](qa/installed39-startup-commit-2026-10-30.json)
found the large-cache startup delay and native Commit column-set transition.
The [ordering and column-ownership checkpoint](qa/commit-columns-cache-scale-2026-10-30.json)
records the repair and retained failures. Installed build41 now verifies stable
initial/selected/edited columns and staging lists in the private workflow. Its
first ready workspace observation was about 9.3 seconds including automation
overhead; representative large-repository timing remains an explicit gate.

The [hosted compatibility repair batch](qa/ci-host-compatibility-2026-10-30.json)
records the SSH bookmark host identity, Settings color-control lifecycle and
pinned Unicode source-loader failures together. Its focused local checks do not
replace the required complete hosted macOS pass. These verification-source repairs are included in the build41 source checkpoint;
the required current hosted macOS pass remains open.

The [current first-use Finder observation](qa/installed37-finder-first-use-2026-10-29.json)
verified the intended unregistered-folder menu and reduced Services entry. The
computer-control connection rejected invocation. Later build38 owner acceptance
covers cold Commit, registration and badges on the tested repository; broader
Finder command and grant acceptance remains scoped separately. The [pending-control source review](qa/pending-control-source-review-2026-10-29.json)
found no additional missing workflow family among the85 pending occurrences;
Windows-only or dormant controls must not be counted as missing Mac dialogs.
This is static evidence, not full dialog or release certification.

The hosted run later failed on Commit checkbox admission, completed-Revert popup
availability and an older standalone Open fixture. The [grouped native correction](qa/native-file-interactions-2026-10-29.json)
passes eighteen relevant native cases/engine pairs, including First Start SSH
authority and a PowerPoint fixture compiler repair. Build37 predates the production
corrections. The terminal hosted run passed Core and SVN but failed seven native
lanes; all seven now have local repairs and focused passes in the continuation
below. A complete corrected-source pass is still required.

## Current hosted recovery batch — November 1, 2026

The [connected repair record](qa/hosted-native-recovery-2026-11-01.json) covers
four production defects: same-content Unified Diff Undo admission, selected
historical-folder transfer names, unavailable child-commit Log pins and account
home root aliases. Three additional hosted failures concern native receiver
capture/readiness. The grouped checkpoint passes the focused Core methods, app
build, historical transfer, Unified Diff, image question and targeted metafile
workflows. Log/Changed Files also pass with both Git engines after the retirement
wait was corrected to observe actual workers. Finder provider passes; effects
were interrupted by an explicit Quit AppleEvent from Vorssaint, and ownership
was not reached. Only those pending Finder cases remain for this checkpoint;
passed families will not be repeated. This does not establish complete hosted CI
or update installed build48.

## Source workflow continuation after build41

The [file activation and Sync options batch](qa/file-activation-sync-options-2026-10-30.json)
adds clicked-row conflict/comparison behavior across four status-list dialogs,
Browser activation and stable footer geometry, and borrowed private SSH identity
ownership through full options and active/retired remote pickers. Its sixteen
native case/engine pairs pass; no Core suite was repeated for app-only changes.
Installed build42 includes this source continuation; its physical acceptance
remains separate from the earlier build41 gestures.

Hosted run877 first reported two failures: the long HEAD radio-control check awaited
model readiness before the native update (repaired locally with unchanged exact
assertions), and WMF `textout-odd` differed from its Unicode EMF raster. The
[later background checkpoint](qa/metafile-wmf-text-background-2026-10-30.json)
proves identical text and a 159-pixel transparent/white edge difference, preserves
production alpha and original wires, and passes the matched-background checks
locally. Hosted confirmation remains open. Neither local batch establishes a
full hosted or installed pass.

## Log refresh and comparison ownership continuation

The [connected Log batch](qa/log-refresh-ownership-2026-10-31.json) fixes dropped
refresh intents, overlapping comparison/history busy settlement and close-through-
comparison cancellation. Same-selection detail completion no longer discards a
captured whole-revision comparison. The old shared CI wait also tried to reuse a
retired model; the fixture preserves retirement and uses a fresh successor.

The Debug build and grouped Log comparison/routing/deferred-refresh checks pass
with system and bundled Git after a fixture-only visibility correction. Default
full assertions remain, with cached compilation and private receiver state.
Build43 predates this source change; full hosted, signed/physical and remaining
source/layout acceptance remain separate.

## Hosted fixture and current manual continuation

The [October 31 grouped repair](qa/ci-native-ownership-background-2026-10-31.json)
passes the affected Branch/Tag handoff and positioned-text native cases with
both Git engines, Merge encoding and one focused full-canvas Core method. The
repairs preserve actual dialog ownership and original wire semantics; they do
not establish a complete hosted macOS pass. Four current [Commit screenshots](qa/manual-commit-captures-2026-10-31.json)
now illustrate the website/manual and bundled Help. Installed build43 is unchanged.

## Utility and local-tool startup continuation

The [utility readiness checkpoint](qa/utility-startup-2026-10-31.json) covers
repository-independent About/Help/global Settings and local Merge admission,
with an isolated selected-Git version probe. Context Settings and real repository
commands retain their permission barrier and FIFO order. Two focused Core tests
and four native case/engine pairs pass after the retained initial failure and
repair. Installed build43 now includes this source continuation; physical and full
hosted acceptance remain separate.

A planned screenshot refresh failed to obtain native computer-control state;
the owned preview was terminated and independently absent. No replacement images
or physical acceptance are claimed. The existing screenshots remain published.
The old hosted Core failure identified at this checkpoint matches the previously
repaired WMF background fixture; full corrected-source CI remains required.

## Current startup/document readiness continuation

The [connected source batch](qa/startup-document-delivery-2026-10-31.json)
opens standalone/local patch documents without unrelated Git configuration or
saved-repository initialization. Git-first FIFO and repository Services retain
actual readiness, authority and cancellation. The shared classifier rejects
encoded NUL paths while keeping literal percent filenames valid.

The older hosted first-use workflow and Statistics export failures exposed
stale synchronous-startup and metafile-canvas expectations. Their fixtures now
retain real readiness, source viewport/vector records and exact saved bytes.
Eleven distinct native case/engine pairs pass cumulatively after the documented
NUL and explicit-CLI held-process repairs. The manual and bundled Help describe
the actual single Open Service. Installed build43 includes this continuation;
physical/signed acceptance and a complete corrected-source hosted pass remain open.

## Installed local testing build39

[Signed build39](qa/signed-consolidation-build39-2026-10-30.json), `0.1.0 (39)`,
is installed from source `fa5f05fe`. The first-use permission picker targets the
clicked folder, and Classic Commit message edits leave the native report header
stable. Real file, selection, checkbox, column, font and appearance changes remain
live. The folder-access guide and bundled Help describe the permission flow.

One signed universal build succeeded with zero contradictory compiler diagnostics.
Strict seals, frozen source inputs, eight owned arm64/x86_64 components, the
scoped public Core/packaged Git sandbox probe, bundled Help, ZIP round trip and
all 6,381 installed inventory members pass. The app remains closed; build38 is
preserved for rollback. No user app was terminated and Finder/Dock were not
restarted. The pre-install registration helper retains its exact PID assertion
failure: the managed extension PID changed while metadata restoration succeeded
and Finder remained running. This does not replace physical integration checks.

The full hosted run on this source has reported failures while other lanes are
still running. Current signed picker
and typing acceptance, the broader source/layout gates and later public/store
distribution remain separate. This local development signature is not an App
Store submission, notarization or complete-port certification.

## Finder permission and Classic Commit presentation continuation

The subsequent hosted run
[41085850782](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41085850782)
found an obsolete Help index-generation timeout and a Quit fixture admission
race. The [Help and Quit repair checkpoint](qa/help-quit-ci-repairs-2026-10-30.json)
records the modern CoreSpotlight index, actual private index inspections, native
Help routing and both-Git Quit checks. Those changes are committed after build39
and are not installed yet. The subsequent
[native fixture continuation](qa/native-ci-readiness-continuation-2026-10-30.json)
records focused local passes for Merge Patch settings, real SSH bookmark
creation/resolution and Finder delivery refusal ownership. The SSH fixture's
canonical-path repair still needs hosted macOS 15.7 verification; the original
Foundation refusal is not proven resolved there. No current complete hosted pass
or additional installed build is implied.

The [October 30 focused batch](qa/commit-finder-presentation-2026-10-30.json)
targets the clicked repository directly in the first-use permission picker and
isolates the Classic Commit file table from message-only updates. Actual native
column-visibility observations now detect transient changes during typing; both
Git engines pass the report/column/typing family while real selection, checkbox,
status, font, appearance and saved column changes remain active. The picker,
Help, Services, Settings ownership, image blink, Merge Patch and affected Log
checks have scoped passes. Installed build39 includes these changes; physical
acceptance remains separate.

Hosted run [41001587894](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41001587894)
passed Core, SVN, the unsigned universal candidate audit, graph framework and
bundled SSH checks, but failed seven native groups. The batch records their
specific fixture lifecycle/publication repairs and focused results. A complete
corrected-source hosted pass remains required; the local Debug driver also
reported contradictory exit-zero diagnostics, preserved in the record rather
than described as a clean build.

## Installed local testing build38

[Signed build38](qa/signed-consolidation-build38-2026-10-30.json), `0.1.0 (38)`,
is installed from source `da767b69`. It consolidates Commit/progress admission,
First Start SSH authority and working-file Log Blame validation with the preceding
Finder/setup corrections. One clean signed universal build, strict seals, frozen
inputs, public Core/packaged Git sandbox probe, bundled Help and ZIP round trip
pass. All 6,381 installed inventory members match; build37 rollback copies remain.
The app was left closed, without Finder/Dock restarts or login/service changes.

The pre-install registration helper reported an all-PID preservation difference:
macOS replaced the managed extension process during re-registration. The record
retains that failure and its review; metadata restoration succeeded, Finder stayed
running, and no app was signalled or deliberately launched. This is not physical
Finder badge/cold-command acceptance by automation. The owner later replied
“yeah works good” to the specific registration/badges and cold Finder Commit
question; [the recorded report](qa/owner-acceptance-build38-2026-10-30.json)
retains that scope without inferring numeric latency or every Finder action.

The published homepage and Getting Started guide display their current screenshots;
source/offline Help image references and unobtrusive credits/imprint links agree.
This is bounded desktop/source evidence. The corrected-source hosted CI run is
active, and owner Finder feedback remains pending. No public binary upload,
notarization or Store submission occurred.

## Working-file Blame and native startup/recovery continuation

The [grouped continuation](qa/startup-bisect-blame-2026-10-30.json) fixes a real
working-row Log Blame regression: a deleted leaf could still dispatch HEAD Blame.
Log and the document opener now share the existing no-follow regular-file/symlink
validation. The owned off-main preflight retains cancellation, selection and
retirement guards; dangling links and explicit historical revisions remain valid.

The last two hosted failures also exposed obsolete fixture timing assumptions.
Startup now exercises its actual asynchronous configuration gate before checking
FIFO/one-shot URL delivery. Bisect separates reset-only failure results from
modal command admission and waits for its actual owner release before requiring
exactly one Close callback. The original full recovery function and its assertions
remain in both the hosted receiver and the focused cached runner.

Eight native case/engine pairs pass: startup and Blame with system/bundled Git,
and full Bisect recovery with system, 2.37.1, 2.39.5 and packaged Git. Initial
failures and affected-only repairs are recorded; no Core or unrelated native
family was rerun. Together with the preceding checkpoint, all seven known CI
failures have local corrections and focused passes. A complete hosted pass on
corrected source and physical Finder acceptance remain open. Signed build38 above
now includes these corrections; the earlier build37 predates them.

## Installed local testing build37

[Signed build37](qa/signed-consolidation-build37-2026-10-29.json), `0.1.0 (37)`,
is installed from source `a25f65ab`. It includes the Finder retirement continuation
and the repaired asynchronous Merge startup check. The single universal build,
strict signatures, frozen inputs, sealed public Core/packaged Git probe, bundled
Help and ZIP/inventory round trip pass. The full installed inventory matches;
build36 rollback copies remain available. Installation left the app closed and
restarted no Finder/Dock process or login/service preference.

The hosted run finished with Core and SVN passing and seven native lanes failing.
All seven failed jobs have local corrections and focused passes recorded above.
A complete hosted pass on corrected source and physical Finder cold command,
badge and real large-repository latency acceptance remain open. No public upload,
notarization or Store submission occurred.

## Installed local testing build36

[Signed build36](qa/signed-consolidation-build36-2026-10-29.json), `0.1.0 (36)`,
is installed from frozen source `939ea9fe`. It includes accepted repository setup
and transition outcomes, retained Finder claim reuse and Settings watch ownership.
The universal build, strict signatures, sealed public Core/packaged Git probe,
Help and ZIP inventory pass. A probe-only Unicode fixture repair was required;
the sealed application did not change. Build35 rollback copies remain available.

The private physical check loaded all five changes and reached Finder cache Ready.
Settings Git OK and Remote Cancel both closed and reopened correctly. Shutdown
sampling found a costly warm-cache retirement rewrite. The [source continuation](qa/finder-retirement-and-startup-2026-10-29.json)
passes focused Core and native checks, but is not yet in build36; installed
large-cache lifecycle performance and Finder cold menus/badges remain acceptance gates.
Test apps quit normally; the private saved repository permission was removed.
No Finder/Dock restart, public upload, notarization or Store submission occurred.
The later CI split into eight dependency-complete lanes is source `54168b21`;
a complete hosted result remains required.

## Installed local testing build35

[Signed build35](qa/signed-consolidation-build35-2026-10-29.json), `0.1.0 (35)`,
is packaged from clean source `e0f1c559`. It adds source marked-screen-row status
and caching, accepted Settings publication recovery, and branch/tag/worktree
creation acceptance across late cancellation. The universal AppStore-configuration
build, frozen inputs, strict seals, packaged Help and ZIP roundtrip inventory pass.
Its disposable signed sandbox parent executes the sealed production Core and
packaged Git, including the three new public contracts; it does not exercise the
shipping AppKit UI or outside file grants.

Following user approval, build35 replaced build34 after a normal quit and was
reopened. The installed bundle matches all 6,381 verified inventory members;
rollback copies of build34 are preserved. The workspace was observed after reopen.
Finder was not restarted, and login/service preferences were not changed.
No public upload, notarization or Store submission occurred. All global acceptance
and Store terms gates below remain open.

## Installed local testing build34

[Signed build34](qa/signed-consolidation-build34-2026-10-29.json), version
`0.1.0 (34)`, is installed from clean source `b7085d24`. It consolidates Unified
Diff zoom/cursor work, Merge AutoAdd completion, standalone image tools,
report-header icons, historical folder archives and safe raw-file transfers.
All eight app-owned components contain arm64/x86_64 code. Frozen inputs, strict
signatures, packaged Help and ZIP extraction/inventory checks pass.

The focused signed parent exercises the sealed production Core framework and
packaged Git for image selection and raw historical archive/file delivery in a
private sandbox container. A deterministic held Git request is independently
identified by its PID and kernel executable path, then reaped. This does not
exercise the shipping AppKit UI, outside repository grants or physical drag/drop.

[The idle installation receipt](qa/signed34-installed-2026-10-29.json) records a
verified atomic swap, complete installed inventory equality and preserved build33
rollback copies. The app was closed before replacement; the idle installation itself launched,
quit or signalled no app process. After the later Compare/Merge checkpoint,
the installed build34 was reopened with the owner's explicit authorization
(main process 88077 observed). Finder/Dock and login/service preferences were
not restarted or changed. Registration refresh caused macOS to
reload the extension host while the Finder process stayed running.

The local package is `TurtleGit-for-Mac-0.1.0-build34-signed.zip` (SHA-256
`0dfa6bffd0c2fedf74a6b1b71cdd0419bc96c1f1e0099b2b8a58c2928f667fa4`).
It is a local Apple Development testing artifact. No public binary release,
notarization or App Store submission was performed. Complete hosted, source,
physical, signed external-grant, Intel/minimum-macOS and Store gates remain open.

## Previous installed build33

[Signed build33](qa/signed-consolidation-build33-2026-10-29.json), version
`0.1.0 (33)`, was built from clean source `4daef1a3`. It includes the three Unified
Diff navigation/editing batches and leading-scalar codec repairs. The unchanged
source-input audit, strict signatures, eight app-owned arm64/x86_64 components,
packaged Help and signature-preserving ZIP extraction/inventory checks pass.
A focused signed-parent check executes the actual production Core framework's
new navigation, selection/byte and BOM/NFD paths under the sandbox; it does not
exercise the shipping AppKit editor or NSUndoManager.

The local package is `TurtleGit-for-Mac-0.1.0-build33-signed.zip` (SHA-256
`e3a7ee07c20243747de3f07e9d8b851aaa0deb5bdef9bcd5721e6e15927818ff`).
It is a local Apple Development testing artifact, not a public release download.
[Build33 was installed and reopened with user approval](qa/signed33-installed-2026-10-29.json).
The complete installed inventory matches the candidate and its strict signature
passes. The original app exited after a delayed normal quit; no signal was sent.
Build32 is preserved for rollback. Finder/Dock were not restarted and no
repository-permission change, App Store upload or notarization was performed.
The workspace was visually confirmed; physical installed workflows,
Intel/minimum-macOS execution, complete hosted CI and full-port acceptance remain
separate.

## Earlier installed checkpoint

[Signed build32](qa/signed-consolidation-build32-2026-10-29.json), version
`0.1.0 (32)`, was installed from clean source `144fdf78`. It adds retained-byte
Blame encoding, Finder returned-volume recovery and metafile canvas/source-alpha
corrections. All eight app-owned components contain arm64 and x86_64; measured
inputs, strict signatures and the complete installed inventory pass. The focused
signed-parent Metafile check passed, including captured Windows alpha samples.
With user approval, TurtleGit quit normally, was replaced and reopened to its
workspace. Build31 is preserved for rollback. This does not establish physical
Intel execution, every installed workflow, physical Finder badges or a complete
hosted CI pass. No App Store submission or notarization was made.

[Build27, version 0.1.0 (27)](qa/signed-consolidation-build27-2026-10-28.json)
was installed from `3d0cf270` and is now preserved for rollback. Measured
inputs, strict signatures, eight owned arm64 components, bundled Help and complete
installed inventory pass. Build26 and universal build22 are preserved. Finder and
Dock were not restarted; only TurtleGit's extension registration was refreshed.

The installed Commit check exercised actual Amend checkboxes in both Git Gui and
Classic, restored the empty draft and original presentation, and made no commit.
Manual menu activation remains unverified after automation targeting errors.
The installed Finder Log check exercised loaded-row selection, full message and
changed files while history continued. Its 1.081-second selection-to-data phase
is one sample excluding click/AX/full-history latency. Focused checks separately
cover graph cancellation, coalescing, stale results, close and Quit ownership.
Both owned app processes exited, and repository HEAD/index were unchanged.

## Hosted Sync tag and LFS repair

The [bounded hosted snapshot](qa/hosted-history-lfs-2026-10-31.json) found
two terminal older-source failures while other jobs remained active. The
[repair checkpoint](qa/hosted-history-lfs-repair-2026-10-31.json) fixes actual Sync
tag actor ownership through local/remote mutation and refill, and corrects the
LFS receiver to use Commit’s existing owned column transaction. Focused Core and
both affected native engines pass. These are local repairs; complete matching-source
hosted CI remains required. Installed build48 includes the repair.

## Remaining gates

| Gate | Evidence and remaining work |
| --- | --- |
| Source behavior and layout | [Family records](PORTING.md#current-component-and-workflow-state--october-25-2026) describe connected implementations. The [resource ledger](DIALOG-COVERAGE.md) keeps partial controls and unmapped platform/example resources explicit. Complete dialog states, command eligibility, layout, keyboard and accessibility acceptance must be established from their actual consumers, rather than counting screens. |
| Connected workflow defects | Commit cross-presentation workflows have a [grouped checkpoint](qa/commit-presentation-workflows-2026-10-29.json). Explicit working-file Compare/conflict intent, captured requesting-repository routing, and Browser read-to-panel/launch ownership now pass their [connected native checkpoint](qa/file-comparison-browser-ownership-2026-10-29.json) with both Git engines and affected regressions. Explicit unchanged-file, copy/rename, Amend first-parent and added/deleted gitlink comparisons pass their [content checkpoint](qa/working-file-content-selection-2026-10-29.json), including read-only index preservation. The later [Log file inspection checkpoint](qa/log-streamed-file-navigation-2026-10-29.json) covers historical navigation and delivery during streamed history; its shared list-control regression is recorded separately. Current Commit screenshots cover both layouts and appearances; signed workflow acceptance remains separate. |
| Current hosted integration | Current `f7a0a97f` [run41927023904](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41927023904) has seven completed validation lanes failed at the app build; SVN passes, distribution was still active at observation. This batch explicitly discards the workspace Revert cancellation function to repair that older-compiler error. Earlier `839406e5` consumer diagnostics retain their separate scopes. Installed [build52](qa/signed-consolidation-build52-2026-11-03.json) binds source `3702643e`; complete corrected-source hosted success remains open. |
| Installed workflow acceptance | [Build52](qa/signed-consolidation-build52-2026-11-03.json) is installed and left closed after strict package/runtime checks and a bounded physical workspace/Commit startup observation on a private 34,304-path repository. Earlier [build41 acceptance](qa/signed-consolidation-build41-2026-10-30.json) retains Commit headers/staging, Log, Remote and Settings observations. Current-version wider recovery, Finder/grants and representative cold repositories remain separate. |
| Finder and permissions | [Build18 cold registration](qa/signed-consolidation-build18-2026-10-27.json) records badges and menus without an unwanted workspace. Current-version first-use grants, persisted watched folders, background refresh, multiple repositories, external file grants and the complete command set still need scoped physical acceptance. Finder Sync's native badge placement is the macOS integration. |
| Startup and large repositories | The [connected readiness batch](qa/finder-readiness-publication-2026-11-03.json) separates usable workspace facts from optional Finder publication. Installed52 first shows usable commands at1.225s while publication continues, and correct Commit rows at the first successful5.569s observation. These include automation overhead and warm filesystem/cache state; cold Finder delivery and every-repository latency remain unproven. |
| Image menu ownership | The [native image menu family](qa/image-main-menu-2026-10-31.json) connects comparison, standalone selection and repository conflict File/View commands, toolbar state and key ownership. Its record distinguishes hidden native checks from physical menu/keyboard/VoiceOver acceptance. Installed build48 contains this family. |
| Editor Open ownership | The [text Open transaction checkpoint](qa/text-open-transaction-2026-10-31.json) records cumulative native source/Open/replacement/Scene passes and final patch permission transfer/retirement. Installed build48 contains this family. Complete physical/signed and full-source behavior acceptance remains separate. |
| Blame navigation | The [caret/navigation checkpoint](qa/blame-caret-navigation-2026-10-31.json) covers actual caret starts, rapid repeated searches, manual interruption, Find rebinding/retirement and physical sheet-drain ownership with bounded Core/native evidence. The unsafe upstream terminal reverse loop is an explicit adaptation. Installed52 includes this family; complete physical, translated and signed workflow acceptance remains separate. |
| Text, image and document compatibility | [Comparison](IMAGE-COMPARISON.md), [metafile compatibility](IMAGE-METAFILE-PARITY.md), [formatted text](METAFILE-TEXT-PARITY.md) and the document-tool records retain unsupported formats, encodings, font/locale differences and external application boundaries. Explicit refusals must remain visible; a passed corpus is not universal format support. |
| Historical filename boundaries | [Historical materialization/comparison](RAW-HISTORY-PARITY.md#materializationcomparison-checkpoint), [folder archives](BROWSER-ARCHIVE-PARITY.md) and [safe individual-file transfers](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md) are implemented and separately checked. Raw original-path checkout, working-tree mutation/comparison, literal folder promises/exports with raw descendants and submodule checkout resolution retain the explicit [namespace boundaries](REPOSITORY-BROWSER-NAMESPACE-PARITY.md). A native-host filename probe does not establish every filesystem's capabilities. |
| Provider and external transport acceptance | Native issue adapters, credentials, SSH, hooks, Git/LFS/SVN and Office adapters have their own bounded records. Authenticated public services, vendor-specific providers, receiving applications and real external permissions remain separate from private loopback/stub tests. |
| Intel and minimum macOS | Universal binary and deployment-target checks establish structure. Execution on Intel and the minimum supported macOS, including UI, helper and Finder workflows, remains unverified by those checks. |
| Localization and accessibility | The [history language checkpoint](qa/history-languages-2026-10-31.json) adds actual German/French native menu/header/filter consumers with literal metadata. The generated catalog retains English fallback where source translations cannot be used safely. Label counts do not establish every dialog's translation, VoiceOver reading order, IME behavior or keyboard usability. |
| Distribution and store terms | The existing [GPL/App Store terms gate](DISTRIBUTION.md#gpl-and-app-store-terms--unresolved-release-gate) remains unresolved. Distribution rights, license/source delivery, release signing, archive/export and the proposed store arrangement require their recorded evidence. A development signature is not distribution clearance. |
| Publication | README, manual, offline Help and the screenshot site exist. Release downloads, store listing and any store submission must describe the actual accepted build. The owner will test locally before publication; no App Store upload or notarization has been performed by this checkpoint. |

## How checkpoints are interpreted

A family record separates its implementation, actual validation, failed attempts
and remaining limits. Native tests use private repositories/preferences and owned
process cleanup. A local focused pass does not silently certify signed Finder,
physical UI, a different SDK, complete hosted integration or unrelated dialogs.

The [October 28 image checkpoint](qa/metafile-spatial-effects-2026-10-28.json)
records 140 distinct focused Core methods cumulatively passing and both native
Git-engine workflows, with retained source-reference and fixture failures. The
[Log checkpoint](qa/log-lfs-family-2026-10-28.json) records its actual native
selection, progress, cancellation, refresh and cache-replacement scope. Neither
record marks the whole port complete.

The previous chronological blocker table is retained in
[the source history at 04a5d7f3](https://github.com/jfk-solutions/turtle-git-mac/blob/04a5d7f336178ec4f32627b10d1f73507a7728cf/docs/RELEASE-BLOCKERS.md).
Its old pending statements and run statuses must be read with later family
continuations; they are not the current feature backlog.
