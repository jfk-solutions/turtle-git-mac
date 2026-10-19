# Source-selected Add and index filters

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This connects the Add workflow family to its source-selected index engine. It is
partial Add/status-list/progress coverage, not whole-app certification.

## Source behavior and native callers

`Git.h::GIT_CMD_ADD` is command index 10, bit `0x400`, already enabled in the
source default `UseLibgit2_mask` of `0x66780`. `AddProgressCommand.cpp::Run` reads
one index, calls `git_index_add_bypath` for each reviewed path, applies requested
executable/link modes only to non-directories, emits Add notifications and checks
cancellation, then writes the index once. The disabled branch uses Git `add -f`.
`SetFileMode` uses libgit2 independently of that switch and changes the existing
index entries without rereading working-file contents.

`src/Git/GitStatusListCtrl.cpp`, the `IDGITLC_ADD`, `IDGITLC_ADD_EXE` and
`IDGITLC_ADD_LINK` cases, opens shared Add progress before refreshing its parent.
`IDD_ADD` keeps its checked selection separate from highlights; `IDD_SVNPROGRESS`
provides the shared Action/Path notifications and completion/post-actions. The
native Add selector, file-only launch, Working Tree/Log status menus, Commit
file-menu Add and Rebase conflict-file Add retain those accepted selections.
Commit's explicit Add now uses its owned Add progress sheet without another
Commit post-action. Ordinary Commit staging and optional Commit index preparation
remain separate source operations.

The engine and private preference provider are captured before asynchronous
validation. File-only workspace entry captures before preflight; selector entry
captures at OK. Commit/Rebase menu entry captures before validating the selected
rows. Later Settings edits cannot change an accepted action or its post-actions.

## Private index and mode ownership

The helper receives an explicit private index, bounded literal UTF-8 NUL path
packet and normal/executable/link or mode-only operation. It does not enable
general repository-location environment overrides. The Core owner keeps its
existing real-index lock, private copy, cancellation checks and one final atomic
publication. Split-index preparation acts on the private copy. An unborn index
is initialized privately. Failures and cancellation preserve the previous real
index, HEAD and working bytes; object creation and completed diagnostic rows do
not imply index publication.

Directory selection is expanded into reviewed file entries for the existing
native directory workflow, while a nested repository/gitlink remains a single
entry. This adapts the source selector's recursive file enumeration to the Mac
API without changing every generic staging call. Exact Unicode spellings,
pathspec-looking names, ignored reviewed files, actual symlinks, linked worktrees
and unrelated index entries retain their separate validation.

Progress mode post-actions operate on the staged object ID and skip directory/
gitlink entries. Editing or deleting the disk file after Add cannot change the
staged blob during a subsequent mode change. The source operation is a mode
change in the index; it does not chmod the working file or create a disk symlink.

The selected library branch reports a missing/deleted reviewed leaf as an error,
following `git_index_add_bypath`. The Git-command branch can stage tracked
removals. This engine difference remains explicit; the Add adapter does not
invent index-removal semantics or silently drop a requested missing entry.
The helper input is bounded to 100,000 paths and 32 MiB of NUL-framed UTF-8,
with each path at most 1 MiB. Invalid packets fail before index mutation.

## Source custom clean filters

`src/libgit2/filter-filter.c` selects `.clean` for index input and `.smudge` for
checkout output. Its priority is the source custom-driver priority 200. The
helper uses that same registration for both directions, with libgit2's built-in
attribute, CRLF and ident filters retaining their ordering.

Configured clean commands run in the actual repository working directory with
the captured Git configuration/executable search paths and the private index.
Literal `%f` uses POSIX shell quoting and `%%` means one percent. Required missing
or failing drivers report an error; optional failures pass through the preceding
filter output. The selected source adapter uses one-shot clean/smudge commands.
It does not acquire Git's persistent `filter.process` protocol from this change;
the Git-command branch retains its normal Git filter behavior.

The actual configured child process group is owned until completion or
cancellation. Existing prompt/filter locks prevent transport interruption from
outliving an owned worker or its native authentication/export activity. Native
progress drains accepted path receipts and fences retired callbacks before
closing or handing off. The native Close action finishes the controller directly,
including an Add sheet owned by Commit; AppKit's disabled standard sheet close
button is not used for that action. No filter command is installed by this workflow.

## Evidence and remaining scope

[Grouped batch evidence](qa/add-index-filters-2026-10-19.json) records actual
builds, focused Core/native checks, failures and repairs. The source comparisons
above define the intended implementation scope; evidence must establish the
recorded cases before they are considered checked. The final universal helper
operation checks, Debug app build, 24 distinct focused Core methods across the
initial and affected repair runs, and the native group with system and packaged
Git passed. The native checkpoint exposed and repaired the actual Close-button
route for Commit-owned Add sheets. Failed fixture/build attempts remain in the
evidence; no full-suite or complete-dialog visual acceptance is inferred.

Real external filter/LFS/provider combinations, installed signed grants, physical
keyboard/Finder interaction, complete source UI acceptance and full hosted
integration remain open. Other libgit2 command-mask consumers and Commit's
separate index-preparation command remain independently scoped. See the
[Add dialog comparison](ADD-PARITY.md), [user guide](LIBGIT2-TRANSPORT.md) and
[Commit comparison](COMMIT-PARITY.md).
