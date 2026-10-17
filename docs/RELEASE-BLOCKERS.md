# Preview and release blockers

The full TortoiseGit port remains the goal. A local preview is a way to try the
implemented workflows; it does not certify complete parity or App Store readiness.

| Deliverable | Current evidence | Remaining action |
| --- | --- | --- |
| Local universal preview | Fresh Release 0.1.0 at ae48b26a, October 18, 2026: both architectures in all eight app components, measured input fingerprint, complete inventories and matching ad-hoc app/extracted-ZIP code seals passed. ZIP is 353,375,136 bytes; [evidence](qa/distribution-current-preview-2026-10-18.json), [trying it](LOCAL-PREVIEW.md) | The manifest retains dirty script inputs. Physical GUI and distribution signing remain open. The preview cannot share Finder App Group data, and the hosted wrapped-editor timeout remains unresolved |
| Unsigned App Store archive | Fresh October 18 archive at ae48b26a passed universal package/cache audits, matching universal dSYMs for eight app components and a 6,303-member inventory; offline export settings prepared | Actual distribution signing, separately signed archive/export, signed runtime and installed acceptance remain open. No export/submission performed; the hosted wrapped-editor timeout is still a release blocker |
| Hosted integration checks | The prior-code [ae48b26a run 39074660712](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39074660712) completed with failure: ownership, terminal, margin-selection, margin and moved passed; wrapped receiver 25205 timed out after 300 seconds and was reaped. Its sampler timed out, with no artifact. The older [bdf35802 captured stack](qa/ci-wrapped-stack-2026-10-18.json) shows active AppKit/SwiftUI/TextKit layout/drawing on macOS 15.7.9 Intel | The connected [presentation repair](qa/merge-presentation-family-2026-10-18.json) passes 13 distinct local native cases and skips unchanged storage/geometry/Find redraw work. Obtain a full passing current macOS run. No confirmed root cause, deadlock or hosted resolution is claimed |
| Documentation and screenshots | [Pages run 39074660721](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/39074660721) succeeded for ae48b26a. README, LICENSE, NOTICE, native screenshots, workflow guides and bundled Help exist; current artifact/CI evidence is linked here | Keep actual captures and documented limitations aligned with the shipped build; local packaging does not certify all screenshot workflows |
| Finder acceptance | Extension, menus, badge publication and cache service are implemented. Actual Apple Development signatures and team-qualified App Group entitlements pass for all three peers; separate sandbox writer/reader and denied nonmember checks pass. [Signed development evidence](qa/signed-finder-development-2026-10-17.json) | Activation, live ignored/modified/normal badges, real repository grants, agent registration/authenticated transfer, background refresh with the app quit and a file-context Show Log passed in the [installed development check](qa/finder-installed-2026-10-17.json). Other commands/multi-selection/modifiers, additional metadata grants and minimum-version/distribution acceptance remain open |
| Crash reporting | Local launch discovery/Review/Dismiss, handled suppression, manual Apple report import/review, explicit inclusion, local Copy/Save and a separate issue form are implemented with scoped checks | Actual system-crash delivery and installed signed access, Windows dump/assert collection, direct DrDump transport and solution lookup remain unported; see CRASH-REPORTING-PARITY.md |
| Native languages | English and 37 bundled source catalogs; safe matching labels, General/First Start selection, private persistence, fallback and grouped native checks pass | Complete remaining native/dynamic/formatted/plural translation, RTL/physical acceptance and signed locale behavior |
| Signed distribution | The October 17 Apple Development checkpoint verifies packaged inherited-sandbox Git/Lexilla and selected installed Finder activation/badge/background/Log behavior for that older candidate. The October 18 unsigned archive and ad-hoc preview contain ae48b26a; they do not renew signed acceptance | Complete intended distribution signing/export, current installed/sandbox checks and corresponding notarization/submission. Development signatures and unsigned inventories do not certify App Store distribution |
| Dialog parity | Current ledger contains 130 upstream dialogs, 120 partial family reviews and zero fully certified dialogs | Finish concrete missing behavior/layout and acceptance within each family; these counts are not a completion percentage |

The fresh local app/ZIP and unsigned archive checkpoint has passed. The next
release gates are a full hosted CI result and physical/signed acceptance. Full upstream parity, physical Finder behavior and signed/App Store
acceptance remain required for the complete goal. No calendar completion date is
claimed from the current audit counts.


The [Compare reload continuation](qa/merge-reload-family-2026-10-17.json) unifies
explicit Reload and pane switching with per-pane Save decisions and clears
shared document history directly. The pre-change moved-block diagnostic passed
locally, so no confirmed root cause or hosted fix is claimed from that result.
