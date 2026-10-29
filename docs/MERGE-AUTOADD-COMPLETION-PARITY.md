# Merge saved-output AutoAdd discovery and completion

Pinned baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source anchors: `TortoiseMerge/MainFrm.cpp:1646–1652,1792–1800` and
`TortoiseProc/Commands/AddCommand.cpp:30–44`.

## Connected save behavior

AutoAdd defaults on. Ordinary new-result saves dispatch source `/command:add
/noui`; Save As has separate policy. The pinned child implementation's `/noui`
body is compiled out, so TurtleGit's real Git addition is a functional adaptation,
not a claim about upstream staging behavior.

A new ordinary Compare or three-file Merge result saved to a confirmed
non-repository folder now completes as a plain file save. Automatic Add does not
ask the user to choose an unrelated repository, look up a Git executable, acquire
additional grants or create an index there. The saved baseline is accepted and
its automatic intent retires. Existing files, Save As and source-copy choices
retain their separate eligibility rules.

Repository-marker discovery returns three distinct outcomes: an actual marker,
no repository after an authorized walk to the filesystem root, or a boundary
requiring authority. Failed reads are errors rather than evidence of absence.
A narrow sandbox output grant does not establish the absence of a repository
above its boundary. Such unknown authority retains its owned chooser, as do
explicit Resolve requests. Existing actual-root checks, linked metadata grants,
exact saved-file receipts, index compare-and-swap and cancellation remain in
place. The global Settings marker-discovery API is unchanged.

## Accepted publication and late cancellation

Git index rename is the Add acceptance boundary. After successful publication,
a late cancellation cannot turn it into a failed Add or leave a misleading Retry
receipt. Compare and three-file Merge adopt that result only while the same
operation, frame/document owner and exact pending-intent revision remain current.
Closed/replaced owners cannot clear another receipt. Pre-publication cancellation
and genuine Add failure still preserve saved bytes and the pending receipt for
Retry Add. Accepted late cancellation does not start optional reload/close work.

## Hosted failure and grouped checkpoint

[Hosted run 40863559740](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/40863559740)
on `59351fd7` passed 3,245 Core methods with two skips and no failures, then
failed the standalone Merge comparison receiver at its required-output Save
wait. Default AutoAdd in a fresh non-Git fixture opened an unanswered repository
chooser; the saved output existed while save completion remained pending.
Disabling AutoAdd in that fixture would conceal the default end-user problem.
The comparison fixture retains the default and its existing output assertions.

The [grouped checkpoint](qa/merge-autoadd-completion-2026-10-29.json) records
seven focused Core methods passing cumulatively, both successful Debug builds,
and ten first-attempt native family/engine passes. Ordinary Compare and three-file
saves retain default AutoAdd and assert zero executable lookups, Add calls and
repository choosers for confirmed plain folders. Four real-index cases cover
late cancellation after Add in Save and Retry for both consumers. The original
comparison failure, three-file entry, frame continuity and explicit saved-output
Resolve checks pass with both system and bundled Git. All ten receivers were
reaped and independently absent; private windows and work drained.

The initial Core run passed six methods and failed the plain-folder walk because
Foundation canonicalization reintroduced `/var`. Darwin `realpath` now supplies
physical ancestors after initial scope admission; strict directory, read-error
and grant checks remain. Intermediate one-method passes remain recorded. Final
validation repeats the three affected physical-path/marker/alias methods using
one production/injected ancestor loop; a transitional test-only normalization
branch was removed. Other unchanged error/cancellation/bounded cases were not
repeated. Original assertions remain, and native checks needed no further repair.

Physical/signed permission sheets, full hosted integration, external caller
exit-status acceptance and complete Merge/full-port parity remain separate.
Installed build33 predates this continuation.
