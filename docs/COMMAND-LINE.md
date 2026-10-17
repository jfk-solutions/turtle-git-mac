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
| `log` | Log Messages | `startrev`, `endrev`, deprecated `revstart`/`revend`, overriding `range`, selected `rev`, `limit`, `findstring`, `findtype`, `findtext`, `findregex` |
| `diff` | File Compare, or Working Tree for a directory | `path2` for two standalone files, paired `startrev`/`endrev` for historical comparison, `alternative` for the configured alternative tool |
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
Remaining entry behavior includes `pathfile`/`deletepathfile`, Log `outfile` picker
and output protocol, Diff `unified`/`line`/`submodule` switches, Resolve
`silent`/`noquestion` automation, shared Windows HWND/group/taskbar/close-on-end
options, process exit/result signaling, and commands outside the six families.
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
