# Native image commands and toolbars

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/MainWindow.cpp::CreateToolbar/DoCommand`, `WM_NOTIFY`
tooltips, and `TortoiseIDiff.rc` View commands/accelerators.

Comparison and conflict-selection windows now use actual AppKit `NSToolbar`
instances. The comparison default follows the source order: Overlay, Blend,
separator, Link, Fit widths, Fit heights, separator, Fit in window, Original size,
Zoom in/out, separator, Info and Vertical. Selection mode omits overlay/blend/
link/dimension matching, as in `CreateToolbar` with `selectionPaths`. Existing
original artwork is reused at 24 points. Source button groups remain fixed;
native overflow and accessible toggle buttons provide macOS behavior. Native
File/View menu buttons at the end retain the commands formerly in the content
header. Lightweight panes hosted without a controller retain their existing
content controls.

Each menu leaf, overflow item and button validates its owning window and current
mode again when invoked. Check states update from the observed model. Overlay
retains its source alpha reset/forced linking and disables Blend outside overlay,
Link inside overlay and Vertical inside overlay; the latter is now also enforced
by the Command-V accelerator. Comparison and selection keyboard dispatch share
the same commands and guards as their toolbar. Busy, active Load Images,
attached-sheet, replacement and closed/retired contexts refuse applicable actions.
Sheet notifications refresh the native toolbar. Retained overflow/menu items
cannot revive a closed viewer. Playback retains its existing stop/retirement
lifetime.

Comparison uses a stable window-owned image model across Load Images rather than
recovering that model from a disappearing native key bridge. This keeps toolbar,
keyboard and pane state on the same model while images change. Accepted image inputs and their file grants are captured before chooser closure;
replacement reload starts after the chooser sheet ends, so ordinary sheet guards
do not discard it. Cancel and retired/replaced chooser callbacks cannot submit
new inputs. Image/text
routing transfers the window toolbar between the two existing command surfaces;
it does not show both toolbars. The active File menu labels the image command
Load Images and sends it to the image chooser, keeping text Open separate.
Image header tooltips retain the complete path/revision or conflict identity
when the visible caption is truncated.

No image decoding, pixel blend, Git operation, conflict resolution or repository
write semantics changed. Existing geometry restoration remains in use. No new
persistent image-mode preference or Windows toolbar customization is invented.

## Verification and limits

After a current Debug build, `scripts/test-image-command-family.py` links app
objects once and runs the connected native toolbar, existing Load Images,
conflict-selection and frame/playback cases. `--only` limits a repair recheck to
its affected case. Both command-line Git engines can be supplied; each case owns
its repository/preferences/windows and requires a final completion marker.
Optional `--captures` uses current-process macOS compositor images, including
native window chrome; review those originals before publishing.

See [the dated record](qa/image-command-2026-10-15.json) for actual results and
repairs. Physical toolbar tracking/overflow, keyboard/VoiceOver, multi-display
resizing, historical-blob Open path prefill, all formats, signed minimum-OS/Intel
and sandbox/App Store acceptance remain open. This does not certify the whole
image viewer or application port.

The final Debug build and affected system-Git cases passed; the prior unchanged
selection case and all four bundled-Git cases passed. Four unaltered current
light/dark window captures were reviewed and published. The dated record retains
every failed attempt, repair, exact case scope and owned process identifier.
