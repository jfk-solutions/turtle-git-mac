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


## Supplementary file-list read — October 27, 2026

The shared comparison reader did not remove all supplementary work. Commit still
requested file attributes for every candidate, including when the date and size
columns were hidden, and revalidated every persisted changelist assignment.
This read family limits filesystem metadata to the columns used by the list
and its active sort. Commit still reads per-row directory facts for extension
copy and ignore actions even when the Extension column is hidden; this does not
eliminate every per-candidate filesystem call. Revealing a metadata column
loads its values through an owned supplementary request, without repeating
status, hooks, provider calls or message seeding. Layout changes reuse an adequate
in-flight request; hiding an unneeded column, refreshing, closing or quitting
cancels obsolete requests, and owner/epoch checks reject late results. Hidden
data is not reused as a mutation witness.

Metadata and changelist display collection share parent containment checks only
within one synchronous repository read. Every later read and every mutation starts
with fresh validation. Persisted assignments outside the candidate list retain
lexical validation and contribute to the changelist menu's full name catalog;
filesystem containment is checked for displayed assignments. The complete
changelist read and mutation APIs retain their full validation. Exact Unicode
spellings remain distinct, and invalid persisted names or paths remain errors.

Repository operation markers, rebase state and LFS presence are captured with
worktree and common Git directories in the same display lifetime. Each directory
is read separately so a literal newline in a repository path cannot split a
multi-path response. Mutation preflight continues to inspect current state.

The [supplementary-read checkpoint](qa/commit-supplementary-read-2026-10-27.json)
records 51 distinct affected Core methods passing cumulatively and native
checks on Git 2.39.5 and bundled 2.55.0. It retains the initial fixture failures
and the contradictory Debug-build diagnostic recheck. This reduces unused work;
it does not establish a fixed startup time or completion of the whole port.

## Ladybird loading observation — October 28, 2026

The user's existing Ladybird checkout was inspected read-only on its current
branch. Its warm clean status read took about 0.39 seconds with Apple Git and
0.40 seconds with bundled Git. Each remaining combined diff took at most 0.07
seconds; the 4.22 MiB/34,303-record index inventory took about 0.02 seconds.
The actual Debug Core display reader took about 0.85 seconds; the complete measured
serial read/config/template path took about 1.3 seconds. Index bytes remained
unchanged. No file contents or pathname inventory were printed, and no hook or
credential was executed/read. Project provider and Start Commit hook configuration
were absent in this checkout at measurement time.

[The numeric profile](qa/ladybird-commit-loading-2026-10-28.json) retains the
individual timings and limits. These are warm diagnostic measurements, not a
before/after speedup or complete installed UI latency. They do not include cold
filesystem state, signed sandbox startup, local global hooks, remote association
credentials or native layout/publication. There was no measured justification to
remove full index, amend, submodule or statistics semantics from the Core reader.

The connected GUI presentation separates active loading, unknown counts,
accepted clean results and failures/cancellation. It also permits cancellation
and replacement of a read-only preview while keeping real hunk writes exclusive.
Empty selection now retires a blank preview. The former reader already produced
empty data without running Git for that selection; this is not a new large-diff
optimization. Further slow installed loading needs an actual phase/timing
observation rather than a speculative claim that the warm Core read was slow.


## Installed Finder publication bottleneck — October 30, 2026

A later [installed build39 observation](qa/installed39-startup-commit-2026-10-30.json)
found a different delay: opening a private three-file repository remained busy
for over a minute behind publication of an 83 MB Finder warm archive. The main
thread was idle; a sampled worker spent most observations sorting long shared
path prefixes for snapshot encoding. Other cache writers, including the new
repository's pre-collection publication reservation, waited behind that work.
This does not contradict the earlier warm Git display-read timings.

Byte-exact encoding now prepares UTF-8 path bytes once per ordering and compares
contiguous buffers. Each exact-record/legacy-map pair shares that ordering,
then releases temporary records before the next map. Store encoding releases
Foundation temporaries before writing. The wire format, canonical-collision
projection, synchronous persistence warnings and cross-process publication
fences are retained. The [grouped checkpoint](qa/commit-columns-cache-scale-2026-10-30.json)
passes 53 targeted Core checks and preserves identical initial 85.1 MB wires in
the paired framework comparison. With matching optimized configurations, a
single private measurement reduced encoding from 3.57 to 1.99 seconds and the
complete publication phase from 7.30 to 5.80 seconds. Startup and unchanged
retirement did not show a comparable improvement. Sequential sampling and OS
cache/CPU state limit the comparison. Publication remains synchronous; these
results do not prove that installed repository/Commit startup is fixed.

## Installed shared-cache continuation — November 3, 2026

The [build51 installed checkpoint](qa/signed-consolidation-build51-2026-11-03.json)
separates actual shipping startup from the hidden native probe. In a synthetic
34,304-path private repository, workspace rows appeared before the global busy
state cleared. Commands were still disabled at 12.7 seconds; the next ready observation
was 76.1 seconds, so the actual completion lies within the recorded observation interval.
A process sample during the wait shows one writer encoding a full Finder snapshot
while other begin/publish requests wait for the local writer lock. The encoding
stack spends its samples sorting JSON keys through Foundation-backed path strings.
The shared live projection was 77.6 MB and warm archive 83.4 MB at that observation.

The earlier exact-record ordering optimization remains present. This is additional
Foundation object-key ordering during serialization and foreground ownership of
optional publication, rather than proof that the earlier optimization was absent.
The connected source continuation removes Foundation object-key sorting from
large volatile snapshots and immutable contribution bodies. Exact UTF-8 records,
legacy collision projections, control-header ordering and atomic/lease checks
remain. Ordinary workspace readiness uses repository facts before waiting on the
shared store. A separately owned publication worker begins its ticket before its
full authoritative collection, preserves nested watch directories and refuses
obsolete root/request results. Selected-file Services retain their required exact
foreground snapshot; Add registration still requires successful publication.
Directional cancellation lets the parent retire the worker without allowing a
replaced optional worker to cancel its parent Git command. Quit continues to own
drainage rather than treating a usable workspace as completed background work.
The [grouped checkpoint](qa/finder-readiness-publication-2026-11-03.json) passes
69 focused Core checks, the Debug build and all eight native case/engine pairs.
The actual held-store case retains usable workspace/Commit controls; queued
replacement and an uninterruptible injected writer remain owned through real
drainage, without late notifications. Existing monitor, cancellation and scope
cases also pass. This is behavioral isolation, not a matched encoding speedup or
signed large-cache latency result; those physical acceptance limits remain open.

Build51 itself contains neither continuation. Its Classic Commit read was ready
at the first successful 4.95-second native observation; action/observation overhead and a
recently created filesystem cache limit that measurement. No cold Finder result
or universal startup guarantee follows from it.

The subsequent [signed build52 check](qa/signed-consolidation-build52-2026-11-03.json)
uses the same private repository with unchanged HEAD/index/status and an existing
106.6 MB warm archive. Workspace commands and both changed rows are ready at the
first 1.225s observation, while the footer separately reports Finder publication
in progress. Commit is then ready at the first successful 5.569s observation;
before normal Quit the workspace reports that publication completed. The app's
owned windows close and its main executable is independently absent. This proves
usable foreground state during that real publication workload. It is not a
matched encoding benchmark, an isolated Commit speedup, a cold-disk guarantee or
physical Finder grant/badge/cold-command proof. Test app preferences/repository
records are restored or removed; optional historical warm metadata may remain.

## Native large-checkout timing — November 3, 2026

The [native timing checkpoint](qa/commit-native-scale-2026-11-03.json) uses a
private local checkout of the reported Ladybird repository with 34,303 tracked
paths. Classic and staging modes run with both Git engines, first clean and then
with one private tracked-file edit. Each new receiver measures controller
construction, actual native table/header readiness and one owned refresh.

The first system-Git Classic load took **10.56 seconds**. The other seven initial
loads took **2.23–2.39 seconds**; all refreshes took **1.65–1.77 seconds**. Controller
construction itself took 0.13–0.19 seconds. All eight cases retained private
HEAD/index and exact row counts, closed their owners and drained their work.
The original checkout's HEAD/index were unchanged and the private copy was removed.

The first receiver's existing phase trace reaches identity readiness at 0.19
seconds, settings/change-data readiness at 10.02, and accepted rows at 10.32.
The interval includes preferences and captured Git reads; individual command cost
and the slow first-load cause are not yet isolated. The first-load gate stays
open. Faster later samples do not establish a product speedup or erase this result.

Filesystem caches were not controlled. Project hooks/providers were rejected and
private configuration excluded user global settings. This measures the hidden
Debug native dialog, rather than full cold Finder launch, signed sandbox IPC or
the installed application. No additional app/Core build or full suite ran.

## First-read diagnosis — November 3, 2026

The [focused diagnosis](qa/commit-first-read-diagnosis-2026-11-03.json) reproduced
the slow hidden-native first load and isolated an 8.84-second Git status child.
A later Trace2 observation places most of its slower status interval in index
refresh, with no content scans. Direct fresh-checkout status took 0.59 seconds;
forcing TurtleGit's C locale still took only 0.66 seconds. No locale or native
layout rewrite is justified by these results.

A scoped user-initiated activity control reduced the observed native first load
to 3.72 seconds, but the separate checkout also had different index-stat counts.
This is a scheduling hypothesis, not a proven App Nap cause or production speedup.
The hidden probe bypasses application-main Git permission preparation. Current
signed application/Finder delivery must be measured before changing shipping
performance policy. The earlier 10.56-second sample and first-load gate remain.
