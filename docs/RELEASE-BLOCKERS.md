# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Fresh Release 0.1.0 at 1286765a, October 17, 2026: both architectures, measured source inputs, complete unsigned-copy inventory, deep strict ad-hoc app/extracted-ZIP seals and matching signed ZIP inventory passed. Local ZIP is 349,429,725 bytes; [evidence](qa/distribution-provenance-preview-2026-10-17.json) | Physical GUI acceptance and a signed distribution remain open. The manifest retains the measured dirty-input snapshot; no hermetic/reproducible-build claim. This ZIP predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches; regenerate at the next distribution checkpoint |
| Unsigned App Store archive | Fresh October 17 archive at 1286765a passed universal bundle/cache audits and matching universal dSYMs for eight app components; complete 6,215-member archive inventory retained | This archive predates the subsequent Statistics, exact-changelist, folding, language, Sync child progress, native Merge history, Sync recovery and Sync conflict-list batches. Real signing, export and sandbox/installed execution acceptance remain open; no submission performed |
| Hosted integration checks | [7ac0327d run 39043881354](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39043881354) failed step 85, Scoped native Merge menus and pane shortcuts: `Conflict block shortcut missing` in lifecycle receiver 92537. The fixture now mounts its native editor and waits for readiness; the affected case passes locally with all five shortcut/Undo assertions retained. [d1bb278f run 39049374735](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39049374735) was in progress at the latest observation | Obtain a full passing current macOS run; local correction does not certify hosted resolution. See [primary dialog batch](qa/primary-command-bands-2026-10-17.json) |
| Documentation and screenshots | [Pages run 39049374694](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39049374694) succeeded for d1bb278f (October 17, 2026). README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Help exist | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Crash reporting | Local launch discovery/Review/Dismiss, handled suppression, manual Apple report import/review, explicit inclusion, local Copy/Save and a separate issue form are implemented with scoped checks | Actual system-crash delivery and installed signed access, Windows dump/assert collection, direct DrDump transport and solution lookup remain unported; see CRASH-REPORTING-PARITY.md |
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
