# Automatic overlay inspection

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/PicWindow.cpp`, `PicWindow.h` and `TortoiseIDiff.rc`.
This family completes the related overlay controls and temporal comparison flow;
it does not change image decoding, Git operations or conflict-side selection.

## Source controls and native behavior

`PicWindow.cpp:397–410` distinguishes an ordinary alpha-button click from
`BN_DOUBLECLICKED`. A normal click kills `ID_ALPHATOGGLETIMER` and calls
`ToggleAlpha`: every nonzero alpha becomes zero, then zero becomes one. The
double-click notification presses the button and starts a 1,000 ms timer. Its
callback (`459–462`) calls the same endpoint toggle. The first click of an actual
double-click sequence has already applied the ordinary toggle; starting the
clock does not invent another immediate change.

The native image viewer now uses an actual `NSButton` with the existing original
alpha-toggle artwork. Its native mouse-down distinguishes the second click;
ordinary target/action and accessibility activation stop the clock and toggle.
Automatic state has a pressed native appearance and an accessible On/Off value.
The model owns the one-second task and checks its generation, exact window,
current image command owner, overlay/Alpha mode and modal availability before
any tick or control response. Native text editing and other windows retain their
own input routing. No global event monitor is installed.

The image model owns a weak subscription to comparison-owner changes, delivered
on the main scheduler after the owner fields change. This refreshes native
button/slider enabled state when an operation ends without changing alpha or
restarting timers. Retirement cancels the subscription; dynamic action and timer
guards remain authoritative during the operation.

The shared comparison host disables automatic sizing and reapplies its explicit
800×440 content minimum on owned layout/appearance callbacks when needed.
Disabling automatic sizing alone was insufficient: hosting attachment could
still clear the minimum. Without lifecycle ownership, hosting layout overwrote
the minimum with 66×142, allowing a severely cropped image window. The native
fixture checks the actual minimum after loading and resizing, then captures it.

Source keyboard alpha commands and slider changes do not kill the source timer.
The native model retains that behavior: Space/arrow commands, the 17-position
slider and Control-Shift-wheel can change alpha while blinking remains armed.
A normal button click is the explicit stop-and-toggle action. Repeated start
replaces the previous generation, so an already scheduled callback cannot toggle
the replacement clock.

`PositionTrackBar` (`63–80`) sizes the vertical alpha channel to the image pane.
The native channel now grows and shrinks with its pane instead of keeping a
fixed 180-point height. Its top endpoint remains the first image, the bottom the
second, with the existing immediate click/drag behavior and 17 positions.
Live slider help follows the source `%i%% alpha`; button help uses the pinned
three-line percentage/click/double-click text (`TortoiseIDiff.rc:273` and
`PicWindow.cpp:475–489`). The native alpha row keeps its compact percentage label
and original image icon in light and dark appearance.

`HasMultipleImages` (`1501–1504`) returns false when a second picture is overlaid.
The source button layout (`1477–1493`) therefore hides frame/navigation/player
controls in overlay mode. Native controls now follow this rule, and the model
also refuses retained Previous/Next/Play actions while overlay is active.
Entering overlay stops both frame players as before. Returning to separate panes
restores frame controls at the retained frame; it does not restart playback.
Conflict panes remain independent and do not gain overlay controls.

## Timer and window ownership

Both frame and blink tasks stop when an input is replaced or dropped, when the
image view is removed, when an owned sheet starts, when the viewer closes or
when the application receives its termination notification. Close/termination
also detach the timer window. Old button/slider callbacks revalidate the exact
window; dismantled controls clear their targets and actions. The frame tick now
revalidates command availability too. Pending task cancellation drains without
holding the image model or source bytes indefinitely. Display-only timers do not
block ordinary application Quit or acquire repository/file mutation leases.

Stopping hidden alpha blinking on XOR/overlay exit and stopping display timers
for an owned modal sheet are explicit macOS ownership adaptations. The pinned
Windows handler can leave its alpha timer running while those controls are
hidden. This port stops that work and never silently resumes it when the mode or
sheet returns. The selected alpha and normal blend mode remain unchanged.
Underlying image bytes, animation formats, source frame delays, frame-index
policy, native background colors and existing zoom/pan behavior remain intact.

## Grouped verification and limits

The cached native receiver adds `scripts/test-image-command-family.py --only
overlay`. It creates private two-frame/three-frame GIF files, preferences and a
Git repository, and exercises the actual native button/slider targets and
second-click mouse-down. Assertions cover delayed real ticks, pressed state,
actual endpoint pixels, manual stop, live percentage help, resize geometry,
retained frame controls, XOR return, sheet ownership, busy owner fencing,
actual drop/reload, Quit notification, window retirement and task drain.
HEAD, raw index and both original GIF byte streams must remain unchanged.
Every owned window/sheet is offscreen or invisible, and failure cleanup closes
those owners. `--captures` deliberately permits brief owned light/dark visual
acceptance using the existing current-process capture path, then hides the window.

The final Debug application passed all eight affected native pairs: overlay,
frames, toolbar and pointer cases with both system and bundled Git. The overlay
case verifies the actual minimum after load and resize; its light/dark captures
were inspected at that minimum, with the full toolbar, slider and footer fitting.
Retained comparison/selection toolbar captures were also inspected in both
appearances. All eight owned receiver processes were reaped. Focused repair
attempts before these final passes exposed and corrected owner-enabled-state
publication and hosting minimum ownership; their failures remain in the QA logs.
The [batch evidence](qa/reference-ssh-overlay-family-2026-10-24.json) records
all attempts and focused repairs. No Core suite was rerun for this native-only
family. Physical double-click timing,
all trackpads, VoiceOver announcement, high-contrast appearance and signed
minimum-OS/App Store acceptance remain separate requirements. No whole-viewer
or whole-application completion claim follows from this family.
