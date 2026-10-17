# Dropped-file transfer workflow

Pinned source: `src/TortoiseShell/ContextMenu.cpp` active drop-menu clauses and
`DropMoveCommand.cpp`, `DropCopyAddCommand.cpp`, `DropCopyCommand.cpp`,
at `7338078f8ddd924b8cddee35f512f2286072136d`.

The active pinned menu offers Move and single-item Move/Rename for versioned
same-worktree sources; otherwise its transfer action is Copy and Add. Copy and
Copy/Rename entries are commented out. The legacy DropCopy implementation also
calls Git add after successful file copies; it is not an unstaged-copy workflow.

The native workspace and Working Tree file lists accept local file URL drops.
A retained native sheet presents the captured source paths and destination folder,
with original Move/Add artwork. Eligible moves expose Move and, for one item,
Move/Rename; external/unversioned selections expose Copy and Add. An owned folder
picker supports another same-worktree destination. Bare repositories, administrative
folders and nested child repository destinations are rejected by the shared Core
folder validator. Text-only drops and empty/overlarge provider sets are refused.

Receiving and choosing a drop has no Git or copy effect. Accepted choices hand
captured URLs, repository permission and destination to the existing Move or
Copy/Add window. Move/Rename opens its validated name child when execution starts.
Drop Move retains source ordered Ignore/Abort recovery; clipboard Paste Move keeps
its distinct stop-on-error behavior. Copy/Add retains recursive copy, overwrite/
keep/cancel, copied Git metadata handling, ordered ordinary staging and cancellation.

Provider reads and destination validation own cancellable tasks and tokens. The
original repository permission and active counter survive forced sheet/parent
closure until work settles. Late URL/destination replies cannot publish or hand off
an action. Quit remains blocked while preparation or the choice sheet is owned.
Source authorization remains in the receiving Copy/Add operation, including its
App Store grants for external sources. Other workspace repositories cannot retarget
a captured Working Tree drop.

This is a native application adaptation of the Windows drag context menu, with
an explicit receiving sheet followed by the existing operation dialog. Installed
Finder right-drag menus are not implemented by this sheet. Physical drag/picker/
keyboard/theme acceptance, signed provider delivery/security scopes and complete
upstream shell parity remain open. Commit's own drop-to-Add selection workflow is
separate and retains its current behavior. Grouped validation follows implementation.

Debug and six grouped native cases passed at the first checkpoint with both Git
engines. Existing Move/Copy regressions were included; Core was unchanged and
not rerun. Every owned receiver was reaped. See
[batch evidence](qa/file-drop-transfer-2026-10-14.json).

The connected [exact transfer identity continuation](FILE-TRANSFER-PARITY.md#exact-movecopyclipboarddrop-identities--october-17-2026) covers source rows, clipboard/drop capture, working-path resolution and Move/Rename/Copy/Add targets. Physical/signed and full dialog acceptance remain partial.
