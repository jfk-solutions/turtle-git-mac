# Native dialog command-line entry

TurtleGit accepts the primary TortoiseProc dialog commands through its macOS app
executable. These open the existing native dialogs with the same Git operations,
menus, original command icons, review steps and cancellation ownership as normal
app entry. Launching a dialog does not accept its Commit, Revert or Resolve action.

Use a new Launch Services instance when invoking an installed application from a
shell. `open` does not reliably deliver new startup arguments to an already running
process. Always supply absolute paths with `open`; Launch Services chooses the
application's working directory independently of the calling shell.

```sh
open -n -a 'TurtleGit for Mac' --args --command=commit \
  --path '/absolute/repository' --logmsg 'Describe the change'

open -n -a 'TurtleGit for Mac' --args /command:repostatus \
  '/path:/absolute/repository'

open -n -a 'TurtleGit for Mac' --args --command=log \
  --path '/absolute/repository' --range 'main..topic' --limit '50'
```

The direct app executable also accepts arguments; relative paths are resolved
against that process's working directory. For example:

```sh
'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=diff --path '/absolute/repository/file.txt' \
  --startrev 'HEAD~1' --endrev 'HEAD'
```

## Supported commands and presets

| Command | Native destination | Presets |
| --- | --- | --- |
| `commit` | Commit | `logmsg` or `logmsgfile`, `bugid`, `wholeproject` |
| `repostatus` (`status` alias) | Working Tree | Selected file/directory scope |
| `log` | Log Messages | `startrev`, `endrev`, deprecated `revstart`/`revend`, overriding `range`, selected `rev`, `limit`, `findstring`, `findtype`, `findtext`, `findregex`, `outfile` |
| `diff` | File Compare, or Working Tree for a directory | `path2` for two standalone files, paired `startrev`/`endrev` for historical comparison, `alternative` for the configured alternative tool, `unified`, `line` |
| `revert` | Revert review | Selected file/directory scope |
| `resolve` | Resolve review | Selected conflict/file/directory scope |

Both `/command:commit /path:...` and `--command=commit --path ...` work.
Native valued options accept `--name=value` or `--name value`. Legacy valued
options require `/name:value`. Flags have no value, for example `/wholeproject`
or `--wholeproject`. Names are case insensitive; user values retain their spelling.
Without `path`, the application's current directory is selected.

Repeat `--path` to select literal names containing `*`, spaces, Unicode or newlines.
Legacy `/path` retains TortoiseProc's `*` selection delimiter. Normal shell quoting
is required; TurtleGit never evaluates a command's message or path as shell code.
`path2` needs one primary selection, and cannot be combined with revisions.

Log limits accept a nonnegative commit count (`0` means unlimited), or a positive
number followed by `week(s)`, `month(s)` or `year(s)`. The existing history model
uses the source's fixed 7/30/365-day units. An omitted start endpoint in `endrev`
is a tip; `startrev` alone means `startrev..HEAD`. `range` overrides both.
`rev` selects a resolved commit without replacing the requested history range.
`findtype` is a decimal upstream mask: messages=1, paths=2, authors=4,
revisions=8, bug IDs=32, subject=64, reference names=128, emails=256, notes=512,
annotated tags=1024; 65535 selects all fields. The reserved regex bit is not a
search field. `findregex` wins over `findtext`, as upstream does.

A message file is read only after obtaining permission for that exact file or a
containing folder. Reads are cancellable and limited to regular files of at most
16 MiB. UTF-8 decoding follows the pinned upstream text reader, including malformed
sequence replacement and a BOM as content. Inline and file messages are mutually
exclusive, including an explicitly empty inline message. Message and issue presets
survive initial template loading. A second invocation in the same process refuses
to replace an existing Commit draft. Log invocations use independent windows.

## Permissions, lifetime and remaining parity

Arguments carry requests, not sandbox permissions. Repository launches reuse an
existing authorized session/bookmark or ask for the containing repository.
External message files and standalone Diff files use their own access requests.
Cancelling a picker stops that launch. Repository adoption, metadata permission
prompts and Git reads retain their existing cancellation/lifetime ownership.
Startup arguments are consumed once after both application launch and workspace
model readiness, regardless of their ordering.

Unknown commands, duplicate scalar options and incompatible or unsupported
switches produce an error in the workspace. They are not silently ignored.
This is a partial command-family port, not full TortoiseProc CLI compatibility.
Remaining entry behavior includes Diff `submodule` switches, Resolve
`silent`/`noquestion` automation, shared Windows HWND/group/taskbar/close-on-end
options, process exit/result signaling, and commands outside the documented families.
Windows paths must be converted to macOS paths by the caller. Full symbolic
Working Copy sentinel, permissive `_wtoi` parsing and every revision-expression
edge case are not claimed; malformed/incomplete native input is diagnosed.
Opening many instances with `open -n` is the caller's choice, not a test policy.

Reviewed source is pinned at
`7338078f8ddd924b8cddee35f512f2286072136d`:
`src/TortoiseProc/Commands/{Commit,Log,Diff,Revert,Resolve,RepoStatus}Command.cpp`,
`src/TortoiseProc/GitLogListBase.h`, `src/Utils/StringUtils.cpp` and
`src/Utils/UnicodeUtils.{h,cpp}`. Existing dialog layout reviews remain partial;
command dispatch does not certify all-dialog visual or functional parity.

## Path-list input and Log revision output

All documented commands also accept `pathfile` in place of `path`. UTF-8 (with optional
BOM), UTF-16 with a BOM, and unmarked UTF-16LE detected by zero bytes are read as
newline-separated paths. Use a BOM for unmarked wide text that could also be UTF-8;
a completely non-ASCII wide list without zero bytes is ambiguous to auto-detection. CRLF is accepted; blank lines are skipped. Paths keep
spaces and `*` literally. Relative entries use the app process's working directory.
For filenames containing newlines, the native `pathfile0` flag selects NUL-separated
UTF-8 records instead. The list is limited to 16 MiB and 4096 selections. Supplying
both `path` and `pathfile` is an error.

```sh
open -n -a 'TurtleGit for Mac' --args --command=commit \
  --pathfile '/absolute/selection.txt' --logmsg 'Describe the change'

open -n -a 'TurtleGit for Mac' --args --command=log \
  --path '/absolute/repository' --outfile '/absolute/selected-commit.txt'
```

`deletepathfile` explicitly removes the input list after a successful read and
validation, before repository dispatch, as TortoiseProc does. Invalid/cancelled
reads preserve it. Deletion requires permission for its containing folder, refuses
a symlink list, and checks the opened file identity before unlinking. The file's
contents still grant no access to the repositories they name; normal repository
permission is acquired separately. Input preparation owns its cancellation and
retains the grant until the worker has finished.

Log's `outfile` opens the normal single-commit picker. Accept writes only the
chosen commit's UTF-8 hash, without a BOM or newline; Cancel writes an empty file,
including replacing an existing output. The output folder must be authorized
before the picker opens. Results are written atomically once, retaining permission
through completion; Quit waits for outstanding command-file work. Closing the
initiating workspace cancels outstanding work before its write starts. An atomic
write already underway can finish. This is a file-result protocol; a process-exit
status protocol is still separate work.

## Unified Diff and initial source line

For a file, Diff's `unified` flag opens the configured unified viewer, including
its alternative-tool choice, with the captured revision pair or HEAD-to-working
comparison. The built-in viewer keeps the existing coloured editable patch,
Find and Save As commands. A directory still opens Working Tree, following source
command precedence. `path2` uses the standalone file comparison route.

```sh
open -n -a 'TurtleGit for Mac' --args --command=diff \
  --path '/absolute/repository/file.txt' --unified --startrev 'HEAD~1' --endrev HEAD

open -n -a 'TurtleGit for Mac' --args --command=diff \
  --path '/absolute/repository/file.txt' --line 120
```

A positive `line` requests a one-based destination source line after native text
alignment is ready; a value beyond the source is clamped to its last line. Zero
keeps normal initial navigation. The range uses source UTF-16 coordinates, keeping
Unicode, line endings and aligned gaps distinct from display rows. A line launch
gets its own comparison window, preserving an existing editor's work. External
Diff tool argument templates receive `%line`; zero is supplied when no line was
requested. Unified, image and submodule viewers have their own navigation and do
not consume a native text-line request.

## Clone, transport and reference dialog launches

These commands open their ordinary native options or browser window. No Clone,
Fetch, Pull, Push, branch/tag creation, checkout or replay is accepted merely by
passing an argument. The windows retain the normal coloured source icons,
settings, captured actions, progress, authentication and cancellation behavior.

| Command | Editable launch presets |
| --- | --- |
| `clone` | `url`, `exactpath`; `path` is the destination folder |
| `fetch` | `remote` |
| `pull` | Normal Pull defaults for the requested repository |
| `push` | `branch` selects the source |
| `branch`, `tag` | `rev` base, `name` |
| `switch` | `rev` |
| `refbrowse` | Reference browser at the requested repository |
| `repobrowser` | `rev`, defaulting to HEAD |
| `reflog` | `ref`, defaulting to HEAD |
| `rebase` | `upstream`, `force` |

```sh
open -n -a 'TurtleGit for Mac' --args --command=clone \
  --url 'https://example.invalid/team/project.git' \
  --path '/absolute/project' --exactpath

open -n -a 'TurtleGit for Mac' --args --command=branch \
  --path '/absolute/repository' --rev HEAD --name 'topic/new-work'

open -n -a 'TurtleGit for Mac' --args --command=rebase \
  --path '/absolute/repository' --upstream 'refs/heads/main' --force
```

Clone's `exactpath` suppresses automatic destination naming, including after URL
edits, following `CCloneDlg::OnURLChange`. Without it, normal destination-name
suggestions remain active. Launching Clone neither creates the destination nor
authorizes its contents; the existing Clone workflow obtains permissions when
needed. Explicit Branch/Tag names survive asynchronous base suggestions. Rebase's
Force flag affects the editable initial plan and survives deferred preparation;
a recovering operation keeps its saved session state. Another CLI Rebase request
focuses an existing Rebase dialog and asks that it be closed before applying new
presets, preserving its current plan.

Fetch, Pull and Push accept multiple repository roots through repeated literal
`--path` or a path file. TurtleGit prepares them in selection order, acquiring each
root's own permission and metadata access, then presents an independently owned
options window for each. Each window captures its own repository, transport
presets and access lease. These native windows are nonmodal; no operation starts
until its user accepts it. Closing/changing the initiating workspace, declining
permission, an invalid root or preparation failure stops the remaining queue;
previously opened windows remain available. This adapts the Windows modal loop:
the source can continue past invalid items, whereas native preparation stops at
that error. A multi-root selection must contain roots, rather than files or
subdirectories. A single repository request still accepts normal in-repository
selection paths. Another CLI request cannot retarget a batch already preparing.

Source review for this continuation covers
`Commands/{Clone,Fetch,Pull,Push,Branch,Tag,Switch,RepositoryBrowser,RefLog,Rebase}Command.cpp`,
`Commands/RefBrowseCommand.h` and `CloneDlg.cpp`, at the same pinned upstream
commit. Windows URL-protocol registration and every legacy command/shared switch
remain outside this continuation; unsupported options still report an error.

## Source-file actions and annotation launches

| Command | Source behavior and native destination |
| --- | --- |
| `blame` | One file; `endrev` selects a historical revision (HEAD by default), `line` selects a one-based source line |
| `prevdiff` | One file or directory; `unified`, `alternative` for file viewers |
| `add` | File-only selections start Add progress; a directory opens the scoped Add checklist |
| `rename` | One selected path opens the existing Rename input/progress workflow |
| `remove` | Selected files/directories open the normal Remove confirmation; `keep` removes from the index while retaining local files |

```sh
open -n -a 'TurtleGit for Mac' --args --command=blame \
  --path '/absolute/repository/file.txt' --endrev 'HEAD~2' --line 40

open -n -a 'TurtleGit for Mac' --args --command=prevdiff \
  --path '/absolute/repository/file.txt' --unified --alternative

open -n -a 'TurtleGit for Mac' --args --command=add \
  --path '/absolute/repository/new folder'

open -n -a 'TurtleGit for Mac' --args --command=remove \
  --path '/absolute/repository/file.txt' --keep
```

These commands also support the path-list input, authorization and explicit list
removal described above. Blame, Previous Diff and Rename require one path,
including after reading a list; invalid cardinality preserves a `deletepathfile`
input. Native `--path` arguments keep shell-quoted asterisks and Unicode literal.

Blame commands use separate viewers, preserving another viewer's selection and
settings. The requested source line is selected and scrolled after annotation
loads; values beyond the file clamp to its final line. Empty `endrev` selects
HEAD. Native Blame's existing annotation, Log/source menus and colored margins
are reused. Bare working-tree entry remains disabled. The Windows Working Copy
sentinel and separate TortoiseGitBlame executable's entire argument protocol are
not implemented by this TortoiseProc-style entry family.

Previous Diff chooses the second history entry **for the selected file**, then
compares it with working bytes; unrelated later commits do not change that base.
A directory opens Changed Files from `HEAD~1` to Working tree. Its directory
precedence ignores the file-only unified/tool choice, matching `PrevDiffCommand`.
Repository-open cleanup preserves the busy owner acquired by a comparison while
its question or Git reads are pending. Insufficient history reports the existing
error. Unified file requests use the
ordinary configured unified viewer (including the alternative tool), or the
built-in colored patch document. Ordinary file requests use the existing native
comparison/editor workflow and external-tool preference.

Add follows the source's immediate file-only behavior: invoking it for files is
an instruction to stage those files after authorization. No further checklist is
shown. A missing selected tracked file stages its deletion; an unknown missing
path reports a progress error. Directory selections open the checked Add list and
wait for OK. A new directory command refuses to replace an existing Add draft.
Preparation captures the repository, permission and initiating window, participates
in Quit ownership, and rejects a late reply after window closure or termination.
An explicit repository switch while preparation runs preserves the captured Add
repository; its completion cannot overwrite the new workspace's output.
`noui` is rejected: its upstream implementation is inactive and this port does not
silently reinterpret it as permission for a different operation.

Rename keeps an existing input draft for the same path; it runs only after OK.
Remove uses the existing source-style Remove/Abort question, defaulting to Abort,
and preserves the existing progress, Ignore/Abort errors and cancellation behavior.
`keep` is accepted only with Remove. New commands do not implicitly accept Rename
or Remove confirmation. Repository/file content is passed as Git arguments rather
than evaluated shell text.

Reviewed pinned handlers: `Commands/{Blame,PrevDiff,Add,Rename,Remove}Command.cpp`,
`AppUtils.cpp::LaunchTortoiseBlame`, `Git/TGitPath.cpp::AreAllPathsFiles` and
`TortoiseGitBlame/TortoiseGitBlameDoc.cpp`. Existing dialog layouts/icons and
backend operations are reused. This adds entry paths; it does not certify complete
source dialog, signed sandbox or process-exit protocol parity.

## Repository creation, Cleanup and Ignore

| Command | Native behavior |
| --- | --- |
| `repocreate` | One destination folder opens Create Repository, including a new folder inside an authorized existing parent |
| `cleanup` | Selected files/directories open Cleanup options; files use their containing directories |
| `ignore` | Selected paths open Ignore; `onlymask` selects extension patterns and `delete` asks about removal after writing rules |

```sh
open -n -a 'TurtleGit for Mac' --args --command=repocreate \
  --path '/absolute/parent/new-repository'

open -n -a 'TurtleGit for Mac' --args --command=cleanup \
  --path '/absolute/repository/generated folder'

open -n -a 'TurtleGit for Mac' --args --command=ignore \
  --path '/absolute/repository/generated.tmp' --onlymask --delete
```

These commands accept the common path-file input as well. `repocreate` requires
one destination, including after reading a list; invalid input is preserved when
`deletepathfile` was requested. Source Create Repository has no `bare` command
switch: the native dialog offers that option, with the existing `.git` destination
name default. Opening it does not initialize or reinitialize Git before OK.
Normal and bare completion reuse the owned workspace handoff described in
[Clone parity](CLONE-PARITY.md#workspace-completion-handoffs--october-18-2026).

A sandbox destination needs permission for both its folder and the existing
working directory from which Git creates it. A containing-parent grant supports
new nested folders without changing the requested destination. Folder choice
belongs to the initiating workspace, blocks Quit while pending, and consumes its
reply once. Cancel, workspace closure and termination reject late replies. A new
request preserves an outstanding chooser. Closing a Create dialog before acceptance
leaves Git unchanged; user-created folders in the system picker follow macOS's
normal behavior.

Cleanup opens the existing options, type/directory defaults and progress workflow;
it never accepts an operation from command arguments. Its flags remain native
controls: `dryrun`, delete policy and other invented command switches are diagnosed
rather than silently accepted. A second Cleanup launch preserves the open dialog's
scope and edited options. The common Git runner already uses literal pathspecs,
so selected names containing brackets/asterisks keep their normal file meaning.
Dry run retains files; accepted removal uses the existing preview, Trash/permanent
choice, metadata permissions, progress and cancellation handling.

Ignore opens the existing scope/destination radio groups and waits for OK. With
`onlymask`, the rule uses the selected extension. With `delete`, ignore rules are
written first, then the source-style Keep file locally? question controls removal
from the index or also from disk. Errors retain the existing per-path Continue/
Abort and summary behavior. Changing the destination and reopening the same
request preserves that draft. No new Keep prompt is bypassed by the CLI flags.

Linked worktrees resolve info/exclude through Git's common metadata directory.
An already-retained metadata grant authorizes that destination; a primary folder
grant alone does not. Ignore/removal selections and duplicate-rule detection retain
exact UTF-8 spellings, including canonical Unicode peers. Existing ignore comments,
line endings and unchanged bytes survive append. The source handlers reviewed are
`Commands/{CreateRepository,Cleanup,Ignore}Command.cpp`, `CleanTypeDlg.cpp` and
`AppUtils.cpp::IgnoreFile`. Full Windows process/shared-switch protocol, signed
sandbox acceptance and every native visual comparison remain open.

## Merge and Stash command entry

| Command | Native workflow | Source presets |
| --- | --- | --- |
| `merge` | Merge review, native reference/Log choosers and owned progress | `abort` opens Abort Merge instead |
| `stashsave` | Stash Save review and owned progress | `msg` supplies the editable message, including an explicitly empty message |
| `stashapply` | Apply the latest stash, then the source result question | No revision or message switches |
| `stashpop` | Pop the latest stash, then the source result question | No revision or message switches |
| `stashlist` | RefLog with `refs/stash` selected | Existing stash inspection, Apply and guarded deletion menus |

```sh
'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=stashsave --path '/absolute/repository' --msg 'Before integration'

'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=merge --path '/absolute/repository' --abort
```

The source Merge command supplies no revision/message option: choose them in the
native dialog. Merge, Abort and Stash Save wait for their native acceptance.
Apply and Pop are operation commands and run after repository authorization;
they retain existing progress, cancellation, conflict/result questions and
View Changes handoffs. Apply retains the stash; successful Pop removes it.
Selections and common path-file input locate the repository rather than limiting
these repository-wide operations to individual files.

A repeated Merge or Stash Save command brings its command-owned draft forward
without replacing edited options or the message. Repeated Abort entry reuses the
open repository review. Stash Save warnings capture their own request identity;
a cancelled or already-consumed reply cannot accept a newer warning snapshot.
A pending stash mutation refuses a competing Apply/Pop launch and an already-open
Save draft's acceptance until that operation settles. This is a native workspace
ownership guard, not an external-process Git lock or a global cross-workspace
transaction system.

Merge, Abort, Save and Restore use their owning workspace's preferences for
message history, progress, output and result prompts. Post-operation callbacks
retain their original repository and update the workspace output only while it
still displays that repository. The dialogs retain existing native controls,
source icons, choices and post-actions. Source review:
`Commands/{Merge,Stash}Command.cpp`, `Commands/Command.cpp` and
`AppUtils.cpp::{Merge,MergeAbort,StashSave,StashApply,StashPop}` at the pinned
revision. Complete process result/shared-switch compatibility and physical/signed
acceptance remain open.
