# zonvie-thymer-effects

A custom GLSL post-process shader for [Zonvie](https://github.com/akiyosi/zonvie), the Neovim GUI, that recreates the editing feel of Thymer.

- Every typed or deleted glyph releases a soft smoke puff.
- The cursor shears and stretches as it moves, and leaves a brief streak when it jumps.
- On dark themes, the cursor casts a gentle glow that follows Neovim's cursor blink.

## Requirements

A Zonvie build with edit-effect shader support. The shader relies on Zonvie-specific inputs (`iCellAge`, `@zonvie-owns-cursor`, `ZONVIE_SHADER_ALPHA`), so it does not run in other terminals or GUIs.

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

## Turning effects on and off

Each effect has a switch at the top of `thymer.glsl`. Set one to `false` to turn that effect off:

```glsl
const bool ENABLE_SMOKE = true;  // smoke puffs on typed and deleted glyphs
const bool ENABLE_TRAIL = true;  // streak when the cursor jumps
const bool ENABLE_GLOW  = true;  // cursor glow on dark themes
```

The cursor's shear and stretch are part of how the shader draws the cursor, so they always stay on.

## Tuning

The constants at the top of `thymer.glsl` control each effect: `PUFF_*` for the smoke, `TRAIL_*` for the jump trail, `SHEAR_*` / `STRETCH_MAX` for the cursor motion, and `GLOW_*` for the glow.

## License

See [LICENSE](LICENSE).
