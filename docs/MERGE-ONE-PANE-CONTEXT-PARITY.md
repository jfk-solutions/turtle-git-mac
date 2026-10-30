# One-pane context commands

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.
The audit covers `LeftView.cpp::AddContextItems`,
`BaseView.cpp::OnContextMenu/AddCutCopyAndPaste/UseViewBlock`,
`RightView.cpp::UseLeftBlock/UseLeftFile`, and the one-pane `LoadViews` branch.

A combined viewer is the source **left view**, even though its editable output
is Mine. Its context menu now uses the left-role Use this block/file labels and
does not expose the right-view Mark/Unmark/Leave only marked commands.
Copy/Cut/Paste precede writable whitespace/line-ending/encoding choices in
combined mode. Read-only combined views show Copy and omit Cut/Paste,
whitespace conversion and line-ending mutation commands. Ordinary output-encoding
conversion stays disabled. The later [input-encoding family](MERGE-INPUT-ENCODING-PARITY.md)
retains the File Encoding menu for source Control-reinterpretation and adds an
explicit Reload with encoding submenu available on read-only inputs. Encoding
items follow the source's nine-choice order and carry explicit format identities,
so reordering cannot dispatch the wrong enum.

Upstream still appends transfer items in the combined left view, but the
handlers address the hidden right view whose data/working file are cleared by
LoadViews. The Mac page disables these two-view commands rather than executing
them against Mine. Block/file transfer and mark handlers reject combined mode
at the model layer too, including stale menu dispatch. Toolbar transfer actions
use the same gate. This corrects the earlier generic right-pane menu behavior,
which could replace Mine with Base from a combined list.

Each menu retains a clipboard command target capturing its own pasteboard and
a weak editor. Copy includes selected removed payload. Cut/Paste operate in
Mine coordinates using the existing combined editing/Undo transaction. Opening
a newer menu does not change an older menu's clipboard destination. Keyboard
Copy still uses the normal system pasteboard. Closed/retired editors and busy or
sheet-owned contexts refuse clipboard commands; retired models no longer allow
editing or transfer dispatch.

The native receiver uses private named pasteboards, real menu dispatch and
actual editor transactions. It checks removed-row copying, cross-menu captured
clipboard identity, Cut/Paste and Undo, source format order/action identity,
read-only command omission, hidden-opposite no-ops, late retirement, and saved
inputs unchanged. The complete grouped Merge receiver retains all previous
families.

Remaining: physical popup anchoring/focus/keyboard/VoiceOver acceptance,
source row-state and selection aliases, exact full menu contents/spacing and
light/dark captures. Mac navigation/Save As/Undo/Redo additions remain alongside
the source commands. The October 16 [in-place editing continuation](MERGE-ONE-PANE-PARITY.md) adds
Edited-row retention for typing and ordinary clipboard edits. Signed/minimum-OS
acceptance remains open. No full TortoiseMerge certification is
claimed.


## Evidence

Unsigned Debug builds passed. One fixture frontend linked the existing app
objects; all fourteen Merge receiver families passed in one owned process.
No Core suite was rerun for the native-only menu changes. The check touched only
private named pasteboards and scratch files. See
[the batch record](qa/merge-one-pane-context-2026-10-12.json).
Hosted CI and physical/signed acceptance remain unproven.

## Read-only encoding fixture correction — October 31, 2026

Hosted run 41129980751 on source `87701028` exposed an older expectation that
read-only mode removed File Encoding entirely. The fixture now follows the
implemented input-reload contract above; production behavior is unchanged.
An explicit unmodified event makes menu/action checks independent of the user's
Control key. It retains Cut/Paste/EOL/whitespace refusal, nine ordered encoding
choices, disabled output conversion, enabled input reload, stale clipboard/edit/
reload guards and unchanged saved bytes.

The focused `scripts/test-native-merge-regex.py --one-pane-context-only` check
passed; owned receiver 57794 was reaped. See
`build/qa/readonly-one-pane-contract-2026-10-31.log`. No LFS/mail batch, app build
or Core suite was rerun; full hosted, physical and signed acceptance remain open.
