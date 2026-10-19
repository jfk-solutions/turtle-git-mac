# PowerPoint presentation comparison

TurtleGit can compare captured `.ppt`, `.pptx` and `.pptm` presentations in a
native slide-review window. Microsoft PowerPoint must be installed to export the
slides. The original files remain unchanged.

## Open a comparison

Compare two revisions or working files through the ordinary file-comparison
commands. New settings include the three PowerPoint associations. With saved
settings from an earlier build, choose **Settings → Diff Viewer → Advanced →
Restore Defaults**, or assign **Microsoft PowerPoint presentation comparison**
to the relevant extension. Restore Defaults replaces the bundled extension
associations; unrelated custom associations remain. Shift uses the existing
alternate-tool selection.

macOS may request permission for TurtleGit to control Microsoft PowerPoint.
An Automation denial reports the relevant System Settings location. PowerPoint
opens captured read-only copies with macros disabled, exports the slides, then
closes those owned presentations and restores its previous macro policy. It
keeps other open presentations and the application instance intact.

## Review slides

The list identifies added, deleted, modified and moved slides with source icons
and different colors. Select a row to inspect the corresponding base and new
slides. **Changes only** hides unchanged rows. Previous/next change moves between
changed slides; ordinary slide navigation also includes unchanged rows.

**Side by side** displays the pair in a shared scrolling surface. **Overlay**
blends the two versions. **Differences** marks changed pixels in red over a muted
slide. Fit and zoom apply to both sides together. View mode, Changes only, Fit and
zoom are saved in the owning settings domain; the selected slide belongs to the
current comparison.

Expand **Text and notes** to read slide text and speaker notes. Their headings
highlight changed fields. **Copy Review** and **Export Review…** produce a text
summary with slide indices, actions, moves and changed text/notes. Cancel stops
preparation or rendering, and Retry can restart the cancelled or failed read.
Close cancels the window's remaining work and releases its captured files after
that work retires. Help opens this guide offline when the bundled book is present.

## Current scope

The Windows script uses PowerPoint's presentation Merge/revision interface.
[Microsoft documents that this interface is unavailable on Mac](https://support.microsoft.com/en-us/office/track-changes-in-your-presentation-35dad781-50f7-4c4f-9b15-cf418f03c279).
TurtleGit provides slide review through private PowerPoint PDF exports and slide
metadata. It compares a finite raster representation, text and notes; tiny visual
changes below the fingerprint resolution can require inspection at higher zoom.

Shape-level accept/reject, editable merged presentations, review comments,
animations, transitions, embedded-object behavior and macro contents remain open
parity work. This adapter is a comparison tool; conflict merging retains the
existing configured merge-tool workflow.

The current limits are 512 slides per side, 128 MiB per exported PDF and 64 MiB of
exported slide text/notes across both sides. The PowerPoint metadata walk also
limits the captured shape count and text units. The reader checks that the export accounts for every
manifest slide, including hidden slides, and reports missing pages instead of
publishing a partial comparison. Password-protected, rights-managed or otherwise
unexportable presentations report the PowerPoint error.

Actual installed PowerPoint rendering, file grants, Automation prompts, hidden
slides and signed sandbox behavior require separate acceptance. See the
[source comparison and dated checks](POWERPOINT-COMPARISON-PARITY.md).
