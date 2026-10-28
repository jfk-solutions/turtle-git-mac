# Local testing and release gates

The goal remains the full native macOS port of TortoiseGit. Implemented screens,
resource mappings and focused checks do not establish complete application parity.
This page identifies current gates; dated implementation detail is in
[the port tracker](PORTING.md) and the linked family records.

## Installed local checkpoint

[Build23, version 0.1.0 (23)](qa/signed-consolidation-build23-2026-10-28.json)
is installed from `f2796388f28b3cff7aa03b25ce62d29724cc5cb0` as an Apple Silicon local test package. Measured
inputs, strict signatures, eight owned arm64 components, bundled Help and complete
installed inventory pass. Universal build22 is preserved. Finder and Dock were
not restarted; only TurtleGit's extension registration was refreshed.

The registered folder retained its general menu after full app exit, but actual
Finder Commit launch failed with error256. The following source repair uses
ordinary URL delivery instead of the failed explicit first-event configuration.
Current signed launch acceptance remains open until that repair is checked.

## Remaining gates

| Gate | Evidence and remaining work |
| --- | --- |
| Source behavior and layout | [Family records](PORTING.md#current-component-and-workflow-state--october-25-2026) describe connected implementations. The [resource ledger](DIALOG-COVERAGE.md) keeps partial controls and unmapped platform/example resources explicit. Complete dialog states, command eligibility, layout, keyboard and accessibility acceptance must be established from their actual consumers, rather than counting screens. |
| Current hosted integration | The [dated Commit failure record](qa/commit-option-observers-2026-10-28.json) records a hosted Core stage with 3,153 methods, two skips and no failures, followed by a native Commit observer failure. Its local repair passes both Git engines; that is not a full hosted pass. The later [hosted run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40709146937) failed the Amend option observer assertion; the native menu still bypasses synchronous metadata handling and its repair remains open. A complete macOS workflow on the release source remains required. Pages success does not certify the app. |
| Installed workflow acceptance | Earlier signed physical checks cover specific private workflows, not every current source batch. Repeat the relevant installed Commit/Log/comparison/replay/Settings paths after consolidation, including error, cancellation and reopen behavior. Build23's static checks and older focused sandbox evidence do not replace those checks. |
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
