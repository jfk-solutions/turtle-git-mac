# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Release 0.1.0 built for arm64/x86_64; bundle/cache audits and app/extracted-ZIP seals passed, October 15, 2026 | Current Help changes have Debug validation; regenerate the universal preview for the current commit, then perform GUI acceptance |
| Hosted integration checks | Run 38785757109 at 0ad4cadc is running; fe13d36e is pending. Older 38778092594 passed Core but failed on a bundled-Git native Unified Diff timeout | Obtain a full hosted pass and diagnose any repeated Unified Diff wait using the new source-line diagnostic; the affected local case passed without reproducing that failure |
| Documentation and screenshots | GitHub Pages run 38789793700 succeeded for fe13d36e; README, LICENSE, NOTICE and workflow documentation exist. Bundled Mac Help and its guide are now implemented locally | Keep actual captures and documented limitations aligned with the shipped build |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented with scoped local checks | Verify activation, overlays and multi-selection menus in the signed installed app |
| Signed distribution | Unsigned universal and ad-hoc preview tooling exist | Build and exercise with the intended Developer ID/App Store signing and provisioning; complete the corresponding export/submission path |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The next release checkpoint is a reproducible local app/ZIP plus a full hosted CI
result. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.
