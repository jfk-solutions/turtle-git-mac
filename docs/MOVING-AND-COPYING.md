# Moving and copying files

TurtleGit uses Git-aware Move so a renamed or relocated versioned file keeps its
index contents separately from any further working-file edits. These operations
change files and the index; they do not create a commit.

## Drop files into TurtleGit

Drop local files or folders onto the main workspace file list or a Working Tree
window's file list. The receiving sheet shows the captured paths and destination.
Use the destination button to choose another folder in the same working tree.

For versioned sources in that working tree, choose **Move here**. A single source
also offers **Move and rename here**. External or unversioned sources offer
**Copy and add here**. Cancel the receiving sheet to leave everything untouched.

The selected action opens its operation window. Review the destination and start
Move or Copy and Add. Move/Rename asks for the new name when execution begins.
An occupied name keeps the name sheet open until a valid destination is entered.

A failed item in a dropped Move offers Ignore or Abort. Earlier successful moves
remain applied. Clipboard Paste Move stops at its first failure. Review the
operation output and current status before retrying either workflow.

## Copy and Add

Copy and Add accepts external source files and folders. Overwrite replaces an
existing file; Keep retains and stages the destination's existing contents;
Cancel stops the sequence. Existing directory-to-directory targets are kept.
A copied repository prompts for Delete, Ignore or Abort: Delete removes only its
copied Git metadata, Ignore excludes that copied repository from staging, and
Abort retains copied files for recovery. The original source remains untouched.

External source permissions are requested by the Copy/Add window when needed.
Cancellation may leave already copied or staged items. The output and refreshed
file list show the result; review those items before running the operation again.

## Clipboard and menus

Versioned-file menus offer Move, Copy files and Copy and Add. Copy files puts local
file URLs on the clipboard. Paste Move accepts versioned paths from the same
working tree; Paste Copy and Add copies the captured URLs into the destination.
Finder's destination-folder clipboard entries require an enabled Finder extension.

The receiving sheet is the current macOS application adaptation of TortoiseGit's
Windows drag context menu. Finder right-drag menus remain an open integration
feature. Signed permission delivery and physical drag acceptance are still pending.
