# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Release 0.1.0 built for arm64/x86_64; bundle/cache audits and app/extracted-ZIP seals passed, October 15, 2026 | Current Help, native LFS list and two-pane/combined/three-pane block navigation, independent block selection and source history/context semantics, initial selection and deferred input ownership and exact browser Unicode paths plus captured reference-menu actions have local validation; regenerate the universal preview for the current commit, then perform GUI acceptance |
| Hosted integration checks | ddfb57ab run 38808679175 passed Git integration (step 58) and Unified Diff editable documents (step 69), then failed the Submodule Update selection runner at step 85 because its standalone source list omitted title/Help dependencies. The runner now uses built app objects and passes locally. cb7724af run 38814893133 is active; a3721aff run 38817913199 is pending | Obtain the complete hosted result and confirmation for the latest commit; no full macOS pass claimed |
| Documentation and screenshots | GitHub Pages run 38817913218 succeeded for a3721aff; README, LICENSE, NOTICE and workflow documentation exist. Bundled Mac Help and its guide are now implemented locally | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The next release checkpoint is a reproducible local app/ZIP plus a full hosted CI
result. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
