# PowerPoint comparison source family

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
Source adapter: `contrib/diff-scripts/diff-ppt.js`.

## Source contract and Mac capability

The script registers `ppt;pptx;pptm`, requires two existing inputs and installed
PowerPoint, disables macros, checks the unsupported Office 2007 branch, opens
the base presentation and merges the new presentation into its review interface.
It marks the review saved to suppress an incidental Save As prompt. The Windows
PowerPoint review engine provides change highlighting and accept/reject behavior.

The inspected Mac `PowerPoint.sdef` exposes slide/shape/notes metadata, macro
security, PDF Save As and exact presentation close. It exposes no presentation
Compare/Merge command. Its `merge` command operates on table cells. Microsoft
also [documents the unavailable Mac Compare/Merge feature](https://support.microsoft.com/en-us/office/track-changes-in-your-presentation-35dad781-50f7-4c4f-9b15-cf418f03c279).
LibreOffice's documented tracked-review merge supports
[text and spreadsheet documents](https://help.libreoffice.org/latest/en-US/text/shared/guide/redlining_docmerge.html);
its existing Writer/Calc adapter cannot provide an Impress revision engine.

## Implemented connected family

The built-in tool and `.ppt`, `.pptx`, `.pptm` associations participate in the
existing selection, alternate-tool inversion, Advanced association editor and
Restore Defaults behavior. Source bytes, revision titles, caller preferences and
folder leases are captured through the shared file-comparison route. A caller
close cancels pending export; a completed independent review owns its own lifetime.

Core preparation copies exact bytes into a private directory and read-only input
files. The native export adapter sends literal Apple-event arguments to fixed
script code. It serializes its own exports around PowerPoint's global macro
policy, disables macros before opening, captures the exact private presentations,
exports all slides and hidden slides, closes those presentations, and restores
and checks the prior macro policy. It never selects an active document for
cleanup or terminates the user's PowerPoint instance. A completion receipt must
confirm cleanup; uncertain completion retains its captured files. Event timeouts
and cooperative cancellation preserve that distinction.

Slide metadata has bounded, versioned manifests and contiguous exported indices.
The PDF reader requires all manifest pages. It owns readers on worker threads,
checks size/page/pixel budgets, and computes deterministic raster fingerprints
rather than comparing variable PDF serialization bytes. Core pairs stable slide
identities and exact visual/content anchors, detects reorder through an increasing
subsequence, and preserves every input slide exactly once. Metadata text and
notes retain literal UTF-8 identity. Refused or oversized output fails explicitly.

The native review window contains source action icons, colored slide actions,
move markers, changes filtering, change/slide navigation, paired/overlay/pixel
difference views, shared fit/zoom and selectable text/notes. It persists display
preferences, copies or exports a review report, offers cancellation/retry and
contextual offline Help. Closing, refused presentation, sheets, retirement and
application Quit retain/cancel/drain the actual owned work before removing files.
The connected Open XML revision engine now adds editable-copy output, described
below. It does not stage repository changes or resolve a Git conflict.

## Validation and explicit gaps

The grouped checkpoint passed 29 relevant Core methods, the final Debug app,
bundle layout/configuration and four native cases: automation contracts, review,
routing and lifecycle. The installed PowerPoint script dictionary compiled;
execution replies and slide PDFs were injected. No live Office export was run.
The [dated evidence](qa/powerpoint-comparison-2026-10-20.json) records the initial
build/fixture failures, a repaired recursive control observer, and only the
affected rechecks. These passes do not establish a complete hosted CI pass.

That original checkpoint established native slide review, before editable
package revision decisions were added. It did not establish shape review or
merged-deck output. The connected package family below extends that scope;
Windows review comments, complete animation/transition/macro behavior, binary
save-back and embedded-object runtime acceptance remain open.
Finite raster fingerprints can miss sub-resolution visual changes. Mac standard
Open lacks a `with window false` parameter; exact owned windows are hidden after
open, so a live Office acceptance run must account for possible initial exposure.

Injected exporter/receiver checks do not establish actual Office rendering,
protected/password prompts, every hidden-slide/text-shape combination, external
application sandbox grants, TCC or App Store approval. The targeted PowerPoint
Apple-event entitlement is distribution preparation requiring separate review.
The broader port remains incomplete.

## Native captures

Actual offscreen native windows with private generated slide PDFs, captured on
October 20, 2026. These show review controls and rendering, not live PowerPoint
conversion or full Windows revision-engine parity. All four were visually
reviewed after replacing an incomplete component-cache capture.

![Native presentation comparison, paired-light](site/assets/presentation-review-paired-light.png)

![Native presentation comparison, paired-dark](site/assets/presentation-review-paired-dark.png)

![Native presentation comparison, overlay-light](site/assets/presentation-review-overlay-light.png)

![Native presentation comparison, overlay-dark](site/assets/presentation-review-overlay-dark.png)


## Open XML revision decisions and editable output

`PresentationPackage` reads bounded ZIP32 stored/DEFLATE members with checksum,
local/central header, path, duplicate and aggregate-size checks. It writes a
deterministic stored ZIP package while preserving opaque member bytes. ZIP64,
encrypted archives and unsupported compression are refused explicitly.

`PresentationRevisionReview` follows PresentationML slide IDs and per-slide
nonvisual shape IDs, compares shape XML and linked content, and records explicit
New/Base decisions. Added/deleted slides, slide ordering, shape/group changes and
stacking order are reviewable. Inseparable slide environment/reference changes
are a complete-slide decision. A shared presentation decision chooses the anchor
metadata/settings; dependency import allocates identities before traversing
cycles and rewrites part relationships/content types for the selected graph.
Groups are atomic shapes. Unsafe mixed decisions fail with a reason.

The native window connects selected/all accept/reject, undo/redo, unresolved and
unsaved state, a native Save Editable Copy panel, original/alias protection,
cancellation/draining and Discard/Cancel closure. Missing PowerPoint falls back
to package metadata review for `.pptx`/`.pptm`; an uncertain Office export does not
transfer its files into a disposable review. Base/New visual previews remain
source previews, not a rendered merged deck. Macro parts are preserved without
execution and require macro-enabled output. Invalidated package signatures are
removed and disclosed.

This advances the source revision workflow without claiming full Windows engine
parity. Binary `.ppt` normalization/save-back, merged result rendering, independent
group-child decisions, complete comment/animation/presentation-wide reference
combinations and physical Office reopening remain explicit gaps. Signed sandbox,
TCC/file grants, minimum-OS acceptance and App Store review remain unverified.

The package structure and separate slide/layout/master/theme/notes relationships
follow Microsoft's [PresentationML structure](https://learn.microsoft.com/en-us/office/open-xml/presentation/structure-of-a-presentationml-document)
and [slide document model](https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-presentation-slides).

Nonvisual slide/shape identities currently drive package matching. Regenerated
IDs are treated as deletion/addition; package-level visual identity rematching
remains open. Source raster review retains its separate visual anchors.

### Editable revision captures

Actual native light/dark windows with private synthetic Open XML packages,
accepted/rejected shape decisions and unavailable source previews. The saved
outputs were checked independently with ZIP/XML readers. These captures do not
show live Office rendering or a synthesized merged-slide preview.

![Editable revision decisions, light](site/assets/presentation-revision-light.png)

![Editable revision decisions, dark](site/assets/presentation-revision-dark.png)

[Revision-family evidence](qa/presentation-revision-family-2026-10-20.json) records
28 distinct focused Core methods, passing native workflows and independent ZIP/XML
output checks after the actual save-identity and retired-Quit repairs. These checks
do not establish live Office reopening or complete source parity.
