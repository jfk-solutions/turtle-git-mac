# TurtleGitMerge Open

Source: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`OpenDlg.cpp/.h`, `IDD_OPENDLG`, `MainFrm.cpp::OnFileOpen`.

Tools → Open in TurtleGitMerge opens a native dialog with Merging / Apply unified
diff radios, separate visible groups, Base file / Their file / My file,
Diff file / Directory, Browse buttons, clipboard checkbox and OK / Cancel / Help.
The last successful mode is saved; Cancel leaves it unchanged. Inactive fields
are ignored. Selecting clipboard disables Diff file; bytes are captured at OK.
Private TurtleGit/TortoiseGit unified-diff UTIs and explicit copied patch text
are supported. Patch preparation remains immutable and uses the existing native
review/apply tool, including its target chooser if Directory is empty.

One input opens the right-hand text pane; two inputs open comparison in source
order. Base+Their with no My uses Their as My; Their+My with no Base uses Their
as Base. Three inputs open the existing three-pane text editor with a standalone
Subversion-backed merge. No Git repository is created and no index operation
runs. The result starts unnamed; Save opens the native Save As panel. My supplies
initial output encoding/permissions. All input files stay unchanged unless the
user explicitly selects one as output. Save validates all input snapshots and
the chosen output snapshot, supports backup/empty-delete/recreation, and refuses
external changes. Mark as resolved is disabled for standalone files. An initial
merged result differing from My is dirty and participates in Close/Quit prompts.

Browse owns native file/directory panels and retained security-scope leases.
Typed paths in App Store mode require explicit Browse authorization. Closing a
picker's owner fences late replies. Standalone editors retain all file grants
for load/save; the app's ordinary repository context remains unchanged.

The app build and grouped native Merge receiver passed. Seventeen backend
cases passed initially; the remaining directory URL assertion passed after its
focused fixture correction. The Save As correction passed two additional
backend cases and the focused native Open receiver; its first-save/cancel and
input preservation checks passed. See the [dated QA record](qa/merge-open-2026-10-12.json).
Shared input paths are supported. Explicitly saving to an input updates its
snapshot for subsequent Save/Save As, empty deletion/recreation and Reload.
Atomic hard-link replacement keeps untouched linked inputs at their old baseline. Path fields accept file URL drops with file/directory gates and retained grants.
Native filesystem completion preserves tilde paths, limits suggestions and avoids
enumerating unauthorized folders in App Store mode. A dialog-owned clipboard
monitor checks format metadata and change count without reading clipboard bytes;
it stops on close. Owner closure cancels the picker and fences late responses.

Physical picker/drop/path-autocompletion acceptance, full light/dark captures, source File/Open replacement of an existing
editor rather than a separate window, exact single-pane toolbar pruning and
signed App Store acceptance remain pending. The directory patch-review list is
implemented by the existing patch workflow and still has its own parity gaps.

The [upstream Open manual](https://tortoisegit.org/docs/tortoisegitmerge/tmerge-dug-open.html)
confirms the unnamed three-file output. First Save and Save As Cancel leave
inputs/output routing unchanged; later Save reuses the selected output.

The lifecycle follow-up passed all 11 Open backend cases and four targeted
snapshot checks after refinement. Its final native receiver passed dropped
URLs, completion, actual metadata timer/owner closure and repeated output-to-input
saves. A format can be added without changing macOS pasteboard ownership count,
so monitoring checks both count and advertised formats, never contents. See the
[lifecycle QA record](qa/merge-open-lifecycle-2026-10-12.json) for failures, repairs
and exact scope. Case-insensitive pathname variants still need volume acceptance.
