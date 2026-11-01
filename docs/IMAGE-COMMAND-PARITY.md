# Native image commands and toolbars

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/MainWindow.cpp::CreateToolbar/DoCommand`, `WM_NOTIFY`
tooltips, and `TortoiseIDiff.rc` View commands/accelerators.

Comparison and conflict-selection windows now use actual AppKit `NSToolbar`
instances. The comparison default follows the source order: Overlay, Blend,
separator, Link, Fit widths, Fit heights, separator, Fit in window, Original size,
Zoom in/out, separator, Info and Vertical. Selection mode omits overlay/blend/
link/dimension matching, as in `CreateToolbar` with `selectionPaths`. Existing
original artwork is reused at 24 points. Source button groups remain fixed;
native overflow and accessible toggle buttons provide macOS behavior. Native
File/View menu buttons at the end retain the commands formerly in the content
header. Lightweight panes hosted without a controller retain their existing
content controls.

Each menu leaf, overflow item and button validates its owning window and current
mode again when invoked. Check states update from the observed model. Overlay
retains its source alpha reset/forced linking and disables Blend outside overlay,
Link inside overlay and Vertical inside overlay; the latter is now also enforced
by the Command-V accelerator. Comparison and selection keyboard dispatch share
the same commands and guards as their toolbar. Busy, active Load Images,
attached-sheet, replacement and closed/retired contexts refuse applicable actions.
Sheet notifications refresh the native toolbar. Retained overflow/menu items
cannot revive a closed viewer. Playback retains its existing stop/retirement
lifetime.

Comparison uses a stable window-owned image model across Load Images rather than
recovering that model from a disappearing native key bridge. This keeps toolbar,
keyboard and pane state on the same model while images change. Accepted image inputs and their file grants are captured before chooser closure;
replacement reload starts after the chooser sheet ends, so ordinary sheet guards
do not discard it. Cancel and retired/replaced chooser callbacks cannot submit
new inputs. Image/text
routing transfers the window toolbar between the two existing command surfaces;
it does not show both toolbars. Image Open sends its request to the image chooser,
keeping text Open separate. The October 31 main-menu continuation below replaces
the earlier File-only Load Images contribution.
Image header tooltips retain the complete path/revision or conflict identity
when the visible caption is truncated.

No image decoding, pixel blend, Git operation, conflict resolution or repository
write semantics changed. Existing geometry restoration remains in use. No new
persistent image-mode preference or Windows toolbar customization is invented.

## Verification and limits

After a current Debug build, `scripts/test-image-command-family.py` links app
objects once and runs the connected native toolbar, existing Load Images,
conflict-selection and frame/playback cases. `--only` limits a repair recheck to
its affected case. Both command-line Git engines can be supplied; each case owns
its repository/preferences/windows and requires a final completion marker.
Optional `--captures` uses current-process macOS compositor images, including
native window chrome; review those originals before publishing.

See [the dated record](qa/image-command-2026-10-15.json) for actual results and
repairs. Physical toolbar tracking/overflow, keyboard/VoiceOver, multi-display
resizing, historical-blob Open path prefill, all formats, signed minimum-OS/Intel
and sandbox/App Store acceptance remain open. This does not certify the whole
image viewer or application port.

The final Debug build and affected system-Git cases passed; the prior unchanged
selection case and all four bundled-Git cases passed. Four unaltered current
light/dark window captures were reviewed and published. The dated record retains
every failed attempt, repair, exact case scope and owned process identifier.

## Native main-menu continuation — October 31, 2026

The pinned comparison menu (`IDC_TORTOISEIDIFF`, `TortoiseIDiff.rc:104–132`)
contains File/Open and the complete View recipe. Its selection menu
(`IDC_TORTOISEIDIFF2`, lines 134–155) omits Open, Overlay, Blend, Link and dimension
matching. Both retain fit/original size, transparent background, zoom,
information, arrangement and appearance commands. Windows Exit is adapted to
the existing macOS Close and app Quit commands.

The continuation connects those recipes to the native application menu bar for
comparison, standalone selection and repository conflict windows. Toolbar menus
and the main menu share command order, state, icons and dispatch rather than
maintaining separate action lists. Native File/View roots are identified by
their roles rather than the English words in their captions. Contributions
belong only to the current image window; switching windows removes them without
removing existing application commands. Old menu items must refuse dispatch
after an owner switch or retirement, even if a caller retained them.
Loading and owned sheets disable actions while retaining the same menu layout.
Image keyboard dispatch retains the source modifier choices and refuses a
different window or an active text-field editor. The source's displayed `V`
label is backed by Ctrl-V in its accelerator table; the Mac binding remains
Command-V rather than adding a new plain-V action.

The active image menu temporarily owns conflicting native shortcuts. Existing
host items retain their actions and positions; their shortcut bindings return
when the image contributions leave. Owned entries are removed before restoration
so AppKit cannot keep their shortcut registration ahead of the restored host.
Busy image commands remain disabled without handing Open to a workspace action.
Text-field editing retains the native Paste binding instead of image arrangement.

The [grouped checkpoint](qa/image-main-menu-2026-10-31.json) records the Debug
build and complete existing toolbar case passing with system and bundled Git.
Each covers all three owner modes, localized semantic roots, literal source
recipes/icons/keys, real menu and window-event actions, busy/sheet refusal, native
field-editor Paste, foreign/stale owner fences and exact host restoration.
Native shortcut priority required the scoped ownership continuation above;
fixture repairs retain disabled-key consumption, asynchronous owner-gate drainage
and explicit private menu/target lifetime. The system pass was retained after
that last fixture-only repair. All owned receiver PIDs were reaped and
independently absent. No Core code changed or unrelated image suites repeated.
Installed build47 predates this family. The record retains every failed attempt
and distinguishes injected key-owner/native-menu proof from OS event ordering. Physical menu tracking, keyboard/VoiceOver,
signed grants and complete image-viewer/source acceptance remain separate.


## Held sheet and keyboard receiver boundaries — November 1, 2026

The existing conflict-owned receiver now waits for exact sheet detachment, worker
accounting and native Select/pane admission after No. The metafile held-reload
receiver supplies its captured invisible key window through the existing seam
before actual Escape dispatch. These correct fixture assumptions, not production
guards; all original Yes/No, cancellation, retirement and byte/index assertions
remain. See [the grouped checkpoint](qa/hosted-native-recovery-2026-11-01.json).


## Toolbar receiver sheet lifetime — November 1, 2026

A later hosted toolbar receiver crashed with SIGSEGV after other image cases
passed. The retained auxiliary sheet now disables release-on-close, matching the
fixture's other directly constructed modal and the application controllers. All
assertions and actual sheet-detachment/close paths remain. The captured log has no
crash backtrace: this source correction does not establish the crash's cause or a
runtime pass. The [queue/toolbar record](qa/hosted-queue-toolbar-2026-11-01.json)
keeps that pending scope separate from the earlier image question checks.
