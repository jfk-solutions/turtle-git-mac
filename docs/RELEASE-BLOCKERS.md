# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Release 0.1.0 built for arm64/x86_64; bundle/cache audits and app/extracted-ZIP seals passed, October 15, 2026 | Current Help, native LFS list and two-pane/combined/three-pane block navigation have local validation; regenerate the universal preview for the current commit, then perform GUI acceptance |
| Hosted integration checks | e67417b3 run 38799322056 failed system-Git UDiff at fixture line 107; it predates the input-readiness repair. The repair passed locally with both engines. ddfb57ab run 38808679175 is in progress and includes that repair | Obtain hosted confirmation and resolve any subsequent failures; no full macOS pass claimed |
| Documentation and screenshots | GitHub Pages run 38808679265 succeeded for ddfb57ab; README, LICENSE, NOTICE and workflow documentation exist. Bundled Mac Help and its guide are now implemented locally | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The next release checkpoint is a reproducible local app/ZIP plus a full hosted CI
result. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
