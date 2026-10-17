# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Release 0.1.0 built for arm64/x86_64; bundle/cache audits and app/extracted-ZIP seals passed, October 15, 2026 | Regenerate the universal preview for current HEAD, including current Help, browser/reference workflows and comparison/merge editing, block choices and formatting, and adaptive Commit/live Log presentation; perform GUI acceptance. Detailed local evidence is recorded in docs/qa |
| Hosted integration checks | Latest observed macOS run [38994546612](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38994546612) for 0ffa4696 is pending (October 17, 2026). Earlier native failures have local repairs; complete hosted verification remains outstanding | Obtain a complete passing macOS result for the current implementation; local grouped passes do not certify hosted integration |
| Documentation and screenshots | GitHub Pages run [38994546668](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/38994546668) succeeded for 0ffa4696 (October 17, 2026). README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Mac Help exist | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The next release checkpoint is a reproducible local app/ZIP plus a full hosted CI
result. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
