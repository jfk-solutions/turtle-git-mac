# SVN command workflows — native implementation

Pinned source: `SVNFetchCommand.cpp`, `SVNRebaseCommand.cpp`,
`AppUtils::SVNDCommit`, `SVNDCommitDlg.cpp`, `SVNIgnoreCommand.cpp`,
`SVNIgnoreTypeDlg.cpp`, the two resource dialogs and `MenuInfo.cpp`, at
`7338078f8ddd924b8cddee35f512f2286072136d`.

The four source groups are now implemented in the app and Finder with the
original icons, preference IDs, ordering and conditions. The containing app
caches the common administration directory's `svn/.metadata` marker, matching
`TGitPath::HasGitSVNDir`; old snapshots default the new flag to false until
refreshed. Finder does not run Git to construct menus. DCommit supports versioned
file/folder selections; Rebase, Fetch and Ignore require one versioned folder.
Merge/bisect excludes DCommit and Rebase while retaining Fetch and Ignore.

**DCommit:** native Normal SVN Commit / Git Style Commit (--rmdir) radio choices
and Remember selection (`svn.rmdir`). A stored choice skips the options dialog.
The preference is written only after OK, with a native Stash/Abort choice for
tracked changes, cancellable command output and a Yes/No restore-stash prompt
after success. Untracked files are excluded from this automatic stash, as in the
source. A created stash is retained on failure/Abort; restoration refuses to pop
an unrelated stash if the list changed. Retry retains the selected workflow.

**Fetch:** resolve the first `svn-remote.svn.fetch` target before execution,
capture its old/new commits and run `git svn fetch`. The completed progress
offers Diff and Log only when the reference changed. Both actions retain the
captured repository and immutable comparison/range, rather than using whichever
repository the main window later selects.

**Rebase:** offer Stash/Abort when tracked changes exist, fetch first, then use
the source's three outcomes: already current, clean fast-forward via hard reset,
or the regular native Rebase dialog with the SVN reference as upstream. The
fast-forward revalidates HEAD and tracked cleanliness before mutation. Source
information and stash-restore prompts are retained. The Rebase Log post-action
waits until the restore-stash choice finishes. An existing Rebase dialog is not
replaced by a new SVN workflow.

**Ignore:** native radio choices for importing `svn show-ignore` to
`.git/info/exclude` (overwrite) or running `svn create-ignore`. The former
preserves exact stdout bytes and writes only after successful completion; failure
retains the old exclude file. The latter retains git-svn's actual file/index
behavior. Sandboxed exclude writes require a real retained scope covering the
resolved administration path, including linked-worktree cases.

One SVN workflow is retained per root. Busy workflows are focused instead of
duplicated; a finished result can be replaced by a new invocation. Windows retain
their Git executable, repository and permission lease through child completion.
Owned cancellation and process-count Quit guards also cover forced closure.
Visible progress uses the existing bounded Git parser/output policy and native
system colors. Closure clears callbacks that otherwise retain the window.

The bundled Git originally contained a NO_PERL failure stub. The new
[private runtime](GIT-SVN-RUNTIME.md) supplies git-svn, its Perl interpreter,
Subversion bindings and network libraries. Capability is checked before the
workflow mutates or stashes files; system/custom Git choices without git-svn
produce an explicit error. A prepared runtime can also be embedded in ordinary
desktop builds, so automatic Git selection can use the bundled implementation.

Remaining acceptance: physical comparisons of both resource dialogs and all
generic progress/post-action states, source cancellation details, real divergent
Rebase UI handoff and stash-conflict cases, public authenticated HTTP/SVN/SSH
servers, credential/trust prompts, signed sandbox/common-directory permissions,
and distribution review. All 55 Finder catalog groups now have implementation
routes; that count does not establish complete application or dialog parity.

Grouped validation, 2026-10-12: 36 focused Core tests passed, zero failures, in
8.167 seconds. Debug arm64 compilation and the final runtime-embedded build
exited 0. The actual Finder builder matched all 61 root entries and the 64-command
condition oracle. One combined native compilation/process verified captured
Fetch actions, DCommit choices/remember/stash/pop, Ignore output, fast-forward
information, duplicate-start and forced-close/Quit fences with real private Git
and injected SVN responses, alongside the existing daemon/review/LFS/mail checks.
The runtime separately passed real local SVN clone/fetch/dcommit/show-ignore/
create-ignore with build-prefix fallbacks hidden. No installed app or Finder
extension was activated. See [the dated record](qa/svn-batch-2026-10-12.json).


## Scoped window ownership and retirement — 2026-10-12

SVN state publication now rechecks owner lifetime after runtime, metadata,
transport, stash and Rebase awaits. Retirement freezes phase/status/output/error
and fetched presentation while operation accounting still settles. The output
pump stops publishing after retirement. Late stash/restore/Rebase responses cannot
start further work or publish a completion callback. Cancel owns one pending
question, captures its original cancellation token and cannot cancel a later
request. Retry waits for the pending cancellation question to settle.

The native controller owns each question/continuation. Closing dismisses and
answers its question once; an injected or native late Yes is ignored. An old
controller's close callback cannot remove a newer cached SVN window. Scoped
opening retains the passed repository/executable/access lease even while another
main-window repository is busy. Reusing options for a different operation now
reports which SVN operation must finish instead of silently showing the wrong
workflow. Same-operation reuse remains available. Private RepositoryModel
construction can skip startup monitoring/publication for bounded native receivers;
production startup keeps its existing default.

Two Debug builds exited 0: the lifecycle implementation, then the added scoped
presenter/monitoring seam. The first native run passed the preceding lifecycle
checks but failed a fixture URL-equality precondition. The final check requires
exact captured repository identity and its canonical root/executable/lease,
retaining the options-state requirement and adding diagnostics. The failed process
was reaped; its private SVN fixture directory was identified and removed.

The corrected receiver passed with system and bundled Git, using private real
Git repositories and injected SVN responses. It retains Fetch range, DCommit
choices/remember/stash/pop, Ignore output and fast-forward checks, and adds frozen
retired presentation, owned prompt settlement/duplicate refusal, duplicate/late
Cancel fences, captured scope under another busy workspace, same-operation reuse,
conflicting-operation refusal and replacement after closure. Totals: two native
receiver compilations, three processes (one initial failed check, two final
passes), all reaped. No Core/full seventeen-family group was rerun. SVN now shares
the app-object cache and is removed from the legacy LFS/mail default group. No
public SVN transport, physical sheet/window/keyboard or signed security-scope
acceptance is claimed. See `qa/svn-scoped-lifecycle-native-2026-10-12.json`.


## Native progress log and completion — 2026-10-12

SVN progress now uses the shared AppKit read-only progress log instead of a plain
SwiftUI Text surface. It inherits source-style bold warning/error prefixes,
light/dark colors, clickable links, log font and context-menu icon preferences,
Copy and Copy all information while preserving selection. SVN exposes captured
progress percentage/work text and a source completion line/range with timing and
locale preferences. Its existing bounded parser/output state remains the body
owner; the completion line is appended through the common formatter. When a
failure has no output, its diagnostic is included in the log. Retired models
continue fencing all output and completion publication.

Retry clears completion/success/work/percentage state and the previous fetched
range before a new attempt, preventing stale Diff/Log handoffs. Preferences and
pasteboard are retained through the model/controller; native QA uses a private
pasteboard before the actual log is created, avoiding the general clipboard.

Debug build exited 0. One object-linked receiver compilation ran the expanded
SVN workflow with system and bundled Git; both passed and were reaped. The actual
native output view displayed injected SVN warning/link output plus completion.
Checks verified clickable attributed links, bold warning RGB colors under Aqua
and Dark Aqua, colored successful completion, source copy menu/order/icons, exact
private Copy/Copy All and retained selection, disabled completion timings, error
exit-code completion and successful Retry reset. The prior complete private SVN
workflow/lifecycle/scoped-window checks remain in the same receiver. No Core or
full seventeen-family group was rerun. No physical pointer/keyboard, screenshot,
public SVN authentication, signed grants or App Store acceptance is claimed.
See `qa/svn-progress-native-2026-10-12.json`.

The bundled authentication callback family now has combined credentials, secure
certificate passphrases, native certificate information/explicit trust choices
and owned client-certificate file selection. See
[SVN authentication parity](SVN-AUTHENTICATION-PARITY.md). Public server/TLS,
physical and signed grant/Keychain acceptance remain open.


## Source forms and accepted workflow state — October 17, 2026

`IDD_SVNDCOMMITTYPE` retains its DCommit Type group, Normal SVN / Git Style
(--rmdir) radio choices, Remember selection and OK/Cancel/Help. `IDD_SVNIGNORE`
retains Type, overwrite-exclude / create-.gitignore radio choices and OK/Cancel.
The two native option windows use compact source ordering and grow into a
resizable progress window with the existing native colored log, original Diff/Log
icons and persistent footer. Hosting bounds and effective native minimum
constraints replace the older unconstrained host/contentMinSize setup. Window
controls and output menus use the captured preferences and private pasteboard
when provided.

OK snapshots the complete options before any capability check or stash prompt.
Remember and the executed --rmdir flag share that accepted value. Import Ignore
captures its destination, and Retry preserves the originally accepted workflow
instead of rereading fields after a failure. A failure during initial runtime or
repository validation repeats that validation on Retry and presents the original
options after recovery, before allowing a mutation.

Native option fields, OK/Retry/Cancel and fetched Diff/Log actions capture their
owner and form generation. Busy/phase transitions and owned questions invalidate
retained actions. Questions gate ordinary Close and other actions even with an
injected presenter; responses settle once and late/replayed answers cannot revive
old controls. The nonaccepting choice is the native Return default for two-choice
questions. Forced closure still retires prompts and backend publication while
retaining operation/Quit accounting until completion.

All twelve resource controls receive partial mappings. Public authenticated
transports, actual divergent Rebase handoff/stash conflicts, physical keyboard/
VoiceOver gestures, signed grants/Keychain and App Store sandbox acceptance remain
open.

Both Debug builds exited 0. Four distinct source/workflow case-engine combinations
passed across system and bundled Git. Visual review found wrapping repository
paths; the final layout uses one line with the full path in a tooltip and effective
native minimum constraints matching the compact forms. Only the two affected
source checks were repeated after this layout change; the prior retained workflow
passes were not repeated. All eight final raw light/dark captures were individually
reviewed: radio groups, Remember, footer, colored logs and original Diff/Log icons
fit. All four owned receivers were reaped and independently absent, with no private
SVN helper paths left. Core was unchanged and not repeated. Each build retains one
exit-zero/no-output diagnostic plus existing warnings, so this is not a clean
diagnostics claim. See [batch evidence](qa/svn-source-family-2026-10-17.json).
