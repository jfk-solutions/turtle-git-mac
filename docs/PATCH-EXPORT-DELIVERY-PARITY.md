# Patch export to mail delivery

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`SyncDlg.cpp::OnBnClickedButtonEmail` (903–932) captures the selected
remote/branch-to-local range, runs `format-patch -o` in the working directory,
then calls `CAppUtils::SendPatchMail` only after successful Git completion.
`Commands/FormatPatchCommand.cpp` (67–88) similarly passes the successful
export's output to mail when requested. The Mac keeps its existing native mail
options and delivery workflow; this family does not add email transport.

## Connected implementation

Synchronization Email Patch and the normal Format Patch dialog now use the same
`FormatPatchExport.exportedFiles` admission as Rebase completion mail. The full
stdout, independently of the bounded visible log, must describe a complete,
ordered, unique list of existing regular files in the approved output directory.
Directory aliases must independently identify that same directory. The admitted
filename suffix bytes are retained; no lossy replacement or subset filtering is
used. Malformed, duplicate, out-of-directory or missing entries refuse the whole
mail handoff. An empty successful export remains an informational empty result.
Git's already-written files remain on disk after validation failure or cancellation.
The existing parser's strict UTF-8 and newline-delimited filename contract remains;
this is not support for arbitrary non-UTF-8 or newline-containing attachment names.

Synchronization captures its selected range before suspension and continues to
export with source-default `noPrefix: false`, independently of saved Format Patch
options. It now shows the actual command/output and captured completion in its
Log and uses the existing Cancel/confirmation controls. The subprocess completion
receipt is distinct from attachment admission: a successful Git footer stays
successful when a later file-list validation error prevents composing mail. That
error is appended separately. A failed or cancelled command cannot produce a
verified attachment receipt, even if it wrote some patch files.

The composer opens after the exact export and validation attempt drains. Each
mail workflow has its own identity; retired owners, changed Quit epochs and late
child callbacks cannot present a replacement composer or clear another workflow.
Existing owned sheets, metadata readers, repository/output access leases and
child cancellation continue through their existing drain paths. Patch export
neither changes the source HEAD/index nor sends mail automatically.

Request Pull writes its own generated request text to one owned file and does
not parse a list from Git stdout. It already guards its mail presentation with
owner/epoch identity. Rebase completion already consumes `formatPatchFiles` and
retains its dedicated progress-to-composer transition; neither route is changed
by this implementation.

## Authored verification scope

Focused Core assertions cover the selected Sync range, exact Unicode/newline
output-directory identity, empty and cancelled export, and successful Git command
completion followed by invalid delivery output. The existing cached native Sync
Email fixture retains real composer/Cancel/empty/error/forced-owner cleanup and
adds a real successful export whose reported output disappears before admission.
It requires all-or-error delivery and preserved successful command output.

The existing cached Format Patch workflow receiver adds a `delivery` case. It
reuses actual valid mail and held-result owner-retirement checks, then rejects
missing, malformed and duplicate returned lists after real successful Git export.
It retains command success, checks no mail dispatch after acknowledgement, and
checks retained output bytes and source HEAD/index witnesses.

The [dated checkpoint](qa/patch-export-delivery-2026-10-25.json) records 17 focused
Core methods, the arm64 Debug build and four native case/engine pairs passing
without a repair/recheck cycle. All four receiver processes are independently
absent. No complete hosted CI, physical keyboard/VoiceOver, signed sandbox or
external email transport acceptance follows from these checks. Installed build 6
predates this source batch.
