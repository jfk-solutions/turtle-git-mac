# Log cache implementation continuation

Source: `GitLogCache.cpp` and `SetDialogs.cpp` at pinned revision
`7338078f8ddd924b8cddee35f512f2286072136d`.

Dialogs 1 now exposes source Enable Log Cache (default true). New Log windows
capture the choice. The native persistent cache stores completed changed-file
records for a selected commit and its compared parent; merge parent groups retain
separate records. Core callers opt into caching explicitly, so mutation validators
and other uncached workflows continue reading Git directly.

The cache lives in the current application's macOS Caches directory, including
its container in a sandboxed build. It does not create repository cache files or
need a new repository write grant. Repository path, Git executable, commit and
compared parent identify records. Actual resolved trees, effective configuration,
engine file metadata, index contents and relevant diff environment identify the
context. Attribute fingerprints include configured/default global attributes,
Git info/attributes and .gitattributes for the changed paths and their ancestors,
including old rename paths. Changed inputs invalidate reuse. Shallow/deepened
parent changes and replace-tree changes therefore select different data.

Records use versioned JSON with Codable file rows, preserving order, rename
pairs, raw status, numeric/binary statistics and submodule flags. Root/file modes
are 0700/0600. Malformed, missing, oversized, unreadable or invalidated entries
fall back to the normal Git reads. Optional cache write/trim errors never fail a
Git read. Cancellation is checked around lookup and before write/return. Entries
are capped at 8 MiB; trimming limits the directory to 1024 entries / 128 MiB.
Concurrent writes replace entries atomically; pruning races become cache misses.

Refs, notes, mailmapped identities, traversal/graph state and working-tree changes
remain fresh. The Windows mapped index/data binary format is replaced by native
JSON records; Windows cache files are not interoperable with this format.

The initial implementation had no dedicated cache acceptance. The dated
continuation below records the subsequent implementation and focused checks;
older Settings/History QA does not establish persistent cache coverage.

The shared [rename/copy detection family](DIFF-DETECTION-PARITY.md) now connects
source percentages, paired file/patch reads, pinned snapshot policy and historical
cache invalidation. Its separate validation record reports the actual scope.

## Log cache / Saved Data continuation, 17 October 2026

Metadata paths are now read separately with exactly one Git record terminator
removed. Repositories, linked metadata and configured global attribute filenames
can contain newlines, including a trailing newline. Attribute path sets and their
sort order use exact UTF-8 bytes. Index and attribute reads are regular-file-only,
bounded to 64 MiB and cancellable by 64 KiB chunk; exceeding that optional-cache
limit falls back to Git. A missing attribute/index is distinct from an unreadable
one. Attribute fingerprints bracket the statistics/raw reads; context is checked
again before publication. This is not a repository lock or an atomic snapshot
across concurrent external Git/config/attribute edits.

Cache operations pin a no-follow directory descriptor. Regular record reads do
not follow record symlinks or block on FIFOs. New 0600 records publish through
unique sibling files and atomic rename. Count, trim and both clear entry points
share the 64-lowercase-hex JSON namespace and ignore foreign JSON, symlinks and
directories. In-process operations serialize; an external writer can repopulate
records after Clear, just as a later Log read can. The cache root is retained.

Saved Data Clear runs away from the main actor. Repeated clicks are rejected
while busy, the native button disables and shows progress, and Settings dismissal
and application Quit retain ownership until accepted cleanup finishes. Forced
retirement lets cleanup drain while refusing late UI updates. New Log windows
capture Enable Log Cache (matching upstream CLogCache construction); changing the
preference does not change the policy of a window already open. Private cache
injection allows verification without touching the user's cache.

The grouped validation checkpoint covers only its explicitly recorded cases. Windows binary cache
interoperability, immutable commit metadata efficiency, performance, system-wide
attributes discovery, shallow/deepening, broad merge/octopus parent permutations,
external-process races and true signed sandbox cache behavior remain open.

### Grouped checkpoint

[17 October evidence](qa/log-cache-branding-family-2026-10-17.json) retains the
initial failures: the context parser rejected Git's echoed `--end-of-options`,
and receiver lookup/AX press did not reach the SwiftUI Clear action. Context now
uses `--revs-only`; Clear is an explicit AppKit target/action button. The native
fixture invokes its target/action with `performClick`, preserving the deletion
and ownership assertions. Physical AX/VoiceOver acceptance is still open.

Five cache cases, seven Saved Data cases and the rename/copy history-cache case
passed across the initial unaffected checks and the four affected repair checks.
The three real-Git cache cases also passed with bundled Git. Four grouped native
cases then passed across system/bundled Git, covering new/open-window preference
policy, actual Clear target/action, duplicate rejection, Quit ownership, retirement,
repopulation, errors and retained Settings workflows. Debug builds passed. All
seven attempted native receivers were reaped and independently absent. The full
Core suite, signed AppStore build, installed Finder and hosted CI were not rerun
or certified by this checkpoint.
