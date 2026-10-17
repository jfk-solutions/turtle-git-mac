# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Fresh Release 0.1.0 at 1286765a, October 17, 2026: both architectures, measured source inputs, complete unsigned-copy inventory, deep strict ad-hoc app/extracted-ZIP seals and matching signed ZIP inventory passed. Local ZIP is 349,429,725 bytes; [evidence](qa/distribution-provenance-preview-2026-10-17.json) | Physical GUI acceptance and a signed distribution remain open. The manifest retains the measured dirty-input snapshot; no hermetic/reproducible-build claim. This ZIP predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches; regenerate at the next distribution checkpoint |
| Unsigned App Store archive | Fresh October 17 archive at 1286765a passed universal bundle/cache audits and matching universal dSYMs for eight app components; complete 6,215-member archive inventory retained | This archive predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches. Real signing, export and sandbox/installed execution acceptance remain open; no submission performed |
| Hosted integration checks | [b818417d run 39055414986](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39055414986) passed 1,809 Core tests (two skipped) and the previously failing Merge menu lifecycle case. It then timed out in native folding after `pair loaded; collapsing`; the owned receiver was reaped. [03d15e28 run 39058837911](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39058837911) is in progress | Repair the folding stall and obtain a full passing current macOS run. No hosted resolution claimed |
| Documentation and screenshots | [Pages run 39058837900](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39058837900) succeeded for 03d15e28. README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Help exist | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented. Actual Apple Development signatures and team-qualified App Group entitlements pass for all three peers; separate sandbox writer/reader and denied nonmember checks pass. [Signed development evidence](qa/signed-finder-development-2026-10-17.json) | Verify activation, live overlays, multi-selection menus, external repository grants and service registration in the signed installed app |
| Crash reporting | Local launch discovery/Review/Dismiss, handled suppression, manual Apple report import/review, explicit inclusion, local Copy/Save and a separate issue form are implemented with scoped checks | Actual system-crash delivery and installed signed access, Windows dump/assert collection, direct DrDump transport and solution lookup remain unported; see CRASH-REPORTING-PARITY.md |
| Native languages | English and 37 bundled source catalogs; safe matching labels, General/First Start selection, private persistence, fallback and grouped native checks pass | Complete remaining native/dynamic/formatted/plural translation, RTL/physical acceptance and signed locale behavior |
| Signed distribution | The October 17 universal AppStore-configuration Apple Development checkpoint passes. Packaged inherited-sandbox Git repository operations and Lexilla execution pass from a real signed sandbox parent; no Finder activation or distribution export performed. This signed checkpoint predates the [LFS exact-target continuation](qa/lfs-path-identities-2026-10-17.json) | Complete installed acceptance, intended Developer ID/App Store distribution signing, export and the corresponding notarization/submission path; regenerate preview/archive after the current implementation batches |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The fresh local app/ZIP and unsigned archive checkpoint has passed. The next
release gates are a full hosted CI result and physical/signed acceptance. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.


The [Compare reload continuation](qa/merge-reload-family-2026-10-17.json) unifies
explicit Reload and pane switching with per-pane Save decisions and clears
shared document history directly. The pre-change moved-block diagnostic passed
locally, so no confirmed root cause or hosted fix is claimed from that result.
