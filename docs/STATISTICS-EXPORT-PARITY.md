# Statistics save and calculation family — October 21, 2026

This continues the [Statistics review](LOG-STATISTICS-PARITY.md), using pinned
TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`, dialog `IDD_STATGRAPH`.

## Source contract and native adaptation

`src/TortoiseProc/StatGraphDlg.cpp` initializes the six metrics, four options,
five source graph buttons and remembered graph page in `OnInitDialog`
(lines 140–307). `ShowLabels` (310–365) separates summary and graph controls.
Those controls, chart styles, source palette, author slider and preference keys
already exist in the native dialog and are retained in this batch.

`OnFileSavestatgraphas` (1445–1466) uses Pictures and All Files, with `.wmf` as
the extensionless Pictures default. `SaveGraph` (1469–1535) renders the current
graph viewport and chooses PNG/JPEG/BMP/GIF by the filename, appending `.jpg` for
unknown extensions. `src/Resources/TortoiseProcENG.rc`, `IDS_STATPICFILEFILTER`,
defines the two source filter groups.

The native sheet now uses Pictures and All Files. Supported typed suffixes select
PDF/PNG/JPEG/BMP/GIF regardless of the filter. Changing filters preserves the
filename. Pictures supplies `.pdf` when there is no extension, an explicit macOS
adaptation for Windows vector output; All Files supplies `.jpg`. Unknown suffixes
get `.jpg` appended. `.wmf` and `.emf` are explicitly refused with PDF guidance.
No Windows metafile graph writer is claimed. This is independent of the WMF/EMF
image comparison decoder.

The panel normalizes the filename before platform overwrite confirmation and file
access authorization. Acceptance validates the exact final URL and refuses an
unnormalized URL rather than exporting to a different sibling. Core destination
resolution preserves literal spelling, including composed/decomposed names.

## Captured workflow and lifetime

Save Graph captures the graph, metric, style, viewport and appearance before
opening its owned sheet. The accepted filename and encoder are frozen in the
single accepted reply. Old, duplicate, closed-owner and Quit-invalidated replies
cannot launch another export. Sheet reply processing waits for actual detachment
before rendering or publishing an error. An export error is another owned sheet,
with the same detachment accounting.

Interactive writing holds the exact destination's scope, coordinates replacement,
stages bytes in a same-volume Foundation replacement workspace, checks
cancellation during writing and immediately before atomic publication, and cleans
its workspace on every exit. An existing destination survives cancellation before
publication. Once publication succeeds, a later cancellation does not report a
failed save. Signed destination-only grants still require installed acceptance.

Ordinary close during calculation/writing requests cancellation and waits. Forced
close retires UI and dismisses owned sheets while retaining the controller, access
lease and Quit accounting through actual worker/sheet drainage. A closing or
retired Statistics controller cannot be reused by Log; an old close callback
cannot clear a replacement controller.

Calculate captures the originating preferences' diff backend once for its whole
read. Partial cancelled results are discarded. The previous complete summary is
retained; retry is available after the worker finishes. Form actions carry the
current revision, including Cancel and Close. Quit confirmation invalidates those
receipts and cancels outstanding work.

## Validation and remaining work

The [dated grouped checkpoint](qa/statistics-export-family-2026-10-21.json)
records 23 focused Core methods, the Debug app build and ten native case/engine
pairs passing across the recorded repairs. The six new export cases cover both
Git engines; the existing calculation/ownership and author-identity families add
two pairs each. The first app build required explicit Swift capture references;
new and older fixture repairs retain the behavioral assertions and accommodate
actual sheet drainage. Only affected native workflows were repeated after those
fixture repairs; Core and the successful new export group were not rerun.

All twelve receivers, including failed attempts, were reaped and independently
absent. No new screenshots were taken; earlier chart captures do not prove physical
save-panel behavior. Help and localization resources were regenerated, and the
site rendered with its two documentation/link checks passing. Earlier Statistics
checkpoints cover their recorded sources and do not prove these new filter,
atomic writer and ownership rules.

Still open: physical save/overwrite and modifier behavior, VoiceOver, exact Windows
font/geometry/shading identity, large-repository performance, WMF/EMF graph writing,
installed signed sandbox replacement on deployment volumes, current complete
hosted integration and whole-dialog acceptance. This family does not certify the
complete Statistics dialog or application.
