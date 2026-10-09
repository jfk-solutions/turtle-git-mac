# Format Patch port audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

The repository operation is implemented and tested. A native dialog, app/Finder
action, progress sheet and mail composition handoff compile. Core and selected
hidden native workflows are verified below. Physical visual/keyboard and signed
sandbox acceptance remain pending; this is not a completed dialog port.

| Source | Blob | Replacement |
| --- | --- | --- |
| `src/TortoiseProc/Commands/FormatPatchCommand.cpp` | `0e05626d7c64c484276c45d5a004d2d9f3d668d3` | `Sources/TurtleGitCore/FormatPatch.swift`, command only |
| `src/TortoiseProc/FormatPatchDlg.cpp` | `b8ad0c02bb27397700a6aee773d87ce7656d62c8` | `Sources/TurtleGitMac/FormatPatchWindow.swift`, partial native UI |
| `src/Git/Git.cpp` | `43dee91dbf94e46564b4cc1a139717fcbd8f6803` | Sole for-merge FETCH_HEAD record selection only |
| `src/TortoiseProc/GitLogListAction.cpp` | `88c255c4c80578c099bbcd4604f6e088f2f9d40a` | Log command start/end presets |
| `src/TortoiseProc/GitLogListBase.cpp` | `19518f37689e19b7e913c9ff8cc9d65ec223c187` | Patch selection eligibility |
| `src/TortoiseProc/ProgressDlg.cpp` | `557988a1303dc86b11c9c74d29be4797aa7e6090` | Native interrupt/stop workflow, partial |

The operation uses the source's `git format-patch [--no-prefix] -o directory`
with one of `--end-of-options since --`, `-count --`, or
`--end-of-options from..to --`. Count accepts 1 through INT_MAX. Since FETCH_HEAD
selects the only record eligible for merge; it rejects zero or multiple records,
rather than exporting from an arbitrary first record. Arguments never pass
through a shell. Existing patches are replaced as in upstream; Git controls
patch numbering, subject filenames, binary data, mail headers and configured
formatting. Export works with a bare repository when the destination is outside
its administrative directory. Git metadata destinations, including symlink
aliases and Git admin roots without a `.git` name, are rejected as a macOS
adaptation. Output directories can be created by Git.

## Native dialog requirements audited from IDD_FORMAT_PATCH

- Output Directory group: editable directory history and folder chooser.
- Version group: Since radio plus branch history and no-tags reference chooser;
  Number Commits radio plus numeric field and stepper; Range radio plus From/To
  histories and single-revision Log pickers. Inactive choices disable their fields.
- Send Mail after create and No a/ and b/ prefixes checkboxes, persisted globally.
- Save unified diff since HEAD, OK, Cancel and Help. The source's unified-diff
  button opens a read-only temporary diff in its viewer, despite the button name.
- Since defaults to its repository preference, Number to 1; directory defaults
  to repository root; From/To use global histories. Supplied start/end revisions
  preset the corresponding mode. OK is disabled for unborn repositories.
- Horizontal resizing, saved geometry, native light/dark appearance and keyboard
  access. Preserve source grouping and relative field positions.
- Progress and error reporting, output refresh, and optional Send Mail handoff
  after successful export. Mail composition must let the user review before sending.

## Evidence and remaining work

The unified-diff button now honors the dedicated Unified Diff Viewer preference
and source's Shift inversion, with exact read-only bytes for an external macOS
application. The preference retains a disabled application for Shift use and is
independent of Alternative Editor. The settings/launch/keyboard implementation
compiles; native and signed acceptance remain pending. See
[UNIFIED-DIFF-VIEWER-PARITY.md](UNIFIED-DIFF-VIEWER-PARITY.md).

The native dialog uses the original Output Directory and Version groups, editable
AppKit history fields, AppKit radio buttons, commit-count field and stepper, From/To
Log selection sheets, both options and the four footer actions. The Since chooser
lists local and remote references without tags. Histories and options persist with
UserDefaults. Its fixed height and horizontal resizing match the source intent;
geometry uses the shared native geometry store. Repository and output-directory access leases
stay retained through Git operations. Store builds require a covered directory
grant, and typed destinations outside existing grants open the folder chooser.

Log's Format Patch context command now presets the same start/end values as the
source. One selected commit opens Since at that hash, exporting commits after it;
the inactive range fields are preset to `hash~1` and `hash`. Two selections can be
nonadjacent; three or more must form contiguous displayed rows. Multiple rows
preset Range from the oldest selected hash's first parent (`~1`) to the newest
selected hash. Git determines the resulting range, which can include commits
between the selected endpoints; this is not a list of independent selected
patches. A root commit lacks the required first parent and Git reports that error
as in source. The helper also supports oldest-first order and rejects multi-row
continuity when rows are hidden; the current native Log has newest-first Git query
results without an additional client-side row filter. Original `menupatch.ico`
is used for this Log command. The Since reference picker now has a case-insensitive
branch filter. Applying a preset to a busy or open-progress dialog is blocked.
Different preset ranges retain separate native dialogs so a new Log request does
not replace the inputs or access leases of an export in progress.

Create Patch Serial appears in the app sidebar and automatic action menu, with
upstream `menudiff.ico` (IDI_CREATEPATCH) in app and Finder menus. Finder enables it
for one directory selection. The read-only unified-diff viewer uses source's
HEAD-to-working-tree stat/patch command, excludes external diff tools and applies
the no-prefix choice. The progress sheet displays errors or Git's output and
blocks closing/Quit while Git is active. Optional mail uses the native compose-email
service with exported patch attachments, retaining the controller and output
grant until its callback. No message was sent during testing.

Format Patch now passes an explicit cancellation token to its Git commands,
including metadata preflight. The optional Git runner spawns an owned POSIX
process group with explicit standard streams and environment. Cancel interrupts
that group, allows 100 ms, sends termination, allows another 100 ms, then forces
the group to stop before reaping its leader. This replaces upstream's Ctrl-C,
Windows descendant enumeration and potentially long waits. Other operations
keep the existing Foundation runner unless they explicitly opt into this path;
this is not a claim of cancellation parity for every dialog. Helpers that detach
into separate sessions would need additional handling and are not covered by
the group test.

The native sheet has Cancel while busy, Stopping Git after a request, Cancelled
after it stops, and Close/Retry through the parent dialog. Escape is routed to
cancel or finish; implicit sheet dismissal is blocked. Partial patches are kept
and diagnostics are displayed, as in the source's interrupted command. Cancellation
does not report success or open mail composition, including a cancellation
accepted just before the awaited result returns to the UI. The output refresh
callback now runs after success, failure or cancellation so partial files can be
seen in status. The parent dialog also blocks editing/export/preset replacement
while its mail composition service is active. These native interactions are
implemented but remain unverified through actual UI control.

An earlier Debug preview launched once, but the computer-control connection failed with
“Sky Computer Use native pipe closed before response” twice. No accessibility
state or screenshot was obtained, so no layout or native interaction pass is
claimed. Normal Quit could not be invoked through that failed connection; the
exact owned PID/executable was rechecked and terminated. No other app was closed.

Seven `FormatPatchTests` pass. They exercise all three selections, empty ranges,
original mail headers and numbered filenames, exact binary patch application with
`git am`, unchanged HEAD/index/working bytes, no-prefix output, replacement of
existing patches, invalid selections, option-shaped revision rejection, metadata
aliases, bare export and FETCH_HEAD disambiguation. These integration tests do
not prove native UI, Finder integration, progress cancellation or signed sandbox
access.

The added Log tests cover one/two/contiguous/sparse/hidden/stale row selections,
both orderings, and real patch generation from a three-commit repository using
the presets. The one-row case exports only the later commit; two and three rows
produce the source's inclusive oldest-to-newest series. Export leaves HEAD and
index unchanged. Native Log menu activation and preset fields remain unverified.

Three `GitProcessCancellationTests` cover an already-cancelled export with no
output directory, ordinary success/failure using the cancellable runner, and a
slow owned helper that writes a partial patch plus stdout/stderr and starts a
sleeping child. Both PIDs share the owned group and disappear after cancellation;
the partial patch, diagnostics, HEAD, index and working bytes are checked. The
helper uses disposable test data; no user Git operation is terminated.

Remaining: verify native light/dark layout and keyboard interaction, successful
export through the dialog, failure/retry, output-folder grants, unborn/bare states,
mail attachments and service failure/cancel callbacks. Verify searchable reference
browsing, source command startrev/endrev presets and Log export entry points;
verify Shift viewer selection and native progress cancellation. Complete the
source Send Mail dialog/options rather than treating native composition alone as
full parity. Signed Finder and App Store testing and screenshots remain pending.

## Captured progress policy and acknowledgement

Format Patch captures AutoCloseGitProgress when export is submitted (upstream
constructs CProgressDlg after options acceptance). Both success auto-close modes
acknowledge automatically because this command supplies no post-actions. Manual
keeps the result. Failure/cancellation stays open; Close returns the native
options, where a new export can be submitted. There is no progress Retry action
in the audited FormatPatchCommand.cpp. Keeping the options behind a failed result
is the existing Mac ownership adaptation; upstream closes its options on OK.

ConfirmKillProcess now presents native Yes/No, default Yes, on the owned progress
sheet. No keeps Git running. Yes stops the existing owned process group and
retains partial patches/diagnostics. While a confirmation is pending, Close and
further Abort are blocked. A success that finishes during the question waits
for its answer before applying auto-close; a late Yes does not reinterpret that
completed success as cancellation.

Result acknowledgement schedules one close or mail callback with the submitted
Send Mail choice and generated file URLs. Duplicate acknowledgement and new
exports in the scheduled handoff interval are rejected. Presets, exports and
unified-diff requests cannot replace open results. Normal close/Quit includes the
result and scheduled handoff; controller invalidation cancels any owned export
and suppresses delayed mail/close. Directory/revision histories and mail/no-prefix
preferences now accept an injected private defaults domain for native QA while
production retains standard preferences. Mail remains the existing native
composition service; the source Send Mail options are still unported.

[Progress QA](qa/format-patch-progress-2026-10-08.json) records four-Git actual
Since/Number/Range exports across all policies, captured choices, duplicate
acknowledgement, generated attachment URLs in a newline directory, real git am
application/tree equality, private history reads, failure/new export, owned
No/Yes cancellation with partial output and deferred completion. Hidden options
hosting does not display a result sheet or prove UI acceptance; no actual mail
service or external editor was invoked. Physical nested alerts, default focus,
keyboard/layout, output grants, service callbacks and signed acceptance remain
pending. Existing screenshots predate these progress changes.

## Source-style live progress

The progress sheet now uses the shared read-only AppKit output view, including
original Copy icons, source error/warning formatting and success/failure footer
colors, locale/timing preferences and bounded UTF-8 output. Current work and
percentage follow command output; ordinary format-patch emits paths without
numeric progress, so no percentage estimate is invented. Close stays visible
and disabled while Git runs. Abort requests the existing confirmation/cancellation
flow, closes a failed result when idle, and is disabled on success. The sheet
content explicitly enables its own controls while the options behind it remain
locked. Escape retains the guarded cancellation/completed acknowledgement path.

Only the final format-patch command streams into progress; FETCH_HEAD and metadata
probes remain internal. Returned stdout still supplies all generated attachment
URLs even if visible output is truncated. Streamed command diagnostics appear
once, with the actual exit-code footer. Empty ranges keep the no-patches message;
cancellation retains partial files and the output-directory explanation.

Invalidating a closed owner cancels its operation, clears progress/confirmation,
and suppresses late output, status refresh, completion/footer and mail/close
handoffs. Busy remains true until the owned operation and child cleanup finish.
Pre-start cancellation creates no output directory. A late unified-diff result
also cannot open its viewer after owner closure. Physical sheet dismissal,
rendered themes, keyboard/default controls, screenshots, signed sandbox grants
and the complete upstream Send Mail options remain unverified.

[October 10 streaming QA](qa/format-patch-stream-2026-10-10.json) records system
and packaged Git checks for real patch paths, completion/copy/color attributes,
live output before process exit, an exit-17 diagnostic appearing once, abandoned
owner/confirmation fencing, leader/child cleanup and partial-file retention,
pre-start cancellation, and unchanged HEAD/index. A flooded output fixture
confirms the captured 16 KiB UTF-8 display limit while both real generated patch
URLs survive in the captured mail handoff. The existing progress regression also
passes with both engines, including all modes/policies and actual git am tree
equality. These are hidden receivers; no mail was sent or composed and no main
app instance was launched.
