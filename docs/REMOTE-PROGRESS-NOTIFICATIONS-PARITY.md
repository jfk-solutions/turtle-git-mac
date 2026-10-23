# Clone and Fetch reference/checkout notifications

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family covers the optional libgit2 Clone/Fetch result list, its captured
reference history and checkout-file actions. It does not certify every Clone,
Fetch, Synchronization or Git Progress dialog. Related pinned resources are
`IDD_CLONE`, `IDD_PULLFETCH` and the shared `IDD_SVNPROGRESS`; this is a partial
workflow-family audit, not clearance of every static control in those dialogs.

## Source contract

`Git.cpp::UsingLibGit2` requires both `UseLibgit2` and the operation's bit in
`UseLibgit2_mask`. Clone is command index 1 (bit 2), Fetch index 2 (bit 4).
The pinned default mask excludes both. Ordinary CLI output must therefore remain
the default; a transcript that resembles a notification is not a typed result.

`ProgressCommands/RemoteProgressCommand.cpp::RemoteUpdatetipsCallback` produces
an Update ref row for each callback, retaining the full old/new object IDs while
displaying shortened hashes. Equal nonzero IDs mean Same; a zero old ID means
New, a zero new ID Deleted. For two changed nonzero IDs, the graph query runs
with new before old: ahead-only means Forward N, behind-only Rewind N. Divergent
history uses the commits' committer timestamps for Newer time, Older time or
Same time. Failed graph classification leaves the change text empty. This is
not a generic forced-update label. Fetch explicitly requests reporting unchanged
tips, so a successful no-change fetch can still have Same rows.

The reference row has Show Log, using the captured full old ID as start revision
and full new ID as end revision, omitting either zero endpoint. Moving the named
reference after completion must not change that range. Its base notification
class has no double-click action, and it has no Open/Explore file actions.

`CloneProgressCommand.h::CheckoutCallback` creates a Checkout file row for each
path callback, independently of the percentage animation. Bare/no-checkout
clones do not invent checkout-file results. The shared WC notification supplies
Show Log, Open, Open With and Explore; directories omit the Open variants and
double-click reveals them. Recursive checkout results must retain the producing
repository and its literal relative path so identically named child files do
not dispatch against the superproject.

`GitProgressList.cpp` allows completed-result menus only after work stops. File
or reference actions require one selected actionable row; multiple selection
offers Copy. Context Copy joins the displayed Path values with CRLF and trims
the trailing whitespace. Keyboard Copy includes Action and Path. Sorting works
within contiguous non-auxiliary blocks, with Path breaking Action-column ties;
command/footer rows stay outside those blocks. Keyboard Copy and Select All are
available while the worker runs; their source handler has no stopped-worker
check. This differs from completed-only context menus and file actions.

## Native implementation and ownership

The transport contract carries typed reference/checkout records independently of
sideband diagnostics. Records retain literal Unicode/whitespace paths, full IDs
and producing repository identity; native display strings are never parsed back
into actions. Failure/cancellation retains already received results, and Retry
starts a fresh attempt so old menu receipts cannot dispatch. The selected-backend
native list preserves the source distinction between running keyboard copying
and completed file/reference actions. Saved action logs include those visible
notification rows alongside diagnostics; default CLI logs retain their transcript.

The private channel uses versioned base64 JSON frames, with a 2 MiB frame limit,
64 MiB aggregate channel limit and 100,000-record limit. Strict decoding excludes
sideband text and invalid/conflicting path or hash fields. Malformed metadata
retains earlier accepted rows and reports incomplete notifications after the real
Git process settles. It does not claim that an already applied Git mutation was
rolled back. Such a warning keeps the result available for inspection.

Native file actions use the existing confined working-file open/reveal service.
Open With revalidates the captured target after its application chooser, retains
access through launch completion and suppresses late effects after owner
retirement. Closing, deferred Quit and post-action handoff drain owned reads,
launches, chooser replies and sheets before releasing their repository grant.

## Validation and remaining limits

The [dated checkpoint](qa/remote-progress-notifications-2026-10-19.json) records
seven distinct focused Core methods with pass evidence after affected repairs,
the universal helper build and both architecture runtime checks, and six native
Clone/Fetch/lifecycle case/engine pairs. Those native checks cover opt-in versus
default CLI, immutable Log endpoints, recursive checkout identity,
selection/sorting/copy, partial results/Retry and native ownership boundaries.
The initial failures and focused fixture/protocol repairs remain recorded.

Review of the actual inactive light/dark captures found a collapsed Clone result
viewport, despite the behavior assertions passing. The typed Clone/Fetch layouts
now reserve usable list height and bound diagnostics; short viewports no longer
paint cropped watermark artwork through the header. A viewport assertion and
affected native capture/retained-consumer recheck accompany that repair; the
dated record distinguishes their outcomes from the initial behavior pass. The
four affected Clone/Fetch case/engine pairs and four retained Revert/Add/Resolve
pairs passed after this native-only repair. All owned receivers were reaped.
Reviewed actual captures: [Clone light](site/assets/clone-reference-checkout-results-light.png),
[Clone dark](site/assets/clone-reference-checkout-results-dark.png),
[Fetch light](site/assets/fetch-reference-results-light.png) and
[Fetch dark](site/assets/fetch-reference-results-dark.png).

Automated offscreen checks do not prove physical Finder behavior, signed
distribution grants, complete VoiceOver/keyboard acceptance or visual parity of
all upstream dialogs. Those remain separate acceptance work.


The [Synchronization continuation](SYNC-TRANSFER-NOTIFICATIONS-PARITY.md) connects this same typed reference-result contract to inline Sync Fetch and its owned follow-ups. Its separate dated checkpoint states actual coverage; standalone Clone/Fetch checks above do not substitute for that integration.
