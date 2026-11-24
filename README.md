# zonvie-thymer-effects

A custom GLSL post-process shader for [Zonvie](https://github.com/akiyosi/zonvie), the Neovim GUI, that recreates the editing feel of Thymer.

- Every typed or deleted glyph releases a soft smoke puff.
- The cursor shears and stretches as it moves, and leaves a brief streak when it jumps.
- On dark themes, the cursor casts a gentle glow that follows Neovim's cursor blink.
- Markdown task items (`- [ ]`, `- [x]`, `- [!]`) draw as rounded checkboxes, with a tick on done tasks and a red `!` on urgent ones.

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

Markdown task lines are drawn as boxes with nothing installed on the Neovim side. Zonvie hands the shader the text of every cell (`iCellText`), so a `- [ ]`, `- [x]` or `- [!]` (also `*` and `+` bullets, and `X`) preceded by a blank is matched exactly, whatever the font: those five cells are repainted as a rounded box, and the text of a done task is greyed out and struck through. Floating windows are covered too. A task prefix inside a code block or mid-sentence is drawn as a box as well; `arr[x]` or `-[x]-` is not.

The boxes follow the text through a smooth scroll (Zonvie's `iRowOffset` input). The rows being pushed out at the edge of the window during the scroll animation carry no text information, so their boxes disappear for those few frames.

`BOX_COLOR_*`, `BOX_SIZE` and `BOX_STRIKE_*` in `thymer.glsl` tune the drawing.

## Turning effects on and off

Each effect has a switch at the top of `thymer.glsl`. Set one to `false` to turn that effect off:

```glsl
const bool ENABLE_SMOKE = true;  // smoke puffs on typed and deleted glyphs
const bool ENABLE_TRAIL = true;  // streak when the cursor jumps
const bool ENABLE_GLOW  = true;  // cursor glow on dark themes
const bool ENABLE_BOXES = true;  // task checkboxes
```

The cursor's shear and stretch are part of how the shader draws the cursor, so they always stay on.

The character under a block cursor stays readable: it is painted in the colour Neovim draws text on the cursor (the `Cursor` highlight's foreground, or the default background). Under the cursor a checkbox or faded done text gives way to the character that is really there. Set `CURSOR_SHOW_GLYPH` to `false` for a solid cursor.

## Tuning

The constants at the top of `thymer.glsl` control each effect: `PUFF_*` for the smoke, `TRAIL_*` for the jump trail, `SHEAR_*` / `STRETCH_MAX` for the cursor motion, and `GLOW_*` for the glow.

## License

See [LICENSE](LICENSE).
