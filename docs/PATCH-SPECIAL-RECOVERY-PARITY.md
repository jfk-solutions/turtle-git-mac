# Binary, symbolic-link and deletion patch recovery

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`;
`Git/GitPatch.cpp::PatchFile`, `GitPatch.h::GetHasConflict`, and
`TortoiseMerge/MainFrm.cpp::PatchFile`, `OnEditUseTheirs` and `OnEditUseMine`.
This extends the [recorded-base recovery](PATCH-RECOVERY-PARITY.md) workflow.
It is a partial native replacement, not a claim of full image/editor parity.

When the current file rejects a patch, preparation retrieves the exact recorded
old blob (new blob for reverse application) and prepares the proposed result in a
private workspace. Binary bytes, symbolic-link pointers and missing endpoints
are preserved without passing them through a text merge. Unsupported link-target
encodings and unsafe paths remain errors; targets must be representable as UTF-8
macOS paths. Gitlinks and directories are not supported as editable file states.

The existing patch window presents Current working file and Patched recorded base
side by side. Each side names its path, type and size. Binary files have a bounded
hex preview; recognized image files can also show a static preview. A symbolic
link shows its target string without reading the target. An absent endpoint is
shown explicitly. This is whole-file selection, not an image merge tool.

Keep current preserves all captured current files and paths, including the original
path of a rename. Use patched selects the complete prepared contents, type and
path changes. The actions use the original Mine/Theirs icons and scoped native
Edit commands, with Control-F10 and Control-F9. A proposed deletion requires an
owned confirmation sheet whose default is Cancel. An explicitly selected empty
regular file remains a zero-byte regular file; the existing text-editor PatchSave
zero-line deletion policy is unchanged.

Both choices revalidate captured bytes, modes, permissions, absence and parent
paths before proceeding. A stale input requires a fresh review. Preview does not
change the worktree or index. Keep current never stages. Use patched observes the
existing optional Add preference for a newly created destination, and reports an
Add failure separately if the selected state was saved. HEAD and original patch
bytes are unchanged. An initially applicable review still requires Refresh before
adopting a conflict introduced after that review.

Choice callbacks and the deletion sheet retain the existing operation, access
grants and Quit ownership. Duplicate choices, selection, Refresh, Open/Reload and
ordinary close are disabled while pending. Cancel or forced retirement fences late
replies; an owned sheet is dismissed when its operation is cancelled. Completed
choices remain visible and cannot be repeated. A retained current version is
listed as “kept current”, distinct from “patched”. Patch all/selected never silently
choose a special-file side; later applicable files can still run.

Remaining work includes complete TortoiseIDiff interaction, backup/policy parity,
non-UTF-8 link targets, physical keyboard/menu/VoiceOver acceptance, signed Finder
and sandbox deployment, and App Store distribution. Grouped validation evidence
is recorded separately in `docs/qa/patch-special-recovery-2026-10-16.json`.

Actual native [light](site/assets/patch-special-recovery-light.png) and
[dark](site/assets/patch-special-recovery-dark.png) captures show the initial
binary-conflict state. Both were visually inspected before publication. They
precede the completed-row label correction; that correction does not change the
captured initial state. They do not certify every special-file view or gesture.

The grouped checkpoint passed 37 focused Core cases and eleven distinct native
case/engine runs. Both Git versions covered special and text recovery, native
file panels, per-file application and full import ownership; the shared menus
also passed. Two earlier special-file runs passed before the completed-row label
repair. All thirteen owned receiver processes were reaped and independently
absent. Debug builds passed; their existing exit-code-zero output diagnostics
are recorded in the QA record. No full hosted CI pass is claimed.
