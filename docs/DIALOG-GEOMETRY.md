# Dialog sizes and positions

Native dialogs remember their frame after moving, resizing or closing. Restoration
runs after the dialog sets its default layout, so default sizing and centering no
longer overwrite the saved frame. Fixed-size dialogs restore position while keeping
their current content dimensions. Resizable windows request their current minimums within the available screen space.
Frames are fitted into a current display's visible area when a monitor disappears
or the saved size no longer fits.

Settings → Saved Data → **Dialog sizes and positions → Clear** removes TurtleGit's
saved geometry. Its tooltip reports saved records; Clear disables when none exist.
New dialogs then use their normal default size and position. Already open windows
can save a new frame when moved, resized or closed, as with TortoiseGit. Histories,
repository bookmarks, ordinary settings, column layouts and splitter preferences
are preserved.

All 54 concrete native window-controller initializers attach after their default
layout. This includes Commit, Log, Clone, transport/replay/working-file dialogs,
comparison editors, browser, Blame/find, statistics and owned progress results.
CLI progress results share the source `ProgressDlg` frame identifier. Other native
kinds have stable individual identifiers, and quick Resolve has a separate one.
Commit and Merge recent-message sheets also share the source `HistoryDlg`
identifier after their initial size and minimums.
Older macOS frame-autosave names are read as fallback and included in Clear's
explicit legacy whitelist. New records use private app preferences under
`TurtleGit.DialogGeometry.`; sandboxed builds use their preferences container.

## Source and verification

The behavior follows TortoiseGit's `EnableSaveRestore` call sites in CommitDlg,
LogDlg, CloneDlg and ProgressDlg, and `SetSavedDataPage.cpp`'s ResizableState
clearing. The pinned source is `7338078f8ddd924b8cddee35f512f2286072136d`.
AppKit notifications and native frame preferences replace Windows registry/window
placement. This is a native implementation rather than copied ResizableLib code.

Core tests cover frame round trips, invalid/corrupt data, missing-monitor and
minimum-size fitting, legacy frame loading and reset scope. The native receiver
uses isolated preferences, actual hidden windows, close/reopen and a real Commit
controller to check that restoration follows defaults. It checks fixed-size
preservation, Saved Data reset and the hidden settings host. Run
`swift test --filter WindowGeometryTests` and, after a Debug build,
`python3 scripts/test-dialog-geometry.py`.

Physical multi-monitor/scaling, user drag/resize, zoom/full-screen state, sheet
placement and every mode-specific layout remain unverified. This controls window
frames only, not complete dialog or signed sandbox parity. The SwiftUI repository
window uses macOS scene behavior and is not included in this controller catalogue.
The full Saved Data page and complete application port remain in progress.
