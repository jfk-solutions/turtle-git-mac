# Blame embedded-language presentation

The pinned `TortoiseGitBlameView.cpp` HTML setup applies Lucida Console to 34
embedded VBScript/JavaScript styles and extends 36 style backgrounds to line end.
The style extractor now retains these exact font names and EOL flags alongside
original colors and bold settings, including exceptional string-at-EOL colors.

The native renderer uses the source font when installed, otherwise Menlo at the
configured point size. Styles without a source font continue using the user's
Blame font. Bold traits apply to the resolved font. Disabling syntax restores the
user font and removes all lexer foreground/background/EOL attributes.

Line-tail backgrounds use the layout manager's actual visible fragments, extending
from their used glyph rectangle to the editor edge. This adapts line fills to
wrapping, horizontal scrolling and native font metrics. Selected revision rows
retain their revision highlighting rather than a lexer tail fill. Dark fills use
the existing source HSL transform. Styled source width is remeasured after font
changes; annotation/source row geometry still comes from native layout.

Core coverage checks all 34 font and 36 EOL flags through the real pinned helper.
Native coverage uses an actual committed HTML/VBScript file and checks attributed
fonts, sampled tail pixels in both themes, selection retention, wrapping, disable/
restore and exact HEAD/index/file preservation. Existing C++/wrap/lifetime cases
remain in the grouped batch. These are private fixtures; no signed acceptance or
full Blame certification is implied.

Remaining Blame work includes full menus/accelerators, displayed Find feedback,
export/encoding/accessibility and complete native/source visual comparison.

The Debug and AppStore builds, regenerated universal helper and distribution
audits passed. Seven focused Core tests passed once. Six native source/lexer/wrap
cases passed across both Git engines; failed pixel/disable fixtures were repaired
and only affected or not-yet-run cases repeated. All owned receivers were reaped.
Calibrated pixels compare the actual tail to an independently drawn reference in
the same display context. Disable/restore waits for the rendered attributes rather
than only the model's idle flag.

Actual [light](site/assets/blame-embedded-light.png) /
[dark](site/assets/blame-embedded-dark.png) captures were individually inspected.
[Batch evidence](qa/blame-embedded-2026-10-13.json) records initial failures,
repairs, source hashes and remaining scope. The captures cover embedded styles,
not the complete Blame Properties/menu or every wrapping/highlight interaction.
