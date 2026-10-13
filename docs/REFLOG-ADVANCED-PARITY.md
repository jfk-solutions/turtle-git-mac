# RefLog Bisect and Combine

Pinned `GitLogListBase.cpp` offers Bisect Start for two selected non-stash events
when a working tree exists, no merge is active, and no bisect session is active.
During a session, Good/Bad apply to one row and Skip can use multiple rows. A first
selected commit with a `refs/bisect/` marker excludes those entries. Reset belongs
to the working-tree action set and is not added to historical RefLog rows.

The native RefLog model now reads bisect state on refresh and supplies these menu
entries with the original icons. Preparation validates the current repository
state and captured raw commit metadata. Start takes bad from the first displayed
selected event and good from the second, prefers known references, and falls back
to the immutable hash if a reference moved. Active operations preserve the selected
revision order and reject an already marked first commit. RepositoryModel connects
the prepared request to the shared Bisect dialog/progress workflow; preparation
itself does not start or mark a session.

Combine follows the source's stronger selection condition: at least two continuous
rows at or below the first displayed HEAD row, with endpoints matching `HEAD~offset`
and `HEAD~(offset+count-1)`. Repeated checkout events may fail this test even when
adjacent, because event positions do not necessarily equal commit ancestry.
The Core reader checks the current HEAD and merge/bare state, reads immutable
metadata, and returns a captured candidate. The existing History Combine window
still validates and confirms the actual rewrite at execution.

Selection changes, refresh and forced close cancel the owned candidate reader.
It retains its repository grant and global Quit accounting until it settles;
obsolete candidates cannot restore a menu entry. The menu uses the same retained
snapshot-validated command target as other RefLog actions. Bisect preparation also
uses the captured-reference/generation/cancellation pipeline before opening its
workflow. Signed App Store paths require the active repository grant.

Core fixtures cover valid/disjoint/stale/duplicate-event Combine spans, Bisect
reference defaults and moved-ref fallback, active-session requests, marked-row
rejection and read-only index/HEAD behavior. Native fixtures dispatch production
menu targets and capture Combine/Bisect requests, check active Good/Bad/Skip states
and original icons, and retire a controlled late ancestry read. Actual Bisect
Start/Reset in those private fixtures sets up the test state; the menu callback
probes do not execute user mutations.

Physical menu tracking while a candidate becomes available, selecting/bare/stash
variants, multi-selection mark behavior, full History Combine/Bisect mutation and
recovery through RefLog, ancestry changes after menu capture, root/merge rewrite
variants and signed execution remain acceptance work. This batch does not certify
all upstream RefLog actions or whole-menu ordering.

Eleven focused Core tests, the final Debug build and four grouped native
receivers passed with system/bundled Git. The initial Core/app error-type boundary
and fixture API spelling failures were repaired before these accepted passes.
All receivers were reaped. [Evidence](qa/reflog-advanced-2026-10-13.json) records the
preparation/routing scope; actual caller mutation and signed acceptance remain open.
