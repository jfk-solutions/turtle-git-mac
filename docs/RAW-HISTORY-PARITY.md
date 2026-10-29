# Historical Git filenames, comparison and file delivery

This family extends the Browser namespace workflow against pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It is a partial workflow review,
not certification of Browser, Log, Blame or the whole port.

The [historical individual-file transfer continuation](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md)
extends raw files to safe-named native providers, file promises and shared
file-list clipboard delivery. This retains exact historical identities and
captured checkout-filter behavior. It does not relax working-tree or literal
folder filename requirements; archive export remains the way to deliver folders
with their original Git member names.

## Source behavior and native adaptation

`src/TortoiseProc/RepositoryBrowser.cpp:733–772,817–837` offers Show log for files
and folders and Blame for files when a working repository is available. Both
commands retain the Browser revision. The source decodes names into its Windows
string namespace; native Browser instead retains each original Git byte path,
including names that cannot be decoded as UTF-8, as documented in
[Browser filename handling](REPOSITORY-BROWSER-NAMESPACE-PARITY.md).

Previously those raw rows could be navigated and inspected as stored objects,
but history actions were refused. The connected native readers now pass exact
Git pathname bytes to the existing owned Git process. Only explicitly indexed
arguments receive a byte override. An escaped caption is diagnostic text; it is
never substituted for the Git filename, evaluated by a shell, or interpreted as
a macOS filesystem path. Embedded NUL and invalid argument indexes are refused.
All other arguments retain their original Unicode spelling and boundaries.

## Connected reads and presentation

File and directory Log reads retain ordinary revision walking, path scoping,
filters, mailmap, source metadata and optional rename following. Directory scopes
still refuse the file-only Follow renames mode. Actual parents, rewritten graph
parents and commit identities remain separate. Blame reads the pinned stored
blob and preserves original line bytes, attribution, renamed/copied origins and
its configured annotation/history choices.

Name-status, numstat and raw diff records preserve distinct pathname identities
instead of merging a raw name with a valid replacement-character sibling. The
selected libgit2 history backend carries the same validated opaque path keys;
the new path transport applies only to historical metadata. Transfer and native
filesystem notification contracts remain unchanged. Cache context is versioned
to prevent old lossy pathname records from being reused. Optional filesystem
attribute fingerprints refuse raw keys, so those records are read without that
cache rather than constructing an invalid native URL.

Browser menu receipts retain the pinned revision and exact path. Log/Blame
captions, origin labels and clipboard presentation use escaped names. Internal
keys do not become user-visible filenames, recent filesystem entries or syntax
loader paths. A late Browser or annotation callback cannot retarget another
repository or a retired owner. Owned history reads retain their cancellation,
process-group drainage, repository access and Quit protection.

## Historical comparison and file delivery continuation

The [materialization checkpoint](qa/raw-historical-materialization-2026-10-27.json)
records its grouped validation separately from the earlier history checkpoint.
It connects historical file comparison and Open/Save to the same exact byte
identity as Log and Blame; the scope and original failures appear below.

Browser **Mark for comparison** and **Compare with marked file**, Log parent or
selected historical comparisons, and Blame's historical comparison callbacks
retain each pinned revision and original path. Both comparison endpoints must be
historical for an opaque path. The tree reader resolves the exact entry and blob
OID, including a renamed old path, without consulting the current checkout or
substituting a valid replacement-character sibling. Regular files, executable
files and symlink blobs retain stored bytes and modes. Comparisons and attribution
read stored data, independently of checkout filters.

Ordinary **Open**, **Open With…**, **View revision with alternative editor** and
**Save revision to…** now accept a raw historical file. They follow the existing
source `GetOneFile` backend policy, rather than silently changing all historical
outputs to filtered or unfiltered data:

| Selected read path | Output policy |
| --- | --- |
| Command-line fallback | Stored blob bytes, as in the source fallback |
| Selected libgit2 GetOneFile helper | Checkout/smudge filters using the exact original byte path and current attribute policy |
| Explicit stored-blob commands | Always stored, unfiltered object bytes |

Pinned source `src/Git/Git.cpp:2777–2871` selects the corresponding GetOneFile
branches; `src/TortoiseProc/RepositoryBrowser.cpp:1229–1309` owns Save/Open and
alternative-editor delivery. The native helper accepts a bounded typed packet
containing the blob OID and encoded pathname bytes. Filters receive the original
pathname, including `%f`, as one argument; no escaped caption or shell-evaluated
filename replaces it. Changing an attribute can change a later filtered output;
it does not change the captured blob OID, file mode or Browser revision.

A raw Git filename never becomes a native destination. Historical deliveries
propose `Git-blob-<full-source-blob-OID>` plus an optional 1–16-character ASCII
alphanumeric extension from the original leaf. The OID identifies the stored
source even if filters transform the delivered bytes. Existing preview/revision
suffixes and private per-operation folders remain in place. A Save panel grants
authority for the user's actual chosen destination. A symlink's bytes are
materialized as file content rather than followed as a native link.

External comparison tools receive private, read-only copies under safe leaves.
Their displayed titles use escaped original paths; file/path placeholders for
opaque historical inputs receive prepared native paths. Filename associations
use an exact decodable leaf when available, with extension/default fallback;
lossy replacement text does not select a different file's rule. Existing tool
selection, alternate-tool policy, security scopes and uncertain external-launch
cleanup remain applicable. Built-in document/notebook preview inputs use the same
safe naming boundary. An absent comparison side uses a labelled
`<side>-absent.<format>` placeholder with no invented stored OID. This does not
establish acceptance by receiving apps.

Historical scoped unified diffs retain byte path arguments for both CLI and the
selected helper. Patch headers use Git-style quoting of original bytes, including
rename endpoints. Hunk data is not decoded and rewritten to hide an invalid
filename. Creating a patch from comparison panes likewise keeps source-byte
labels, modes and symlink target bytes; its Save panel proposes a safe leaf.
Historical pane edits can be saved to an explicitly chosen output, not written
back through an opaque key into the checkout. Native captions, lists, tooltips and
clipboard presentation remain escaped and contain no internal NUL-prefixed keys.

All these reads and output panels retain the existing owner/session receipts,
revision and backend capture, cancellation and Quit gates. A refresh, navigation,
close or retired chooser cannot launch or write a late output. Ordinary UTF-8
paths keep their established authority and filesystem checks.

## Materialization/comparison checkpoint

The [materialization checkpoint](qa/raw-historical-materialization-2026-10-27.json)
records 154 distinct Core methods passing cumulatively and all seven native
Browser cases passing with both system and bundled Git (14 engine/case pairs).
The initial Core fixture used a CR-terminated string prefix; stricter signed
CRLF byte assertions passed with both actual patch backends. Native fixture
repairs replaced an obsolete disabled-Open expectation and selected the helper
explicitly for filtered-output checks. The final case holds and retires the
actual smudge child. These repairs preserve the behavioral assertions.

The universal helper and unsigned Debug app passed. All 16 attempted native
receivers were reaped and independently absent. Generated localization and Help
checks passed. These focused results do not establish physical Finder behavior,
external Office automation, signed deployment or full hosted CI.

## Earlier verification and remaining boundaries

The earlier [history-only checkpoint](qa/raw-history-family-2026-10-27.json)
records that family's implementation and validation state. It does not establish
the materialization continuation above. All 149 distinct relevant Core methods
passed cumulatively: the initial group caught an ordinary-path Blame admission
regression, then the nine affected ordinary/raw cases passed after restoring the
existing path checks. The universal helper, regenerated project/resources and
final unsigned Debug build passed.

All six Browser namespace cases passed with both system and bundled Git. The
first native run retained an old dispatch count; the corrected fixture preserves
its assertions and the failed/unrun cases passed without repeating the already
passing listing/navigation pair. The new history case checks actual native menu
selectors/icons, raw folder history, pinned reads after HEAD drops the raw names,
origin callbacks, display/copy/tooltip identity, filesystem refusal and held Git
read retirement. All 13 attempted receivers were reaped and independently absent.
There was no physical screenshot or signed deployment check. Earlier Browser
checks establish their dated families, not these new paths.

Raw original-path checkout, working-tree comparisons/mutation, filesystem
reveal, folder exports/promises and submodule checkout resolution remain separate
implementation work. Their pathname-dependent dispatchers refuse a raw key
instead of addressing a replacement spelling. A mark involving a working-tree
endpoint retains that refusal even when its other side is historical. Historical
single-file comparisons/materialization and safe chosen-name delivery are now
implemented in this continuation; folder transfer still preflights every
descendant and refuses an unrepresentable name. Hash-only revision actions remain
independent of these restrictions.

Physical gestures, VoiceOver, signed sandbox grants, external receiving
applications, Intel/minimum-OS execution, full hosted CI and complete source
visual parity require separate acceptance. No signed installation or App Store
submission is part of this checkpoint.
