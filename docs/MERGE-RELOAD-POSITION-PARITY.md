# Compare and Merge Reload position

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseMerge/MainFrm.cpp`, `LoadViews` (759–1083), `OnFileReload`
(2135), external-change acceptance and input-encoding commands.

## Source behavior and native adaptation

The source uses `LoadViews(-1)` for explicit Reload and accepted external changes.
It captures the Right viewport and target caret before rebuilding, maps the old
line into the new projection, synchronizes vertical scrolling and resets horizontal
scrolling. Fresh Open and input-encoding reinterpretation use configured initial
navigation instead. Reload first offers to save unsaved work.

Both native text editors now give F5, the Reload command and accepted external
changes a distinct Reload purpose. They capture logical source line, UTF-16 column
and top line before reading. After the accepted document and its actual native
panes are ready, they map those coordinates into the new presentation, clamp
missing lines/shorter columns and restore the caret and viewport. Hidden folded
rows needed for the restored location are revealed. Horizontal origins return
to native character zero at the left edge, including each pane’s ruler inset.

Classic aligned panes use Right/Mine as the common vertical anchor. Native carets
remain specific to each pane's source coordinates; this is a macOS adaptation of
the upstream single target-caret point. P4-style panes retain their independent
vertical positions. This does not claim exact Windows display-row or pixel
coordinates when different diff projections or native fonts produce other rows.

Combined Compare tracks whether a changed row belongs to Base or Mine, so Removed
and Added rows with the same displayed source number cannot alias. Common rows
belong to both inputs; when a common row splits, Mine supplies the normal target.
When a changed origin disappears, the remaining matching logical line is preferred
before clamping to a nearby available source row.

## Save, cancellation and ownership

Save, Don't Save and Cancel retain the captured Reload purpose. A successful owned
Save can retarget the receipt to its newly published baseline/result destination;
it cannot authorize another source, reversed orientation or pane mode. Failed
saves and cancelled questions leave the prior document and draft in place. Failed
reads retain the old accepted document; a retry captures its current position.
F5 after an initial failed read uses fresh-load navigation because no old document
exists to restore.

Restoration checks the captured window, document, input/layout generation and
navigation intent. It waits for actual current native text and settled wrapping
geometry, without polling or a fixed delay. New input, mode changes, explicit
navigation and retirement invalidate stale restoration. Restoring native selection
also refreshes the active difference/conflict metadata used by status and commands.
Fresh Open and changed input encoding retain first-difference/conflict preferences.

## Validation and limits

The [grouped checkpoint](qa/native-ci-recovery-2026-11-26.json) passes both editor
workflows with system and bundled Git. Private native receivers exercise actual
F5 and Reload menu dispatch, external-change acceptance, Save/Don't Save/Cancel,
failed save/read and retry, Unicode and shorter inputs, combined row origins,
Classic/P4 scrolling, stale/closed owners and repository integrity. Classic peers
retain the canonical Mine viewport within each native pane's own EOF bounds.

Failed attempts remain recorded. Fixture repairs distinguish actual sheet
detachment, configured standalone output, regenerated result versus saved bytes,
canonical Mine versus independent Result scrolling, and native per-pane bounds.
The connected batch used three incremental Debug builds; the latter builds added
failure diagnostics and repaired Import Quit/Save. Passing unrelated cohorts and
unchanged Core/runtime builds were retained. A fresh full hosted run is required.

Remaining acceptance includes physical keyboard/menu gestures, large-file and
wrapped/folded viewport boundaries, real conflicted Git stage/orientation changes,
minimum supported macOS and signed sandbox execution. The installed build59 is a
separate earlier package and does not contain this source batch. This family does
not certify every upstream dialog or complete editor parity.
