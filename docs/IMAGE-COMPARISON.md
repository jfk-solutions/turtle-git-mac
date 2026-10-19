# Comparing images

Open an image’s **Diff** command from Working Tree, Commit or the changed-file
list in Log. The built-in comparer displays the two versions in image panes.
The headers identify each file and revision; a newly added or deleted image has
an empty pane on the missing side. External comparison-tool settings can change
which viewer opens.

Hover over a toolbar button to read its command name. The **View** menu offers
these same controls:

- **Arrange vertical** changes the two panes from side-by-side to top/bottom.
- **Fit image widths** or **Fit image heights** matches that dimension between
  the images. A single option preserves proportions; enabling both matches
  both dimensions.
- **Fit images in window** shrinks images to the available space while keeping
  small images at their original size.
- **Original size**, **Zoom in** and **Zoom out** control magnification. Linked
  dimension controls remain active during these commands.
- **Link image positions** makes scrolling one pane move the other. Drag an
  image to pan, or use the scrollbars or trackpad.
- **Image info** shows byte size, pixel dimensions, available resolution and
  decoded color depth.
- **Overlay images** puts both versions in one pane. Move the vertical slider
  on the left to blend between them in 17 positions: top shows the first
  image, bottom the second. The button above it changes a nonzero blend to
  zero, then switches back to one. Control-Shift-wheel adjusts the blend.
  Overlay keeps image positions linked. Turn it off to return to two panes.
- With overlay enabled, turn **Blend alpha** off for XOR comparison. Identical
  areas appear white and changed pixels appear in color. Turn it back on to
  restore the alpha slider.

Keyboard commands follow the source image viewer: **O** toggles overlay,
**F** fits, **S** restores original size, **W/H** match widths/heights,
**I** toggles information, **+/−** zoom, and **Command-V** switches arrangement.
The arrow keys set alpha to zero (Up), one (Down), or half (Left/Right).
**Space** toggles alpha endpoints and **Escape** closes the comparison.

The image comparison is read-only. It does not stage, save or resolve files.
The viewer follows the app’s light/dark appearance.

Multi-image files have Previous/Next buttons and an image counter beneath the
pane header. Navigation stops at the first or last image. GIF frames and TIFF
pages offer Play/Stop; ICO variants offer navigation only. Linked panes receive
the same player commands, while each file uses its own playback timing. Turn
linking off to operate panes independently. Turning overlay on stops playback.
Conflict panes have independent player controls; Select copies the complete
original file, including all frames. See [frame/page parity](IMAGE-FRAMES-PARITY.md).

This portion of the port is still being completed. Broader image controls and
format-specific behavior still need porting. See [image comparison parity](IMAGE-COMPARISON-PARITY.md) for
the source comparison and verification scope.

For an image conflict, **Edit conflicts** opens Mine, Base and Theirs. Each pane
has **Select** at the bottom right. Select copies that image to the working file,
then asks whether to mark it resolved. **No** keeps the chosen image and the
unmerged stages, so you can inspect or select another side. **Yes** stages the
chosen image and closes the viewer. It does not commit or continue a rebase.
For add/add conflicts, Base is empty and cannot be selected. Rebase pane titles
identify which branch each side represents. See [image conflict parity](IMAGE-CONFLICT-PARITY.md).

Use **View → Transparent color…** to choose a background behind transparent
pixels. OK applies the chosen color to every pane in that window; Cancel keeps
the current choice. **View → Dark Mode** (D) switches that image window's
appearance and resets the transparency background to the theme default.

Use the app's **File → Load Images…** to compare image files without opening a
repository. In an image viewer, **File → Open…** or **Cmd+O** opens the same
native two-path chooser. Use Browse for either side, leave a side blank for a
single image, or choose the same image twice. Cancel keeps the existing view.


## Windows metafiles

WMF, EMF and EMF+ inputs use the bundled metafile renderer in the existing image
panes. No separately installed converter is needed. Load Images and image-pane
drops accept these formats too. Rendering supports captured vector paths, text,
transforms, clipping and embedded bitmaps; recorded dimensions and available
resolution feed the normal zoom and Image Info controls. EMF+ embedded images
and texture brushes include indexed 1/4/8-bit palettes and 16-bit RGB555, RGB565
and ARGB1555, alongside 24/32-bit bitmap formats. Formatted EMF+ text supports
wrapping, tabs, right-to-left and vertical layout, spacing, alignment, trimming
and font decorations through native glyph outlines. See the
[text format scope](METAFILE-TEXT-PARITY.md) for exact limits. Classic EMF
clipping includes union, intersection, XOR and subtraction, path/rectangle clips,
clip offsets and metaregions; see the [classic clipping scope](METAFILE-CLASSIC-CLIP-PARITY.md).
EMF+ pen strokes include transformed nibs, compound bands, separate end caps,
joins, dashes and Center/Inset positioning; see the [pen scope](METAFILE-PEN-PARITY.md).

Decoding runs in the background. Closing or replacing an input cancels the owned
decoder and prevents a delayed preview from replacing a newer view. Rendering
never rewrites the original file or conflict stage. Selecting a conflict side
copies its original bytes, including when that side cannot be rendered.

Some Windows drawing records and font behavior still need compatibility work.
Unsupported records and malformed files retain an undecodable image side rather
than showing an incomplete successful drawing. See the
[metafile renderer comparison](IMAGE-METAFILE-PARITY.md) and
[native consumer comparison](METAFILE-CONSUMER-PARITY.md) for the supported record
families, actual checks and remaining limits.
