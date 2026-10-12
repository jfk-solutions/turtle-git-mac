# Autotext Tester

Adapted from `AutoTextTestDlg.cpp/.h` and `IDD_AUTOTEXTTESTDLG` at the
pinned TortoiseGit source revision recorded in PORTING.md. GPL-2.0-or-later.

The native fixed-size window retains the source order: editable file content,
regex, explicit default Scan button, read-only auto words, parse timing and Exit.
It supports light/dark system appearance and plain-text private clipboard menus
with the application's icon preference. Content is limited to 200 × 1024 UTF-16
units. Source CString conversion stops content at its first NUL for scanning.

The packaged C++ helper compiles case-insensitive ECMAScript expressions. Every
nonempty capture group is collected, deduplicated and sorted by UTF-16 order;
whole matches are not implicitly words. Empty input clears result/timing without
launching the helper. Invalid expressions replace results with the source error
prefix. The helper contains pathological expressions with bounded execution.
Elapsed timing includes helper startup/IPC, unlike the source in-process clock.

Scan runs off the main actor. Inputs are disabled during scanning. Exit cancels
owned helper work and fences late results; Quit waits for active matching to
settle. The utility never writes completion definitions or repository settings.
The standalone File-menu entry adapts `AutoTextTestCommand.h` (`autotexttest`),
which requires neither a repository nor Git. An additional button in Settings →
Dialogs 2 → Commit opens one page-owned tester. Leaving that page closes it.
The settings shortcut is a macOS addition. Legacy Windows command-line spelling
remains pending.

Remaining acceptance: physical keyboard/VoiceOver review, exact font/spacing
comparison against a running Windows dialog, signed sandbox execution and the
complete upstream autocompletion configuration/editing workflow. This dialog is
partial, not certified complete.


Actual Aqua/Dark Aqua compositor captures were compared with the pinned resource
control order. They exposed an NSHostingController fitting-width collapse, missed
by data/control tests. Window minimum/maximum constraints alone did not prevent
that programmatic resize. The fixed SwiftUI host frame and explicit content size
now retain the intended 660 × 640 point dialog. The focused receiver checks actual
content bounds, and the capture case rejects collapsed PNG dimensions. Reviewed
images show both editors, full labels, Scan, results, timing and Exit. See the
utility capture record; physical/signed and full visual certification remain open.
