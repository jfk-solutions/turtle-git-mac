# Finder clipboard transfers

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` disables
its ordinary ClipPaste entry in `TortoiseShell/MenuInfo.cpp`, while
`PasteMoveCommand` and `PasteCopyCommand` remain implemented. TurtleGit provides
these as explicit macOS additions, separate from source menu masks.

## Connected workflow

A cached non-bare working-tree folder offers Paste Copy and Add when the clipboard
contains file URLs. Paste Move additionally requires cached versioned sources from
the same working tree. Roots, unknown/unversioned move sources, administrative
selections and nonfolder destinations do not receive the move entry. Finder runs
no Git. The containing app revalidates destination and source paths before mutation.

The menu captures both destination and ordered file URLs. Repeated `source` query
fields preserve literal names independently of `path` destination fields. Ordinary
commands reject transfer payloads; transfers require one destination and nonempty
sources, with bounded count and URL size. No clipboard reread follows delivery.
Original icons honor the existing icon preference. These entries stay in the
TurtleGit submenu; a separate clipboard-transfers toggle has Apply/Cancel and
backward-compatible persistence without adding Windows mask bits.

Destination authorization uses the existing app repository permission path.
Copy opens with the captured destination and sources; Move resolves clipboard paths
and destination together before enabling mutation. External Copy sources that lack
sandbox scope request an owned native authorization panel for the same captured
files/folders. Arbitrary replacements are rejected. Source leases remain retained
through copying, Git Add, questions and retirement. A cancelled or late permission
reply cannot start a copy, and Quit remains blocked until outstanding work settles.
The root-adoption generation suppresses a stale dialog handoff after closure.

These commands open the native transfer window for review; delivery alone does not
copy, move or stage files. See [File transfers](FILE-TRANSFER-PARITY.md).

## Acceptance still open

The batch includes actual menu-builder assertions, request/eligibility tests and a
native receiver for captured adoption and owned permission continuation. The
receiver injects the final route and permission adapter; installed Finder URL
routing, physical clipboard gestures, the displayed authorization panel, signed
App Group/security scopes, large URL delivery and Finder refresh need acceptance.
Finder drag-destination menus remain unimplemented. No full shell or App Store
parity is claimed. The Debug build, 26 related Core tests, actual menu-builder receiver and four
native cases across system/bundled Git passed. The native fixture initially failed
because unsigned source URLs already reported a scope; a diagnostic run established
that copying/staging succeeded while authorization was skipped. An injected denied
initial permission provider now exercises authorization deterministically. Core and
menu checks were not repeated for that native-only repair. Every owned receiver
was reaped. See [batch results](qa/finder-transfer-2026-10-14.json).
