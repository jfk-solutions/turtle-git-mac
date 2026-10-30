# Local testing and release gates

The goal remains the full native macOS port of TortoiseGit. Implemented screens,
resource mappings and focused checks do not establish complete application parity.
This page identifies current gates; dated implementation detail is in
[the port tracker](PORTING.md) and the linked family records.

## Finish line for the first locally accepted release

This is the current release checklist. Historical checkpoints below are evidence,
not additional implementation milestones. A new batch must address a concrete
missing source behavior, reported defect or failing check.

- [x] Finish and validate the [Clone/Init/Submodule Add/Switch/Reset batch](qa/repository-setup-transitions-2026-10-29.json).
- [ ] Accept the installed everyday workflows: Finder cold Commit launch and
  registration/badges; responsive Commit loading and stable staging lists;
  selecting a Log commit and inspecting its files; Settings OK/Cancel and remotes.
  The [partial build35 check](qa/installed35-workflows-2026-10-29.json) verified
  staging transfers, Log inspection and Remote selection. It found live cache
  contention. Build36 verified Settings OK/Cancel and Remote selection; Finder
  cold launch remains open, and retirement still performed a costly warm-cache
  rewrite. The private fixture permission was removed and test apps quit normally.
- [ ] Obtain a complete hosted macOS CI pass on the release source and repair
  concrete failures without repeatedly running unrelated local suites.
- [ ] Close the explicit source/layout gaps in the family records and establish
  the remaining dialog states, keyboard and accessibility acceptance. Resource
  counts alone do not complete this requirement.
- [ ] Check the accepted build's README, license/source notices, manual, offline
  Help and screenshot website together; keep publisher credit unobtrusive.
- [ ] Deliver the signed local testing package for owner acceptance. Public
  distribution and the later App Store submission remain separate, including
  distribution signing and the unresolved GPL/App Store terms gate.

The [current first-use Finder observation](qa/installed37-finder-first-use-2026-10-29.json)
verified the intended unregistered-folder menu and reduced Services entry. The
computer-control connection rejected invocation; cold Commit, registration and
badges remain open. The [pending-control source review](qa/pending-control-source-review-2026-10-29.json)
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
corrected source, signed build38 and physical Finder acceptance remain open.
Installed build37 predates these production corrections.

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

## Remaining gates

| Gate | Evidence and remaining work |
| --- | --- |
| Source behavior and layout | [Family records](PORTING.md#current-component-and-workflow-state--october-25-2026) describe connected implementations. The [resource ledger](DIALOG-COVERAGE.md) keeps partial controls and unmapped platform/example resources explicit. Complete dialog states, command eligibility, layout, keyboard and accessibility acceptance must be established from their actual consumers, rather than counting screens. |
| Connected workflow defects | Commit cross-presentation workflows have a [grouped checkpoint](qa/commit-presentation-workflows-2026-10-29.json). Explicit working-file Compare/conflict intent, captured requesting-repository routing, and Browser read-to-panel/launch ownership now pass their [connected native checkpoint](qa/file-comparison-browser-ownership-2026-10-29.json) with both Git engines and affected regressions. Explicit unchanged-file, copy/rename, Amend first-parent and added/deleted gitlink comparisons pass their [content checkpoint](qa/working-file-content-selection-2026-10-29.json), including read-only index preservation. The later [Log file inspection checkpoint](qa/log-streamed-file-navigation-2026-10-29.json) covers historical navigation and delivery during streamed history; its shared list-control regression is recorded separately. Current Commit screenshots cover both layouts and appearances; signed workflow acceptance remains separate. |
| Current hosted integration | The [dated Commit failure record](qa/commit-option-observers-2026-10-28.json) records a hosted Core stage with 3,153 methods, two skips and no failures, followed by a native Commit observer failure. Its local repair passes both Git engines; that is not a full hosted pass. The later [hosted run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40709146937) failed the Amend option observer assertion; the following [Commit option workflow repair](qa/commit-option-workflow-2026-10-28.json) aligns eleven native option routes and passes the focused menu/shared-handler family with both Git engines. The invisible receiver cannot dispatch actual checkbox actions; build27 separately verifies basic physical Amend checkbox behavior in both views, with broader option/lifecycle acceptance still open. The later [hosted run 40734366346](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40734366346) failed an outdated exact initial loading-caption assertion. The [October 29 caption checkpoint](qa/commit-loading-caption-2026-10-29.json) preserves busy/phase ownership and passes the affected Commit family with both Git engines. The older-source [run 40781174821](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40781174821) completed 3,201 Core methods with two skips and zero failures, then failed the same outdated initial-loading caption assertion; the recorded later caption repair remains local evidence. The later [run 40801565372](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40801565372) on `adbf6be7` passed 3,222 Core methods with two skips, then failed the first conflict-pane header activation assertion. The [header continuation](MERGE-PANE-HEADER-PARITY.md#activation-result-and-mounted-pane-ownership--october-29-2026) distinguishes actual native-render readiness from the production focus/admission repair. The subsequent [run 40809282544](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40809282544) on `a38bdba6` passed 3,228 Core methods with two skips and both Compare engines, then failed that same conflict header activation assertion. Its older source predates the recorded header repair; the later complete hosted workflow remains unproven. The later [run 40830336479](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40830336479) on `c366f2b3` ran 3,234 Core methods with two skips and 326 failed assertions in two metafile methods. The [canvas-bounds continuation](METAFILE-CANVAS-BOUNDS-PARITY.md) corrects the physical-frame/device-bound conflation and recorded-Plus classification without changing expected pixels or tolerances. A complete macOS workflow on the release source remains required. The later [run 40863559740](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40863559740) on `59351fd7` passed 3,245 Core methods with two skips and no failures, then timed out saving a required standalone Merge output: default AutoAdd opened a repository chooser for a plain non-Git folder. The [AutoAdd completion continuation](MERGE-AUTOADD-COMPLETION-PARITY.md) addresses that end-user policy and retains sandbox-unknown authority. Its local checkpoint does not establish a complete hosted pass. Pages success does not certify the app. |
| Installed workflow acceptance | Earlier signed physical checks cover specific private workflows, not every current source batch. Repeat the relevant installed Commit/Log/comparison/replay/Settings paths after consolidation, including error, cancellation and reopen behavior. Build27's static checks and older focused sandbox evidence do not replace those checks. |
| Finder and permissions | [Build18 cold registration](qa/signed-consolidation-build18-2026-10-27.json) records badges and menus without an unwanted workspace. Current-version first-use grants, persisted watched folders, background refresh, multiple repositories, external file grants and the complete command set still need scoped physical acceptance. Finder Sync's native badge placement is the macOS integration. |
| Startup and large repositories | [Finder publication](qa/finder-publication-pipeline-2026-10-27.json) and [shared Commit reads](qa/commit-shared-display-read-2026-10-27.json) have measured improvements. Complete installed startup/status latency and representative large repositories remain separate measurements; synthetic command counts are not an end-user timing guarantee. |
| Text, image and document compatibility | [Comparison](IMAGE-COMPARISON.md), [metafile compatibility](IMAGE-METAFILE-PARITY.md), [formatted text](METAFILE-TEXT-PARITY.md) and the document-tool records retain unsupported formats, encodings, font/locale differences and external application boundaries. Explicit refusals must remain visible; a passed corpus is not universal format support. |
| Historical filename boundaries | [Historical materialization/comparison](RAW-HISTORY-PARITY.md#materializationcomparison-checkpoint), [folder archives](BROWSER-ARCHIVE-PARITY.md) and [safe individual-file transfers](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md) are implemented and separately checked. Raw original-path checkout, working-tree mutation/comparison, literal folder promises/exports with raw descendants and submodule checkout resolution retain the explicit [namespace boundaries](REPOSITORY-BROWSER-NAMESPACE-PARITY.md). A native-host filename probe does not establish every filesystem's capabilities. |
| Provider and external transport acceptance | Native issue adapters, credentials, SSH, hooks, Git/LFS/SVN and Office adapters have their own bounded records. Authenticated public services, vendor-specific providers, receiving applications and real external permissions remain separate from private loopback/stub tests. |
| Intel and minimum macOS | Universal binary and deployment-target checks establish structure. Execution on Intel and the minimum supported macOS, including UI, helper and Finder workflows, remains unverified by those checks. |
| Localization and accessibility | The generated catalog retains English fallback where source translations cannot be used safely. Label counts do not establish every dialog's translation, VoiceOver reading order, IME behavior or keyboard usability. |
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
