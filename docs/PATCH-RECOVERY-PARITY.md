# Recorded-base patch recovery

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`Git/GitPatch.cpp::PatchFile`, `GitPatch.h::GetFailedHunks/GetHasConflict`,
`TortoiseMerge/MainFrm.cpp::PatchFile` and `FilePatchesDlg.cpp` initial row states.

Upstream first tries the working file, then retrieves the version named by the
patch and patches that base. It opens the recorded base, current working file and
patched base as a three-way merge. The native patch viewer now follows that flow.
It never substitutes HEAD or a guessed revision when the recorded object is absent.

Preparation copies captured inputs to a private workspace and uses the original
reverse/strip/include and apply-policy settings. If direct application fails, Git
index headers supply the exact old blob (new blob for reverse patches). Locally
available blob bytes seed that workspace; only its files are patched. The caller
retains current working-file snapshots for later Save validation. No application,
index change, commit or remote fetch is part of Preview. Recorded-base text renames
and executable modes use the same captured source/destination path machinery.
Missing versions and unsafe paths remain errors rather than approximate merges.
[Special-file recovery](PATCH-SPECIAL-RECOVERY-PARITY.md) now provides explicit
whole-file choices for binary, symbolic-link and deletion conflicts.

The list now has initial Ready/Conflict/Error classification. Like the pinned
source's `rejects` flag and nonempty base-path test, Conflict means recorded-base
recovery was necessary; it is not a numeric count of unresolved hunks. A successful
whole-patch check establishes Ready without preparing every file twice. Otherwise
per-file preparation establishes the rows, with owned cancellation. Completed paths
are excluded from repeated inspection. An initially applicable review still refuses
later conflicts until Refresh; Save always validates its own captured inputs.

Preview embeds the existing Subversion-backed three-pane editor beside the file
list. The native Merge toolbar is rebound to that editor, including side choices,
Undo/Redo, Find, source comparisons, Save As and view controls. Captions identify
Current working file and Patched recorded base. Source block choices retain engine
row metadata and exact Undo; remaining conflicts require explicit Save confirmation.
Mark as resolved is disabled because this is patch review, not Git index resolution.

Save generates the existing guarded edited-result patch from captured current files
to the reviewed result. It validates bytes, modes and paths before application;
source patch bytes stay unchanged. A completed merge retains its clean preview and
clears its edit history; another Save or edit is refused. The existing optional Add
preference applies to explicitly saved new files. A zero-line result follows
PatchSave's existing deletion semantics. Full backup/empty-file policy equivalence
with every non-patch editor remains a separate review requirement.

Patch all/selected continue in source file order. Directly applicable files use the
existing application path. A clean recorded-base merge saves both independent
changes without staging. Conflicting or ignored-conflict results remain unwritten
and point to Preview; later files still run. The original atomic checked-file Core
API stays distinct. Dirty Cancel/discard/save, Open/Reload, parent operations, Quit,
forced retirement and late result fencing share the viewer/editor owners and grants.

[Grouped evidence](qa/patch-recovery-2026-10-16.json) records the actual build,
Core/native scope, repairs and captures. This remains partial upstream parity:
missing base objects require the appropriate local history, and full physical toolbar/menu/input,
large-patch performance, signed Finder/sandbox and App Store acceptance remain open.

The grouped checkpoint and focused repairs cover **31 distinct passing Core
cases** and **nine passing native case/engine runs**. Core
checks include exact conflict preview/save, reverse blob identity, clean context
merging, rename/mode preservation, ignored-conflict refusal and stale/unsafe paths.
Native recovery ran on both Git versions, alongside retained panel, per-file,
full import/editor/ownership and shared-menu workflows. Initial stale-review,
error-type and toolbar compile repairs are recorded; the first native fixture
needed current-conflict reselection after Undo. No action fence was weakened.
All owned receivers were reaped and independently absent.

Actual [light](site/assets/patch-recovery-light.png) and
[dark](site/assets/patch-recovery-dark.png) captures show the embedded editor
and initial states. They precede the fixture-only reselection correction and use
the same built app as the passing native run. They certify that displayed state,
not every physical input/menu transition or every completed-save view.
