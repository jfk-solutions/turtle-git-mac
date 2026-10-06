# Editing Git notes

Git notes add information to an existing commit without changing that commit.
TurtleGit displays them below the commit message in Log Messages.

1. Open Log Messages and select one commit.
2. Open its context menu and choose **Edit Notes**.
3. Edit the note. **OK** saves it; **Cancel** keeps the existing note.

Command-Return also saves. Escape cancels. If your project requires a minimum
message length, OK is disabled until the note meets it. Configure your Git name
and email before editing; TurtleGit reports an identity error when Git cannot
create the note. Editing is unavailable for stash rows.

The editor loads the active Git notes ref. Additional notes refs configured for
Log display are not combined into the editable text. It saves back to the ref
that was active when you opened the editor. Clearing the text saves an empty note;
it does not delete the note association. Notes are separate from the commit and
need their own fetch/push configuration; see the [Git notes manual](https://git-scm.com/docs/git-notes).

Wait for saving to finish before closing the editor. If the write fails, the draft
remains available for correction or retry. If the app says notes were saved but
could not be refreshed, refresh Log to read them again. Refresh an existing Notes
search after editing so its matches are recalculated.

The current implementation and outstanding UI verification are recorded in
[Edit Notes parity](EDIT-NOTES-PARITY.md). macOS screenshots for this workflow are
still pending.
