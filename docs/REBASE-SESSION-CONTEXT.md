# Rebase session context

Active Rebase sessions now store `turtlegit-session.json` in the session's actual
Git state directory, resolved with `rev-parse --git-path`. It records schema
version 1, original branch/upstream/onto choices, Force, Preserve Merges, Fetch/Pull
origin and configured auto-start. Cherry Pick never records after-Fetch origin.

The backend writes context after Git returns an active session, including a
conflict or Edit pause. This works without relying on the custom sequence editor
being invoked. A successful operation with no remaining session creates no
context file. The native window restores context when loading or refreshing an
active session. Separate linked worktrees use their own Git state directory.

A reopened Fetch/Pull Rebase retains Show Log/Push/Send Mail/Rebase after successful
completion, and restarting retains its upstream and configured auto-start.
Branch/upstream/onto controls show the original choices rather than substituting
Git's resolved onto hash for the upstream. Existing replay identity and source
commit recovery are unaffected.

Missing, malformed or unknown-version metadata is ignored, leaving the existing
Git-state fallback usable. Sessions created before this addition cannot recover
an origin that was never recorded. Git removes the context along with its active
state directory on completion or Abort; no repository config or user preferences
are changed. The context does not persist a finished-session history report.

Core fixtures check recovered choices/origin, legacy and malformed fallback,
successful cleanup, linked-worktree isolation and a Preserve Merges conflict
that does not invoke the custom sequence editor. Native fixtures check a real
Edit pause, a new controller reopening the session, restored branch/upstream/onto,
completion command sets and restart. These use hidden views and injected handoffs;
displayed focus, current screenshots and signed sandbox execution remain pending.
