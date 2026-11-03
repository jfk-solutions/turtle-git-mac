# Commit display read scope

The November 3 continuation narrows auxiliary index reads for both captured
Commit refreshes and their fallback flag reader. Index flags and gitlink modes
are requested for the current change candidates rather than every clean tracked
file. A clean or wholly untracked change list launches no auxiliary index reader.
Untracked embedded repositories retain their directory rows and default flags
without passing their trailing-slash names to an index query. Exact UTF-8 names,
conflict stages, lowercase index flags and submodule modes remain part of the
display snapshot. Literal arguments are deduplicated and split under the existing
platform byte budget; cancellation is checked before each batch and record.
Directory pathspec descendants cannot become unrelated display candidates.

On an unborn branch the working and staged comparisons use the same cached diff;
the captured read reuses that result instead of launching an identical second
diff. Ordinary HEAD and amend comparisons retain separate reads. These are
operation-local display facts, never mutation authority or a cross-refresh cache.
The general Working Tree dialog retains its full inventory.

Pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d` CommitDlg.cpp
uses its accepted status list for submodule controls (`GetSubmoduleCount`, line
3078); native Commit likewise consumes submodule membership for displayed rows.
No native controls, persistence, labels or user commands change in this batch.

The [focused Core checkpoint](qa/commit-scoped-index-2026-11-03.json) passes:
24 initial tests, then only the 15 affected reader tests after the embedded-repo
correction. A second engine-configured run passes; its four legacy refresh tests
retain their system-Git fixture, while the captured/new fixtures honor the engine
override. No native receiver or app build ran for these Core-only changes.
This removes proven excess subprocess output and parsing; it does not establish
a wall-clock latency improvement on the owner's large repository. Physical
Finder launch, current signed-app acceptance and complete hosted CI remain open.

The parallel review identified directory-only Finder registration admission and
containing-root grant recovery as the next workflow batch. That subsequent
[source continuation](qa/finder-root-grants-2026-11-03.json) records its own
validation and pending chooser runtime acceptance; this Commit batch itself
does not establish Finder behavior.
