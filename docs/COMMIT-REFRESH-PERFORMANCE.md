# Commit refresh cost — October 26, 2026

Commit’s change scan previously requested ignored files, collected metadata for
those hidden rows, and then loaded the complete Working Tree inventory solely to
obtain index flags. A clean large checkout could therefore pay for tens of
thousands of ignored records, tracked-file attributes and locale-aware sorting
before displaying an empty list.

The Commit status collector now omits ignored paths. The general status API keeps
its existing ignored-file default for Finder and Working Tree consumers. Both
normal and parent-Amend lists preserve actual changes, untracked paths, renames
and conflict entries. This follows the pinned CommitDlg’s nonignored status list
(`CommitDlg.cpp:1412–1418`); no ignored-file action was removed from Commit.

Commit reload reads index flags for its captured change entries in one index
read, without another status scan, file attributes or all-file sort. A clean list
returns without starting Git. Metadata collection excludes ignored candidates,
including injected/native recovery snapshots. Full Working Tree inventory and
its metadata remain available to that dialog.

All reads retain the existing reload cancellation/owner checks and publish one
coherent result. Stage/unstage refresh still reads current index/worktree state;
its untracked/conflict lookup also omits unused ignored records. No status or
index data is reused across distinct reloads, and no automatic staging or commit
is added.

The [grouped checkpoint](qa/commit-refresh-2026-10-26.json) records 11 affected
Core checks, a Debug build and four offscreen native case/engine pairs passing.
Native checks retain changed/staged/rename/untracked rows, exact index flags,
Classic/Git Gui F5 and selections, partial staging, cancellation and retirement.
The first build’s optional-owner compile error was repaired; Core was not rerun.

Read-only collection on the reported clean large checkout fell from 18.76 seconds
to 0.44 seconds. The old path collected 27,819 ignored metadata rows and a
62,122-row Working Tree inventory; the new path collected zero rows for this
clean Commit. These are one warm-filesystem sample per configuration (old release,
new Debug), covering status/metadata/flags rather than complete dialog startup.
They are not a fixed performance guarantee. Signed installation and complete
hosted CI remain separate from these focused checks.
