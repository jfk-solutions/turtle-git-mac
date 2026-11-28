# Pending source-resource review — November 28, 2026

This bounded development review covers source `a4ff95ec32ad8e7d1c618c81db7daee89c754be6`
against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
It records source/platform distinctions without clearing pending control mappings
or certifying complete dialog, physical, accessibility or signed behavior.

## Pending resource inventory

The [bounded inventory review](qa/hosted-pending-resource-review-2026-11-28.json)
records every one of the 81 pending static control rows, with exact resource,
control occurrence, existing status and pinned/native evidence. The existing
[ledger](DIALOG-COVERAGE.md) remains authoritative and unchanged in classification:
no mapping was added or pending control cleared by this review.

Nine auxiliary resources account for 55 rows:

- `IDD_WAITDIALOG` is a Windows COM sample progress surface. The native issue
  adapter already has asynchronous loading/submission, progress, cancellation and
  retired-owner guards. Windows COM binary loading is not claimed.
- `IDD_URL` has no active caller established in the pinned source; ordinary Clone
  and remote URL workflows are separate implemented consumers.
- `IDD_SETTINGSWIN11CONTEXTMENU` configures Windows shell package registration.
  Native Finder menu policy and macOS extension management replace that platform
  integration; they do not emulate Windows registration.
- `IDD_CACHE_DIALOG` belongs to the upstream cache developer test executable,
  rather than a shipped user Git workflow. Native cache/watch tests exist.
- `IDD_SENDREPORTDLG`, `IDD_SENDFULLDUMPDLG`, `IDD_ASKSENDFULLDUMPDLG`,
  `IDD_SOLUTIONDLG` and `IDD_SENDASSERTREPORTDLG` belong to the Windows crash
  service family. The actual differences are retained below.

The other 26 pending rows occur in partially reviewed native families. Seventeen
are platform adaptations: Windows shell-library creation, Explorer/elevation/
floppy policy, Explorer overlay-slot/Registry notices, animation controls,
Cygwin/Msys2 compatibility choices and language-DLL downloading/rescanning.
Six are inactive source controls: four Statistics file-change summary placeholders
and two hidden English-file-list controls. The Statistics label is assigned in
the source, but its display/numeric updates are commented; this is not a claim
that the IDs have no references. Three are implemented but unmapped: dynamic
operation-specific progress follow-up, native authentication wording/layout and
the editable patch surface. A static **Show log** caption is not a universal
follow-up contract: pinned progress dispatch uses its supplied action list.

The native first-start language choice uses bundled localizations and requests a
manual app restart. The pinned Windows wizard restarts a separate process; the
Mac choice preserves shared repository/editor work. These counts describe review
categories, not feature completion or all-dialog acceptance.

## Crash reporting remains a deliberate boundary

The [native problem-report adaptation](CRASH-REPORTING-PARITY.md) discovers and
reviews Apple-generated reports, defaults report inclusion off, exposes the exact
local preview and Copy/Save payload, and opens a separate blank issue form.
It has cancellation, file-read/export ownership and late-callback guards.
It does not collect Windows memory minidumps/assertions, upload directly to
DrDump, query that service for a solution, or offer its returned solution URL or
executable. Those pinned workflows remain unported; local Apple report review
and export are not full equivalence. This review does not enable automatic upload.

