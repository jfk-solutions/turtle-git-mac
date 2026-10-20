# PowerPoint presentation comparison

TurtleGit can compare captured `.ppt`, `.pptx` and `.pptm` presentations in a
native review window. For `.pptx` and `.pptm`, it also reviews package-aware
slide and shape revisions and saves an editable copy. Microsoft PowerPoint is
needed for rendered source-slide previews and binary `.ppt` comparison. When
PowerPoint is unavailable, Open XML presentations can still be reviewed through
their package metadata and revision decisions. The original files remain unchanged.

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
summary with slide indices, actions, moves and changed text/notes. Editable review
entries also include their Accepted New / Rejected Base / Unresolved decisions. Cancel stops
preparation or rendering, and Retry can restart the cancelled or failed read.
Close cancels the window's remaining work and releases its captured files after
that work retires. Help opens this guide offline when the bundled book is present.

## Accept or reject revisions

For a supported Open XML presentation, **Editable revision review** lists changed
slides, shapes/groups, stacking order and shared presentation properties. Select
an entry to read its scope and the corresponding Base/New text and notes.
**Accept selected** takes New; **Reject selected** keeps Base. **Accept all** and
**Reject all** decide the full review. Undo and Redo restore decision changes;
Command-Z and Shift-Command-Z use the same review history.

Pictures, charts, embedded content, layouts and themes are package dependencies,
not just visible text. The review compares linked content as well as XML. Groups
are reviewed as a unit. Changes whose references must stay together, such as a
slide environment with notes/timing/layout changes, are labeled as a complete
slide decision. The selected dependency graph is carried into the output.

After every entry has a decision, **Save Editable Copy…** writes a `.pptx` or
`.pptm` presentation through a native Save panel. Macro-bearing inputs require a
macro-enabled output extension. TurtleGit preserves opaque macro parts without
executing them. Package digital signatures are removed when saving reviewed
output; the file must be signed again. The originals, their aliases and TurtleGit's
captured inputs cannot be selected as the output.

The source slide previews remain **Base** and **New** throughout review. They do
not render the combined result; open the saved copy in PowerPoint to inspect it.
A package error or unsupported mixed combination reports its reason rather than
silently flattening the content. A binary `.ppt` comparison remains visual and
has no editable package review. Save to Open XML separately before using revision
decisions for that format.

Closing a review or quitting the app with unsaved decisions offers **Discard / Cancel**. Save the
editable copy before closing to retain the result. Decisions belong to the current
review session. Closing or cancelling during work cancels its captured token and
keeps file grants/private inputs alive until the actual reader or writer settles.
An in-flight atomic save may already have committed before cancellation arrives.

## Current scope

The Windows script uses PowerPoint's presentation Merge/revision interface.
[Microsoft documents that this interface is unavailable on Mac](https://support.microsoft.com/en-us/office/track-changes-in-your-presentation-35dad781-50f7-4c4f-9b15-cf418f03c279).
TurtleGit provides slide review through private PowerPoint PDF exports and slide
metadata. It compares a finite raster representation, text and notes; tiny visual
changes below the fingerprint resolution can require inspection at higher zoom.

The package revision engine adds slide and shape/group decisions and editable
Open XML output; it does not reproduce Windows PowerPoint's entire revision UI.
Individual children inside groups, arbitrary presentation-wide reference changes,
all animation/transition/comment combinations, binary conversion/save-back and
merged-result rendering still require broader implementation or acceptance.
Unsupported combinations report a reason instead of losing dependent content. This adapter is a comparison tool; conflict merging retains the
existing configured merge-tool workflow.

The package editor currently accepts transitional Open XML with UTF-8 XML. Strict
Open XML namespaces, UTF-16/non-UTF-8 XML, DTD/entity declarations, encrypted or
ZIP64 archives and unknown top-level shape constructs report an explicit reason.
Mixed choices involving incompatible comment-author registries, global notes or
handout masters, namespace prefixes, duplicate group-child IDs or references to
rejected shapes/slides can be refused. Choose a coherent complete revision or
adjust the decisions; the editor does not silently discard those references.

Package limits are 20,000 ZIP members, 128 MiB per member, 512 MiB expanded and
768 MiB archived; XML/dependency/shape traversal has additional bounded limits.
The current visual limits are 512 slides per side, 128 MiB per exported PDF and 64 MiB of
exported slide text/notes across both sides. The PowerPoint metadata walk also
limits the captured shape count and text units. The reader checks that the export accounts for every
manifest slide, including hidden slides, and reports missing pages instead of
publishing a partial comparison. Password-protected, rights-managed or otherwise
unexportable presentations report the PowerPoint error.

Actual installed PowerPoint rendering, file grants, Automation prompts, hidden
slides and signed sandbox behavior require separate acceptance. See the
[source comparison and dated checks](POWERPOINT-COMPARISON-PARITY.md).
