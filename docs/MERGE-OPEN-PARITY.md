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
runs. My file supplies output encoding/permissions. Save validates original My,
Base and Their snapshots, supports backup/empty-delete/recreation, and refuses
external changes. Mark as resolved is disabled for standalone files. An initial
merged result differing from My is dirty and participates in Close/Quit prompts.

Browse owns native file/directory panels and retained security-scope leases.
Typed paths in App Store mode require explicit Browse authorization. Closing a
picker's owner fences late replies. Standalone editors retain all file grants
for load/save; the app's ordinary repository context remains unchanged.

The app build and grouped native Merge receiver passed. Seventeen backend
cases passed initially; the remaining directory URL assertion passed after its
focused fixture correction. See the [dated QA record](qa/merge-open-2026-10-12.json).
Standalone three-file inputs currently must be distinct; alias support remains
open. Physical picker/drop/path-autocompletion acceptance, clipboard change
monitoring, full light/dark captures, source File/Open replacement of an existing
editor rather than a separate window, exact single-pane toolbar pruning and
signed App Store acceptance remain pending. The directory patch-review list is
implemented by the existing patch workflow and still has its own parity gaps.
