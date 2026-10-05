# Format Patch port audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

The repository operation is implemented and tested. A native dialog, app/Finder
action, progress sheet and mail composition handoff now compile. Native runtime,
visual and signed sandbox verification are still pending; this is not a completed
dialog port.

| Source | Blob | Replacement |
| --- | --- | --- |
| `src/TortoiseProc/Commands/FormatPatchCommand.cpp` | `0e05626d7c64c484276c45d5a004d2d9f3d668d3` | `Sources/TurtleGitCore/FormatPatch.swift`, command only |
| `src/TortoiseProc/FormatPatchDlg.cpp` | `b8ad0c02bb27397700a6aee773d87ce7656d62c8` | `Sources/TurtleGitMac/FormatPatchWindow.swift`, partial native UI |
| `src/Git/Git.cpp` | `43dee91dbf94e46564b4cc1a139717fcbd8f6803` | Sole for-merge FETCH_HEAD record selection only |

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

The native dialog uses the original Output Directory and Version groups, editable
AppKit history fields, AppKit radio buttons, commit-count field and stepper, From/To
Log selection sheets, both options and the four footer actions. The Since chooser
lists local and remote references without tags. Histories and options persist with
UserDefaults. Its fixed height and horizontal resizing match the source intent;
geometry uses AppKit frame autosave. Repository and output-directory access leases
stay retained through Git operations. Store builds require a covered directory
grant, and typed destinations outside existing grants open the folder chooser.

Create Patch Serial appears in the app sidebar and automatic action menu, with
upstream `menudiff.ico` (IDI_CREATEPATCH) in app and Finder menus. Finder enables it
for one directory selection. The read-only unified-diff viewer uses source's
HEAD-to-working-tree stat/patch command, excludes external diff tools and applies
the no-prefix choice. The progress sheet displays errors or Git's output and
blocks closing/Quit while Git is active. Optional mail uses the native compose-email
service with exported patch attachments, retaining the controller and output
grant until its callback. No message was sent during testing.

The Debug preview launched once, but the computer-control connection failed with
“Sky Computer Use native pipe closed before response” twice. No accessibility
state or screenshot was obtained, so no layout or native interaction pass is
claimed. Normal Quit could not be invoked through that failed connection; the
exact owned PID/executable was rechecked and terminated. No other app was closed.

Five `FormatPatchTests` pass. They exercise all three selections, empty ranges,
original mail headers and numbered filenames, exact binary patch application with
`git am`, unchanged HEAD/index/working bytes, no-prefix output, replacement of
existing patches, invalid selections, option-shaped revision rejection, metadata
aliases, bare export and FETCH_HEAD disambiguation. These integration tests do
not prove native UI, Finder integration, progress cancellation or signed sandbox
access.

Remaining: verify native light/dark layout and keyboard interaction, successful
export through the dialog, failure/retry, output-folder grants, unborn/bare states,
mail attachments and service failure/cancel callbacks. Add searchable reference
browsing, source command startrev/endrev presets and Log export entry points,
Shift alternative diff viewer and upstream progress cancellation. Complete the
source Send Mail dialog/options rather than treating native composition alone as
full parity. Signed Finder and App Store testing and screenshots remain pending.
