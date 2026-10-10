# Comparing images

Open an image’s **Diff** command from Working Tree, Commit or the changed-file
list in Log. The built-in comparer displays the two versions in image panes.
The headers identify each file and revision; a newly added or deleted image has
an empty pane on the missing side. External comparison-tool settings can change
which viewer opens.

Hover over a toolbar button to read its command name. The **View** menu offers
these same controls:

- **Arrange vertical** changes the two panes from side-by-side to top/bottom.
- **Fit images in window** scales each pane to its available space.
- **Original size**, **Zoom in** and **Zoom out** control magnification.
- **Link image positions** makes scrolling one pane move the other. Drag an
  image to pan, or use the scrollbars or trackpad.
- **Image info** shows byte size, pixel dimensions, available resolution and
  decoded color depth.
- **Overlay images** puts both versions in one pane. Move the vertical slider
  on the left to blend between them; the button above it switches endpoints.
  Overlay keeps image positions linked. Turn it off to return to two panes.
- With overlay enabled, turn **Blend alpha** off for XOR comparison. Identical
  areas appear white and changed pixels appear in color. Turn it back on to
  restore the alpha slider.

The image comparison is read-only. It does not stage, save or resolve files.
The viewer follows the app’s light/dark appearance.

This portion of the port is still being completed. Animation currently displays
its first frame, and three-way image-conflict selection is not yet available. See [image comparison parity](IMAGE-COMPARISON-PARITY.md) for
the source comparison and verification scope.
