# Edit Notes parity

Pinned reference: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Upstream comparison

`GitLogListBase.cpp` places Edit Notes after the revision mutation actions with
original `IDI_EDIT` artwork and excludes stash revisions and the adjacent stash
index parent. `GitLogListAction.cpp` invokes `CAppUtils::EditNote`, which checks
identity, reads the active default note and configures `IDD_INPUTDLG` with the Edit
Notes title/hint. Its optional checkbox is hidden. `InputDlg.cpp` supplies the
multiline editor, Undo, initial end caret, project minimum log length, resizable
layout, saved geometry and Control-Return acceptance. `Git.cpp` creates/replaces
the note using libgit2, including empty content.

## Native implementation

The revision menu now has Edit Notes with original `menuedit.ico`; selection,
busy/loading and stash/index-parent guards are mapped. Owned loading checks Git
identity and reads the exact note blob from the active notes ref, independently
of extra `notes.displayRef` output. Selection replacement, reload and close cancel
that read and reject stale responses. Read errors do not open a blank editor.

The native sheet maps the visible hint, plain multiline editor and OK/Cancel
controls. It seeds exact Unicode text, starts the caret at the end, enables Undo,
and disables quote/dash/text substitution. Command-Return and Control-Return
accept; Escape cancels. Project `tgit.logminsize` uses the shared existing scope
precedence and includes, also from HEAD in a bare repository. Minimum length is
measured in UTF-16 units, following the source editor. NUL/non-UTF-8 notes are
rejected rather than silently rewritten.

Saving writes exact UTF-8 bytes using `git notes add --force --allow-empty
--no-stripspace --file`, retaining the notes ref captured when the dialog opened.
Empty content creates an empty note rather than deleting its association. The
save is not interruptible: OK/Cancel and parent close remain guarded until it
finishes. The displayed notes aggregate is then reread into the existing entry
and message pane without reloading all history. A failed write keeps the draft
for retry; a successful write followed by a failed display refresh closes the
editor and explicitly reports that notes were saved. This recovery presentation
is a native adaptation of upstream's separate save/read error paths.

The CLI flags and default/display ref distinction are documented in the
[official Git notes manual](https://git-scm.com/docs/git-notes).

## Evidence and remaining work

See [the verification record](qa/log-notes-edit-2026-10-06.json) for focused core
and headless native checks. A headless receiver is not displayed dialog acceptance.

Still pending: displayed menu/dialog/keyboard/focus/Undo/resize acceptance in
light/dark, saved geometry, log-font/width settings, project issue highlighting,
link and spelling behavior, missing-identity Settings handoff, broader multi-ref
and malformed-note compatibility, and signed sandbox/App Store checks. Updating a
note does not rerun an existing Notes search; refresh its search when needed.
Concurrent external note changes are force-overwritten on OK, as upstream does.
The full Log/application port remains incomplete.
