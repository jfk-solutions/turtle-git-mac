# Log Merge and Rebase commands

The Log revision menu now includes Merge to the current branch and Rebase the
current branch onto the selected revision, with the original Merge/Rebase icons.
The comparison uses `GitLogListBase.cpp` and `GitLogListAction.cpp` at
`7338078f8ddd924b8cddee35f512f2286072136d`.

Upstream enables these for a single non-HEAD, non-stash selection in a working
tree without an active Merge. TurtleGit uses those eligibility rules and disables
commands while the Log is busy, reading/saving notes, jumping or copying details.
Before handoff it freshly checks bare status, Merge/Rebase state and actual HEAD.
Changing the selected revision or invalidating the Log during that read prevents
handoff. It opens dialogs for review rather than executing Merge/Rebase directly.

Merge uses the first still-valid reference attached to the selected revision,
or its hash. Rebase prefers a still-valid local branch, using its short name,
then another valid reference or the hash, matching upstream's branch guess.
References are checked against the selected hash, so a moved/deleted label does
not redirect the command to a different commit. Explicit clicked-ref-label
selection remains pending.

The native Merge window selects the matching Branch, Tag or Commit choice.
A symbolic/unlisted reference is retained in the Commit field. The existing
Merge options and backend remain available. Rebase opens the native plan with
the chosen upstream and does not auto-start.

Origin handling distinguishes a Rebase opened from Log from a direct Rebase or
one opened after Fetch/Pull. Upstream's Log action does not configure completion
buttons, so TurtleGit does not add them for that origin. Active session context
stores optional `fromLog`; reopening preserves the behavior, while older context
without that field still decodes. Cherry Pick keeps its separate behavior.

## Verification and remaining work

The native receiver builds the actual AppKit revision menu, checks titles/icons
and invokes its selectors. It verifies Merge/tag and Rebase/local branch handoffs,
moved-reference/hash fallback, Branch/Tag/Commit Merge presets, stale/multiple/
HEAD/stash/bare guards and fresh active Merge/Rebase rejection. It also performs
a normal Log-origin Rebase, reopens it, continues and checks successful completion
without post buttons, then restores the disposable fixture. Handoffs are injected
and views are hidden; no displayed navigation or signed execution is claimed.

Clicked-label targeting, broad displayed dialog/keyboard/accessibility parity,
remaining advanced Log commands and full application parity remain unfinished.


## Shared log font in Rebase

Rebase's editable commit message, read-only message text and progress output now
use the Dialogs font preferences, matching RebaseDlg's message/output font call
sites. Changes apply to open native views. Font changes preserve the draft and
selected text. Progress remains read-only. Other comparison/output views keep
their separate appearance settings or existing native font.

[Log/Rebase font QA](qa/log-rebase-font-2026-10-08.json) exercises hidden native
Log and Rebase hosts using isolated preferences. Rebase UI state is a fixture;
this receiver performs no rebase operation and does not prove conflict recovery,
squash/split transitions, signed sandbox or physical appearance acceptance.
