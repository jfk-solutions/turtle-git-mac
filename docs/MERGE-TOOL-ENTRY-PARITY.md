# Standalone TurtleGitMerge command entry

This batch ports command entry from pinned
`src/TortoiseMerge/TortoiseMerge.cpp` (especially lines 169–235 and 315–405),
`CWorkingFile::TransferDetailsFrom`, and `CMainFrame::FileSave`.
The pin is recorded in `upstream.json`; this document records a connected entry
workflow, not completion of the Merge editor or the whole application.

The Open fallback and editor replacement use
`src/Resources/TortoiseMergeENG.rc` / `IDD_OPENDLG`. This remains a partial
workflow audit; it does not certify the dialog or shared editor frame.

## Command contract

`MergeToolInvocation.parse(arguments:currentDirectory:)` parses arguments without
argv[0]. The native `--merge-tool` marker selects the standalone tool, including
an empty request which can open its file chooser. Known source Merge arguments
also select it without the marker. `/command:…`, `--command …` and
`--command=…` repository requests return nil before any Merge recognition, leaving
TortoiseProc-style routing in charge. Ordinary Launch Services document arguments
without the marker or Merge options also return nil.

Source `/key:value`, `/flag`, native `--key value`, `--key=value` and `--flag`
forms are supported. Keys are case insensitive. Native descriptive aliases such
as `--base-name`, `--save-required-on-conflicts` and `--working-copy` map to their
source keys. Duplicate options, unsupported options, NUL arguments, missing
values, empty file options and invalid one-based line numbers fail explicitly.
Paths retain literal stars, spaces, newlines and raw Unicode spelling; they are
not split as repository `/path` lists. Relative paths resolve against the captured
absolute working directory. Parsing does not read a path, acquire a security
scope, or grant access to a file.

| Source options | Typed data / behavior |
| --- | --- |
| `base`, `theirs`, `mine`, `merged` | Independent file URLs; the merged target need not exist yet. |
| `basename`, `theirsname`, `minename`, `mergedname` | Descriptive labels kept separate from filesystem paths. |
| `basereflectedname`, `theirsreflectedname`, `minereflectedname`, `mergedreflectedname` | Display-only reflected names. |
| `readonly`, `blame` | Independent Blame flag; Blame also implies read-only. File permissions are checked when the native reader opens the file. |
| `oneway`, `line` | One-pane preference and positive one-based initial line. A `diff` request overrides One Way, as upstream does. |
| `saverequired`, `saverequiredonconflicts` | Separate mandatory-save policies consumed by native editor close ownership. |
| `deletebasetheirsmineonclose` | Typed input-cleanup request, separate from the merged output. Native owner cleanup requires actual access and identity ownership. |
| `diff`, `patchpath`, `wc`, `reversedpatch` | Patch URL, target directory and direction. `wc` supplies the patch file's parent only when `patchpath` is absent. |
| `patchoriginal`, `patchpatched` | Original/patched descriptive suffixes, including deliberately empty strings. |
| `createunifieddiff`, `origfile`, `modifiedfile`, `outfile` | Unified-patch generation and an independent optional output URL. |
| `help`, `?` | Explicit tool help request. |

The marker also permits one to three positional files: Mine alone, Base + Mine,
or Base + Mine + Theirs. `--` makes subsequent literal path arguments unambiguous.
Mixing positional files with named inputs fails explicitly. Unmarked positional
Launch Services paths remain outside this parser.

Upstream's Base + Theirs without Mine is a **two-file** case. Its
`TransferDetailsFrom` moves the Theirs filename and descriptive name into Mine,
then retires Theirs. The source helper does not copy reflected names. The typed
request preserves this distinction instead of accidentally opening a three-file
merge with two references to the same pane.

## Captured outputs and saving

`MergeToolOutputTarget` captures an existing regular output's bytes, permissions
and file identity, or captures its absence, before asynchronous generation or
editor presentation. `validate()` and every atomic save reject changed bytes,
permissions, appearance/disappearance or a replaced identity even when replacement
bytes match. Symlink and directory outputs are rejected. Read-only outputs route
to native Save As instead of having their mode changed. Backup, empty-result
deletion, subsequent recreation and encoding choices reuse the existing Merge
save implementation.

The byte save API writes exact bytes without decoding or re-encoding, allowing a
unified patch to retain original non-UTF-8 data. The text API uses the selected
codec and rejects unrepresentable text. Returned targets become the baseline for
later writes. `savedPaneContent(like:)` supplies clean draft bytes while retaining
the original Mine pane's path and metadata; saving a separate merged output does
not make Reload read that output as though it were the original Mine input.

`WorkingTextMerge(base:theirs:mine:merged:)` retains an independent `outputURL`.
An explicit merged output is snapshotted on initial Read, before the generated
merge result is presented. Its existing bytes/permissions, or absence, supply the
result's clean baseline; the generated text remains the three-input merge
presentation. `save()` writes that output, preserving the three inputs when the
output is separate. `saveTo` uses the pre-captured target for the same output,
and intentional Reload acknowledges a new reviewed output snapshot. The original
three-file Open API keeps its existing default Mine behavior.

Missing named inputs are empty panes through opt-in
`MergeToolFileInput.read(at:)`, `WorkingFileComparison.readForMergeTool`, and
`WorkingTextMerge(..., allowMissingInputs: true)`. Their absence is retained in
read/save snapshots, so a file appearing after the editor opens cannot silently
be overwritten. Ordinary working-tree and Merge Open readers keep their strict
existing-file behavior. A missing input's parent-folder grant remains the native
entry owner's responsibility. Unified generation can use the same empty-input
helper and retain a `MergeToolOutputTarget` input capture for post-generation
validation without creating placeholder files.

## Native three-file entry

`TextConflictWindowModel.configureMergeTool(_:)` accepts launch configuration only
before the first load. Source/result headings and editor accessibility names use
descriptive labels; reflected paths stay display-only. Configured output Save
uses the captured output directly, while ordinary Merge Open retains picker-first
behavior. Required-save flags keep even a clean result pending until accepted Save;
ordinary `saverequired` clears on conflicts unless `saverequiredonconflicts` is
also present. Failed or cancelled Save retains the pending state.

Read-only and Blame launches disable native text mutation, block/whole-file
transfers, format/whitespace changes, source/result Save As and rebinding, and
Save handlers/menu/toolbar. Navigation, Find and source comparison remain
available. Initial line navigation resolves the original Mine line through aligned
view rows after load. Exit state exposes accepted Save, current conflict status,
and pending load/save/format/EditorConfig work to the launch owner.

The dedicated
[three-file native fixture](qa/merge-tool-three-file-native-2026-10-18.swift)
covers existing/absent outputs, stale-output refusal, mandatory flags/cancellation,
labels/reflected names/source line and actual read-only/Blame controls. Its presence
alone does not mean those checks passed.

## Evidence and remaining acceptance

Focused Core coverage is in
[MergeToolInvocationTests.swift](../Tests/TurtleGitCoreTests/MergeToolInvocationTests.swift):
source/native arguments, pane transfer, command isolation, literal filenames,
strict errors and Windows protocol refusal; absent/existing outputs, exact binary
bytes, backup/delete/recreate, replaced identity, permissions and symlink refusal;
independent merged output and rejection of stale targets before the first Save.
Existing `MergeOpenTests` retain source/input alias and Save As regressions.
These are implementation fixtures until the parent grouped checkpoint records
actual build and test results.

Native routing, labels, line navigation, read-only/mandatory-save states, input
cleanup, file/folder authorization and command-line patch generation are integrated
by the native owners in the same batch. Their actual validation and limitations
must be recorded at that checkpoint. A parser test does not prove those workflows.

Windows HWND resolve notifications (`resolvemsghwnd`, `resolvemsgwparam`,
`resolvemsglparam`) have no native HWND receiver and are rejected explicitly.
Full physical keyboard, richer source Blame-column rendering, VoiceOver,
sandboxed/signature and all source Merge-window acceptance remain open.


## Startup, ownership, patches and Git completion

`MergeToolLaunchSession` captures the request, preference domain and originating
window before any authorization. Every input and output-parent grant survives
asynchronous preparation and editor work; sandboxed argv strings request real
file/folder authorization. Missing inputs authorize their parent. Cancellation
retains noncooperative work until its reply drains and refuses late presentation.
The session owns native two-/three-file editors, Open fallback and patch chooser
preparation. Reverse/readonly patch flags and source original/patched captions
reach the real patch parent and child; readonly leaves navigation available while
blocking Apply, special resolution and edited-result Save.

Create Unified Diff captures input/output snapshots, generates raw patch bytes
with the existing pinned Git path, revalidates both inputs and atomically writes
only the captured output. It never decodes arbitrary patch bytes into UI strings.
The wrapper execs a dedicated app process and preserves arguments/exit status.
Startup completion and approved application Quit drain owned work and cache shutdown
before process exit. A merge requires an actually saved result, no newer unsaved
edits and no unresolved conflicts. Compare-only close succeeds without a save;
a requested merged output discarded without Save does not report success.

Explicit input cleanup occurs after owned work drains. It unlinks only unchanged
requested input objects, preserves external edits and the output (including an
existing output alias), and never follows a symlink while removing it. Missing
inputs are ignored. This ownership policy is a deliberate adaptation of source
unconditional temporary-input deletion; it does not certify arbitrary concurrent
external-writer races. No cleanup flag is added automatically to Git commands.

The grouped parent checkpoint uses `scripts/test-merge-tool-entry.py`: one waiting
wrapper check and private two-file, three-file and startup/authorization/patch/
unified/cleanup receivers with both Git engines. Its actual result is recorded
only after running. The normal Merge Open/patch families are retained checks;
physical input, real App Store terminal grants, minimum-OS/Intel, complete Blame
columns and Git-root-relative reflected-name patch headers remain open.


## Parent checkpoint — October 18, 2026

All 24 distinct focused Core cases and ten distinct native/workflow receipts
pass: six new case/engine combinations, three retained Open/replacement/patch
workflows, and the waiting-wrapper receipt. Exact path spelling exposed one Core
parser defect; the affected check passed after repair without repeating the full
Core selection. The initial native batch passed; subsequent integration review
added actual controller replacement, owned output/Open choosers, retired exporter
drain and failed-load completion handling. The affected receipts preserve all
assertions; fixture enum labels, busy-entry injection and prior error-sheet
settlement were repaired explicitly.

[Batch evidence](qa/merge-tool-entry-2026-10-18.json) records every check/repair,
six incremental build outcomes, source/log hashes and all 21 reaped/absent owned
processes. No native test app remains running. The earlier hosted Pages failure
was stale generated LFS/privacy help; the regenerated offline book now includes
the Merge-tool guide and passes its resource check. This is not yet evidence of
a successful hosted Pages deployment or complete macOS workflow.

File/Open now follows the current adopted controller and keeps discarded original
Git results failed. Replaced models and cancelled patch preparations retain their
actual work until drain. Ordinary replacement resets merged output, descriptive
labels, initial line and required-save state; frame readonly/view policy survives.
Two-file reflected metadata survives too. Three-file reflected-label continuity,
full Blame text columns, reflected-name Git-relative patch headers, dedicated
standalone scene/menus, physical focus/accessibility and signed/minimum-OS
acceptance remain explicit gaps. These scoped checks certify neither all Merge
states nor the full application.


## Follow-up frame and comparison family

The later [Blame comparison review](MERGE-BLAME-PARITY.md),
[reflected patch review](MERGE-REFLECTED-PATCH-PARITY.md) and
[standalone presentation review](MERGE-TOOL-PRESENTATION-PARITY.md) supersede the
corresponding missing-behavior notes above. Source inspection corrected the older
claim about missing Blame columns: the pinned Merge tool strips a fixed metadata
prefix during converted-file comparison; it does not provide a separate column.
The reflected-header source is `MainFrm.cpp::OnEditCreateunifieddifffile`, rather
than the previously named, nonexistent `TryGitUnifiedDiff` symbol.

Three-file replacement now retains all four reflected frame names independently
of the new working inputs. It resets the prior invocation, descriptive names,
merged output, required-save policy and initial line. Source Blame policy follows
two/three-file replacements and supplies the actual input encodings to the shared
engine. The command's original discarded-result status remains failed. The
follow-up checkpoint is recorded separately; historical results above remain
scoped to their original source revision.
