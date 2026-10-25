# Configured issue-regex failure behavior

This family compares pinned TortoiseGit
7338078f8ddd924b8cddee35f512f2286072136d:
ProjectProperties.cpp::AutoUpdateRegex, HasBugID, FindBugIDPositions,
Commit's missing-issue decision and history insertion, and SciEdit issue styling.

## End-user behavior

A malformed configured bugtraq.logregex no longer turns Commit preparation or
history issue extraction into an expression-editor error. An invalid first
expression has no check match or extracted IDs. A valid first expression still
answers HasBugID when only extraction is invalid; its extracted-ID list is empty.
This distinction matters: the source missing-issue warning depends on the first
match, not on whether any ID ranges were extracted.

Commit still validates a separate numeric issue field. It still offers the
project's missing-issue question where applicable, preserves a declined draft,
and inserts a separate issue-line template according to existing source rules.
History insertion can proceed without extracted IDs and leaves the previous
separate issue field alone when extraction is empty. Existing owner, cancellation,
draft-edit and stale-response fences remain responsible for applying results.

Log, Blame/Rebase batch metadata and issue position readers retain empty-ID
behavior for invalid configured syntax. The explicit Regex Tester continues to
use strict matching, show invalid input and retain its last valid expression
pair. Its source only accepts edited expressions when both edit controls are
valid; partial compilation is not a missing tester feature.

## Helper and styling boundaries

Configured matching uses a versioned source receipt containing syntax state,
HasBugID and UTF-16 ranges. Invalid check and invalid extraction are distinct
states. Malformed receipts, impossible ranges, nonzero helper exits, missing
executables, timeout and cancellation remain failures, rather than fake
successful no-match results.

SciEdit's issue pass uses UTF-8 byte expressions and offsets. Its configured
syntax receipt permits URL and bold/italic/underline passes to continue after an
invalid issue expression. The styling actor no longer catches every helper
failure and reports an apparently successful plain result. Presentation owners
keep drafts editable when a style request fails; styling never rewrites text.

Strict legacy helper modes remain strict. The compatible tolerant issue-ID mode
also retains a valid check when extraction compilation fails. The packaged
universal helper and its source/provenance are rebuilt together.

## Compiled-state scope

The configured properties are immutable value snapshots. Source Commit reads
project properties at initialization; native Commit likewise loads them during
initial preparation rather than every F5. This covers the active configured
consumer lifecycle. The C++ object's setters can retain previously compiled
expressions during later invalid mutations. This batch does not expose that
mutable setter API or introduce a process-global regex cache shared between
repositories. The tester has its separate source-valid-pair acceptance boundary.

## Checkpoint

The [dated checkpoint](qa/issue-regex-consumers-2026-10-25.json) records the
universal helper and all-architecture protocol checks, Debug app build, 31
focused Core methods and all six native case/engine pairs passing. Native
coverage includes two actual private commits with each Git executable,
accepted/declined missing-issue decisions, Log/history/style recovery,
stale/closed-owner fences and the retained strict Regex Tester lifecycle.

The first Core attempt exposed a new fixture expectation that contradicted the
source's existing same-line supplementary-character formatting quirk; its
indexed follow-up assertion trapped. The repaired fixture uses a new line to
test ordinary formatting, explicitly retains the source quirk, and guards count
before indexing. No production correction or full local Core rerun was needed.

The app's helper is normalized and ad-hoc signed by bundle layout. Its manifest
preserves the new source hash, protocol version and original unsigned binary
hash; direct raw binary equality with the producer is not expected. All owned
native receiver processes were reaped. This is a Debug checkpoint rather than
acceptance of a newly installed signed distribution.

Full source/dialog visual parity, physical/VoiceOver acceptance, signed installed
execution and current complete hosted CI remain separate requirements.
