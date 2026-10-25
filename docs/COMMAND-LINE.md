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
| `diff` | File Compare, or Working Tree for a directory | `submodule` for a gitlink dialog, `path2` for standalone or paired historical files, paired `startrev`/`endrev` for historical comparison, `alternative` for the configured alternative tool, `unified`, `line` |
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
`path2` needs one primary selection. Without revisions it compares two different
standalone files; with paired `startrev`/`endrev` it compares primary-at-start
with path2-at-end, including the same path at two revisions.

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

## Inaccessible repository diagnosis

The `inaccessible` command opens a diagnostic for one selected repository folder
without requiring successful repository adoption:

```sh
open -n -a 'TurtleGit for Mac' --args --command=inaccessible \
  --path '/absolute/repository'
```

It reports the library's repository-open result. Launching the command does not
trust the folder or change configuration. When eligible, a separate explicit
trust action adds that exact folder to Git's global `safe.directory` entries.
The configuration directory may require its own macOS permission. Folder access
and Git ownership trust are separate decisions. An explicit Retry reopens the
selected repository; it does not accept the original Git operation. See the
[source contract and current acceptance scope](INACCESSIBLE-REPOSITORY-PARITY.md).

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
Remaining entry behavior includes shared Windows HWND/group/taskbar/close-on-end
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
command precedence unless `submodule` is supplied. Historical `path2` keeps the
file comparison route even with `unified`; standalone `path2` keeps its existing
file pair route.

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
`--path` or a path file. Original order and repeated roots are retained, matching
upstream's `orgPathList`; repeated inputs still use the multi-root rules. Each
item must be an actual working-tree root or bare-repository root. Invalid files,
subdirectories and non-repositories report preparation errors and are skipped so
later roots can still be handled. A single repository request retains normal
in-repository selection behavior.

The batch presents one actual options dialog at a time, with its own repository,
access lease and captured presets (`remote` for Fetch, `branch` for Push). No
transport starts until the user accepts its options. Cancelling or failing one
repository does not prevent later roots. The next root waits for the current
dialog, operation/result, sheets and source-modal follow-up chain to finish.
Independent source commands, such as Log or Commit launched from a result, keep
their own windows and do not hold the transport queue.

| Result action | Batch behavior |
| --- | --- |
| Fetch/Pull/Push again, Retry, Reset, Switch or Rebase | Finish this repository's workflow before advancing |
| Stash Save, Stash Apply/Pop, Request Pull or mail after Rebase | Finish the connected source-modal workflow before advancing |
| Log, Commit, Resolve, comparison, Submodule Update or Commit Superproject | Open independently, matching upstream's separate-process command |


Existing primary grants can cover roots separately; otherwise the batch uses an
owned asynchronous folder chooser. Declining the batch's access request stops it.
A chooser reply never grants access after cancellation or owner closure. Closing
or replacing the initiating workspace or quitting cancels the current owned
workflow and stops the remaining queue, retaining worker/grant accounting until
actual drainage. A later command or Service cannot retarget a pending batch.
The [transport batch evidence](qa/command-transport-batch-family-2026-10-20.json)
records the verified scope and remaining installed/signed acceptance.

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

## Patch series, archive and mailbox entry

| Command | Native destination | Presets |
| --- | --- | --- |
| `formatpatch` | Create Patch Serial | `startrev` alone selects Since and presets inactive From/To to `startrev~1`/`startrev`; paired `startrev`/`endrev` selects Range |
| `export` | Export ZIP | `rev` selects the revision; one selected directory presets subtree export |
| `importpatch` | Import Patch mailbox list | `droptarget` selects the destination repository independently of input files |

An end-only Format Patch value leaves the dialog defaults, as in the source.
An empty start value also leaves defaults. Export accepts one selected file or
directory, including after reading a path list. These commands open native
review controls; they do not generate archives/patches or apply commits before
acceptance. Repeated command entry preserves edited Format Patch and Export
drafts. Log's separate preset windows remain available.

```sh
'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=formatpatch --path '/absolute/repository' \
  --startrev 'HEAD~3' --endrev HEAD

'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=importpatch --path '/absolute/mailboxes/series.mbox' \
  --droptarget '/absolute/repository'
```

Import authorizes the selected input files independently of the repository.
Existing live grants can cover multiple selected inputs; retained per-file grants
reach preview, mailbox application and existing viewer/mail handoffs. Source
command input accepts every non-directory file, including mailbox names without
`.patch` or `.diff`. Reopening the same repository list preserves options, row
identities/check states and order, and appends only new exact paths. A busy Import
owner refuses list changes. No mail is sent by opening these commands.

Without `droptarget`, Import discovers the first selected path's repository when
its containing folder can be probed. Otherwise an owned native repository chooser
asks for the destination. A file-only grant does not authorize probing its parent
Git metadata. Cancelling a file grant or repository choice stops the launch.
Pending preparation blocks Quit/replacement; duplicate or late native replies,
closure of the initiating window and termination cannot adopt a repository or
open an Import window. An explicit Git metadata target is rejected. The normal
metadata-permission and bare-working-tree guards still apply during adoption.

Format Patch, archive Export and Import consumers receive owning workspace
preferences. Output-folder authorization, native options, progress, cancellation,
error/recovery and source icons remain their existing workflows. Source review:
`Commands/{FormatPatch,Export,ImportPatch}Command.cpp` and
`AppUtils.cpp::Export`, at the pinned revision. Complete Windows process protocol,
physical chooser/keyboard/layout and signed sandbox acceptance remain open.

## Stateful Bisect entry

`bisect` accepts source `start`, `good`, `bad`, `skip`, `reset` and `ref` options.
Good/Bad distinguish a missing option from a present empty value. Native syntax
accepts `--good`, `--good=revision` or `--good revision`; legacy syntax uses
`/good` or `/good:revision`. Start/Skip/Reset are flags without values. Common
path-file input retains the complete request while locating its repository.

```sh
'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=bisect --path '/absolute/repository' --start \
  --good 'known-good' --bad 'known-bad'

'/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac' \
  --command=bisect --path '/absolute/repository' --good --ref HEAD
```

Routing reads Git's actual session state before deciding the operation. With no
active session, Start opens the two-revision review and applies its editable
Good/Bad presets; empty Bad retains the native branch/HEAD default. It does not
start before native OK. Reopening an existing Start review preserves edited
inputs. Dirty tracked files retain the existing Stash/Abort acceptance path.

With an active session, the source priority is Good, then Bad, then Skip, then
Reset. Presence selects Good/Bad; their values are Start presets, while `ref`
selects the commit for an active classification. Empty or omitted `ref` means
current HEAD. Reset ignores `ref` and restores the session's original revision.
An active `start` combined with an operation flag follows that operation;
`start` alone while active is refused. No operation flag without Start while
inactive is accepted. Requests with no applicable operation report the source
“Operation unknown or not allowed.” result without mutating Git.

Good/Bad delegate to the session's custom Git terms. Active operations use the
existing owned progress, cancellation/recovery and continuation controls. A live
picker or operation refuses a competing command rather than queuing it. Invalid
state still publishes the recovered session so Reset remains available. Owning
workspace preferences reach progress/pickers; retired windows refuse late work.
Source review is pinned `Commands/BisectCommand.cpp` and
`AppUtils.cpp::{BisectStart,BisectOperation}`. This does not establish all legacy
argument permissiveness, cross-process locking, physical interaction or signed
App Store acceptance.

## Submodule Add, Update and Sync entry

| Source command | Native destination and inputs |
| --- | --- |
| `subadd` | One selected path opens Submodule Add; an ordinary file supplies its containing directory. Repository/Path histories and key controls remain editable; Add runs only after OK |
| `subupdate` | `bkpath` selects the discovery base; otherwise use the first selected path's parent. The nearest repository must contain `.gitmodules`. Selected directories filter the module list; `selectedpath` supplies a relative initial selection |
| `subsync` | The same superproject lookup and optional `bkpath`; immediately opens the existing Sync progress workflow. Selected directories run in order, ordinary files are skipped, and a file-only selection does not become whole-project Sync |

```sh
open -n -a 'TurtleGit for Mac' --args --command=subadd \
  --path '/absolute/project/vendor'

open -n -a 'TurtleGit for Mac' --args --command=subupdate \
  --path '/absolute/project' --bkpath '/absolute/project' \
  --selectedpath 'vendor/library'

open -n -a 'TurtleGit for Mac' --args --command=subsync \
  --path '/absolute/project/vendor/library'
```

For root-folder requests, pass `bkpath` explicitly: the pinned handler's default
is the selected path's parent. Lookup stops at the nearest repository; a child
repository without `.gitmodules` does not search past its own boundary. The app
requires a folder grant covering the selected paths, discovery base and resolved
superproject. Neither a CLI path nor `bkpath` grants access. An outside selection,
missing superproject, insufficient grant or declined authorization stops dispatch.
Path-list input derives its default base after reading the list, and invalid
single-path Add lists are retained even with `deletepathfile`.

`selectedpath` is relative to the superproject and rejects absolute/traversing
paths. Legacy `/selectedpath:` converts Windows separators to `/`; native
`--selectedpath` retains literal backslashes. A requested selection is intersected
with the configured paths in the filtered list. Whole Project and persisted
Update options retain the ordinary dialog behavior. Existing Add/Update drafts
are focused and preserved when another command arrives, with an explicit error;
active Add/Update/Sync progress owners refuse a competing command for the same operation. No command
implicitly accepts Add or Update. Sync follows its immediate source semantics.

All entry routes reuse the native source-layout forms, original action icons,
owned Add key/source/path sheets, option persistence, progress/cancellation and
Update's Bisect post-actions. Workspace preferences now reach all three dialog
and progress families. Source review covers pinned `Commands/SubmoduleCommand.cpp`,
`Git/GitAdminDir.cpp::GetSuperProjectRoot` and the existing Add/Update resources.
The [batch evidence](qa/submodule-commands-2026-10-18.json) records grouped checks
and limits. Physical interaction, external metadata/security-scope grants,
network/key execution and signed App Store acceptance remain separate work.

## Synchronization and SVN entry

| Source command | Native behavior |
| --- | --- |
| `sync` | Opens Git Synchronization for the authorized working tree; `seq` supplies source startup placement sequencing |
| `svnfetch` | Starts the existing SVN Fetch progress workflow and exposes fetched Diff/Log post-actions when the upstream changes |
| `svnrebase` | Runs the existing tracked-change Stash question, SVN Fetch, and up-to-date / fast-forward / native Rebase continuation |
| `svndcommit` | Opens the normal DCommit Type options unless this repository has a remembered type; Remember and Git Style retain their ordinary semantics |
| `svnignore` | Opens Import SVN Ignore's destination choices and waits for OK before overwriting exclude or creating `.gitignore` |

```sh
open -n -a 'TurtleGit for Mac' --args --command=sync \
  --path '/absolute/project' --seq 3

open -n -a 'TurtleGit for Mac' --args --command=svnfetch \
  --path '/absolute/git-svn-project'

open -n -a 'TurtleGit for Mac' --args --command=svndcommit \
  --path '/absolute/git-svn-project'
```

All five accept the common path-list input and require an authorized working tree;
bare repositories are refused. SVN also retains its existing runtime/remote
validation. Fetch/Rebase are immediate source operations after those checks;
DCommit follows its saved type/options and Ignore retains explicit acceptance.
These are not silent option-bypass commands. Unsupported command-specific options
report an error. Network authentication, permission and progress ownership remain
in their existing native workflows.

`seq` accepts a signed 32-bit integer only with `sync`. With the advanced
**Randomize Sync Dialog startup position** setting enabled, positive sequences
use the source modulo-five, 30-point offset and 150-point wrap, constrained to the
macOS visible screen. Zero, negative or omitted CLI values add no offset. Ordinary
in-app Sync launches retain their native placement sequence. Another request
focuses an existing Sync review without moving it or replacing edited inputs.
Workspace preferences reach both Sync and SVN forms/progress.

An existing SVN options draft, active operation, cancellation decision, attached
sheet or controller question retains its owner. This includes a question still
held by an otherwise finished operation. A competing operation focuses that
window and reports that the current workflow must finish. Repeated same-operation
options requests preserve fields; a completed, question-free workflow can be
replaced by another operation. No request implicitly accepts an existing draft.

Reviewed pinned handlers are `Commands/{Sync,SVNFetch,SVNRebase,SVNDCommit,SVNIgnore}Command.cpp`,
`SyncDlg.cpp` placement and `AppUtils::SVNDCommit`; the existing native resource
forms/icons are reused. [Dated evidence](qa/sync-svn-commands-2026-10-18.json)
records actual Git state checks with private injected SVN transport, selected
native checks and remaining limits. It does not certify public SVN transport,
physical interactions, signed grants, complete source dialogs or App Store use.

## Historical comparison, Cat, references and Graph output

| Source command | Native destination and inputs |
| --- | --- |
| `showcompare` | One selected file/directory; `revision1` is the base and `revision2` the destination, with `unified` and `alternative` viewer selection |
| `cat` | One selected historical file or blob context; required `revision` and `savepath` publish the filtered file bytes after repository/output authorization |
| `commitisonrefs` | Opens an independent References commit is on window; optional `rev` supplies the editable revision, while empty/omitted input remains blank |
| `revisiongraph` | Opens Revision Graph normally; nonempty `output` loads/renders a separate hidden graph and writes the selected format |

```sh
open -n -a 'TurtleGit for Mac' --args --command=showcompare \
  --path '/absolute/project/file.txt' --revision1 'HEAD~1' --revision2 HEAD

open -n -a 'TurtleGit for Mac' --args --command=cat \
  --path '/absolute/project/file.txt' --revision HEAD \
  --savepath '/absolute/output/file.txt'

open -n -a 'TurtleGit for Mac' --args --command=commitisonrefs \
  --path '/absolute/project' --rev HEAD

open -n -a 'TurtleGit for Mac' --args --command=revisiongraph \
  --path '/absolute/project' --output '/absolute/output/history.svg'
```

ShowCompare's native directory route uses Changed Files; a file opens the existing
comparison viewer, and Unified uses the owned configured unified-viewer path.
An empty/omitted side, or a 40/64-zero working-copy sentinel, selects Working tree;
this port currently requires at least one actual revision. Both-working/empty
source requests remain a command parity gap. Commit/tree revisions retain the
normal comparison resolver. Bare repositories can compare two historical sides;
a Working tree request there reports the existing error. Native literal paths
retain spaces, Unicode and glob characters; legacy `/path:` still uses `*` to
separate selections. Cat and ShowCompare reject multi-path lists before an
explicitly requested input-list deletion.

Cat resolves its revision/object once, peels tags and reads an exact blob path
from a commit/tree, or accepts a direct blob/object expression such as
`HEAD:path with spaces`. Git's `cat-file --filters --path=…` supplies checkout
filters/EOL conversion using the selected path, matching the filtered-file
workflow rather than checking out a file or changing the index. This is a native
Git adaptation of CatCommand's blob/GetOneFile branch; it does not reproduce all
Windows CLI-versus-libgit2 backend differences. Deleted directories, current file/directory collisions and bare
virtual file paths discover an existing authorized directory before Git runs.
Custom filters can invoke their configured helpers and retain ordinary sandbox
restrictions; public LFS/filter/Keychain acceptance is separate.

`savepath` and Graph `output` require their own parent-folder permission. Bytes
are staged in a private file and published with one directory-relative atomic
rename only after the initiating native owner remains valid. Closing that owner
or terminating its workspace cancels the read/render/staging work. A failed or
cancelled operation preserves an existing destination; temporary files are
removed. This deliberately avoids upstream Cat's error-path destination deletion.
The owner retains both repository and output scopes through completion and
participates in Quit accounting. Separate concurrent external writers are not
serialized by this local ownership mechanism.

Graph output selects SVG, GV/DOT, PNG, JPEG, BMP, GIF or native PDF from the file
extension, with the same graph model, fonts, colors and export renderer as Save
Graph As. An extensionless output or an unknown suffix appends `.jpg` and uses
JPEG, matching the source fallback. For example, `--output history.custom`
writes `history.custom.jpg`. Output authorization names that final path before
rendering or writing. Windows WMF/EMF are refused before output permission or
writing; PDF provides the native vector alternative, and metafile graph writing
remains unported. Hidden
output owns a separate graph and does not retarget an existing interactive graph.
A normal Graph command reuses its existing view and preserves its filters.

Standalone containing-reference windows retain independent editable input,
filter, source icons, reference actions and pickers. Show Log, Browse, comparison,
unified output and navigation have workspace consumers using the captured
repository/access. Closing a window retires its reads and any later unified
handoff. The application remains running after Cat/hidden Graph completion;
Windows' separate TortoiseProc process-exit/return-code contract is not implemented
by this native application entry path.

Pinned review covers `Commands/{ShowCompare,Cat,CommitIsOnRefs,RevisionGraph}Command.cpp`,
`GitDiff::DiffCommit`, `FileDiffDlg`, unified launch and Graph save/hidden completion.
[Batch evidence](qa/history-commands-2026-10-18.json) separates actual byte/Git/native
checks from full dialogs, filters, physical/signed and App Store acceptance.

## Git LFS commands

| Command | Behavior | Options |
| --- | --- | --- |
| `lfslocks` | Open/focus the server-wide LFS Locks list | shared path/path-file inputs |
| `lfslock` | Lock the selected literal files through native progress | shared path/path-file inputs |
| `lfsunlock` | Unlock the selected literal files through native progress | `force`, shared path/path-file inputs |

```sh
open -n -a 'TurtleGit for Mac' --args --command=lfsunlock --force \
  --path '/absolute/repository/large asset.bin'
```

Lock and Unlock are direct action commands and start their selected batch after
repository authorization. They do not add a separate confirmation absent from
upstream. Only Unlock accepts Force. Failed Unlock offers the existing explicit
Force retry for the captured paths. Selection validation finishes before the
first remote mutation; cancellation cannot undo locks already changed remotely.
The list preserves an existing window's checks and Force draft. Its server-wide
locks query follows pinned `LFSLocksDlg`/`GitStatusListCtrl`, even when entry was
through one file. Directory LFS actions are refused. Direct commands accept
missing/unversioned literal files and leave per-file eligibility to Git LFS;
Finder's cached menu entry additionally revalidates versioned targets.

These commands inherit the owning presentation settings and existing native
progress icons, Log/Pull post-actions and result review. Delayed preparation is
cancelled when its launching window closes or the workspace retires. Local
injected-reply checks do not establish a real authenticated LFS provider or
signed Finder integration; see [LFS parity](LFS-PARITY.md).

## Worktree creation and management entry

| Command | Native workflow | Options |
| --- | --- | --- |
| `worktreecreate` | New Worktree | one repository path or shared path-file input |
| `worktreelist` | Worktree List | one repository path or shared path-file input |
| `dropworktreecreate` | New Worktree with a dropped-folder destination preset | required `droptarget`, one source repository |

```sh
open -n -a 'TurtleGit for Mac' --args --command=worktreelist \
  --path '/absolute/repository'
open -n -a 'TurtleGit for Mac' --args --command=dropworktreecreate \
  --path '/absolute/source.git' --droptarget '/absolute/destination-folder'
```

These entries open the existing source-style forms and do not accept creation or
management actions. Normal creation proposes `<repository>-worktree`, or strips
`.git` from a repository ending in that suffix. Drop creation appends the source
repository basename to `droptarget`, stripping `.git`; if that would propose the
source repository itself, it keeps the drop folder. Preset construction is lexical
and does not probe or authorize the external destination. Bare repositories can
create linked checkouts through the same native form.

A competing Create/drop command focuses an existing creation form, manager-owned
Add child or progress review, preserving its input and captured operation. List
entry reuses its current manager and preserves active management/review state.
Forms, pickers, progress and manager children inherit the owning preferences.

On OK in a scoped build, a typed destination outside existing grants asks for the
worktree directory or an existing parent folder. It captures destination and Git
options before that chooser; Cancel, wrong-folder replies and late replies after
closure cannot start a mutation. No destination grant is inferred from `droptarget`.
The source and destination permissions remain held through Git execution, and
Submodule Update retains both the new checkout and its external source metadata.
A created checkout queues a manager refresh through current child/result review.

The command is available for integration callers. Automatic Windows-style Finder
drag-menu interception is not implemented by this entry route. Lexical source
self-comparison does not certify all case/normalization/symlink-alias spellings.
Physical Finder, signed access and complete visual parity remain open; see
[Worktree parity and evidence](WORKTREE-PARITY.md).

## Request Pull and Send Mail entry

| Command | Native workflow | Inputs |
| --- | --- | --- |
| `requestpull` | Request pull | one repository; optional editable `endrev` and `url` |
| `sendmail` | Send Patch options/progress | ordered file paths or a shared authorized path file |

```sh
open -n -a 'TurtleGit for Mac' --args --command=requestpull \
  --path '/absolute/repository' --endrev topic --url '/absolute/published.git'
open -n -a 'TurtleGit for Mac' --args --command=sendmail \
  --path '/absolute/1.patch' --path '/absolute/2.patch'
```

Request Pull preserves the source's editable end revision and repository URL;
missing/empty presets retain saved history/defaults. A later command focuses its
existing command window and preserves its options, picker, generation and mail
handoff. Normal independent app entry remains separate. No request is generated
until OK. The owning settings govern the form, history, Start Log and mail route.

Send Mail uses the original ordered file list, including duplicate occurrences,
matching `SendMailCommand::orgPathList`. Finder's selection remains deduplicated.
Native repeated paths preserve literal asterisks/newlines/Unicode; legacy `/path:`
uses its `*` separator. Path files retain order/duplicates and the usual bounded,
authorized read and explicit optional deletion. No extension/existence filter narrows the
original file list. Missing paths or directory entries remain visible and can be
unchecked; acceptance reads/prepares only checked files, so a bad unselected entry
does not block the valid selection. Opening the options does not send or prepare a
message in another app.

File preparation captures its launching window, settings, selected files and
permission state. Scoped builds use an owned native files/folders chooser; Cancel,
wrong grants, window close and retirement prevent a later composer handoff.
Pending work remains accounted for until it drains. A first-file repository
supplies sender identity only within granted folders; linked metadata/object
folders request separate access before Git runs. Source and related scopes remain
with the workflow. Saved grants can be renewed without reordering Recents.
Files outside a discovered repository use an exclusive private Git-global context
and leave the active checkout unchanged. That directory is removed when its
owning workflow releases it. Every options/progress workflow retains its own
files, preferences and sender context through review and delivery.

These are native startup routes into the existing source forms, original icons,
preview/checkbox/subject behavior and delivery backends. Local grant-policy and
loopback checks do not establish physical Finder input, real scope issuance,
public SMTP/Apple Mail acceptance or signed App Store approval. See
[Request Pull](REQUEST-PULL-PARITY.md) and [Finder mail](FINDER-LFS-MAIL-PARITY.md).

## Settings, About, Help and First Start entry

`about` and `help` open their existing native application services without
repository discovery or a required Git executable. Command Help selects the
manual overview; normal dialog Help remains contextual. `firststartwizard`
opens/reuses the native setup wizard. Numeric `page` values 0–4 select Language,
Welcome, Git, User and Authentication; missing/invalid/out-of-range pages start
at Language. An existing wizard keeps its page/draft and active work. Explicit
wizard startup does not race the automatic first-run Language page.

User/Authentication initial pages bootstrap the selected engine's global identity
and credential configuration without applying engine settings or writing Git
configuration. The existing native permission, Next/Back/Finish, credential and
key-generation paths remain. Closing bootstrap cancels and waits for its actual
read to drain; a late reply cannot populate a retired wizard.

`settings` accepts one selected path plus an optional source `page` name. It
looks for repository markers within available folders before requiring Git.
Outside a repository it opens Global Settings and leaves the current checkout
unchanged. Inside a repository it resolves/authorizes metadata and uses normal
workspace adoption/rollback, unless already in that repository. Modified/active
Settings can refuse a different context. Defaults are Git inside a repository
and General outside; unknown or unavailable page names retain those defaults.

| Source page name | Native page |
| --- | --- |
| `main`, `look`, `extmenu` | General, Context Menu, Set Extended Menu Item |
| `dialog`, `dialog2`, `dialog3` | Dialogs 1, 2, 3 |
| `color1`, `color2`, `color3` | Colors 1, 2, 3 |
| `alternativeeditor` | Alternative Editor |
| `gitconfig`, `gitremote`, `gitcredential` | Git, Remote, Credential |
| `hooks`, `bugtraq`, `bugtraqconfig` | Hook Scripts, Issue Tracker Integration, Issue Tracker Config |
| `overlay`, `overlays`, `overlayshandlers` | Icon Overlays, Icon Set, Overlay Handlers |
| `proxy`, `smtp` | Network, Email |
| `diff`, `merge` | Diff Viewer, Merge Tool |
| `save`, `blame`, `udiff`, `advanced` | Saved Data, Blame, Unified Diff, Advanced |

Names are case-sensitive as in `Settings.cpp`. Remote and Issue Tracker Config
require a repository for source command selection. Windows-only `win11menu` is
unavailable on macOS and uses the normal fallback; Finder configuration uses the
native Context Menu pages. Remote command entry sets the source No Fetch policy
for that Settings window; saving a remote does not ask for the post-save Fetch.
Idle page jumps reuse the same window and retain its transaction/page drafts;
active operations or child questions refuse page changes. Owning preferences are
forwarded into Settings and embedded Remote. macOS does not need the source's
Windows administrator-only Credential property sheet.

```sh
open -n -a 'TurtleGit for Mac' --args --command=settings \
  --path '/absolute/repository' --page gitremote
open -n -a 'TurtleGit for Mac' --args --command=firststartwizard --page=3
```

[Utility batch evidence](qa/utility-commands-2026-10-18.json) separates local
source/default/lifecycle checks from real Help browser, physical pickers,
rendered/VoiceOver parity, signed deployment and App Store acceptance. The later
[service command continuation](#daemon-updates-autotext-and-introduction-entry)
records Daemon, updates, Autotext and introduction entry. Release administration,
remaining command contracts and full source acceptance remain separate work.

## Dropped-file Move and Copy/Add entry

The active source `dropmove` and `dropcopyadd` commands accept explicit source
`path` arguments or an authorized path file, plus the required `droptarget`
folder. `dropmove` also accepts `rename`; it asks for a new name when one source
is selected. These explicit operation commands begin after destination/source
validation. Ordinary app menu, clipboard and receiving-sheet entries retain
review before execution.

```sh
open -n -a 'TurtleGit for Mac' --args --command=dropmove \
  --path '/absolute/repository/file.txt' --droptarget '/absolute/repository/folder'
open -n -a 'TurtleGit for Mac' --args --command=dropmove \
  --path '/absolute/repository/file.txt' --droptarget '/absolute/repository/folder' --rename
open -n -a 'TurtleGit for Mac' --args --command=dropcopyadd \
  --path '/absolute/external/folder' --droptarget '/absolute/repository/folder'
```

Destination authorization and linked metadata discovery happen before adopting
the target working tree. Move requires versioned sources from that same working
tree; outside, bare, administrative and nonfolder destinations are refused.
Original source URLs stay independent of the destination used for repository
adoption. Git administrative source entries are skipped. Copy/Add also skips a
source equal to the destination folder. Native transfers retain the exact ordered
unique file identities used by their existing menu/clipboard workflows.

Move starts the existing `git mv` progress, including collision name sheets,
optional Move/Rename and ordered Ignore/Abort recovery. Separate index/working
bytes remain separate. Copy/Add starts its existing external-source authorization,
Overwrite/Keep/Cancel and copied repository/submodule metadata Delete/Ignore/Abort
workflow, then ordinary Git Add after the copy batch. Neither command commits.
Earlier successful moves/copies remain when later work fails or is cancelled.

Preparation captures the initiating window, grants, input list and preferences.
Window closure/retirement cancels pending work; transferred adoption retains the
original owner. The operation window owns work after handoff, and counters/grants
remain held through actual cancellation drain. A late source grant cannot resume
a retired Copy/Add window. The native result view remains available for Close.

This command family does not add Finder right-drag interception. Windows' disabled
`dropcopy`, `pastecopy` and `pastemove` command aliases remain disabled; macOS
clipboard commands have their existing native entry points. See
[transfer command evidence](qa/transfer-commands-2026-10-18.json) and
[dropped-file workflow parity](FILE-DROP-TRANSFER-PARITY.md) for validation and
physical/signed/source acceptance gaps.

## Daemon, updates, Autotext and introduction entry

`daemon` accepts one repository/file path and opens the existing source warning
and native progress workflow, including bare repositories. It does not bypass
Proceed/Abort or the remembered Proceed choice. Repeated commands reuse that
repository's warning/progress/result window and cannot launch a second server.
The selected repository/grant and owning preferences reach the existing runner.
Normal serving retains upstream's port/listen/export defaults; private tests use
loopback/injected workers. See [Daemon parity](DAEMON-PARITY.md).

`updatecheck`, `autotexttest` and `rtfm` need no Git executable or repository.
They use the application's existing utilities without adopting the current path.

| Update command | Behavior |
| --- | --- |
| `updatecheck` | Check quietly; display an available release, otherwise finish without a window |
| `updatecheck --visible` | Show the result, including up-to-date, empty-feed and error results |
| `updatecheck --force` | Offer the published release even if its valid version is equal/older; show the result when available |
| `updatecheck --visible --force` | Show the forced check and its result immediately |

Explicit checks bypass the weekly scheduling preference/deadline. A visible
request promotes an in-flight quiet check without a duplicate request. Force can
promote that check or its already-displayed result; it preserves the current
window, selected files and accepted downloads. Up-to-date ordinary checks do not
offer download controls. Version/feed/integrity/URL errors remain errors; Force
does not bypass asset validation, SHA-256 checks or non-overwriting publication.
Cancelling a quiet request retires delivery while accounting remains until actual
transport return. App Store builds never query/download GitHub releases; visible
or forced checks show the App Store explanation, while ordinary quiet checks finish.

`autotexttest` opens/reuses the native Autotext Tester. Content, regex and a running
scan survive repeated entry; closing cancels the scan and rejects late results.
Command-owned windows are independent of a Settings page's tester child. Both
carry the owning preferences. The packaged ECMAScript matcher is unchanged.

`rtfm` adapts the source launch explanation to the native client. It explains the
File/Finder entry points and offers Help or OK. Help opens the manual overview;
OK opens Documents in Finder. A failed Documents launch remains visible for
retry. Repeated entry reuses the explanation; closed windows reject stale actions.
Ordinary application startup still opens the native repository workspace.

```sh
open -n -a 'TurtleGit for Mac' --args --command=daemon --path '/absolute/repository'
open -n -a 'TurtleGit for Mac' --args --command=updatecheck --visible --force
open -n -a 'TurtleGit for Mac' --args --command=autotexttest
open -n -a 'TurtleGit for Mac' --args --command=rtfm
```

[Service command evidence](qa/service-commands-2026-10-18.json) records grouped
validation and separates injected/private execution from public release/LAN
behavior, physical Help/Finder actions, complete layout and signed Store acceptance.

## Standalone conflict editing

`conflicteditor` opens the existing specialized editor for one conflicted file or
submodule. `alternative` selects the alternative merge tool; without it the
normal choice is explicit, independent of currently pressed modifier keys.

```sh
open -n -a 'TurtleGit for Mac' --args --command=conflicteditor \
  --path '/absolute/repository/conflicted-file.txt'
open -n -a 'TurtleGit for Mac' --args --command=conflicteditor \
  --path '/absolute/repository/conflicted-file.txt' --alternative
```

Authorized path files retain the same flag and single-item requirement. A missing
working file can still open Delete/Modify from its index stages. Initialized
submodule selections follow the shared superproject conflict resolver. Bare and
repository-root-only selections are refused.

Preparation captures the original window, input and preference store, authorizes
working-tree/linked metadata, and uses normal adoption/rollback before routing.
Native Text, Image, Delete/Modify and Submodule editors share captured settings
and exact conflict identities. Duplicate native entry preserves the current
controller/draft. Closing during preparation cancels it and retains ownership
until the actual read returns; a late reply cannot open another editor.

See [conflict editor parity](CONFLICT-EDITOR-PARITY.md) and
[batch evidence](qa/conflict-commands-2026-10-18.json) for actual validation and
remaining source, external-tool, physical and signed acceptance.

## Resolve review and automation

`resolve` accepts `silent` and `noquestion`, independently:

| Flags | Source-compatible behavior |
| --- | --- |
| Neither | Checked conflict review, then native progress |
| `silent` | Checked review, then apply without progress; errors remain visible |
| `noquestion` | Skip review and show Skip progress for the raw argv list |
| Both | Force-add the original selected paths without review/progress |

```sh
open -n -a 'TurtleGit for Mac' --args --command=resolve \
  --path '/absolute/repository/resolved.txt' --noquestion --silent
```

Both flags preserve literal repeated paths and authorized path-list inputs.
Direct Silent also accepts ignored/unversioned files and directories, including
the working-tree root; it stops on the first failure and does not commit.
`noquestion` alone retains the pinned source's Skip behavior because bypassing the
review does not populate conflict-action flags. It must not be used as an alias
for the combined direct-staging mode. See [Resolve command parity](RESOLVE-PARITY.md#resolve-command-modes-and-shared-ownership--october-18-2026).

Permission/metadata access, original owner/preferences and full-path validation
still apply. Repeated reviews retain checked work, duplicate pending direct batches
coalesce, and cancelled/closed owners suppress late delivery through actual drain.
Windows HWND refresh and process-result protocols remain unported.


## Diff submodule and historical entry family — October 18, 2026

`diff --submodule` opens Submodule Diff for one selected gitlink. It retains the
source From/To subjects, change colours, Log buttons, dirty Show Diff, Compare,
identical-pointer Working Tree and Submodule Update options/progress. The source
has one `submodule` switch; `submodulepath` and `submoduleforce` are not aliases.
Paired `startrev`/`endrev` select superproject commits whose gitlinks supply the
child hashes. Forty- or sixty-four-zero working sentinels compare the other
revision against the actual child checkout; two working sides compare the indexed
gitlink with that checkout. Each dialog button captures its own current Shift
alternative-tool choice, as the source does.

`submodule --unified` follows the unified patch route instead. Without `submodule`,
a directory still opens Working Tree before applying revision/unified options.
Historical `path2` reads primary-at-start and path2-at-end without checking out
files. The two paths can match and their parent folders can have disappeared.
Paths must belong to the same repository for this historical route; a destination
outside it falls back to the existing standalone pair after repository access.
An existing directory endpoint uses the source's destination-path submodule route.
Explicit pairs whose sides are both historical also work in bare repositories;
a working sentinel is refused there.

Repository access, metadata scopes, the initiating owner and preferences remain
captured through preparation and the actual comparison drain. Closing an owner
cancels pending preparation; changing workspace preferences during a permission
callback does not retarget the command or its Submodule Diff child Log/Compare.
This extends the existing dialogs; it does not certify all upstream visual parity,
physical Finder integration or a signed/App Store distribution.


## Standalone Merge-tool entry

The same app executable accepts `--merge-tool` and source Merge arguments such as
`/base:… /mine:…`, independently of `/command:…` repository dispatch. Run it
through the waiting [wrapper](../scripts/turtlegit-merge) for Git difftool/mergetool;
using `open --args` alone does not provide the waiting/result contract.
[Setup and examples](MERGE-TOOL.md) cover separate merged output, names, readonly,
initial line, missing-input empty panes, patch chooser/reverse entry and unified
output. [Source review](MERGE-TOOL-ENTRY-PARITY.md) records the exact accepted
arguments, remaining Blame/reflected-header/Windows protocol gaps, and completion
and cleanup adaptations. Native labels and reflected names never replace the
file paths or grant filesystem access.


## Standalone Unified Diff

Launch the app executable with `--unified-diff` to create an editable Unnamed
document, or provide one file or an explicit stdin stream. This mode opens only
the native Unified Diff window, without a repository workspace or first-start
wizard. Opening, editing and saving text do not require a Git executable.

```sh
"/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac" --unified-diff
"/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac" --unified-diff --patchfile changes.txt --title "Review changes"
git diff --binary | "/Applications/TurtleGit for Mac.app/Contents/MacOS/TurtleGitMac" --unified-diff --stdin --title "Working tree"
```

The source aliases `/patchfile:path`, `/p` and `/title:caption` are also accepted.
An arbitrary filename is allowed in this explicit mode; ordinary macOS document
associations remain `.patch` and `.diff`. Use `--` before a literal filename that
looks like an option. Choose a single input; conflicting inputs, duplicate titles
and malformed options are rejected. `/command:` and `--command` retain their
repository-command meaning.

Stdin is consumed only with `--stdin` or `/p`. EOF publishes the captured bytes as
one document, including empty EOF; partial input is not editable. The input limit
is less than 250 MiB. Closing the window cancels and drains its reader. Quit
cancels all active readers, waits for them, then performs the normal unsaved
document decisions. The caller's descriptor is never closed or reconfigured.
File inputs must resolve to regular files; use stdin for pipe input. Sandboxed
command-line file arguments require an explicit matching file selection if no
file scope is available; the argument itself grants no access.

The File menu's Dark Mode command changes only the current viewer. Save, Save As,
Find, Print and Settings reuse the existing document workflow. Apply Patch resolves
the configured Git engine when invoked and opens the existing target/review
workflow. The command process stays alive until its document closes and accepted
external workspace handoffs finish. See
[the implementation and validation record](UNIFIED-DIFF-STANDALONE-PARITY.md) for limits.

### Finder/document delivery while a standalone Merge or Unified Diff tool is open

The application delegate receives macOS URL/document events. An ordinary workspace
queues early events until its model and startup command are ready, then delivers
them once in received order. The former window-view URL handler is removed so an
event has one owner.

A standalone Merge or Unified Diff process forwards supported `turtlegit://action` requests and
`.patch`/`.diff` documents through Launch Services to a fresh workspace instance,
with empty launch arguments. It preserves the URL list, order and duplicates;
Merge input/output arguments are never inherited by the new workspace. Unknown
schemes/actions and unrelated document types do not launch a workspace. URLs
carry selection, not access authority; ordinary workspace checks still apply.

Accepted launches retain their file scopes through the Launch Services callback.
Failures have an owned native acknowledgment even if the Merge editor has closed.
The waiting Git tool's captured result is unchanged and exits only after its
external launch work has drained. User Quit refuses active handoff work. Retiring
the parent never terminates an independently launched user workspace.
See [handoff review](WORKSPACE-OPEN-HANDOFF-PARITY.md) for verification limits.
