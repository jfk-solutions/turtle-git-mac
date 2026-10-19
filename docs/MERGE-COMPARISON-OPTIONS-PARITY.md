# Merge comparison options

[Grouped lifecycle evidence](qa/merge-comparison-lifecycle-2026-10-16.json) records
59 focused Core checks, ten native editor workflows, source/fixture repairs and
owned cleanup. This remains a partial port.

## Shared Reload and pane-switch decisions — October 17, 2026

Explicit Reload and switching between two panes and the combined view now use
that same owned Save/Don't Save/Cancel transaction. Both dirty panes offer Save
left, Save right, Save both, Don't Save and Cancel, with Save both as the default.
Saving only one pane reloads the other from disk. Cancel preserves both drafts,
the view preference and chronological Undo. Failed Save retains the current view.
The accepted continuation waits for an attached native sheet to end before
starting its Save or reload; forced closure removes its observer and refuses
late answers. Duplicate answers cannot start a second reload.

The model now clears its shared UndoManager directly, even while split/combined
native editors are being replaced or no editor callback remains. Exposed Undo
and Redo flags reset with it. Combined reload selects Mine, and cancelled engine
requests cannot publish a replacement alignment. This follows pinned
MainFrm::OnFileReload, OnViewOnewaydiff, CheckForSave and LoadViews/CUndo::Clear.

The recorded hosted moved-block discard failure is not reproduced by the local
pre-change diagnostic. These changes address related ownership/history gaps;
a current complete hosted pass is still required before claiming that failure
resolved. See [batch evidence](qa/merge-reload-family-2026-10-17.json).

## Owned Save and reload — October 16, 2026

Two-pane and combined option/active-regex changes now follow the pinned
MainFrm::CheckForSave(Options) → LoadViews sequence. A dirty editor owns a native
Save / Don't Save / Cancel sheet. When both panes are dirty it offers Save left,
Save right and Save both, defaulting to both; unsaved panes reload from disk.
Cancel retains the draft, selected options and Undo. A failed or cancelled Save
does not apply the pending option/filter or persist its new preference.

Accepted changes reload the current file targets and clear the shared Undo/Redo
history, as LoadViews clears CUndo. Old row snapshots therefore cannot be
restored into the new option context. The selected change is captured until its
once-only answer/Save settles. Question/Save intervals block editing, duplicate
changes, normal Close and Quit. Forced owner closure settles the sheet, cancels
owned work and refuses late answers. An active regex definition changed or
removed in Settings uses the same dirty workflow; unrelated definition changes
only refresh available choices.

These two-pane rules supersede the earlier draft-recomputation description below.
Three-pane dirty option changes retain their existing behavior. Source option
preferences are written before the accepted two-pane reload, matching the pinned
handlers; a later read/engine failure can leave the new option selected with an
error. Complete failure UX, physical sheets/VoiceOver and signed acceptance remain
open.

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`. Reviewed
DiffData.cpp options, MainFrm.cpp comparison handlers, SetMainPage.cpp defaults,
FileTextLines.cpp conversion ordering and Subversion's normalize_buffer.

Both native comparison windows provide Compare whitespaces, Ignore whitespace
changes, Ignore all whitespace changes, Ignore line endings and Ignore case
changes. Merge Editor settings exposes the same defaults through its existing
Apply/Cancel transaction. Source defaults are compare whitespace, case-sensitive,
and IgnoreEOL=true. Low-level engine APIs retain an explicit exact mode for
callers that need byte/EOL-sensitive comparison.

The three whitespace choices preserve whitespace, collapse runs of ASCII
space/tab/VT/FF, or remove them. A run is distinct from absent whitespace in
Ignore changes mode. Non-ASCII spaces are retained. Regex replacement happens
before whitespace/case normalization. Line-ending comparison normalizes each
recognized ending to LF when requested, retaining the distinction between an
ended final line and no final newline. Case uses macOS Unicode lowercase with
the POSIX locale, not full case folding. Windows locale/Unicode edge equivalence
remains unverified.

Comparison keys are separate from original text and encoding metadata. Filtered
rows retain original bytes, numbers and the green palette. Block transfers use
original source content and existing target-ending normalization. Two-pane
changes originally recomputed current drafts with debounce, cancellation and
selection/mark remapping; the owned Save/reload continuation above replaces that
behavior for user option/filter changes. Three-pane changes use dirty Save/discard/Cancel before regeneration;
Cancel or an engine failure retains the prior option/result. Preferences are
saved only after successful three-pane regeneration. Saved settings become the
defaults for subsequent explicit Reload and new windows.

Pinned comment profiles and source stripping now feed both viewers; see
[comment comparison](MERGE-COMMENTS-PARITY.md). Remaining: profile overrides,
full source Unicode locale behavior,
source whitespace-difference visibility categories, all ending/regex edge cases,
physical menu/settings interaction, complete visual captures, signed helper and
App Store acceptance. This advances the complete port without certifying all
TortoiseGitMerge comparison or settings behavior.

Grouped evidence: 28 Core tests passed, the unsigned Debug build completed with
existing diagnostics, and both native receivers passed together in one frontend
compilation/process. They verify Cancel versus successful persistence, option
choices and the existing native editing/save/cancellation paths. Settings controls
compiled; their physical Apply/Cancel interaction remains unverified. All owned
windows/helpers exited. See `qa/comparison-options-2026-10-12.json`.


## Three-way common rows and independent visibility — October 19, 2026

The [three-way state/visibility continuation](MERGE-THREE-WAY-HIDE-PARITY.md)
keeps normalized common merge rows Normal + Hidden rather than assigning the
two-way green filtered role. Ignored conflicts promote state without discarding
source hide flags. Explicit flags survive result projection, source choices,
manual edits and document history; result-led folding synchronizes all panes.
The two-way authoritative presentation was already correct and is retained.
See the continuation and its checkpoint for actual checks and remaining limits.
