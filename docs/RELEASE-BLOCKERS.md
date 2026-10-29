# Local testing and release gates

The goal remains the full native macOS port of TortoiseGit. Implemented screens,
resource mappings and focused checks do not establish complete application parity.
This page identifies current gates; dated implementation detail is in
[the port tracker](PORTING.md) and the linked family records.

## Installed local testing build33

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
| Historical filename boundaries | [Historical materialization/comparison](RAW-HISTORY-PARITY.md#materializationcomparison-checkpoint) is implemented and separately checked. Raw original-path checkout, working-tree mutation/comparison, folders with raw descendants and submodule checkout resolution retain the explicit [namespace boundaries](REPOSITORY-BROWSER-NAMESPACE-PARITY.md). A native-host filename probe does not establish every filesystem's capabilities. |
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
