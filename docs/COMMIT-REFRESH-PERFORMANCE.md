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

## Recreated staged-deletion copies

The later working-file Revert validation exposed a metadata regression in the
initial optimization: an ignored local copy of a staged deletion no longer
received `hasUnversionedCopy`, because its duplicate porcelain `!!` record was
absent. Rebase's shared versioned list consequently disabled Add/Delete for
that copy.

The collector now checks only existing staged-deletion candidates using safe
literal-path validation and `lstat`. Regular files and symlinks, including broken
symlinks, retain the local-copy flag without enumerating ignored trees or adding
ignored rows. Missing files and ignored directories do not acquire that flag.
The ordinary and parent-Amend projections retain the enriched metadata. Four
focused refresh methods pass; the [connected Revert checkpoint](qa/working-file-revert-disposition-2026-10-26.json)
records the discovered failure and affected native recheck separately from the
earlier performance measurements. No new large-checkout timing is claimed.

## Shared display read — October 27, 2026

A normal reload still requested three independent formats for each of its
working, staged and unstaged comparisons: nine diff invocations. Parent-Amend
also rebuilt two of those inventories while projecting its status entries. The
connected continuation shares those facts within one display-read lifetime. Each
comparison requests raw and numstat output together; names and rename pairs come
from raw records because Git's name-status option disables the other formats.
One tagged staged index inventory supplies both gitlink names and index flags.

The captured result retains normal, staging, parent-Amend, parentless and unborn
behavior, including index-only rows canceled out by working files, binary/mode
changes, conflict stages and exact unusual path spellings. It remains display
data: mutation preflight and raw index witnesses are read freshly. Nothing is
cached across reloads or used to authorize a write.

Native owner/cancellation checks still surround the read and final atomic
publication. Metadata, message/provider loading, Start-Commit hooks, missing
staged-file recovery and row restoration retain their existing order. Injected
status readers retain their complete legacy path for existing callers; the new
native check counts actual Git commands on the default shipping path instead
of replacing that reader.

Recovery separates read ownership from permission to present a question. A pending
Cancel confirmation allows an otherwise valid read with no missing files to
finish; declining Cancel retains that result. If staged files really are missing,
recovery waits for the answer and sheet detachment before asking or changing the
index. Accepting Cancel or closing the window still cancels and drains the read.

The [shared-read checkpoint](qa/commit-shared-display-read-2026-10-27.json) records
implementation and grouped verification separately. Reduced process counts do
not establish complete installed Commit startup timing. Signed Finder activity,
first-launch grants, external hooks/providers and minimum-version/Intel
acceptance remain separate from this change. No dialog layout or source option
is removed.
