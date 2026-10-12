# Merge Colors settings

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, SetColorPage.cpp,
DiffColors.h and Resources/TortoiseMergeENG.rc::IDD_SETCOLORPAGE.

Settings → Diff Viewer → Merge Editor → Colors adds the source color matrix:
Normal, Added, Removed, Modified, Conflicted, Conflict resolved, Empty and Filtered;
Inline differences Added/Removed; and Misc Whitespaces. Foreground/background
controls follow the source's supported columns. Native color pickers edit opaque
sRGB values; the renderers use the same color space. A Light/Dark selector edits independent palettes; app appearance stays
under General. Restore Default resets only the displayed palette. Apply persists
both palettes and updates open viewers; Cancel discards drafts through the existing
settings transaction.

Source orange/yellow/red/green/purple/gray defaults and the dark variants are
preserved. Normal dark colors use the source #202020/#DDDDDD. macOS uses an
independent whitespace color per palette, adapting the source's one registry
Whitespace value. Missing/invalid persisted colors fall back to source defaults.
The store caches immutable palette snapshots under a lock; per-row drawing does
not decode preferences. Settings Apply atomically swaps the snapshot before
notifying open panes. No file contents or source encodings change.

Both viewers use configured supported-state foreground/background colors.
Normal colors cover the full canvas and caret. Locator stripes use the same
backgrounds. Existing inline backgrounds and missing-character marks use their
configured roles. Space/tab/EOL paths use Whitespaces; the dark ending-icon cache
invalidates when the palette changes. Original icon bytes remain unchanged.

Modified is consumed by the existing inline common background. The settings
store also retains Conflict resolved for the fuller resolved/edited result-state
presentation, which remains incomplete. This page does not certify complete
three-pane state coloring or the complete merge editor.

## Evidence and remaining work

The grouped Core check passed 21 tests with zero failures, including source RGB
values, selective Restore Default, private persistence and malformed-data fallback,
as well as the existing General/whitespace/presentation cases. The unsigned Debug
build passed with existing diagnostic noise. See
[the batch record](qa/merge-colors-2026-10-12.json).

The isolated existing two-pane receiver passed. The first combined receiver
reached the custom-color probe but timed out: its expected sRGB component did
not match the renderer's calibrated RGB conversion. A direct AppKit check
confirmed that calibrated (0.2, 0.4, 0.6) became sRGB approximately (0.253, 0.480,
0.665). Rendering now constructs explicit sRGB colors to match the picker/store.

The focused native palette/whitespace receiver then passed actual supported-
state background and normal foreground RGB, selective palette restore and
unchanged text/selection/history/generation/files. The final app build passed.
The whole combined receiver was not repeated after the color-space correction.
All owned windows/helpers closed; physical picker interaction remains open.

Remaining acceptance: physical picker/Apply/Cancel/Restore interactions, full
light/dark page and pane captures, all editor state aliases, resolved/edited
three-pane presentation, high contrast/large files, signed/minimum-OS and full
application parity. The source inventory marks the Colors page partial.
