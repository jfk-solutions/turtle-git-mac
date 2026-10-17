# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Fresh Release 0.1.0 at 1286765a, October 17, 2026: both architectures, measured source inputs, complete unsigned-copy inventory, deep strict ad-hoc app/extracted-ZIP seals and matching signed ZIP inventory passed. Local ZIP is 349,429,725 bytes; [evidence](qa/distribution-provenance-preview-2026-10-17.json) | Physical GUI acceptance and a signed distribution remain open. The manifest retains the measured dirty-input snapshot; no hermetic/reproducible-build claim. This ZIP predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches; regenerate at the next distribution checkpoint |
| Unsigned App Store archive | Fresh October 17 archive at 1286765a passed universal bundle/cache audits and matching universal dSYMs for eight app components; complete 6,215-member archive inventory retained | This archive predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches. Real signing, export and sandbox/installed execution acceptance remain open; no submission performed |
| Hosted integration checks | Run [39013950765](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39013950765) for a4811601 remains in progress (Git integration job 117343554354 confirmed live at the October 17 observation); [39014702461](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39014702461) for a0138ef3 is cancelled, and current-main [39016255915](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39016255915) for fa3b7e69 is pending. The latest inspected terminal [33391321 run](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39008624452) failed Moved blocks and wrapped editor navigation: `Discard/reload did not restore move mapping`; owned receiver 24007 was reaped. Earlier [d7133b3b](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39007075056) failed conflict-menu Undo, and the earlier folding timeout remains tracked | Obtain a full current passing macOS result; investigate the moved-map reload failure. Local grouped passes do not certify hosted integration |
| Documentation and screenshots | GitHub Pages run [39016255949](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39016255949) succeeded for fa3b7e69 (October 17, 2026). README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Help exist | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Crash reporting | Native Apple report import/review, explicit inclusion, local Copy/Save and a separate issue form are implemented with scoped checks | Automatic recovery, Windows dump/assert collection, direct DrDump transport and solution lookup remain unported; see CRASH-REPORTING-PARITY.md |
| Native languages | English and 37 bundled source catalogs; safe matching labels, General/First Start selection, private persistence, fallback and grouped native checks pass | Complete remaining native/dynamic/formatted/plural translation, RTL/physical acceptance and signed locale behavior |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The fresh local app/ZIP and unsigned archive checkpoint has passed. The next
release gates are a full hosted CI result and physical/signed acceptance. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.


The [Compare reload continuation](qa/merge-reload-family-2026-10-17.json) unifies
explicit Reload and pane switching with per-pane Save decisions and clears
shared document history directly. The pre-change moved-block diagnostic passed
locally, so no confirmed root cause or hosted fix is claimed from that result.
