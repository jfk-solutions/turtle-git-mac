# Clone completion, warnings and histories

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`CloneDlg::OnOK`, `CloneCommand` post-command callback and `StorePuttyKey`, plus
`HistoryCombo` saved entries/deletion.

A completed Git clone and its later SSH configuration now have separate outcomes.
The shared Core result retains raw command output and configuration warnings;
Git command failure still throws. The existing String-returning API includes the
warning in its summary. As upstream StorePuttyKey does, a key-setting failure no
longer turns an otherwise successful clone into a failed transport. Native agent
key storage remains separate from legacy core.sshCommand configuration.

The result retains Show Log and Show in Finder after successful opening, even
when SSH configuration warned. A visible orange warning keeps that result open
for review instead of auto-closing under No Errors. This adapts the source's
synchronous error acknowledgment to the retained native result. Warnings remain
part of the captured adoption output.

Native discovery/opening can fail after transport succeeded. That result says
Clone completed and offers Retry opening repository and Show in Finder. Retry
performs only discovery; it never clones again into the populated folder. Opening
captures the original destination, executable and grants, publishes adoption once,
and retains independent cancellation/Quit lifetime. Closing after completed Git
work cannot expose the original Clone submission again. Forced retirement rejects
late opening results. Legacy direct model callers retain the same completed-command
boundary and can retry opening independently.

URL/key histories now use the shared bounded HistoryCombo rules and native
Shift-Delete while the enabled dropdown is open. Deletion persists immediately,
selects the nearest remaining item, preserves exact macOS path/URL spelling and
rejects retired/busy callbacks. Other users of the shared Clone combo keep their
existing behavior unless they supply deletion. Source entries load at most 25;
saves retain the source 26-item boundary and fold CR/LF in saved text.

Accepted submissions validate branch/origin names and granted inputs before
saving the captured source/key/recursive/SSH choices, then begin transport.
Failures retain those histories, matching source OnOK timing. Invalid parameters,
permission cancellation and ordinary dismissal do not add history. Typed key text
is remembered even when auto-load is off; remembering a path never grants access.
The native remembered directory remains the parent folder for the next auto-name,
rather than reusing Windows path concatenation.

[Grouped evidence](qa/clone-completion-2026-10-17.json) records twenty distinct
passing focused Core checks: seven Clone cases and thirteen SSH transport cases.
The new warning fixture initially missed the injected error and then indexed an
absent warning; its repair and private-agent cleanup are recorded. Only that SSH
group repeated, with no application change. One Debug build passed with 12
exit-zero/no-output compiler diagnostics. All eight native case/engine runs
passed on the first grouped attempt. They cover completion/history, retained
progress, streaming and creation ownership on system and packaged Git. All eight
owned receivers were reaped and independently absent. Help remains byte-identical
to the built bundle; the website renders 263 documents without unresolved fragments.

The explicit retry/adoption assertion exercises the production progress path;
legacy direct callers retain the creation receiver's forced-close metadata checks,
without a separate direct opening-retry acceptance claim. The native warning
fixture maps SVN entry to a real local Git clone and rejects its legacy key config;
the Core fixture verifies an actual private agent/native remote key failure.
Neither establishes live git-svn or server authentication.

Complete physical layout/keyboard/VoiceOver,
real network/git-svn/authentication, signed grants/Finder and App Store acceptance
remain open. This does not certify the whole Clone dialog or application.


### Clone checkout-filter continuation — October 19, 2026

The [Clone checkout family](CLONE-CHECKOUT-FILTERS-PARITY.md) connects configured
custom smudge filters to selected libgit2 Clone and its recursive checkout option.
It distinguishes initial destination cleanup from later recursive partial work,
retains bare/no-checkout suppression and owns actual filter cancellation/progress.
Configured LFS one-shot smudge, source boundaries and grouped evidence are tracked
in that family; it does not claim persistent filter-process or complete providers.

## Native bare result setup — October 21, 2026

[Creation setup](REPOSITORY-CREATION-SETUP-PARITY.md) adds an owned, optional
TurtleGit folder icon after actual bare discovery. Metadata failure is retained as
a completed-result warning without repeating Git. Direct and progress routes share
the helper; inspection retries reuse the destination receipt. Ownership and access
remain held through actual optional work even when the window is retired.
