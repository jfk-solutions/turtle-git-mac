# Compare and Merge input encoding

This family ports per-pane encoding reload separately from output format
conversion. It covers two-file/historical comparisons and three-way conflict,
standalone and patch merge inputs. Complete editor parity and signed/physical
acceptance remain open.

## Source contract

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseMerge/MainFrm.cpp`:

- `AdjustUnicodeTypeForLoad`, lines 3526–3554, selects a concrete reader and maps
  UTF-8/UTF-16 BOM menu variants to their corresponding load encoding.
- `OnEncodingLeft/Right/Bottom`, lines 3557–3626, capture Control: ordinary
  selection changes output type; Control changes one source's decoder, retains
  that encoding and calls `LoadViews`.
- `OnUpdateEncodingLeft/Right/Bottom`, lines 3693–3724, enable input reload even
  for read-only panes while Control is held. Read-only EOL conversion stays
  disabled.

## Native implementation

The encoding controls retain ordinary output conversion and offer an explicit
**Reload with encoding** submenu. Control-selection of an encoding follows the
source reload gesture. Captured pane/role receipts prevent a menu opened for an
old document or pane from changing its successor. The explicit submenu provides
the same reload action without requiring a modifier, including read-only inputs.

The selected decoder reads the original bytes, independently for each input.
It does not re-encode an already decoded string. Two-pane comparison retains
physical input identity across left/right switching. Three-way documents retain
Base/Mine/Theirs raw inputs, including the actual conflict-stage/rebase mapping,
and regenerate through the current merge engine. Ordinary reload reapplies
accepted overrides; a new document starts with its own input policy. BOM choices
select a reader rather than adding a BOM to source files.

Reload uses existing dirty Save/Discard/Cancel choices. Cancel preserves the
draft, history and accepted decoder. A successful reload publishes the decoded
document, alignment/merge result, format metadata and navigation together, and
starts a fresh editing history. Failed or cancelled decoding retains the current
accepted view and overrides. A Save explicitly chosen before reload may already
have written the prior draft even if the subsequent decoder fails.

Input reinterpretation itself writes neither source files nor Git's index.
Output encoding/EOL conversion remains a separate draft edit requiring Save.
Read-only source panes continue to reject EOL edits and output conversion.

## Validation and remaining work

The dated grouped checkpoint is
[merge-input-encoding-2026-10-21.json](qa/merge-input-encoding-2026-10-21.json).
The checkpoint passed 63 focused Core methods, the Debug build and eight native
case/engine pairs across the recorded compile, selector and fixture repairs.
Core includes real reversed rebase stages and unchanged index/working snapshots.
Native checks include captured menus, historical/undecoded inputs, source swaps,
raw/BOM comparison children, failed decode retention and owned dirty reloads.
It records actual checks, failures and focused repairs; it does not imply every
encoding, external filter/provider or source state was exercised.

Actual full-window [light](site/assets/merge-input-encoding-light.png) and
[dark](site/assets/merge-input-encoding-dark.png) captures show both reloaded UTF-8
inputs, native encoding controls, source colors and separate read-only EOL state.
The window chrome is inactive. These captures were reviewed individually and
the capture owner was closed immediately afterward.

Physical Control gestures/popups, keyboard/VoiceOver, every code page and malformed
input combination, signed file grants and minimum-version/Intel acceptance remain
open. Complete TortoiseMerge layout/behavior, current hosted integration, Finder
and App Store distribution have separate gates.
