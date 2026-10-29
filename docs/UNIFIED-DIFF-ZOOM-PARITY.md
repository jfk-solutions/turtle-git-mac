# Unified Diff temporary zoom and printer magnification

Pinned baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
Source anchors: Scintilla `KeyMap.cxx:163–165`, `Editor.cxx:251–262,4116–4129,8431`,
`ViewStyle.cxx:65–68,234`, `ScintillaWin.cxx:1885–1944` and
`EditView.cxx:2701`; UDiff `MainWindow.cpp:913–936`.

## Connected native workflow

Edit → Zoom and the text context menu provide Zoom In, Zoom Out and Actual Size,
with existing source artwork. Command-Plus (also Command-Equals), Command-Minus
and Command-0 use the focused patch editor. Control with keypad Add, Subtract and
Divide retains the source aliases. Read-only patch previews use the same commands.
Find fields and unrelated windows retain their keyboard input.

Zoom changes the current editor's level by one, within the source interactive
range −10…60. Effective font size is max(configured size + level, 1 point).
Font, line-number gutter, tab stops, document extent and rectangular selection
geometry reflow together. The top displayed fragment and its fractional offset
are retained where bounds allow; this is not pointer-anchored image zoom.
Font reflow rebuilds even explicit rectangle rows using their retained endpoints,
as the source RefreshStyleData/SetRectangularRange does.

Reloading or opening another document in the same editor retains the temporary
level. A new editor starts at zero. Zoom neither edits document bytes nor writes
the saved base font preference, and creates no Undo transaction. The immutable
print snapshot uses the configured base size and tab spacing, matching the
source's default zero print magnification regardless of screen zoom.

## Wheel adaptation and ownership

Control or Command with vertical wheel input zooms while the pointer is over an
attached patch viewport, without moving keyboard focus from Find. A discrete
wheel event contributes one source tick by direction; precise Cocoa deltas use
10 logical points per 120-unit tick. Signed partial ticks accumulate, reverse
naturally and produce at most one zoom command per delivered complete event.
Shift, horizontal-dominant input and input outside the viewport pass through.
Cocoa momentum does not create zoom commands. Gesture and interruption fences
prevent stale input from zooming a replacement document or resuming a partial
tick after a modal, busy, error or Quit interruption.

Keyboard and retained menu actions require the current focused owner. Wheel
input additionally checks the receiving window, pointer location and visibility.
Marked text, sheets, modal windows, busy/error states, Quit, detached or retired
owners refuse zoom. No repository authority is acquired for these view commands.

## Validation and remaining work

The [grouped checkpoint](qa/unified-zoom-2026-10-29.json) records six focused
Core methods with no failures, one successful Debug build, final zoom and
affected navigation passes with both system and bundled Git, and PDF printing.
Actual key/wheel events, owner menus, explicit rectangle reflow, retained/new
editor lifetime, Find responder preservation and byte/Undo/repository invariants
passed. Selection/whole/margin PDFs contained one/six/eleven pages with exact
immutable source text. All seven receivers from successful and failed attempts
were reaped and independently confirmed absent; private windows closed.

The record retains three fixture-only failures: CoreGraphics phase/momentum
fields need explicit conversion from AppKit phase values, and SwiftUI accessibility
identifiers are not copied to the underlying NSTextField. A bounded diagnostic
confirmed the actual Find field editor was already focused. The corrected fixture
uses that unique owning Find field and checks its exact responder before and
after hover. No product source, behavioral assertion, Core run, Debug build or
passed navigation/printing check was changed or repeated for these repairs.
Physical trackpad/device sensitivity, keyboard layouts, VoiceOver/IME, printer
hardware, signed installed execution and complete UDiff parity remain separate.
Installed build33 predates this continuation.
