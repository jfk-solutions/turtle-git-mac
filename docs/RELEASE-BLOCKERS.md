# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Fresh Release 0.1.0 at 1286765a, October 17, 2026: both architectures, measured source inputs, complete unsigned-copy inventory, deep strict ad-hoc app/extracted-ZIP seals and matching signed ZIP inventory passed. Local ZIP is 349,429,725 bytes; [evidence](qa/distribution-provenance-preview-2026-10-17.json) | Physical GUI acceptance and a signed distribution remain open. The manifest retains the measured dirty-input snapshot; no hermetic/reproducible-build claim |
| Unsigned App Store archive | Fresh October 17 archive at 1286765a passed universal bundle/cache audits and matching universal dSYMs for eight app components; complete 6,215-member archive inventory retained | Real signing, export and sandbox/installed execution acceptance remain open; no submission performed |
| Hosted integration checks | macOS run [38999577669](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38999577669) failed when the native Merge folding case exceeded its 300-second limit. Its owned receiver was reaped. A focused local reproduction passed on October 17; the hosted failure remains unresolved. A separate [39004429670](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39004429670) failed compiling the long About animation pixel expression; it is now split into typed components, awaiting hosted confirmation. Newer run [39005135437](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39005135437) for cb83f966 is still in progress at the latest observation | Obtain a complete passing macOS result for the current implementation; local grouped passes do not certify hosted integration |
| Documentation and screenshots | GitHub Pages run [39006000527](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39006000527) succeeded for 9f6646d5 (October 17, 2026). README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Help exist | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Crash reporting | Native Apple report import/review, explicit inclusion, local Copy/Save and a separate issue form are implemented with scoped checks | Automatic recovery, Windows dump/assert collection, direct DrDump transport and solution lookup remain unported; see CRASH-REPORTING-PARITY.md |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The fresh local app/ZIP and unsigned archive checkpoint has passed. The next
release gates are a full hosted CI result and physical/signed acceptance. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
