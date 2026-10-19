# Three-way row states and visibility

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This batch ports the separate state and hide metadata of TortoiseMerge's
three-way view records through initial comparison, result projection, edits,
source choices, Undo/Redo and synchronized native folding.

## Source behavior

`TortoiseMerge/DiffData.cpp:705–716` emits common Mine, Theirs and result rows as
Normal + Hidden, even when comparison options made unequal original payloads
compare equal. This differs from the two-way FilteredDiff path at lines 463–532.
The native authoritative two-way `SubversionComparisonPresentation` already
implements that distinction; its interim coordinate alignment is not the final
comparison result.

The three-way ignored-conflict post-pass at lines 969–1008 changes source rows
to ConflictAdded and the result to Conflicted_Ignored. `ViewData.h::SetState`
changes the state without resetting its hide flag. Thus an ignored common
conflict retains Hidden while an ignored identical-added change retains Shown.
The ignored range remains unresolved metadata even when collapsed: Save still
warns and Mark as resolved remains unavailable. Three pairwise different original
payloads or three pairwise different endings identify that conflict; differing
in mixed channels alone does not.

Noncommon view records also retain explicit flags. The unchanged Mine partner
of a Theirs-only removal is Normal + Shown (`DiffData.cpp:905`), while the
unchanged Theirs partner of a Mine-only removal is Normal + Hidden (line 940).
`HideUnchangedSections` starts from the result's HideState and synchronizes both
source panes. A color or Normal-state predicate cannot reconstruct this map.

`BottomView.cpp::UseBlock` copies the complete source view record before resolving
its state. Source choices therefore retain copied visibility, including a Hidden
ignored common row. Newly typed result records are Shown. These metadata changes
are never serialized into repository files or staging entries.

## Native implementation

`SubversionMergePresentation` assigns explicit three-way states and flags instead
of inferring a filtered color from raw byte inequality. Aligned result records,
serialized result runs and their UTF-16 navigation ranges retain hide metadata
independently of state. Adjacent equal-state runs with different visibility do
not compact together. The source-aware result initializer retains those flags
when opening a merge; free-edit fallback keeps a line shown if any part is shown
or has no checked hidden mapping.

Aligned result edits, whole-view transformations and copied source blocks preserve
untouched flags and source coordinates. Manual replacement creates Shown records.
The existing document history stores both row records and result runs, so Undo
and Redo restore the metadata together with text and unresolved ignored ranges.
Same-byte resolution still participates in the existing dirty/Save transaction.

`TextConflictWindow` derives the shared fold map from result hide flags and
installs the same aligned visibility in all three panes. Serialized fallback uses
checked result anchors and independent result-run flags. It does not use row color
to force a conflict visible or hide an unchanged partner. Explicit **Continue
resolving conflicts** can reveal a collapsed ignored conflict without accepting
it; ordinary visible-block navigation retains its existing source behavior.
Comparison options, palette preferences, dirty Save/Don't Save/Cancel ownership,
helper cancellation and exact captured input bytes retain their existing owners.

## Evidence and remaining work

[The batch checkpoint](qa/merge-threeway-hide-2026-10-19.json) records the executed
Core and native scopes, failures, repairs and owned cleanup. Core cases use actual
engine plans for whitespace, endings, case, comments, regex and combinations,
plus independent source-state/visibility assertions. Native cases inspect actual
text-storage colors in both appearances, synchronized collapse/reveal, edit and
choice history, warning ownership and byte preservation with both Git engines.
The record distinguishes checks run on the final implementation from earlier
attempts and retained checks.

This does not certify the complete Merge editor, every source whitespace enum,
all Windows locale behavior, physical mouse/keyboard/VoiceOver interaction,
minimum-OS rendering, signed Finder integration or App Store distribution.
Existing format, source-coordinate, external-reload and whole-dialog acceptance
requirements remain separate.
