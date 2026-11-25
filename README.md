# zonvie-thymer-effects

A custom GLSL post-process shader for [Zonvie](https://github.com/akiyosi/zonvie), the Neovim GUI, that recreates the editing feel of Thymer.

- Every typed or deleted glyph releases a soft smoke puff.
- The cursor shears and stretches as it moves, and leaves a brief streak when it jumps.
- On dark themes, the cursor casts a gentle glow that follows Neovim's cursor blink.
- Markdown task items (`- [ ]`, `- [x]`, `- [!]`) draw as rounded checkboxes, with a tick on done tasks and a red `!` on urgent ones.
- Markdown tables draw with ruled lines: a rounded frame, a rule under the header, and lines between the columns and rows.
- Markdown headings (`#`, `##`, `###`) draw larger, into the blank line beside them.

## Requirements

A Zonvie build with edit-effect shader support. The shader relies on Zonvie-specific inputs (`iCellAge`, `iCellText`, `@zonvie-owns-cursor`, `ZONVIE_SHADER_ALPHA`), so it does not run in other terminals or GUIs.

## Usage

Add the shader to `~/.config/zonvie/config.toml`:

```toml
[shaders]
enabled = true
paths = ["/path/to/thymer.glsl"]
preserve_alpha = true
```

`preserve_alpha` is optional. Turn it on to keep window transparency and blur showing through.

The glow follows `guicursor` blinking. To make it pulse, enable blinking, for example:

```vim
set guicursor+=a:blinkwait700-blinkoff400-blinkon250
```

## Task checkboxes

Markdown task lines are drawn as boxes with nothing installed on the Neovim side. Zonvie hands the shader the text of every cell (`iCellText`), so a `- [ ]`, `- [x]` or `- [!]` (also `*` and `+` bullets, and `X`) preceded by a blank is matched exactly, whatever the font: those five cells are repainted as a rounded box, and the text of a done task is faded and struck through. Floating windows are covered too. A task prefix inside a code block or mid-sentence is drawn as a box as well; `arr[x]` or `-[x]-` is not.

The boxes follow the text through a smooth scroll (Zonvie's `iRowOffset` input). The rows being pushed out at the edge of the window during the scroll animation carry no text information, so their boxes disappear for those few frames.

The boxes take their colours from the colorscheme. An open box is drawn in the colour its `[` has (`@markup.list.unchecked` where Tree-sitter highlights Markdown). A done box and the line through its text take the default text colour, not the colour of `[x]`, which many colorschemes paint green as a status. `- [!]` is not Markdown and has no colour of its own in a colorscheme, so its red is fixed (`BOX_COLOR_URGENT`).

`BOX_COLOR_URGENT`, `BOX_SIZE` and `BOX_STRIKE_*` in `thymer.glsl` tune the drawing.

## Tables

Markdown tables are drawn from the text of the cells too, with nothing installed on the Neovim side. A table is pipes standing in a column over two rows or more, whose second row is the delimiter row (`|---|:--:|`). Each `|` is repainted as a vertical rule and the delimiter row as the rule under the header; a rounded frame, a tinted header band and faint lines between the body rows are drawn round the cells.

The text of the cells is left where it is, so a table reads as drawn only when its source is aligned, with a pipe at both ends of each row. A row whose pipes have moved out of line drops back to plain text and the table closes above it, which is what you see while typing in a cell until the table is realigned. The delimiter row shows its own text while the cursor is on it. Column alignment (`:--:`) is not shown.

A table is recognised by its header, so once the header has scrolled out of the window the rest is plain text again, unless the pipes run up to the first row of the Neovim grid: then it is drawn without a header.

The rules and the header band take the colour the colorscheme gives the pipes they replace, thinned toward the background.

`TABLE_ALPHA`, `TABLE_ROW_ALPHA`, `TABLE_HEAD_FILL`, `TABLE_LINE_W` and `TABLE_RADIUS` in `thymer.glsl` tune the drawing.

## Headings

A heading line is drawn larger: `#` at 1.7 times, `##` at 1.4, `###` at 1.2. It grows into the blank line below it, or into the one above when only that one is blank, so the page is not rearranged: no other line moves or changes size. A heading with text directly above and below it has no room and stays as it is.

Everything on the line grows with it, the cursor and the smoke of what is typed there included. The line is scaled about the left edge of its own text, so the sign and number columns stay as they are. The `#` marks are kept and scaled with the rest.

Headings are found by Tree-sitter's captures (`@markup.heading.1` to `.3`), so the buffer needs Tree-sitter highlighting for Markdown; without it headings stay their own size. Only the first 16 cells of a row are looked at: a heading indented further, or one in a window that does not start at the left edge of the Neovim grid (the right half of a vertical split), is not enlarged. The enlarged letters are the ones Neovim drew, stretched, so they are a little softer than text set at that size.

`HEAD_SCALE_1`, `HEAD_SCALE_2` and `HEAD_SCALE_3` in `thymer.glsl` set the sizes. One blank line is all the room there is, so a scale above 2 is cut off.

## Turning effects on and off

Each effect has a switch at the top of `thymer.glsl`. Set one to `false` to turn that effect off:

```glsl
const bool ENABLE_SMOKE = true;  // smoke puffs on typed and deleted glyphs
const bool ENABLE_TRAIL = true;  // streak when the cursor jumps
const bool ENABLE_GLOW  = true;  // cursor glow on dark themes
const bool ENABLE_BOXES = true;  // task checkboxes
const bool ENABLE_TABLES = true; // Markdown tables drawn with ruled lines
const bool ENABLE_HEADINGS = true; // Markdown headings drawn larger
```

The cursor's shear and stretch are part of how the shader draws the cursor, so they always stay on.

The character under a block cursor stays readable: it is painted in the colour Neovim draws text on the cursor (the `Cursor` highlight's foreground, or the default background). Under the cursor a checkbox, a table rule or faded done text gives way to the character that is really there. Set `CURSOR_SHOW_GLYPH` to `false` for a solid cursor.

## Tuning

The constants at the top of `thymer.glsl` control each effect: `PUFF_*` for the smoke, `TRAIL_*` for the jump trail, `SHEAR_*` / `STRETCH_MAX` for the cursor motion, and `GLOW_*` for the glow.

## License

See [LICENSE](LICENSE).
