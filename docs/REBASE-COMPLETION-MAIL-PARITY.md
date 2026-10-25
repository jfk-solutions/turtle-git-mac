# Rebase completion export and Send Mail

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`AppUtils.cpp::RebaseAfterFetch` at 2495–2512 and `SendPatchMail` at 2140–2167.
This connects the `IDD_REBASE` completion action to the existing native Send Mail
workflow. It is a partial family audit, not certification of either full dialog.

## Source behavior

After a successful Rebase opened after Fetch, Send Mail immediately runs
`git format-patch -o <repository> --end-of-options <upstream>..<branch>`.
Both endpoints use the source branch-name normalization. It does not open the
Format Patch options dialog or inherit that dialog's saved no-prefix setting.
An export failure reports diagnostics. An empty successful export shows an
informational message. Otherwise the generated files open in the mail composer;
opening that composer does not send a message.

Existing patch files can be replaced. Files already written before an export
failure or cancellation remain available on disk. The export does not commit or
change the index. Git configuration still controls applicable format-patch
behavior, as it does in the source command.

## Native implementation scope

The native completion action connects directly to an owned export
workflow for the captured repository, access lease, upstream-to-branch selection
and preferences. Its output directory is the repository itself. That directory
is already covered by a valid repository grant; an extra directory picker is not
a sandbox requirement. Ordinary Format Patch remains a separate editable command.

The direct route uses source export defaults, shows command progress and permits
cancellation while work is running. File discovery uses actual command stdout,
independently of the bounded visible diagnostic log. Both range endpoints
normalize a sole for-merge `FETCH_HEAD` record, captured once per export;
ambiguous records are refused. Empty output does not adopt older patch files.
macOS Git can precompose a directory argument when printing its output. Exact,
composed and decomposed directory spellings are accepted only when POSIX
directory identity matches the approved destination; filename bytes remain
unchanged. Unverifiable output, traversal, duplicate paths and nonregular files
are refused. Only a successful nonempty
export can open the existing Send Mail composer, after export and presentation
ownership have settled. Failure and empty-range results remain reviewable.

The owner retains repository/file access through the export and composer. Forced
closure cancels work, suppresses late presentation and retains worker/release
accounting through actual drain. Quit confirmation fences successor presentation.
Finder and command transport handoffs retain the same captured workflow chain.

The real workspace handoff also exposed a native notification loop: the Rebase
change callback requested its own state refresh, and that refresh notified the
same callback again. The completed dialog could remain busy indefinitely. The
callback must notify other repository consumers without requesting its own
refresh; external mutation paths retain their explicit state refreshes. The
end-to-end scenario retains this integration boundary rather than replacing the
completion callback with an injected export.

## Validation and remaining work

The [grouped checkpoint](qa/rebase-completion-mail-2026-10-25.json) records
15 distinct focused Core methods cumulatively passing, a successful final Debug
app build, and all six native scenario/engine pairs cumulatively passing with
system Git 2.54.0 and bundled Git 2.55.0. The actual workspace factory performs a
real Rebase, an embedded revision-file revert, direct export and the actual mail
composer handoff. Other cases retain actual Git exports and native windows. Private wrappers hold
or fail after real export for cancellation and ownership checks. Start approval,
revision-revert informational acknowledgement and presentation capture use
existing callbacks; receiver windows stay hidden. No email is sent.

The initial Core prefix assertion needed Git-quoted path handling. One app build
failed because the new file lacked checked-project membership; the existing
XcodeGen directory recipe already covered it. Native diagnostics then exposed
the real self-refresh loop and a valid Unicode directory spelling refused by
the initial parser. Those production repairs, all four build attempts, failed
native attempts and affected rechecks are recorded. Passed unaffected checks
were retained, rather than rerunning the full Core suite.

All ten attempted native receivers were reaped and independently absent. App
objects were cached; fixture changes required only fixture recompilation.
This is not a full hosted CI, physical visual or signed deployment acceptance.

Physical presentation/focus/VoiceOver, signed sandbox grants, minimum supported
macOS, physical Intel, full hosted integration and App Store distribution
acceptance remain open. Actual Finder/command transport-chain invocation of this
new successor is not proved by the workspace scenario. The existing Send Mail transport and composer have their
own partial audits; this family does not certify all mail clients or send email
as part of its verification. Full Rebase and application parity remain open.
