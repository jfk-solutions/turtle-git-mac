# History navigation, deletion and submodule inspection

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This continuation connects the existing source-selected MergeBase7 and
CheckCleanWT12 readers to related history actions and child repository workflows.
It does not change the history walk, graph layout or mutation engine.

## Source decisions and native consumers

| Source | Contract | Native consumer |
| --- | --- | --- |
| `LogDlg.cpp:2641/2649/2743/2751` | Only Tag/Branch FF jumps inspect ancestry; upward selected-to-candidate, downward candidate-to-selected | Log Jump Up/Down, retaining candidate order and selection ownership |
| `BrowseRefsDlg.cpp:681` | One branch, including remote tracking, gets an unmerged warning; tags and multiple selections skip ancestry inspection | Browse References deletion preparation |
| `AppUtils.cpp:3855` | Shared warning inspects local heads only; tags/remotes/stash retain separate rules | Log, Reflog, Sync and Revision Graph named deletion |
| `GitDiff.cpp:335/338`, `AppUtils.cpp:1808/1809` | Differing commits inspect old-to-new then reverse; unavailable sides end as Unknown, unrelated commits retain timestamp classification | Child Submodule Diff and conflict details, including Changed Files and Log entry |
| `GitLogListAction.cpp:643` | Combine checks tracked cleanliness before resetting; staged changes are not allowed | Combine preparation and begin, followed by the existing checked Commit/replay/rollback workflow |

The common-ancestor reader obtains one merge base and compares it to the starting
commit. Structural algorithms needing all merge bases keep their own reader.
Plain jumps and deletion selections outside the source gate do not start these
ancestry inspections. Native child readers retain the existing identical, missing
and uninitialized branches; unavailable metadata remains Unknown. The source
classifier may attempt ancestry before finally forcing unavailable sides to
Unknown; the native unavailable-side guard avoids that redundant read.

The cleanliness reader rejects unborn HEAD and tracked staged/working changes,
omits untracked files and excludes submodule dirtiness, matching the source
flags. It may refresh the index stat cache. Combine retains branch/HEAD and
selection checks; the final readiness read must complete before mutation checks
and hard/soft reset. The disabled commit-revert cleanliness block remains absent.

## Accepted actions and child repositories

Each native action captures its settings when accepted and keeps the selected
backend through inspection, questions and continuation. Prepared Combine and its
begin action share that accepted configuration. A later independent action may
capture new preferences. Child repositories retain the selected helper/config,
Git executable, askpass and diff policy while the native owner retains its grants.
All existing containment, child-root, immutable-object, index-stage and mutation
checks remain in their workflows.

A missing requested helper or incomplete reply reports a read failure. It must
not manufacture a successful ancestry classification, a clean tree or a deletion
confirmation. No-common-ancestor results retain the source false decision.
Optional missing commit metadata still follows the existing unavailable-side
presentation; cancellation must drain before any result can publish. Retired
owners and changed inputs reject late work. Existing native menus, source icons,
colored submodule classifications and question controls remain the user interface.

## Checkpoint and remaining work

The [dated checkpoint](qa/history-submodule-inspection-2026-10-20.json) records
passing evidence for 62 distinct relevant Core methods, the final Debug app,
six new native case/engine pairs and the older prepared-submodule case with both
Git versions. Only checks affected by recorded failures were repeated. The batch
also repairs stale destructive confirmation: a conflict externally resolved while
the deletion question is open now refuses that outdated confirmation before
Trash; initial missing-conflict Skip behavior remains intact. These checks
certify neither the entire source call graph nor complete dialog parity.
Physical keyboard/accessibility and complete layout acceptance, current hosted
integration, installed signed grants, real Intel/minimum-version execution and
App Store distribution remain separate gates. See the earlier
[Replay/Merge/Resolve inspection family](REPLAY-INSPECTION-PARITY.md) and
[single-commit detail family](SINGLE-COMMIT-DETAILS-PARITY.md) for their boundaries.
