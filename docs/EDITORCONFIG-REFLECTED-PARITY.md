# EditorConfig reflected-file and pane ownership family

This partial source audit follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, specifically
`src/TortoiseMerge/BaseView.cpp::SetEditorConfigEnabled` (217–237),
`MainFrm.cpp::LoadViews`, `OnViewSwitchleft`, `CWorkingFile::SetFileName` and
`BaseView.cpp::SaveFileTo`. The shared file chooser is
`src/Resources/TortoiseMergeENG.rc` / `IDD_OPENDLG`; this review does not certify
that dialog or the complete editor.

The two-file editor now resolves each pane's nonempty reflected filename before
its actual working/rebound file. Switching sides changes that association with
the input, rather than leaving indentation settings attached to a stale temporary
filename. SaveFileTo changes its actual target; the source working-file setter
retains reflected metadata, which continues to win. Without reflected metadata,
the native rebound target supplies the new configuration path.

Three-file Base, Theirs, Mine and Merged panes now have independent targets.
Standalone files use their own input/output URLs; exported source panes use the
accepted rebound target. Repository/patch virtual sources retain their original
repository-relative path when they have no materialized working-file URL. All
four reflected names override these fallbacks independently. A missing reflected
leaf is valid: the official parser reads its containing configuration hierarchy
without creating or opening the leaf. Relative, NUL-containing or URI reflected
metadata fails instead of silently reading an unrelated temporary-file config.
Raw Unicode spelling, newlines and metacharacters remain literal path data.

A changed result filename changes its native pane display key. The model moves
that pane's EditorConfig toggle/loaded/default state to the new key, retires old
requests/epochs and re-resolves the current target. Source export/rebinding also
re-resolves enabled panes. Reload retains the current rebound/output identities.
These commands do not change source text, codec, line endings or editing history.

## Authorization and cancellation

A reflected path is not an access grant. Each editor uses the existing owned
EditorConfig reader and folder chooser, serializing its pane requests so only one
sheet/parser interval owns the window at a time. Acquired real folder leases
remain in that editor and are reused only if their actual scope covers another
target. No bookmark is persisted, and configuration-read grants do not become
implicit save authority. Retiring the editor clears those cached scopes; each
active parser still holds its own leases until actual drain.

Queued reads retain model/global operation accounting. Reload, toggle replacement
and Close cancel their own tokens, and late parser results cannot restore retired
pane state. Cancelling a folder chooser suppresses duplicate questions for the
same parent among the already queued reads. A later explicit read can retry;
other directories retain their own authorization requirement. Ancestors outside
the granted folder remain subject to the sandbox; this is not full ancestor-scope
or signed App Store acceptance.

## Save-property source audit and checks

`CEditorConfigWrapper` parses charset, ending, trailing-whitespace and final-newline
properties, but its only non-wrapper consumer in the pinned Merge source is
`SetEditorConfigEnabled`, which applies tab width and indent style. No new save
transform is introduced. Existing focused save-property checks and the new native
fixture retain exact UTF-8 bytes, trailing spaces and missing final newline through
Save As despite rules requesting UTF-16/CRLF/trim/final-newline.

`EditorConfigPathTests` covers reflected priority, absent leaves, actual-path
fallback, invalid metadata and exact Unicode/metacharacter paths. The new
`qa/editorconfig-reflected-native-2026-10-18.swift` fixture exercises the real
pinned parser, actual two/four-pane models, Switch Sides, SaveFileTo, result Save
As migration, source rebinding, Reload, one held authorization with scope reuse,
queued permission cancellation/retry and noncooperative parser retirement. The
parent batch records actual outcomes after grouped validation; fixture existence
is not evidence of a pass. Physical menu/focus/VoiceOver, minimum-OS/Intel,
signed sandbox authorization, complete source decoder behavior and full editor
visual parity remain open.

Actual build/check outcomes and remaining acceptance limits are recorded in the
[grouped batch evidence](qa/metadata-port-2026-10-18.json).
