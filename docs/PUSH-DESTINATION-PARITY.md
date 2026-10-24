# Push destination and saved-mapping parity

Pinned reference: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This batch extends the partial [Push family review](PUSH-PARITY.md); it does not
establish complete Push dialog or transport acceptance.

## Source contract and native implementation

`CAppUtils::DoPush`, `src/TortoiseProc/AppUtils.cpp:2831–2844`, constructs the
outgoing refspec from the entered source and, when nonempty, `:` plus the entered
destination. It does not rewrite a short destination to `refs/heads/` or
`refs/tags/`, and does not query remote refs to choose a namespace.

`Sources/TurtleGitCore/Push.swift` now forwards that literal refspec. Git resolves
an existing unique short remote tag or branch; a colliding branch and tag fails
without selecting one. Explicit `refs/heads/…` and `refs/tags/…` destinations
resolve that ambiguity. Empty source produces `:destination`, including deletion
of an existing short or qualified tag. A raw hash can update an existing unique
short destination, but creating a new destination from a raw hash requires an
explicit namespace when Git cannot infer one. The previous automatic namespace
rewrite was a port divergence. The older hash-to-new-branch fixture now supplies
`refs/heads/hash-target` explicitly.

Validation still checks source identity/uniqueness and destination ref syntax.
The `refs/heads/` prefix used to validate a bare destination's syntax is never
sent as an inferred destination. No remote namespace preflight or fallback was
added. Named remote, URL/path, and each all-remotes transport receive the same
literal spelling, so different servers retain their own namespace/error behavior.
Unicode spellings remain byte-preserved through the existing
`core.precomposeunicode=false` command path. Push remains a Git CLI operation;
this batch adds no alternate libgit2 push implementation.

Existing flags, SSH preparation, authentication, hooks, streamed output,
cancellation, result ownership and post-actions retain their paths. A later
all-remotes failure reports earlier completed destinations without rollback.
A cancellation already signalled before submission prevents config or transport
writes. Saved short-branch defaults still precede transport and remain saved if
transport fails, matching the source ordering.

## Enabled options versus mapping ownership

`CPushDlg::EnDisablePushRemoteArchiveBranch`, `PushDlg.cpp:336–354`, enables
`IDC_PROC_PUSH_SET_UPSTREAM` for named-remote mode with a nonempty source or all
branches. The two saved-mapping controls (`IDC_PROC_PUSH_SET_PUSHBRANCH` and
`IDC_PROC_PUSH_SET_PUSHREMOTE`) require named single-remote mode, a nonempty
source, no all-branches mode and no upstream setting. The source does not require
that text to denote a local branch before enabling those controls. Native
`PushWindow.swift` now uses that same text/mode policy, including tags and hashes.

Submission is separate: `PushDlg.cpp:466–489` writes mappings only when
`g_Git.IsLocalBranch(m_BranchSourceName)` succeeds. `Git.cpp:1615–1619` compares
that supplied text literally against local branch names. Both the libgit2
`git_branch_name` path (`Git.cpp:1746–1764`) and CLI branch-list path
(`Git.cpp:1780–1816`) return short local names. Therefore only an exact short
local branch owns `branch.<name>.pushbranch`/`pushremote` writes. A tag, hash,
`HEAD`, revision expression or fully qualified `refs/heads/…` source can have the
save controls checked and still performs no mapping write. Core accepts that
submission as a no-op for configuration, rather than rejecting it. Suggested
branch defaults remain independently available; resolving `HEAD` for a suggestion
does not authorize saving its current branch's mapping. Upstream flags are passed
to Git without imposing a local-branch-only UI restriction.

`PushDlg.cpp:456–464` saves URL history, destination history and the selected
remote inside the ordinary submission branch, excluding all-branches and remote
removal. Native remembered-remote persistence now follows that same gate; removal
and all-branches leave the previous ordinary selection intact. The existing
preflight/owned confirmation path still decides whether submission is accepted.

## Focused evidence and remaining work

New `PushDestinationTests.swift` contains real disposable local/bare-repository
cases for branch/hash updates to existing short tags, short/qualified tag deletion,
branch/tag collision and explicit escape, unqualified new hash failure and
qualified success, URL transport, per-server all-remotes partial failure, literal
saved destinations after rejection, pre-cancellation, non-short-branch save no-op,
tag upstream forwarding, and exact Unicode refspec/transport flags against a
private rejecting hook. Existing Push tests retain transport, flags, source
identity, validation and cancellation coverage. The saved-default fixture uses
short `main` to exercise actual mapping ownership; the qualified-source suggestion
assertion remains. Native namespace/removal/source-picker fixtures are maintained
with the parent batch's grouped receiver checks.

The [dated grouped checkpoint](qa/push-destination-family-2026-10-24.json) records
25 relevant Core methods, the Debug app build and six native case/engine pairs
passing on their first run. All six owned receivers were reaped and independently
absent. Fixtures use private
repositories/preferences and owned helper cleanup. Hosted CI, physical keyboard
and accessibility interaction, signed sandbox grants, real network credentials,
and all exceptional remote/protocol states remain separate acceptance work.
