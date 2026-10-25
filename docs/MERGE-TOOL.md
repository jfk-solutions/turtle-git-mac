# Use TurtleGitMerge with Git

TurtleGitMerge can open native two-file comparison, three-file merge, and patch
review directly from a terminal. The waiting wrapper is
[`scripts/turtlegit-merge`](../scripts/turtlegit-merge). By default it uses
`/Applications/TurtleGit for Mac.app`; set `TURTLEGIT_APP` to another app bundle,
or `TURTLEGIT_MERGE_EXECUTABLE` to a development executable.

## Choose a comparison interface

The **Interface** selector in text comparison and conflict windows offers
**Classic** (the default) or **P4Merge-style**. The choice is shared and saved
for later diff/merge windows. Both interfaces use the same comparison, editing,
Undo/Redo, source-choice and save operations.

The alternative two-file view connects changed blocks with curved colored bands.
Three-way merge follows the four-pane P4Merge arrangement: **Theirs / Base /
Yours** above an editable **Merge result**. Purple identifies Theirs, yellow the
common Base, and green Yours. The source panes show their original lines, so
insertions and deletions have different heights joined by curved ribbons.

The compact toolbar and flat file headers leave more room for text. Unresolved
regions show the source candidates in yellow, purple and green, joined to the
result by a colored flow gutter. This is a display projection: Git conflict
markers remain in the underlying result, and Save still warns about unresolved
conflicts. Typing within a candidate region resolves that region to its visible
contents plus your edit; Undo restores its conflict state.

The compact colored source buttons beside each result chunk are toggles. Select a source to
include it; select it again to remove it. You can combine sources in click order.
Identical text is included once. The three **Use whole file** controls replace
the result with that complete source. All choices and manual result edits support
Undo/Redo. A gray result band identifies manually edited text. Save uses the same
output target, encoding checks and conflict-resolution safeguards as Classic.
The source/result divider position is saved independently of the classic layout.

Changing the interface preserves the current result. If an edit crosses several
engine regions and destroys their exact result mapping, that region's source
buttons are disabled; Undo or reload restores the mapping. P4Merge-style is a
TurtleGit presentation inspired by Perforce's tool, not the Perforce application.

Use the wrapper's absolute path in your Git configuration. For example, after
placing it at `~/bin/turtlegit-merge`:

```sh
git config --global diff.tool turtlegit
git config --global difftool.turtlegit.cmd '"$HOME/bin/turtlegit-merge" --base "$LOCAL" --mine "$REMOTE" --readonly'
git config --global merge.tool turtlegit
git config --global mergetool.turtlegit.cmd '"$HOME/bin/turtlegit-merge" --base "$BASE" --theirs "$REMOTE" --mine "$LOCAL" --merged "$MERGED" --saverequired'
git config --global mergetool.turtlegit.trustExitCode true
```

Then use `git difftool` or `git mergetool`. Each command starts its own tool
process, waits for the editor to close and returns its result to Git. A three-file
merge reports success only after the result was saved, has no remaining conflict
markers and has no newer unsaved edits. Discarding a requested merge result does
not mark the Git merge successful. Saving a separate merged output preserves the
Base/Theirs/Mine inputs. No automatic staging occurs in this standalone editor.

Direct examples:

```sh
~/bin/turtlegit-merge --base old.txt --mine new.txt --readonly
~/bin/turtlegit-merge --base base.txt --theirs remote.txt --mine local.txt --merged result.txt --saverequired
~/bin/turtlegit-merge --diff change.patch --patchpath ./target
~/bin/turtlegit-merge --diff change.patch --patchpath ./target --reversedpatch
~/bin/turtlegit-merge --createunifieddiff --origfile old.txt --modifiedfile new.txt --outfile change.patch
```

Standalone requests open only the requested Merge editor or chooser, with its
File, Edit, Navigate, View and Help commands. They do not open a repository
workspace or start Finder monitoring. A Finder action or patch-file open received
while this tool process is running is handed to a new workspace process. It does
not replace the Git editor or alter the Git result. Tool exit waits for an
accepted workspace launch and any owned launch-error acknowledgment. The new
workspace still performs its normal repository/file authorization. With no file arguments the tool opens its
native Open dialog. A patch without a
target asks for the target directory; a target without a patch asks for the patch.
`--wc` uses a supplied patch's containing folder as its default target. Read-only
and Blame requests retain navigation while refusing file mutations. `--line` is
one-based. Descriptive names such as `--basename` and `--mergedname` affect
captions. Reflected names remain display metadata, never input/output paths or
access grants. The editor's **Create unified diff file** command uses Git-relative
reflected header names when both names belong to the same working tree; the
separate `--createunifieddiff` command retains its ordinary generated headers.
File/Open resets descriptive labels and the merged-output target while preserving
read-only/Blame policy and reflected names for the replacement document.

`--blame` compares the fixed-width metadata-prefixed text format used by the
source tool. Where source encoding, line endings or comparison options require
conversion, matching omits the first 66 UTF-16 code units of lines longer than
66 units. The displayed source text and line numbers remain intact. Plain UTF-8
or ASCII inputs may bypass that source conversion path. This option does not
request Git history or add Blame columns.
Missing merge inputs are shown as empty panes. A file appearing or changing while
an edit is open requires Reload before it can be accepted as the new baseline.

A sandboxed App Store build requires file/folder authorization for command-line
paths, including a missing output's parent directory. A terminal path is not a
security-scoped grant. Canceling an authorization chooser ends the waiting
command unsuccessfully without a permission-renewal error. A wrong selection can
be corrected in the chooser. Interactive Open authorizes typed role paths before
checking their existence; it still rejects missing inputs after authorization.
The tool retains its input/output grants until the command and owned panels
finish. See [authorization behavior](MERGE-AUTHORIZATION-PARITY.md) for the
connected workflow and verification scope. Store distribution and physical
signed acceptance remain separate release checks.

`--deletebasetheirsmineonclose` is intended for disposable tool inputs. It removes
only explicitly supplied input objects whose identity and contents still match
the captured input, after owned editor work drains; it preserves changed inputs
and the merged output. It never removes a symlink target. This is a deliberate
macOS ownership adaptation to the source cleanup flag.

In a three-file merge, **View → Line diff bar** can display a compact Theirs/Mine
comparison below the panes. It follows the inspected line and always shows
whitespace and inline differences, even when those markers are hidden in the
editors. The strip preserves your selection and keyboard focus. Three-file
loads initially hide it; changing Locator visibility restores its saved choice.
**View → Line numbers** changes the current window's numbering without changing
the Merge Editor Settings default.

See [the source entry review](MERGE-TOOL-ENTRY-PARITY.md) and
[two-file behavior review](MERGE-TOOL-COMPARISON-PARITY.md) for remaining states and
platform differences. This does not certify complete TortoiseMerge parity.

The P4Merge-style toolbar has separate previous/next controls for all differences and unresolved conflicts (red arrows). Resolved chunks are skipped by conflict navigation. It also offers Find, Go to Line, line numbers, whitespace and word wrap. Included source symbols use their source color; excluded symbols are filled gray. Identical alternatives sit together with an = between them and toggle the shared text once. A + or − badge indicates an insertion or deletion relative to Base, independently of selection. Hovering shows the source, identical peers and a hand cursor. Each chunk has one aligned row on a neutral gutter. Highlight bands continue through the line-number margin, with overlay scrollbars keeping the connector edges clear.
