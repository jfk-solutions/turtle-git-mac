# Merge command frame continuity

This partial workflow review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseMerge/MainFrm.cpp::OnFileOpen`, `CWorkingFile::SetFileName` and
`CWorkingFile::TransferDetailsFrom`. The native Open dialog corresponds to
`src/Resources/TortoiseMergeENG.rc` / `IDD_OPENDLG`.

File/Open prepares a fresh native document before transferring the original
window. The original command's readonly and Blame policies survive the transfer.
The three-file model now carries Base, Theirs, Mine and Merged reflected names
independently from its working URLs, matching the frame metadata that
`SetFileName` leaves intact. Two-file replacements retain their corresponding
Base/Mine metadata in the current pane orientation; Switch Sides updates that
orientation before the next Open. Returning to three files preserves those names
and restores the Theirs/Merged names not displayed by the two-file editor.
The new document does not inherit the old descriptive labels, explicit output,
required-save obligation or initial line. It uses the newly chosen input files.
Reflected captions never select those files or authorize access to them.

The shared diff engine receives the actual Base/Mine/Theirs encodings when
reading working files, repository stages, rebound sources or patch recovery.
This preserves the source's Blame conversion decisions after Reload and Open,
without keeping a stale BOM/encoding mask from a previous document. Original
text remains available for source display and ordinary saved content.

The launch session follows its currently adopted controller. A discarded
original Git result still fails the original command, even if the replacement
editor closes cleanly. Retired reads and exports drain before session completion.
The new native continuity fixture performs an actual three-file → two-file →
three-file handoff in one native window, checks reflected names versus input
URLs, rejects readonly Save, preserves all input/output bytes and waits for
current/retired work to finish. Its existence alone is not a passing checkpoint.

[Batch evidence](qa/merge-frame-2026-10-18.json) records the combined checkpoint
with [Blame matching](MERGE-BLAME-PARITY.md),
[reflected patch exports](MERGE-REFLECTED-PATCH-PARITY.md) and
[standalone presentation](MERGE-TOOL-PRESENTATION-PARITY.md).
Physical focus/VoiceOver, complete displayed source parity, reflected-path
EditorConfig semantics, signed sandbox terminal authorization and minimum-OS/
Intel acceptance remain separate work. This review certifies no whole dialog or
whole-app completion.
