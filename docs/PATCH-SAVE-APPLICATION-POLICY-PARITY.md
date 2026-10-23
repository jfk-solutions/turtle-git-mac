# Patch application and explicit Save policies

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseMerge/MainFrm.cpp::PatchSave` (1626–1654), `FileSave`
(1657–1740), and `SaveFile` (1433–1548). Automatic Patch All/Selected and explicit
editor Save are distinct source workflows.

The batch API accepts a captured AutoAdd choice. Its default remains false for
existing non-UI callers; the native review captures the source preference,
which defaults true. Both ordinary applicable files and clean recorded-base text
merges add a newly created destination only when that accepted choice permits it.
Plain-folder review never initializes or writes an index. Add failure is a
separate `addError`: the actual patched file remains successful and later files
can continue. Completed mutations do not become rollback claims when cancellation
arrives during Add.

Before each distinct selected path, the Core emits its original file ID, exact
path bytes, completed-path count and total. Cancellation from that receipt stops
before starting the file. The existing per-file result callback remains the
settled receipt. Repeated records for one path remain a single work item, and the
original list order remains authoritative.

`saveWorkingTreePatchFile(options:nil)` retains automatic PatchSave behavior:
no backup and deletion of a zero-record text result. Explicit FileSave passes the
captured Backup preference and accepted Keep/Delete decision in
`MergeFileSaveOptions`. Keep saves a regular zero-byte result; Delete removes it.
A nonempty explicit deletion is refused. Backups preserve captured original bytes
and permissions, reject nonregular `.bak` targets, and are prepared after stale
input checks and successful generated-patch validation. Earlier successful backup
creation is not rolled back if a later external race prevents saving, matching the
existing nontransactional source boundary. Special-file whole-state Keep/Use
Patched policies remain separate and preserve explicit empty regular files.

The source `SaveFile` returns zero for a single empty `NoEnding` record, including
an otherwise BOM-only file. A terminated blank line is a real record. Automatic
content-changing text patches apply that same distinction after Git succeeds;
metadata-only mode/rename records do not acquire a text deletion policy. A failed
post-apply empty cleanup produces `postApplyError` and a visible output warning,
while retaining the successful Git mutation receipt. No `.bak` is produced by
this automatic path.

Implementation: `GitPatch.swift`, the shared atomic backup primitive in
`FileComparisonEditing.swift`, and the native patch-review controls. Focused Core
class `WorkingPatchSavePolicyTests` uses real private Git repositories for
captured Add/disabled/plain-directory behavior, Add failure continuation, explicit
backup/Keep/Delete, unsafe/stale refusal, pre-file cancellation, empty/BOM/blank
records, metadata-only mode changes, a real cleanup failure, and recorded-base
rename merge. The parent records actual grouped validation after the full batch
freezes in the [dated record](qa/merge-patch-family-2026-10-21.json).
Fixture existence is not a pass.

The October 23 grouped checkpoint passes all six case/engine pairs across the
three native scenarios, with twelve reviewed light/dark captures. The patch/Core
group passes 48 tests; a separate 59-test focused check covers actual hosted
assertion repairs. Failed attempts and their repairs remain in the dated record.
These scoped results do not establish complete upstream or signed acceptance.
