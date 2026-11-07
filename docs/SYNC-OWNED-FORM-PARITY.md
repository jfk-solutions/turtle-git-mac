# Synchronization form and progress ownership

This continuation covers native Synchronization history editing, conflict-list
refresh, captured Checkout/Merge progress and their connected Fetch/Rebase paths.
It does not establish complete Synchronization or application parity.

The pinned TortoiseGit source is
`7338078f8ddd924b8cddee35f512f2286072136d`. `SyncDlg.cpp` lines 630–659 run a
separate `git merge --ff-only -- <upstream>` progress dialog after the user chooses
Merge. A nonzero command status can offer Resolve when working-tree conflicts
remain; Resolve opens Commit. The macOS handoff retains the exact repository
actor and backend that produced the accepted state, rather than constructing a
replacement actor from later preferences. Core still refuses foreign actors,
changed HEAD or attachment, precancelled work and invalid targets before mutation.

Progress distinguishes the actual announced merge from failed preparatory Git
reads. A metadata error keeps its original typed diagnostic without inventing a
Resolve action. A failed or cancelled announced merge keeps its command result
while a fresh token owns the separate conflict inspection. Late answers to an
old cancellation question cannot cancel the replacement read. Recovery consumes
its receipt once and returns to Commit only after progress work, questions and
native sheets have detached. Checkout, Merge and tag completion retain the same
physical sheet boundary; callback delivery clears parent ownership before its
continuation runs.

Sync's editable history controls retain a receipt for continuous edits in the
same field. A native selection followed immediately by Shift+Delete must work
before SwiftUI repaints the form. The current read generation may also accept
that field's deletion and cancel its own superseded catalog query, retaining
ownership until the real worker drains. A changed other field, replaced catalog,
invalid index, changed option, attached sheet or retired owner cannot revive an
old callback. Stored URL and Git reference spellings remain exact UTF-8 values,
including distinct NFC and NFD names; branch history keeps its separate upstream
case-insensitive policy.

The native history fixture uses the repository actor's captured filesystem root
for its preferences namespace. Foundation can standardize `/private/var` to
`/var` while both name the same private fixture. This filesystem-key correction
does not normalize history values, Git reference names or file payloads. Loading
still must not save history, and the full URL inventory and saved byte spellings
remain asserted.

`SyncDlg.cpp` handles F5 only outside a blocked operation. The macOS window also
requires the matching key window and an unobstructed presentation. The prohibited
background receiver supplies only its owned window's public key-state getter
while dispatching the actual native key equivalent. Production event, window,
modal and sheet guards remain unchanged. This establishes routing under supplied
key authority, not physical desktop keyboard-focus acceptance.

## Validation scope

`scripts/test-sync-owned-form-family.py` compiles the related fixtures once against
the actual Debug app and imported frameworks. Existing Sync entry points retain
their selected case options and delegate to this cached receiver. Each case has
private repositories, HOME, preferences, configuration, temporary storage and
pasteboards. Automated windows stay transparent and offscreen. Cleanup closes
owned native windows, waits for worker and sheet retirements, and independently
checks exact helper images or authored wrappers holding private fixture resources.
The driver collects independent case failures after cleanup; it never treats an
incomplete receiver or helper cleanup as a pass.

The initial grouped checkpoint and affected repairs are retained in the
[November 7 native record](qa/sync-owned-form-family-2026-11-07.json). Strict
assertions cover real fast-forward commands and original failures, backend and
actor capture, foreign/stale/metadata refusal, actual cancellation and read drain,
Resolve-to-Commit, tag sheets, conflict tables, native history selection/deletion,
Pull checkout/recovery and exact-reference Push/Pull/retirement. Current hosted,
signed physical, accessibility, minimum-OS and full dialog visual acceptance remain
separate release gates.
