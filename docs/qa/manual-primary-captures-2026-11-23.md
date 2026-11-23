# Current primary Mac screenshots — November 23, 2026

Status: twelve documented native appearances captured and visually reviewed.
Classic Commit, Git Gui-style staging, Log, Resolve, Sync outgoing history and
Sync conflicts each have light/dark original compositor PNGs. This is bounded
appearance acceptance, not whole-port visual or interaction parity.

The first cohort used isolated clean c8c89189 source and matching existing Debug
objects. Review rejected its six Log/Resolve/Sync-conflict images: changed-file
headers were absent, Path columns collapsed, and the Sync viewport clipped its
first conflict. All twelve first-attempt PNGs, transformed fixture sources,
stdout/stderr and reviewed failure receipt remain in
`build/qa/manual-primary-captures-2026-11-23/prior-attempt-20261123T022607568447Z`.

After production geometry repair, only those six appearances were recaptured:

```sh
python3 scripts/capture-manual-primary-2026-11-23.py \
  --debug-root <corrected-isolated-checkout> \
  --only log --only resolve --only sync-conflicts
```

The current receipt records the dirty source state relative to committed c8,
production source hashes, architecture-specific app object bytes, native link
fingerprint and embedded bundle metadata separately. The six unchanged original
Commit/Sync-history images retain their earlier clean-c8 provenance and exact PNG
hashes. No newer paused-Replay or Blame views are pictured. Embedded bundle
version/revision metadata is not substituted for the actual source/object state.

Root reviewed repaired Log light, Resolve dark and Sync-conflicts dark;
current_ci_status reviewed repaired Log dark, Resolve light and Sync-conflicts
light. Changed-file column headers, full paths, extensions and all three conflicts
are now visible. Native geometry records rows3/3 and Path420 for both conflict
surfaces, with a full first-row intersection and the native header inset y=-28.
All twelve final asset hashes match their receipt, and all twelve preserved
first-attempt PNG hashes match the earlier receipt. Inactive native title bars
and the compact issue-picker's truncated caption remain as actually rendered.

The actual capture uses one real native window at a time, briefly contained on
screen at alpha one, ordered forward without activation or makeKey, then hidden
immediately and closed. It uses ScreenCaptureKit `desktopIndependentWindow` and
original PNG bytes, without view snapshots, compositing, redrawing or pixel edits.
An available unlocked desktop is required. Homepage dimensions come from the
original PNG headers, not an assumed window aspect ratio.

The existing cached native receiver links actual Debug objects; it does not build
the app. Private offline repositories supply real status/history and three merge
conflicts. Private preferences and HOME/CFFIXED_USER_HOME/TMPDIR/XDG/Git settings
are used. Capture preserves HEAD, index/config and working contents after setup;
it performs no Commit, stage, resolution, transport or save operation. No shared
pasteboard, Keychain, Finder registration, user repository, installed app or
system appearance is changed. The receiver's windows/sheets close, relevant
workers drain, and the owned process is reaped. The repaired attempt closed six
owners; the preserved initial attempt closed twelve.

The homepage, Getting Started and dialog guide reference the final assets. The
root agent coordinates final Help regeneration and resource copying after this
review; no further Swift build or capture is implied by this document. The
receipt does not establish hosted CI success, signed installation, physical
Finder integration or acceptance of every upstream dialog.
