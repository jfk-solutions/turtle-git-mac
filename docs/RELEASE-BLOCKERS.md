# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Release 0.1.0 built for arm64/x86_64; bundle/cache audits and app/extracted-ZIP seals passed, October 15, 2026 | Current Help, native LFS list and two-pane/combined/three-pane block navigation, independent block selection and source history/context semantics, initial selection and deferred input ownership and exact browser Unicode paths plus captured reference-menu actions and ordinary source/result block choices plus retained in-place comparison editing plus history savepoints/gap cleanup/owned option reload and aligned result row records/locator/precise single-side resolutions plus native result record editing/source gaps/all-pane Undo have local validation; regenerate the universal preview for the current commit, then perform GUI acceptance |
| Hosted integration checks | cb7724af run 38814893133 passed Git integration and Unified Diff, then failed step 82 in a headless TwoPaneEngineVerification viewport wait. This batch fixes that fixture and passes its local engine workflow; the earlier Submodule runner compile repair also remains in current source | Obtain the complete hosted result for the latest commit; 396182b5 run 38825796244 was last observed pending; 1e03c7c8 run 38824056371 was cancelled. No full macOS pass claimed |
| Documentation and screenshots | GitHub Pages run 38825796264 succeeded for 396182b5; README, LICENSE, NOTICE and workflow documentation exist. Bundled Mac Help and its guide are now implemented locally | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The next release checkpoint is a reproducible local app/ZIP plus a full hosted CI
result. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
