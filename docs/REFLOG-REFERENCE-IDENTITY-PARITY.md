# RefLog named-reference selection and actions

Implementation continuation, October 24, 2026. The scoped grouped checkpoint passed after two fixture-only repairs. This records one connected RefLog reference-selection/command family, not full RefLog or application parity.

The pinned source is TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`. `src/TortoiseProc/RefLogDlg.cpp::Refresh` populates the reference selector and loads the selected named log. `GitLogListBase.cpp:2245–2281` enumerates reference-delete leaves and All using the friendly-name map; `GitLogListAction.cpp:1031–1066` excludes only the exact current branch and dispatches each reference separately. Source CString reference identity does not apply Swift's canonical Unicode equality.

The native RefLog selector now inserts explicit `NSMenuItem` objects, preserving raw UTF-8 names and their indices when labels are canonically equivalent. Each item carries its exact reference and a captured model/catalog/current-reference context. Each projection owns a separate native target. Replaced, detached and dismantled targets retire; late callbacks cannot reinterpret an old index against a new catalog. Dispatch requires the current target, enabled control, exact owning window, no sheet/modal dialog, current context and the model's existing refresh gate. Re-selecting the current exact reference remains a harmless no-op. Native owner focus is not replaced with a global key-window assumption.

Candidate construction, annotated-tag suffix deduplication, current-branch exclusion, named-reference membership and All deletion now preserve byte-distinct names. Current-branch Switch exclusion and explicit Switch dispatch use the same identity. A canonically equivalent sibling of the current branch remains available as a separate target; the current exact branch remains protected. Existing source command order, icons, per-reference confirmation/error handling, expected object checks and cancellation remain in place.

Async transport, deletion, note/history operations, combine/bisect requests and native menu receipts now compare the captured named log exactly. Selected row identity remains tied to its displayed log. Root Core integration applies invocation-only `core.precomposeunicode=false` to named-ref reading, preparation/revalidation and mutation in the ReferenceLog, operation, diff and HistoryReferenceDeletion paths, without changing persisted repository configuration. `ReferenceLogEntry` equality/hash and operation/deletion selector membership likewise preserve exact selector and data bytes. This does not introduce another Git execution path.

Private packed references can preserve distinct canonical-equivalent names even on a volume whose loose paths alias them. Such a volume may still alias reflog files, and this work does not claim to change filesystem Unicode behavior or recover separate historical contents that the underlying Git/filesystem cannot store. Invalid UTF-8 reference names are outside this scope.

Grouped acceptance covers actual popup items and targets, named-log selector prefixes, current/sibling candidates, native All dispatch, stale names/reference contexts, busy/Quit/held-confirmation/retirement refusal, exact Core argv and selector guards, cancelled reads, persisted preference preservation and owned receiver cleanup. Physical popup interaction, VoiceOver, signed grants and complete hosted integration remain separate acceptance claims.

The [dated checkpoint](qa/reflog-reference-identity-family-2026-10-24.json) records
29 relevant Core methods and six native case/engine pairs passing. The app build
returned zero with five contradictory exit-zero diagnostics retained in its log.
The native fixture first required an explicit nonblocking sheet overload, then
explicit Swift ownership of two temporary windows after a receiver release crash.
No production changes, Core rerun or app rebuild were needed for those repairs.
All seven attempted receivers were reaped and independently absent.
