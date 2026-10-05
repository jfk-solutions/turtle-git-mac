# Format Patch port audit

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

The repository operation is implemented and tested. The native dialog, menu
entry, progress window and mail workflow are still pending; this is not a
completed dialog port.

| Source | Blob | Replacement |
| --- | --- | --- |
| `src/TortoiseProc/Commands/FormatPatchCommand.cpp` | `0e05626d7c64c484276c45d5a004d2d9f3d668d3` | `Sources/TurtleGitCore/FormatPatch.swift`, command only |
| `src/TortoiseProc/FormatPatchDlg.cpp` | `b8ad0c02bb27397700a6aee773d87ce7656d62c8` | Audited; native UI pending |
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

Five `FormatPatchTests` pass. They exercise all three selections, empty ranges,
original mail headers and numbered filenames, exact binary patch application with
`git am`, unchanged HEAD/index/working bytes, no-prefix output, replacement of
existing patches, invalid selections, option-shaped revision rejection, metadata
aliases, bare export and FETCH_HEAD disambiguation. These integration tests do
not prove native UI, Finder integration, progress cancellation or signed sandbox
access.

Next: implement the dialog and its retained repository/output-directory access
leases, the reference/Log pickers, saved preferences, unified-diff viewer, optional
mail composition, action/menu routing and actual light/dark screenshot QA.
