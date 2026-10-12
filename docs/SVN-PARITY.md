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
