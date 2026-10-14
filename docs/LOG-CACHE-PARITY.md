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

This continuation is **uncompiled and untested**. Persistence across process
restart, corruption/input invalidation, shallow/replace/attribute cases,
concurrency/cancellation, eviction, sandbox execution and performance need the
combined section check. Physical checkbox and keyboard/visual acceptance remain
open. Source immutable commit-metadata cache efficiency still needs comparison;
this implements persistent diff-file reuse, not certification of every source
cache behavior. The older Settings/History QA records do not cover this change.

The shared [rename/copy detection family](DIFF-DETECTION-PARITY.md) now connects
source percentages, paired file/patch reads, pinned snapshot policy and historical
cache invalidation. Its separate validation record reports the actual scope.
