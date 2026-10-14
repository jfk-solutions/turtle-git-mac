# File Move and Move/Rename parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Commands/DropMoveCommand.cpp` and `Commands/PasteMoveCommand.cpp`.
This is a native app adaptation of the same-working-tree move workflow.

## Implemented workflow

Commit and Working Tree versioned-file menus offer Move with the original Rename
artwork. Multiple captured paths retain their selection order. The native window
provides a destination folder, a single-item Rename while moving option, Move and
Cancel. Its owned folder picker validates the same working tree before acceptance.
A collision opens a Rename-style name sheet; invalid names retain the same sheet.
The validated name returns an immutable move plan before mutation.

Actual `git mv --` preserves separate index and working-file contents, directory
children and symlink identity. Literal Unicode, newlines and leading dashes remain
arguments. Administrative paths, nested repositories, outside folders, occupied
names and self-descendant moves are rejected. Case-only renaming may use `-f` only
for the existing case alias. Prepared source metadata, index entries and HEAD are
checked again before execution; these checks do not provide a filesystem transaction.

Ordered progress streams bounded Git output. Per-item failures offer Ignore or
Abort, with Abort the default. Earlier successful moves remain applied when a later
item fails or the user cancels, matching upstream's nontransactional sequence.
Captured parent lists remap paths and refresh after the operation. The access lease,
cancellation token, child prompts and active-operation counters survive until
owned work settles; retired windows suppress late callbacks. Move does not commit.

The macOS window retains a Close result view instead of upstream's automatically
ending shell progress dialog. Folder selection replaces Windows drag-destination
input. The ordinary Finder source menu mask is unchanged by this app command.

## Validation and remaining work

The batch includes real-Git Core cases and a native receiver for streamed
cancellation, collision correction, staged/working byte preservation, ordered Ignore
recovery and forced retirement. The Debug build, 21 related Core tests and four native cases (Move and Commit file
workflows with system and bundled Git) passed at the grouped checkpoint. The initial
compile failed because the name callback referenced a nonoptional local window;
that reference was corrected before the successful repair. All four owned receiver
processes were reaped. See [batch results](qa/file-move-2026-10-14.json).

Finder drag menus, clipboard Paste Move, Drop Copy/Add, cross-repository copy,
submodule/gitmodules edge cases and complete shared Rename-dialog consumers remain
open. Displayed picker, keyboard, light/dark, parent selection restoration and signed
sandbox/Finder acceptance still require physical QA. This does not certify full
Rename, shell or TortoiseGit parity. See [Rename parity](RENAME-PARITY.md).
