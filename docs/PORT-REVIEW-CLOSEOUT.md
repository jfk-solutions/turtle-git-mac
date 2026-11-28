# Bounded port review and local delivery — November 28, 2026

This development record reviews source `a4ff95ec32ad8e7d1c618c81db7daee89c754be6`
against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
It preserves the distinction between a pending inventory entry, an actual
implementation difference and unverified physical or release behavior. It is
not a complete source/dialog audit or a declaration that the port is finished.

## Pending resource inventory

The separate [bounded resource review](PENDING-RESOURCE-REVIEW.md) records the
pending inventory and the explicit Windows crash-service differences. Its
resource-specific evidence is kept separate from CI and candidate packaging.

## Hosted recovery evidence

Matching-source [run 46069911765](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/46069911765)
recorded **SUCCESS** for Rebase source forms/connected workflows, step 201 of
job `140746248409`, from **2026-11-27 22:26:17 to 22:42:18 UTC**.
The [Rebase recovery record](qa/hosted-rebase-add-cohort-recovery-2026-11-27.json)
retains the prior timeout, cumulative-budget diagnosis, unchanged per-process/
wait budgets and complete cohort coverage. The History lane recorded **SUCCESS**
at **2026-11-27 23:14:36 UTC**; the
[Log recovery record](qa/hosted-log-operands-recovery-2026-11-27.json) retains that
separate hosted result alongside earlier focused evidence.

Actual GitHub job metadata, observed on November 28 at 01:30:11 UTC, records
these additional results (completion times below are GitHub `completed_at`,
not watcher polling times; all times UTC):

| Lane / job | Result | Actual completion or status |
| --- | --- | --- |
| Core / `140746248393` | Success | November 27, 23:51:18 |
| Commit/repository / `140746248414` | Success | November 27, 23:53:54 |
| History / `140746248429` | Success | November 27, 23:14:36 |
| Images / `140746248432` | Success, including steps 169/170/426/435/436 | November 28, 00:48:17 |
| Settings/Finder / `140746248379` | Success | November 28, 00:59:36 |
| Replay / `140746248409` | Success | November 28, 00:59:19 |
| Editors / `140746248418` | Cancelled | November 27, 23:14:40 to November 28, 01:16:32 |
| Distribution / `140746248441` | Still running, observed at step 444 | November 28, 01:30:11 snapshot; no success inferred |

The SVN runtime producer completed successfully on November 27 at 21:28:50 UTC.

Editors had a step 142 external Unicode/CaseConvert download timeout and the
step 305 creation-picker assertion. Its later Rebase conflict receiver was
interrupted after approximately 141 seconds, below its 300 second budget. Available
metadata does not identify the cancellation initiator; unexecuted or interrupted
steps remain unverified. This must not be reported as a complete hosted pass.

Two subsequent local repairs preserve the original behavioral oracles:

- `9a380900e96f80c4645187334e3cce41aff057e4` adds bounded retry to the shared
  Unicode source download. Fifteen helper tests and both full source oracles
  passed; see the [download recovery record](qa/hosted-unicode-source-download-recovery-2026-11-28.json).
- `5b5bfbc0dff196539b0c5ba103e18a78deb49003` changes only the picker fixture's
  native publication admission. Exact ancestry/hash/graph/single-selection
  assertions remain independent. Creation pickers passed with both Git engines
  in 48.174 seconds, and all owned PIDs were independently absent; see the
  [picker/cancellation record](qa/hosted-editor-picker-and-cancellation-2026-11-28.json).

Neither repair changes application source or control mappings. **Complete hosted
acceptance of the corrected source remains required.** The six successful lanes
retain their exact `a4ff95ec` scope; Distribution's final result remains unverified in
this snapshot. No physical Finder, VoiceOver or signed UI result is inferred.

## Signed local candidate 61

The [candidate summary](qa/hosted-signed61-local-candidate-2026-11-28.json) binds
version **0.1.0 (61)** to source `a4ff95ec32ad8e7d1c618c81db7daee89c754be6`,
input `e86798d1768c50841c68c6ac2a4b6b2c3a4ba17660b93c3565c3850469506b62`
and main executable `920576c23e04d1d48c37855917a9c07bb164a885b66860297561c99196c39a6a`.
Candidate 61 remains immutable at exact `a4ff95ec`; it is not relabeled as either later
CI repair commit. The Apple Development-signed universal package is
`build/local-testing/TurtleGit-for-Mac-0.1.0-build61-signed`.

One actual Xcode build succeeded. The original wrapper exit **1** remains recorded:
its candidate-registration cleanup classification was resolved separately in the
immutable `signed61-final-cleanup-resolution-2026-11-27.json` receipt
(SHA-256 `adb6dc438adb81b0d8e9ea300892b33153747083bcdaa5b7fff7a642c20e557d`),
without another build or changing the original receipt. Strict seals/resources,
one fresh **local-tools** phase, complete copied/extracted app inventories and
exact corresponding-source archive verification passed. The app ZIP SHA-256 is
`f5bd68b94616342ea5fb3edd1072119b213c19e6b07241959fb4841fbc3696ef`.

No candidate 61 installation, physical UI/Finder/SSH acceptance, public upload,
notarization or Store submission is claimed. Image build 56 and SSH build 57 evidence
remains historical with its measured component limits; it is not fresh build 61 execution.
The installed owner-testing build 60 and its rollback are separate artifacts.

## Documentation and release boundaries

README, homepage and Getting Started already include real native screenshots;
Getting Started has 16 existing referenced images. The Notes guide already has
light/dark editor captures, and its stale manual-plan note is corrected here.
Other unillustrated guides are illustration opportunities rather than proof of
missing Git functionality. No current screenshot was regenerated by this batch.

Later public distribution still needs owner approval, channel-specific signing/
archive and account details, final listing/screenshots/privacy answers and
license/Store-terms clearance. The saved seller/contact and provisional paid
price are preparation preferences, not authorization to submit or publish.
The original user journeys still require their exact-build owner acceptance;
see the [local checklist](LOCAL-TESTING-CHECKLIST.md). Missing mapping evidence,
Windows platform differences and incomplete physical verification must not be
presented as a newly invented feature backlog or a feature percentage.
