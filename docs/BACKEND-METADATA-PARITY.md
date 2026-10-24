# Backend metadata reads

## Pinned source and scope

The `UseLibgit2` master switch is separate from `UseLibgit2_mask`.
Pinned `Git.cpp` `GetTagList` (1476), `GetBranchList` (1710),
`GetRemoteList` (1955), `GetMapHashToFriendName` (2232), and `GetTagInfo`
(3783) use the master switch. `GitRevLoglist::SafeGetSimpleList` (57) and
`SafeFetchFullInfo` (180) use command bit 15. The Reference Browser retains its
separate bit 18 and merged-filter exception; ordinary Push stays on Git, while
bit 11 selects remote-reference deletion. This batch adds no transport fallback.

## Implemented family

- Core `checkoutReferences` now captures the master configuration and uses a
  lightweight libgit2 reference inventory when enabled, independent of bit 18.
  Literal names and symbolic targets survive without requiring a commit object;
  unborn repositories return an empty catalog and detached HEAD does not invent
  a local branch. The existing optional FETCH_HEAD reader and native ordering
  remain in the same path. Branch/tag/symbolic choices feed existing Switch,
  Rebase, Push and other native reference controls without new UI labels.
- Core `remoteNames` uses libgit2's configured remote list under the same master
  switch. Captured settings, cancellation and exact UTF-8 names are retained.
  Canonically equivalent names remain separate configured remotes. Existing
  Fetch/Pull/Push manager-return and refresh ownership controls remain in force.
- Log label metadata uses captured libgit2 inventory and peeled annotated-tag
  targets. Broken symbolic remote references are skipped like the pinned
  `GetMapHashToFriendName`; genuine lookup failures remain failures. Raw tag
  object bytes come from the selected helper instead of CLI `cat-file` and use
  the existing native formatting. Native recursive tag peeling and batched tag
  details preserve the established nested-tag behavior.
- Batched `revisionChanges`/`revisionActions` now honor bit 15. Root and all merge
  parents are validated against the captured entry before publishing a complete
  result. Up to 128 revisions share one helper process, including repeated captured
  rows; accepted uppercase object IDs are normalized for the helper while caller
  dictionary keys stay unchanged. Existing helper rename detection and threshold settings provide the
  same backend as individual Log file lists. This reaches Log/Sync action
  columns, History file filtering and combined comparison consumers.

The helper adds bounded private `turtlegit-checkout-refs`,
`turtlegit-configured-remotes`, and bounded `turtlegit-tag-objects`/raw `turtlegit-tag-object` endpoints. Inventory
framing accepts the new optional peeled OID, validates names/object IDs/counts,
rejects partial responses and retains cancellation. Configured remote names are
not incorrectly validated as `refs/` paths. No Git configuration is rewritten
by a metadata read. An explicitly selected missing helper reports the runtime
error; it does not silently use the other engine.

## Authored verification and remaining work

`BackendMetadataReadTests` covers mask-independent master catalogs, exact remote
names, unborn/detached and dangling symbolic state, annotated tag bytes/targets,
root/rename/merge action metadata, a 129-row/two-process batching oracle, uppercase
OID acceptance, selected missing runtime and pre-cancellation.
The private offscreen native receiver `backend-metadata-native-2026-10-24.swift`
and `scripts/test-backend-metadata.py` exercise actual Push/Fetch loading with
mask zero, mutate private preferences while an accepted read is held to verify
captured policy, and trace the selected helper, plus retirement during a held metadata
process. All windows/preferences/helper processes are owned by the receiver and
runner. Physical popup input is outside this automated scope.

The [grouped checkpoint](qa/tools-metadata-compressed-family-2026-10-24.json)
rebuilt and validated the universal helper on both architectures. Its 70 relevant
Core methods pass cumulatively after two test-oracle repairs: rename similarity
text differs between the source helper and Git, and the retained Git command-count
fixture now explicitly selects Git. Actual native catalogs/lifetime cases pass
with both system and bundled Git; all four receivers are independently absent and
owned-helper scans found no survivors. This scoped pass does not prove the full
hosted suite or physical popup input.

This completes the scoped catalog/label/action reader family, not every
master-switch libgit2 call in upstream. General revision-name resolution
(`GetHash`), branch/tag existence lookups, and submodule-object lookup
have additional pinned master-only implementations; this batch does not claim to
port those backend choices. Their existing native workflows continue to work
through their current Git operations. Pinned Git notes reads/writes use unconditional
libgit2 calls; their native backend choice is a separate compatibility boundary,
not a missing command-mask or master-switch consumer. Full provider, minimum-version/Intel,
physical keyboard/VoiceOver, signed deployment and hosted integration acceptance
remain separate.

The connected [revision lookup family](REVISION-LOOKUP-PARITY.md) adds typed
resolution and exact existence/collision checks for Create Branch/Tag, Switch,
Push, Fetch-to-Rebase and Synchronization. Its accepted forms and handoffs retain
the selected backend; callers outside that family remain separately scoped.
