# Image conflict selection

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseIDiff/MainWindow.cpp` selection mode and `SELECTBUTTON_ID`,
`PicWindow.cpp` Select button, and `TortoiseIDiff.rc`.

The source opens Mine, Base and Theirs in that order, each with its own image
and a Select button at the bottom right. Its selection-mode toolbar omits
Overlay, Blend, Link positions and linked width/height controls. It retains
Fit, Original size, Zoom, Image info and vertical arrangement. The native
replacement follows that layout with three independently fitted image panes,
two draggable splitters and original icon resources. It can arrange panes
side by side or top to bottom. Source image bytes determine routing, rather
than file extensions. Rebase Mine/Theirs use the same stage inversion as the
existing text conflict editor; their titles identify the rebase meaning.

Select copies the chosen stage's exact bytes into the working file. The index
stays unmerged until the user answers Yes to “Mark as resolved?”. Answering No
keeps the selected working image and the window open, allowing another choice.
Answering Yes stages that working file and closes after success. Selection does
not commit or continue merge/rebase. Missing Base in add/add conflicts has an
empty pane and disabled Select. Mixed image/non-image and nonregular conflicts
continue through the existing conflict workflows.

The source copies before asking. The native port additionally captures working
bytes/permissions and index stages; it revalidates them before copying and again
before staging after the confirmation. External edits, changed stages and
symlink destinations require reloading. Atomic writes preserve existing file
permissions. Errors after saving leave the window open. Owned operation tokens
prevent queued selection after retirement. Close/Quit is fenced during selection
and while a confirmation is pending; application-wide event monitors are not used.

## Verification and remaining work

The focused Core/text/image/icon/file-comparison suite passed 39 tests,
including all three byte selections, explicit resolution, unchanged unrelated
index/working files, rebase stage inversion, changed bytes/permissions, stale
stages, symlink refusal, missing Base, cancelled writes and mixed-format routing.
The final native receiver passed with system and bundled Git: actual
Mine/Base/Theirs pixels/order, independent fit/zoom, vertical layout, AppKit
Select buttons and production Yes/No sheets; No preserves unmerged index bytes,
Yes rejects an edit during confirmation, Reload recovers and a fresh Yes stages
the selected bytes and closes. HEAD remains unchanged. Close/Quit fencing passed.
Light/dark offscreen captures were visually inspected with readable toolbar,
metadata and Select controls. The receiver keeps sheet parents transparent and
offscreen and then orders them out; all owned windows and fixtures are removed.
Unsigned Debug and App Store builds and bundle audits passed, including
the Finder extension and all 112 original icon resources. See the [QA record](qa/image-conflict-2026-10-10.json). This is a partial native replacement. Broader multiframe/provider
behavior, full format/DPI/border behavior, retained
splitter preferences, physical keyboard/mouse/VoiceOver acceptance and signed
sandbox/Finder/App Store acceptance remain open. The complete TortoiseGit port
is not finished.


Multi-image conflict panes now share native frame/page controls and independent
playback with the comparison viewer. Select still copies the complete original
stage bytes, regardless of the currently previewed frame. See
[frame/page parity](IMAGE-FRAMES-PARITY.md).

All three conflict panes share a transparency color chooser and local Dark Mode,
including the D key. Their navigation/zoom models remain independent. See
[color parity](IMAGE-COLORS-PARITY.md).
