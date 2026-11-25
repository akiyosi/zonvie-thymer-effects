// Thymer-style edit effects for Zonvie.
//
// Measured frame by frame off Thymer's demo video of typing and deleting
// (60 fps, 74 px cells); "the demo" below always means that video:
//
//   1. Every glyph that was just typed or just deleted gets ONE soft "smoke
//      puff": a round, blurred blob in the ink colour, about half a cell
//      across, with a random offset and size per glyph, that fades over
//      roughly 0.3 s. A typed glyph's puff sits ABOVE the glyph and drifts
//      up; a deleted glyph's puff stays where the glyph was. Fast typing or
//      a held Backspace leaves a train of 4-6 puffs visible at once
//      ("release ye▮ ●●●●●"). The blobs are ink-coloured (G-R = -2 on the
//      demo, i.e. blurred ink, not the teal cursor) and darken the paper by
//      25-35/255 at their core.
//   2. The cursor shears and stretches along its direction of travel and
//      relaxes back.
//   3. A cursor JUMP hides the cursor and replaces it, for ~0.13 s, with a
//      straight streak in the cursor's colour joining the old and new
//      positions; the cursor then pops back at the destination (TRAIL_*).
//
// Effect 1 is driven purely by the per-cell edit age Zonvie exposes
// (iCellAge / zonvieCellAge): no feedback, no dependence on the previous
// frame, so nothing can run away or smear. Each edited cell owns one puff
// whose position, size and strength come from a hash of the cell
// coordinates, which is what gives the demo's random look.
//
// The smoke is painted opaque: under `[shaders] preserve_alpha` the bridge
// would otherwise pin every pixel to the terminal's alpha, so a translucent
// window lets the blurred backdrop through the puff and it washes out over
// a bright window behind (an external window over the main one).
#define ZONVIE_SHADER_ALPHA 1

// @zonvie-owns-cursor
// The marker above tells Zonvie to skip its native cursor pass for EVERY
// cursor shape, so this shader draws the cursor. `guicursor` still decides
// the shape: it arrives as iCurrentCursorStyle and is honoured below. The
// glyph under a block cursor is painted in iCursorText, as the native pass
// paints it (CURSOR_SHOW_GLYPH).

// Headings are found by Tree-sitter's captures, read as bits 0..2 of a
// cell's group mask in the order declared here.
// @zonvie-hl-groups: @markup.heading.1 @markup.heading.2 @markup.heading.3

// ---- switches ------------------------------------------------------------
// Turn each effect on or off. The cursor's shear and stretch are part of
// drawing the cursor and always stay on.
const bool ENABLE_SMOKE = true;  // smoke puffs on typed and deleted glyphs
const bool ENABLE_TRAIL = true;  // streak when the cursor jumps
const bool ENABLE_GLOW  = true;  // cursor glow on dark themes
const bool ENABLE_BOXES = true;  // task checkboxes
const bool ENABLE_TABLES = true; // Markdown tables drawn with ruled lines
const bool ENABLE_HEADINGS = true; // Markdown headings drawn larger

// ---- tunables -------------------------------------------------------------

// Markdown headings. A heading line is drawn larger, into the blank line
// below it (or, when only the line above is blank, into that one): the
// page is not rearranged, and no other line moves or changes size. A
// heading with text on both sides has no room and stays as it is. The line
// is scaled about the left edge of its own text, so the sign and number
// columns stay as they are. Everything on the line is scaled with it: the
// cursor, the smoke of what is typed there.
const float HEAD_SCALE_1     = 1.70;  // `#`: at most 2, one blank line being all the room there is
const float HEAD_SCALE_2     = 1.40;  // `##`
const float HEAD_SCALE_3     = 1.20;  // `###`
const int   HEAD_COLS        = 16;    // cells of a row read for its heading; all blank, the row counts as blank

// Task checkboxes. Zonvie hands the shader the codepoint of every cell
// (iCellText), so a task prefix is matched by its text, not its pixels: a
// `- [ ]`, `- [x]` or `- [!]` (also `*` and `+` bullets, and `X`) with a
// blank before the bullet. The five cells from the bullet to `]` are
// repainted as one box on the paper colour of their row, and the text of a
// done task is faded and struck through.
// The colours are the colorscheme's. An open box is drawn in the colour its
// `[` has (`@markup.list.unchecked` where Tree-sitter highlights Markdown).
// A done box and the strike through its text take the default text colour,
// not the colour of `[x]`: colorschemes paint that one as a status (green in
// many), which reads as a second accent beside the text. `- [!]` is not
// Markdown and a colorscheme has no colour for it, so that one is fixed.
const bool  BOX_STRIKE       = true;   // fade and strike through done tasks
const int   BOX_STRIKE_SCAN  = 240;    // how far left a fragment looks for its `- [x]` (stops at the grid's edge)
const float BOX_STRIKE_FADE  = 0.45;   // how far done text fades toward the paper
const float BOX_STRIKE_Y     = 0.57;   // strike line centre / cell height
const float BOX_STRIKE_W     = 0.035;  // strike line half width / cell height
const float BOX_INK_THRESH   = 0.15;   // colour distance from paper that counts as ink (fading only)
const float BOX_SIZE         = 0.62;   // box side / cell height
const float BOX_CENTRE       = 0.68;   // box centre / five-cell width
const vec3  BOX_COLOR_URGENT = vec3(0.72, 0.20, 0.20);   // `- [!]`: red outline and "!"
const float BOX_RADIUS       = 0.16;   // corner radius / box side
const float BOX_STROKE       = 0.14;   // outline width / box side
const float BOX_AA_PX        = 0.9;    // edge softness in pixels

// Markdown tables. A table is found by its text alone: pipes standing in a
// column over two rows or more, whose second row is the delimiter row
// (`|---|:--:|`). The pipes are repainted as vertical rules, the delimiter
// row as the rule under the header, and a frame and row lines are drawn
// round the cells; the cells' own text is left where it is, so the table
// reads as drawn only when its source is aligned.
// The rules take the colour the colorscheme gives the pipes they replace,
// thinned toward the paper.
const int   TABLE_ROWS       = 64;     // rows a column of pipes is followed, each way
const int   TABLE_COLS       = 64;     // cells a fragment looks sideways for its table's pipes
const float TABLE_ALPHA      = 0.55;   // how much of the pipes' colour a rule is
const float TABLE_ROW_ALPHA  = 0.22;   // ... and a line between two body rows
const float TABLE_HEAD_FILL  = 0.08;   // how far the header band is tinted toward that colour
const float TABLE_LINE_W     = 0.045;  // rule width / cell height
const float TABLE_HEAD_W     = 1.5;    // the rule under the header / an ordinary rule
const float TABLE_RADIUS     = 0.42;   // frame corner radius / cell width
const float TABLE_AA_PX      = 0.7;    // edge softness in pixels

// Smoke puffs.
const float PUFF_LIFE_MIN_S  = 0.10;  // per-puff life is drawn uniformly from [MIN, MAX]
const float PUFF_LIFE_MAX_S  = 1.50;
const float PUFF_DELAY_MAX_S = 0.16;  // per-puff random onset delay after the edit
const float PUFF_FADE_IN_S   = 0.03;  // ramp so a delayed puff does not pop in
const float PUFF_SIGMA_CELL  = 0.21;  // Gaussian sigma / cell height (demo blob ~0.5 cell wide)
const float PUFF_SIGMA_JIT   = 0.08;  // per-puff size jitter, fraction of cell height
const float PUFF_MAX         = 0.70;  // peak blend toward ink (demo: 25-35/255 on a 128/255 contrast)
const float PUFF_RISE_CELL   = 0.16;  // typed puff: how far above the glyph it starts
const float PUFF_DRIFT_CELL  = 0.14;  // typed puff: how much further it rises over its life
const float PUFF_JITTER_X    = 0.30;  // random horizontal offset, fraction of cell width
const float PUFF_INK_THRESH  = 0.22;  // colour distance from the paper that counts as ink
const float PUFF_SHAPE_BLUR_MIN = 0.06; // typed puff: blur radius of the glyph copy at birth, fraction of cell height
const float PUFF_SHAPE_BLUR_MAX = 0.34; // ... and at the end of its life: the haze dissipates
const float PUFF_SHAPE_GAIN  = 1.4;   // typed puff: blurred glyph density -> opacity
const float PUFF_SHAPE_BLOB_MIN = 0.10; // weight of the soft blob under the glyph copy at birth
const float PUFF_SHAPE_BLOB_MAX = 0.70; // ... and at the end: the shape melts into a blob
const float PUFF_GROW        = 0.8;   // deleted puff: blob radius grows by this fraction over its life
const float PUFF_SKIP_EPS    = 1e-3;  // a puff contributing less than this to a fragment is skipped

// Typed-puff disc blur: 1 centre tap plus 3 rings of 8. Ring r sits at
// r/3 of the blur radius with weight exp(-0.5 * (r / 1.8)^2); the sum
// counts every tap, inside the cell or not.
const float PUFF_RING_W[4] = float[4](1.0, 0.856997, 0.539408, 0.249352);
const float PUFF_RING_W_SUM = 14.166056;
const vec2 PUFF_DIR_EVEN[8] = vec2[8](
    vec2( 1.0, 0.0), vec2( 0.707107,  0.707107), vec2(0.0,  1.0), vec2(-0.707107,  0.707107),
    vec2(-1.0, 0.0), vec2(-0.707107, -0.707107), vec2(0.0, -1.0), vec2( 0.707107, -0.707107));
const vec2 PUFF_DIR_ODD[8] = vec2[8](
    vec2( 0.923880,  0.382683), vec2( 0.382683,  0.923880), vec2(-0.382683,  0.923880), vec2(-0.923880,  0.382683),
    vec2(-0.923880, -0.382683), vec2(-0.382683, -0.923880), vec2( 0.382683, -0.923880), vec2( 0.923880, -0.382683));

// Cursor jump trail. Measured off the demo at 4.28-4.48 s, where the cursor
// leaves Ln 1 Col 1 for Ln 6 Col 19: a STRAIGHT streak joining the two
// cursor centres, appearing at full length in the first frame after the
// move. Not a smeared copy of the cursor — at 2544 px the cursor is 26 px
// wide and the streak measures ~7 px across (half maximum), i.e. a thin
// line. Its core darkens the paper by (56,50,52) where paper-minus-ink is
// (148,148,148), i.e. a consistent 0.34-0.38 of the way to the text colour.
// The streak here is drawn in the CURSOR's colour instead, by preference:
// the demo's grey-olive streak reads as an artefact of its palette, and a
// cursor trail that carries the cursor's own colour is what this GUI wants.
// The background-only mask is kept, so the streak still yields to text
// wherever it crosses a glyph. It holds full strength for ~85 ms and is gone
// by ~200 ms. Typing never shows it: one-cell moves are far below
// TRAIL_MIN_CELLS.
// Timings straight off the demo, tracking the teal cursor block frame by
// frame across 4.28-4.45 s. The move is NOT "cursor teleports, line fades":
//   -17 ms  cursor at the old position
//     0 ms  the streak appears, its middle not yet filled
//    17 ms  the streak has closed up over its whole length
//    67 ms  the middle drops out again, the two ends still there
//    83 ms  everything gone
// The streak is knitted from both ends and unpicked from the middle — see
// TRAIL_COVER0. (The demo also hides the cursor for the streak's whole life
// and only materialises it at 117 ms; that lag is deliberately not copied —
// the cursor here appears at its destination straight away.)
const float TRAIL_LIFE_S      = 0.10;   // streak lifetime; the cursor is hidden for all of it
// The streak does not simply appear and fade: it is BORN FROM ITS TWO ENDS
// and DIES FROM ITS MIDDLE. Summing the darkening over fifths of the path
// (frame 4 = 100%) gives, for the three interior fifths:
//     0 ms   77%  26%  78%   <- the middle has not filled in yet
//    17 ms   99%  97%  98%
//    33 ms  100% 100% 100%
//    67 ms   61%   5%  72%   <- the middle has already gone
//    83 ms    4%   4%   7%
// So a single "coverage" value, measured from each end inward, explains the
// whole life: it opens to 1 in one frame, holds, then closes back to 0.
// Coverage is measured from each END inward: a fragment at `mid` (0 at the
// ends, 1 at the middle) is drawn while mid < cover. These values were
// fitted to the table above and reproduce it to 5% RMS.
const float TRAIL_COVER0      = 0.40;   // coverage on the first frame
const float TRAIL_COVER_MAX   = 1.05;   // fully closed up (past 1 so the middle is solid)
const float TRAIL_COVER_END   = -0.40;  // past 0 so even the tips are gone at the end
const float TRAIL_RISE        = 0.22;   // fraction of the life spent closing up
const float TRAIL_FALL        = 0.35;   // fraction of the life before it starts parting
const float TRAIL_COVER_EDGE  = 0.90;   // softness of the coverage boundary
const float TRAIL_FADE_FROM   = 0.55;   // the whole streak also dims from here on
// The streak has NO taper: zoomed 4x on the demo's frames 2-7, it leaves the
// old cursor's cell at full width and runs into the destination at full
// width. (An earlier reading of the along-path profile suggested fading
// tips; that was an artefact of endpoints estimated a few px off, which
// walks the sampling window off the line towards the ends.)
const float TRAIL_MAX         = 0.35;   // peak blend toward the cursor colour
// Half width / cell height. The alpha ramp is smoothstep(hw, hw*TRAIL_SOFT),
// whose half-maximum sits at ~1.7*hw, so the visible full width is
// 2*1.7*hw = 3.4*hw of a cell height. 0.032 gives ~0.11, a shade under the
// demo's measured 0.13.
const float TRAIL_HALF_W_CELL = 0.032;
const float TRAIL_SOFT        = 2.4;    // outer edge / half width
const float TRAIL_MIN_CELLS   = 2.5;    // shorter moves (typing, Enter, one scroll step) draw nothing

// Cursor shear/stretch. Demo, block cursor, per keystroke: the LEADING
// (top) edge tilts ~10% of the height in the direction of travel and the box
// widens ~55% while moving, both relaxing within ~0.12 s.
const float SHEAR_DURATION_S = 0.12;
const float SHEAR_MAX        = 0.10;  // shear amount / cursor height
const float SHEAR_DIR        = 1.0;   // +1: top edge leads
const float STRETCH_MAX      = 0.55;  // symmetric stretch while moving, fraction of width
const float CURSOR_RADIUS_PX = 1.5;
const bool  CURSOR_SHOW_GLYPH = true;  // paint the glyph under the cursor in the cursor's text colour
// Brightness of the cursor during the off phase of a `guicursor` blink, so
// the blink dims the cursor instead of removing it; 0 hides it as Neovim
// does. The colour is scaled, not blended with the background: Thymer's
// dark-theme cursor keeps its hue and drops to ~0.66 in every channel, while
// a blend toward a dark background turns a warm cursor muddy grey.
// iCursorVisible is also 0 where no cursor is shown at all (an inactive
// external window, a cursor Neovim hid), so above 0 a dimmed cursor stays
// at the last position there too.
const float CURSOR_BLINK_OFF_LEVEL = 0.66;

// Cursor glow. A dark theme only: the cursor lights the cells around it in
// its own colour while it is shown, so it goes on and off with Neovim's
// `guicursor` blink (iCursorVisible). With blink disabled it stays lit.
const float GLOW_SIGMA_CELL  = 1.6;   // Gaussian sigma / cell height
const float GLOW_REACH_SIGMA = 3.0;   // fragments further than this many sigmas skip the glow
const float GLOW_MAX         = 0.16;  // peak added light at the cursor's centre
const float GLOW_DARK_LUMA   = 0.40;  // background luminance below which the theme counts as dark
const float GLOW_WHITEN      = 0.35;  // how far the light is pushed from the cursor colour toward white

// ---- helpers --------------------------------------------------------------

float sdRoundBox(vec2 p, vec2 halfSize, float r) {
    vec2 q = abs(p) - halfSize + vec2(r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Three decorrelated uniforms in [0,1) per cell. Only the cell coordinate
// goes in, so a puff keeps its shape from frame to frame.
vec3 hash3(vec2 cell) {
    vec3 p = vec3(cell, cell.x * 0.37 + cell.y * 1.13);
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yzz) * p.zyx);
}

bool insideCursorRect(vec2 p, vec4 rect) {
    return p.x >= rect.x && p.x <= rect.x + rect.z &&
           p.y >= rect.y - rect.w && p.y <= rect.y;
}

// Does the cell at this centre currently show ink? Five samples: centre and
// a small cross. Distinguishes a typed glyph (ink present) from a deleted one
// (cell now empty), which decides where its puff goes.
bool cellHasInk(vec2 centrePx, vec3 paper) {
    vec2 cs = iCellSize;
    vec2 o[5];
    o[0] = vec2(0.0);
    o[1] = vec2( 0.22 * cs.x, 0.0);
    o[2] = vec2(-0.22 * cs.x, 0.0);
    o[3] = vec2(0.0,  0.22 * cs.y);
    o[4] = vec2(0.0, -0.22 * cs.y);
    for (int i = 0; i < 5; ++i) {
        vec3 c = texture(iChannel0, (centrePx + o[i]) / iResolution.xy).rgb;
        if (distance(c, paper) > PUFF_INK_THRESH) return true;
    }
    return false;
}

// Paper and ink colours for the text row that contains cell row `c0.y`.
// Paper: the most common colour at the cells' top-left corners, a spot that
// is background for practically every glyph (a centre sample is NOT: a run
// of l/t/i stems made ink the majority and swapped the two, and the smoke
// then bleached the glyphs). Ink: the cell-centre sample farthest from
// paper, among cells whose centre differs from THEIR OWN corner — a merely
// highlighted but empty cell (hlsearch, Visual, CursorLine) would otherwise
// donate its background colour.
//
// Only cells inside THIS window count. An external window (an ext float,
// the ext-cmdline) is small, and a cursor near its left edge put most of the
// sample cells outside its drawable, where the wrapper returns the padding
// colour: that became the "paper", the real paper became the "ink", and
// every typed puff was masked away.
//
// `here` is the calling fragment's own colour, used only as a last resort
// when no cell of the row lies inside the window.
void estimatePaperInk(vec2 c0, vec2 cs, vec3 here, out vec3 paper, out vec3 ink) {
    vec3 smp[9];
    vec3 cen[9];
    int nSmp = 0;
    for (int dx = -6; dx <= 8 && nSmp < 9; ++dx) {
        vec2 cellMin = iGridOrigin + (c0 + vec2(float(dx), 0.0)) * cs;
        vec2 centre = cellMin + cs * 0.5;
        if (centre.x < iWindowOffset.x || centre.x >= iWindowOffset.x + iWindowSize.x ||
            centre.y < iWindowOffset.y || centre.y >= iWindowOffset.y + iWindowSize.y) continue;
        vec2 corner = cellMin + cs * vec2(0.08, 0.08);
        vec3 c = texture(iChannel0, corner / iResolution.xy).rgb;
        vec3 m = texture(iChannel0, centre / iResolution.xy).rgb;
        // A sample under the cursor would report the cursor colour.
        if (insideCursorRect(centre, iCurrentCursor)) {
            if (nSmp == 0) continue;
            c = smp[nSmp - 1];
            m = c;
        }
        smp[nSmp] = c;
        cen[nSmp] = m;
        ++nSmp;
    }
    if (nSmp == 0) { nSmp = 1; smp[0] = here; cen[0] = here; }
    paper = smp[0];
    int bestN = -1;
    for (int i = 0; i < nSmp; ++i) {
        int n = 0;
        for (int j = 0; j < nSmp; ++j) if (distance(smp[i], smp[j]) < 0.10) ++n;
        if (n > bestN) { bestN = n; paper = smp[i]; }
    }
    ink = paper;
    float best = 0.0;
    for (int i = 0; i < nSmp; ++i) {
        if (distance(cen[i], smp[i]) < PUFF_INK_THRESH) continue;
        float dist = distance(cen[i], paper);
        if (dist > best) { best = dist; ink = cen[i]; }
    }
    if (best < PUFF_INK_THRESH) {
        float pol = sign(dot(iCurrentCursorColor.rgb - paper, vec3(0.299, 0.587, 0.114)));
        ink = clamp(paper + vec3(0.5 * pol), 0.0, 1.0);
    }
}

// Distance from p to the segment ab.
float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

vec3 cornerAt(vec2 cellMin, vec2 cs) {
    return texture(iChannel0, (cellMin + cs * 0.08) / iResolution.xy).rgb;
}

bool isBlankCp(uint c) {
    return c == 0x20u || c == 0u;  // a space, or a cell with no text
}

// A window separator or a float's border: Neovim draws both with
// box-drawing characters (the border into the float's own grid).
bool isBorderCp(uint c) {
    return c >= 0x2500u && c <= 0x257Fu;
}

// What may sit before a bullet: a blank or a border.
bool canPrecedeBullet(uint c) {
    return isBlankCp(c) || isBorderCp(c);
}

// Does a task run start at the cell `bullet`? Returns 0 for none, 1 open,
// 2 done, 3 urgent. Bullet, space, `[`, mark, `]`, with a blank, a border
// or the grid's edge before the bullet so `a-[x]` is left alone. Only that one
// cell is checked: a float shares the text plane with the window under it,
// so the cells further left may belong to another window's line.
int taskRunAt(ivec2 bullet) {
    uint b = zonvieCellTextAt(bullet);
    if (b != 0x2Du && b != 0x2Au && b != 0x2Bu) return 0;  // - * +
    if (zonvieCellTextAt(bullet + ivec2(1, 0)) != 0x20u) return 0;
    if (zonvieCellTextAt(bullet + ivec2(2, 0)) != 0x5Bu) return 0;  // [
    if (zonvieCellTextAt(bullet + ivec2(4, 0)) != 0x5Du) return 0;  // ]
    uint m = zonvieCellTextAt(bullet + ivec2(3, 0));
    int kind = m == 0x20u ? 1 : (m == 0x78u || m == 0x58u) ? 2 : m == 0x21u ? 3 : 0;  // ' ' x X !
    if (kind == 0) return 0;
    if (bullet.x > 0 && !canPrecedeBullet(zonvieCellTextAt(bullet - ivec2(1, 0)))) return 0;
    return kind;
}

// Paint the task box for the cell with top-left `cellMin`. `q` is the
// fragment's offset from the cell centre in pixels, `ink` the box's colour.
// Returns the painted colour over `paper`.
vec3 paintBox(int kind, vec2 q, float side, vec3 paper, vec3 ink) {
    float hs = side * 0.5;
    float aa = BOX_AA_PX;
    float dBox = sdRoundBox(q, vec2(hs), BOX_RADIUS * side);
    float fill = 1.0 - smoothstep(-aa, aa, dBox);
    float ring = fill * smoothstep(-aa, aa, dBox + BOX_STROKE * side);
    vec3 col = paper;
    if (kind == 2) {
        col = mix(col, ink, fill);
        // Tick: two strokes, drawn in the paper colour. +y is down.
        vec2 a = vec2(-0.30, -0.02) * side;
        vec2 b = vec2(-0.08, 0.22) * side;
        vec2 c = vec2(0.32, -0.22) * side;
        float dTick = min(sdSegment(q, a, b), sdSegment(q, b, c)) - 0.07 * side;
        col = mix(col, paper, 1.0 - smoothstep(-aa, aa, dTick));
    } else {
        col = mix(col, ink, ring);
        if (kind == 3) {
            // "!": a bar and a dot.
            float dBar = sdSegment(q, vec2(0.0, -0.28 * side), vec2(0.0, 0.06 * side)) - 0.07 * side;
            float dDot = length(q - vec2(0.0, 0.26 * side)) - 0.08 * side;
            float mark = 1.0 - smoothstep(-aa, aa, min(dBar, dDot));
            col = mix(col, ink, mark);
        }
    }
    return col;
}

// Is this cell on the text of a done task? Scans left for a `- [x]` run
// (the text starts six cells after its bullet), to the grid's left edge,
// the nearest window border, or two blank cells in a row: the strike's own
// end-of-text rule, and no `- [x] ` run holds two blanks together. One tap
// per step gates the full match.
bool onDoneTask(ivec2 cell) {
    bool prevBlank = false;
    for (int j = 1; j < BOX_STRIKE_SCAN + 6; ++j) {
        ivec2 bullet = cell - ivec2(j, 0);
        if (bullet.x < 0) return false;
        uint b = zonvieCellTextAt(bullet);
        // A window separator or float border: the cells beyond it belong
        // to another window's line.
        if (isBorderCp(b)) return false;
        // A space only: 0 is the right half of a wide glyph, not a gap.
        bool blank = b == 0x20u;
        if (blank && prevBlank) return false;
        prevBlank = blank;
        if (j < 6 || (b != 0x2Du && b != 0x2Au && b != 0x2Bu)) continue;
        if (taskRunAt(bullet) == 2) return true;
    }
    return false;
}

bool isPipeAt(ivec2 c) {
    return zonvieCellTextAt(c) == 0x7Cu;  // |
}

// From the pipe at `pipe`, are the cells on its `dir` side, up to the next
// pipe, a delimiter cell: hyphens, with optional colons and blanks?
bool delimiterRun(ivec2 pipe, int dir) {
    bool dash = false;
    for (int k = 1; k <= TABLE_COLS; ++k) {
        uint t = zonvieCellTextAt(pipe + ivec2(dir * k, 0));
        if (t == 0x7Cu) return dash;
        if (t == 0x2Du) dash = true;                   // -
        else if (t != 0x3Au && t != 0x20u) return false;  // : and blank
    }
    return false;
}

// The table the pipe at `pipe` stands in: its first and last row. Returns 0
// when the column of pipes is not a table, 1 for a table (the header is row
// r0, the delimiter row r0 + 1), 2 for a column that runs off the top of
// the grid: a table whose header has scrolled away, drawn without one.
int tableAt(ivec2 pipe, out int r0, out int r1) {
    r0 = pipe.y;
    r1 = pipe.y;
    for (int k = 1; k < TABLE_ROWS; ++k) {
        if (!isPipeAt(ivec2(pipe.x, pipe.y - k))) break;
        r0 = pipe.y - k;
    }
    for (int k = 1; k < TABLE_ROWS; ++k) {
        if (!isPipeAt(ivec2(pipe.x, pipe.y + k))) break;
        r1 = pipe.y + k;
    }
    if (r1 == r0) return 0;
    ivec2 d = ivec2(pipe.x, r0 + 1);
    if (delimiterRun(d, 1) || delimiterRun(d, -1)) return 1;
    return (r0 == 0 && r1 >= 2) ? 2 : 0;
}

// Is there a pipe on the `dir` side of `c` in its row, before a window
// border or the grid's edge?
bool pipeBeside(ivec2 c, int dir, out int at) {
    for (int k = 1; k <= TABLE_COLS; ++k) {
        ivec2 q = c + ivec2(dir * k, 0);
        if (q.x < 0) return false;
        uint t = zonvieCellTextAt(q);
        if (t == 0x7Cu) {
            at = q.x;
            return true;
        }
        if (isBorderCp(t)) return false;
    }
    return false;
}

// What the first cells of `row` hold: the level of its heading (1 to 3, 0
// for none) with the column the heading's text starts at, and whether they
// are all blank. One pass with no way out of the loop, and every row asked
// about is read whole: a loop that can be left early here, or one reached
// only on some paths, takes Metal's compiler minutes to build.
void headingRow(int row, out int level, out int col, out bool blank) {
    level = 0;
    col = 0;
    bool any = false;
    for (int x = 0; x < HEAD_COLS; ++x) {
        uvec4 c = zonvieCellAt4(ivec2(x, row));
        uint g = c.w & 7u;
        if (level == 0 && g != 0u) {
            level = (g & 1u) != 0u ? 1 : ((g & 2u) != 0u ? 2 : 3);
            col = x;
        }
        any = any || !isBlankCp(c.x);
    }
    // Rows past the root grid are other grids' text.
    bool in_grid = row >= 0 && row < iRootRows;
    if (!in_grid) level = 0;
    blank = in_grid && !any;
}

float headingScale(int level) {
    return level == 1 ? HEAD_SCALE_1 : (level == 2 ? HEAD_SCALE_2 : HEAD_SCALE_3);
}

// Where the picture at `fragCoord` comes from: the same place, except in a
// heading's enlarged line. That line covers the heading's own row and the
// part of the blank row it grows into; a pixel there shows the heading row
// scaled about its fixed edge (its top when it grows down, its bottom when
// it grows up) and about the left edge of its text.
vec2 headingSource(vec2 fragCoord) {
    ivec2 cell;
    vec2 cellMin, cs;
    bool on_grid = zonvieCellGeom(fragCoord, cell, cellMin, cs) && cell.y < iRootRows;

    // This row, and the rows a heading here could grow into or one beside
    // it could grow from.
    int level, col, level_up, col_up, level_down, col_down, unused_level, unused_col;
    bool blank, blank_up, blank_down, blank_down2;
    headingRow(cell.y, level, col, blank);
    headingRow(cell.y - 1, level_up, col_up, blank_up);
    headingRow(cell.y + 1, level_down, col_down, blank_down);
    headingRow(cell.y + 2, unused_level, unused_col, blank_down2);

    // The heading whose enlarged line may cover this pixel, the top of its
    // row and which way it grows.
    int lvl = 0;
    int from = 0;
    float top = cellMin.y;
    bool down = true;
    if (level > 0 && (blank_down || blank_up)) {
        lvl = level;
        from = col;
        down = blank_down;
    } else if (level == 0 && blank && level_up > 0) {
        lvl = level_up;
        from = col_up;
        top = cellMin.y - cs.y;
    } else if (level == 0 && blank && level_down > 0 && !blank_down2) {
        // The heading below grows up into this row only when it cannot
        // grow down.
        lvl = level_down;
        from = col_down;
        top = cellMin.y + cs.y;
        down = false;
    }

    float k = headingScale(lvl);
    float left = iGridOrigin.x + float(from) * cs.x;
    float fixed_y = down ? top : top + cs.y;
    vec2 src = vec2(left + (fragCoord.x - left) / k, fixed_y + (fragCoord.y - fixed_y) / k);
    bool inside = on_grid && lvl > 0 && fragCoord.x >= left && src.y >= top && src.y < top + cs.y;
    return inside ? src : fragCoord;
}

// ---- main -----------------------------------------------------------------

// The frame at `fragCoord` with every effect but the headings' enlargement.
void thymerImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    vec4 sharp = texture(iChannel0, uv);
    vec3 base = sharp.rgb;
    float alpha = sharp.a;

    bool cursorActive = (iTime - iTimeCursorChange) <= SHEAR_DURATION_S;

    // ---- task checkboxes -------------------------------------------------
    // This fragment may sit in any of the five cells of a `- [?]` run; try
    // each start. zonvieCellGeom gives the fragment's cell where it is drawn
    // (mid smooth-scroll, or in a window with its own font and cell size),
    // and the box rides with it. The paper is the corner of that cell.
    ivec2 cell;
    vec2 cellMin, cs;
    if (ENABLE_BOXES && zonvieCellGeom(fragCoord, cell, cellMin, cs)) {
        vec2 p = fragCoord;
        vec3 paper = cornerAt(cellMin, cs);
        for (int k = 0; k < 5; ++k) {
            ivec2 bullet = cell - ivec2(k, 0);
            if (bullet.x < 0) break;
            int kind = taskRunAt(bullet);
            if (kind == 0) continue;
            vec2 bulletMin = cellMin - vec2(float(k) * cs.x, 0.0);
            float width = 5.0 * cs.x;
            float side = BOX_SIZE * cs.y;
            vec2 q = p - (bulletMin + vec2(width * BOX_CENTRE, cs.y * 0.5));
            vec3 ink = kind == 3 ? BOX_COLOR_URGENT
                     : kind == 2 ? iForegroundColor
                     : zonvieCellFgAt(bullet + ivec2(2, 0));
            base = paintBox(kind, q, side, paper, ink);
            break;
        }
        // Done-task text: fade the ink and strike through it. The line
        // stops after two blank cells in a row, where the text ends. The
        // scan for the task run is the expensive part, so a fragment that
        // could show neither fade nor line (no ink, blank cell, blank or
        // border next) decides from two taps and skips it.
        if (BOX_STRIKE && base == sharp.rgb) {
            bool ink = distance(sharp.rgb, paper) > BOX_INK_THRESH;
            uint here = zonvieCellTextAt(cell);
            uint next = zonvieCellTextAt(cell + ivec2(1, 0));
            bool textHere = !isBorderCp(here) &&
                            (ink || !isBlankCp(here) || (!isBlankCp(next) && !isBorderCp(next)));
            if ((ink || textHere) && onDoneTask(cell)) {
                if (ink) base = mix(sharp.rgb, paper, BOX_STRIKE_FADE);
                float relY = (p.y - cellMin.y) / cs.y;
                if (textHere && abs(relY - BOX_STRIKE_Y) < BOX_STRIKE_W) {
                    base = mix(iForegroundColor, paper, BOX_STRIKE_FADE);
                }
            }
        }
    }

    // ---- Markdown tables ---------------------------------------------------
    // A fragment is in a table when its cell is one of the table's pipes,
    // or lies between two pipes of a table row. The table is read off the
    // pipe at or left of the cell.
    // A window separator or a float's border is never part of a table: the
    // text plane is shared, so its cell can sit between a pipe of the window
    // on its left and one of the window on its right.
    if (ENABLE_TABLES && zonvieCellGeom(fragCoord, cell, cellMin, cs) && !isBorderCp(zonvieCellTextAt(cell))) {
        vec2 p = fragCoord;
        bool onPipe = isPipeAt(cell);
        int lx = cell.x, rx = cell.x;
        bool leftPipe = pipeBeside(cell, -1, lx);
        int r0 = 0, r1 = 0;
        int kind = 0;
        bool rightPipe = false;
        if (onPipe || leftPipe) {
            rightPipe = pipeBeside(cell, 1, rx);
            // A pipe is read with its neighbours in the row, a cell with
            // the pipes either side of it, and only the rows those columns
            // of pipes share are a table: a row whose pipes have moved out
            // of line drops back to plain text, and the table closes above
            // it. A neighbour that is not a pipe of this same table (a
            // window separator drawn as `|`, a stray pipe) does not count,
            // so the table still ends where it ends.
            int q0 = 0, q1 = 0;
            if (onPipe) {
                kind = tableAt(cell, r0, r1);
                int rows = r1;
                if (kind != 0 && rightPipe) {
                    rightPipe = tableAt(ivec2(rx, cell.y), q0, q1) == kind && q0 == r0;
                    if (rightPipe) rows = min(rows, q1);
                }
                if (kind != 0 && leftPipe) {
                    leftPipe = tableAt(ivec2(lx, cell.y), q0, q1) == kind && q0 == r0;
                    if (leftPipe) rows = min(rows, q1);
                }
                if (!leftPipe && !rightPipe) kind = 0;
                r1 = rows;
            } else if (rightPipe) {
                kind = tableAt(ivec2(lx, cell.y), r0, r1);
                if (kind != 0 && (tableAt(ivec2(rx, cell.y), q0, q1) != kind || q0 != r0)) kind = 0;
                r1 = min(r1, q1);
            }
        }
        if (kind != 0) {
            vec3 paper = cornerAt(cellMin, cs);
            // The colour of this row's pipe: the one under the fragment, or
            // the one on its left.
            vec3 ink = zonvieCellFgAt(ivec2(onPipe ? cell.x : lx, cell.y));
            bool first = onPipe && !leftPipe;
            bool last = onPipe && !rightPipe;
            bool top = cell.y == r0;
            bool bottom = cell.y == r1;
            bool head = kind == 1 && cell.y == r0;
            // The delimiter row keeps its text while the cursor is on it,
            // so its colons can be edited.
            ivec2 curCell;
            vec2 curMin, curCs;
            bool curHere = zonvieCellGeom(iCurrentCursor.xy + vec2(0.5 * iCurrentCursor.z, -0.5 * iCurrentCursor.w),
                                          curCell, curMin, curCs) && curCell.y == cell.y;
            // The delimiter row: the second row of a table, or the first
            // row left of one whose header alone has scrolled away.
            int ruleRow = kind == 1 ? r0 + 1 : -1;
            ivec2 topPipe = ivec2(onPipe ? cell.x : lx, r0);
            if (kind == 2 && (delimiterRun(topPipe, 1) || delimiterRun(topPipe, -1))) ruleRow = r0;
            bool rule = cell.y == ruleRow && !curHere;
            bool bodyLine = !bottom && !head && cell.y != ruleRow;

            float w = max(1.0, TABLE_LINE_W * cs.y);
            float rad = TABLE_RADIUS * cs.x;
            float xc = cellMin.x + 0.5 * cs.x;
            float xl = first ? xc : cellMin.x - 1.0;
            float xr = last ? xc : cellMin.x + cs.x + 1.0;
            float yT = cellMin.y + 0.5 * w;
            float yB = cellMin.y + cs.y - 0.5 * w;
            float yC = cellMin.y + 0.5 * cs.y;
            bool corner = first || last;
            // The centre of the frame's corner arc in this cell, if it has one.
            float ax = first ? xc + rad : xc - rad;
            float sx = first ? 1.0 : -1.0;

            // Outside the frame: the outer half of an end pipe's cell, and
            // the corner beyond the arc.
            bool outside = (first && p.x < xc - 0.5 * w) || (last && p.x > xc + 0.5 * w);
            if (corner && top && kind == 1 && (p.x - ax) * sx < 0.0 && p.y < yT + rad &&
                length(p - vec2(ax, yT + rad)) > rad + 0.5 * w) outside = true;
            if (corner && bottom && (p.x - ax) * sx < 0.0 && p.y > yB - rad &&
                length(p - vec2(ax, yB - rad)) > rad + 0.5 * w) outside = true;

            if (onPipe || rule) base = paper;
            if (!outside && (head || (rule && p.y < yC))) base = mix(base, ink, TABLE_HEAD_FILL);

            float d = 1e5;      // distance to the frame and the cells' rules
            float dHead = 1e5;  // ... to the rule under the header
            float dRow = 1e5;   // ... to a line between body rows
            bool arcTop = corner && top && kind == 1;
            bool arcBottom = corner && bottom;
            if (onPipe) {
                float ya = arcTop ? yT + rad : (top && kind == 1 ? yT : cellMin.y - 1.0);
                float yb = arcBottom ? yB - rad : (bottom ? yB : cellMin.y + cs.y + 1.0);
                d = sdSegment(p, vec2(xc, ya), vec2(xc, yb));
            }
            if (top && kind == 1) {
                if (arcTop) {
                    vec2 c = vec2(ax, yT + rad);
                    if ((p.x - ax) * sx <= 0.0 && p.y <= c.y) d = min(d, abs(length(p - c) - rad));
                    d = min(d, sdSegment(p, vec2(ax, yT), vec2(first ? xr : xl, yT)));
                } else {
                    d = min(d, sdSegment(p, vec2(xl, yT), vec2(xr, yT)));
                }
            }
            if (bottom) {
                if (arcBottom) {
                    vec2 c = vec2(ax, yB - rad);
                    if ((p.x - ax) * sx <= 0.0 && p.y >= c.y) d = min(d, abs(length(p - c) - rad));
                    d = min(d, sdSegment(p, vec2(ax, yB), vec2(first ? xr : xl, yB)));
                } else {
                    d = min(d, sdSegment(p, vec2(xl, yB), vec2(xr, yB)));
                }
            }
            if (rule) dHead = sdSegment(p, vec2(xl, yC), vec2(xr, yC));
            if (bodyLine) dRow = sdSegment(p, vec2(xl, yB), vec2(xr, yB));

            vec3 lineCol = mix(paper, ink, TABLE_ALPHA);
            float aa = TABLE_AA_PX;
            base = mix(base, mix(paper, ink, TABLE_ROW_ALPHA), 1.0 - smoothstep(0.5 * w - aa, 0.5 * w + aa, dRow));
            base = mix(base, lineCol, 1.0 - smoothstep(0.5 * w - aa, 0.5 * w + aa, d));
            float wh = TABLE_HEAD_W * w;
            base = mix(base, lineCol, 1.0 - smoothstep(0.5 * wh - aa, 0.5 * wh + aa, dHead));
        }
    }

    // The frame as the boxes and tables left it: the glyphs they painted
    // over are gone from the picture, so later masks must not treat them as
    // ink.
    vec3 boxed = base;

    // ---- smoke puffs -----------------------------------------------------
    // Gate on the global "last edit" time first so idle frames pay nothing,
    // then look at the cells around this pixel: its own row, the row below
    // (a typed puff rises out of its cell into the row above it) and the row
    // above (a blob swells downward past its cell's bottom edge). Missing
    // either row cuts the haze off flat at a cell boundary.
    if (ENABLE_SMOKE && (iTime - iTimeLastEdit) <= PUFF_DELAY_MAX_S + PUFF_LIFE_MAX_S &&
        iCellSize.x > 0.0 && iCellSize.y > 0.0) {
        vec2 cs = iCellSize;
        vec2 cellF = (fragCoord - iGridOrigin) / cs;
        vec2 c0 = floor(cellF);

        // Pre-pass: is any cell in reach still live? 15 texelFetches into
        // iCellAge and nothing else — no iChannel0 taps, no sqrt. Everything
        // below (the 18-tap estimator with its O(n^2) majority vote, and the
        // per-cell blur) is skipped when the answer is no. This matters
        // because the outer gate stays open for ~1.7 s after ANY keystroke,
        // so without it every fragment of the window paid the full estimate
        // for that whole window while only a handful of cells had smoke.
        float ages[15];
        bool anyLive = false;
        {
            int k = 0;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -2; dx <= 2; ++dx) {
                    vec2 ac = iGridOrigin + (c0 + vec2(float(dx), float(dy)) + 0.5) * cs;
                    float a = zonvieCellAge(ac);
                    ages[k] = a;
                    ++k;
                    if (a <= PUFF_DELAY_MAX_S + PUFF_LIFE_MAX_S) anyLive = true;
                }
            }
        }

        if (anyLive) {
        vec3 paper, ink;
        estimatePaperInk(c0, cs, sharp.rgb, paper, ink);

        float acc = 0.0;
        bool any = false;
        int kAge = 0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -2; dx <= 2; ++dx) {
                vec2 cell = c0 + vec2(float(dx), float(dy));
                vec2 centre = iGridOrigin + (cell + 0.5) * cs;
                float age = ages[kAge];
                ++kAge;
                if (age > PUFF_DELAY_MAX_S + PUFF_LIFE_MAX_S) continue;
                vec3 h = hash3(cell);
                // A second hash draw for timing, so it is independent of the
                // shape draw: each puff appears after its own short delay and
                // lives its own length.
                vec3 h2 = hash3(cell + vec2(17.0, 29.0));
                float delay = h2.x * PUFF_DELAY_MAX_S;
                float life = mix(PUFF_LIFE_MIN_S, PUFF_LIFE_MAX_S, h2.y);
                float local = age - delay;
                if (local < 0.0 || local >= life) continue;
                any = true;
                float t = local / life;
                // Third draw: how this puff dissipates. `spread` scales how
                // far it blurs out, `dis` bends the dissipation curve (some
                // puffs melt early, some hold their shape and then go), and
                // `fadeExp` bends the brightness curve independently.
                vec3 h3 = hash3(cell + vec2(41.0, 7.0));
                float spread = 0.5 + h3.x;
                float dis = pow(t, mix(0.6, 1.8, h3.y));
                float fadeExp = mix(0.8, 2.0, h3.z);
                float fadeIn = smoothstep(0.0, PUFF_FADE_IN_S, local);
                // Fade: linear-ish, a touch slower at first so a fresh puff
                // reads at full strength for a few frames.
                float amp = PUFF_MAX * pow(1.0 - t, fadeExp) * (0.75 + 0.25 * h.z) * fadeIn;
                if (amp < PUFF_SKIP_EPS) continue;

                // Where the puff sits. Typed: above the glyph, rising. Deleted:
                // on the glyph's old spot, barely moving. Both placements are
                // computed before the cell is probed for ink, so a fragment
                // that neither could reach skips the probe's taps.
                //
                // On the grid's top row there is no room above: a small
                // external window (an ext float with one or two rows) would
                // push the puff out of its drawable and the typed glyph would
                // seem to get no smoke at all. Keep it inside the cell there,
                // hugging the glyph's upper half.
                float rise = (cell.y < 0.5) ? 0.04 : PUFF_RISE_CELL * (0.6 + 0.4 * h.y);
                float drift = (cell.y < 0.5) ? 0.03 : PUFF_DRIFT_CELL;
                vec2 offT = vec2((h.x - 0.5) * PUFF_JITTER_X * cs.x,
                                 -(rise + drift * t) * cs.y);
                vec2 offD = vec2((h.x - 0.5) * 0.6 * PUFF_JITTER_X * cs.x,
                                 ((h.y - 0.5) * 0.2 - 0.08 * t) * cs.y);
                // The blob swells as it dissipates.
                float sigma = (PUFF_SIGMA_CELL + (h.z - 0.5) * PUFF_SIGMA_JIT) * cs.y * (1.0 + PUFF_GROW * spread * dis);
                // Slightly taller than wide, like the demo's blobs.
                vec2 sig2 = vec2(sigma * 0.85, sigma);
                vec2 dT = (fragCoord - centre - offT) / sig2;
                vec2 dD = (fragCoord - centre - offD) / sig2;
                float gT = exp(-0.5 * dot(dT, dT));
                float gD = exp(-0.5 * dot(dD, dD));
                float blobW = mix(PUFF_SHAPE_BLOB_MIN, PUFF_SHAPE_BLOB_MAX, dis);

                // Typed puff: the shape of the glyph itself, sampled at this
                // pixel shifted back by the puff offset through a small disc
                // blur. Taps are confined to the source cell so a neighbour's
                // glyph never leaks in, which also means a `src` further than
                // the blur radius outside it can only sum to zero. Born almost
                // sharp, then the blur radius widens with age and the soft
                // blob takes over: the haze dissipates instead of merely
                // fading.
                vec2 cellMin = iGridOrigin + cell * cs;
                vec2 cellMax = cellMin + cs;
                float rB = mix(PUFF_SHAPE_BLUR_MIN, PUFF_SHAPE_BLUR_MAX * spread, dis) * cs.y;
                vec2 src = fragCoord - offT;
                bool inBlur = src.x >= cellMin.x - rB && src.x < cellMax.x + rB &&
                              src.y >= cellMin.y - rB && src.y < cellMax.y + rB;
                if (!inBlur && gD * amp < PUFF_SKIP_EPS && blobW * gT * amp < PUFF_SKIP_EPS) continue;

                // THIS cell's own background, not the row's majority: a cell
                // under `cursorcolumn`, `hlsearch`, MatchParen or Visual has
                // a background of its own, and measuring it against the row
                // paper reported the whole cell as ink — the puff came out a
                // solid rectangle in the highlight colour instead of a copy
                // of the glyph.
                vec3 cellPaper = texture(iChannel0, (cellMin + cs * 0.08) / iResolution.xy).rgb;
                bool typed = cellHasInk(centre, cellPaper);

                float g = gD;
                if (typed) {
                    float density = 0.0;
                    if (inBlur) {
                        // Ring weights exp(-0.5 * (ring / 1.8)^2) do not depend
                        // on rB, and every tap counts toward the weight sum
                        // whether or not it lands in the cell, so the sum is a
                        // constant too. Rings 1 and 3 sit half a step (22.5
                        // degrees) round from rings 0 and 2.
                        float inkSum = 0.0;
                        if (src.x >= cellMin.x && src.y >= cellMin.y && src.x < cellMax.x && src.y < cellMax.y) {
                            vec3 c = texture(iChannel0, src / iResolution.xy).rgb;
                            inkSum += smoothstep(0.08, 0.30, distance(c, cellPaper));
                        }
                        for (int ring = 1; ring <= 3; ++ring) {
                            float rr = rB * float(ring) / 3.0;
                            float w = PUFF_RING_W[ring];
                            for (int i = 0; i < 8; ++i) {
                                vec2 tp = src + ((ring == 2) ? PUFF_DIR_EVEN[i] : PUFF_DIR_ODD[i]) * rr;
                                if (tp.x < cellMin.x || tp.y < cellMin.y || tp.x >= cellMax.x || tp.y >= cellMax.y) continue;
                                vec3 c = texture(iChannel0, tp / iResolution.xy).rgb;
                                inkSum += w * smoothstep(0.08, 0.30, distance(c, cellPaper));
                            }
                        }
                        density = inkSum / PUFF_RING_W_SUM;
                    }
                    g = clamp(density * PUFF_SHAPE_GAIN + blobW * gT, 0.0, 1.0);
                }
                acc = 1.0 - (1.0 - acc) * (1.0 - g * amp);
            }
        }

        if (any && acc > 0.002) {
            // Background pixels only: a puff never tints a glyph stroke. A
            // pixel counts as background when it matches EITHER the row's
            // majority paper OR its own cell's background — the second half
            // is what keeps a `cursorcolumn` / `colorcolumn` / highlighted
            // cell from cutting a notch out of every puff crossing it.
            vec3 hereCorner = texture(iChannel0, (iGridOrigin + c0 * cs + cs * 0.08) / iResolution.xy).rgb;
            float onBg = 1.0 - smoothstep(0.10, 0.25,
                min(distance(sharp.rgb, paper), distance(sharp.rgb, hereCorner)));
            base = mix(base, ink, acc * onBg);
            alpha = mix(alpha, 1.0, acc * onBg);
        }
        }
    }

    // ---- cursor jump trail -----------------------------------------------
    // A straight streak joining the cursor's previous and current centres.
    // Gated on distance so it fires on a jump (a click, a motion, a search)
    // and never on typing: Enter moves one cell height and a smooth-scroll
    // step moves the cursor one row at a time, both below the threshold.
    // Drawn before the cursor so the cursor sits on top of its own trail.
    float trailAge = iTime - iTimeCursorChange;
    vec2 pa = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5,
                   iPreviousCursor.y - iPreviousCursor.w * 0.5);
    vec2 pb = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5,
                   iCurrentCursor.y - iCurrentCursor.w * 0.5);
    vec2 seg = pb - pa;
    float minLen = TRAIL_MIN_CELLS * iCellSize.y;
    // A jump, as opposed to typing: only these hide the cursor and streak.
    bool jumped = iCellSize.y > 0.0 && iCurrentCursor.z > 0.0 &&
                  iPreviousCursor.z > 0.0 && dot(seg, seg) > minLen * minLen;
    if (ENABLE_TRAIL && jumped && trailAge >= 0.0 && trailAge <= TRAIL_LIFE_S) {
        {
            float segLen2 = dot(seg, seg);
            float hProj = clamp(dot(fragCoord - pa, seg) / segLen2, 0.0, 1.0);
            float dSeg = distance(fragCoord, pa + seg * hProj);
            float hw = TRAIL_HALF_W_CELL * iCellSize.y;
            float aLine = 1.0 - smoothstep(hw, hw * TRAIL_SOFT, dSeg);
            // Coverage closes in from the two ends and later parts again
            // from the middle, so the streak knits itself together and is
            // unpicked instead of fading out flat.
            float u = trailAge / TRAIL_LIFE_S;
            float cover = min(mix(TRAIL_COVER0, TRAIL_COVER_MAX, smoothstep(0.0, TRAIL_RISE, u)),
                              mix(TRAIL_COVER_MAX, TRAIL_COVER_END, smoothstep(TRAIL_FALL, 1.0, u)));
            float mid = 1.0 - abs(2.0 * hProj - 1.0);   // 0 at the ends, 1 at the middle
            aLine *= (1.0 - smoothstep(cover, cover + TRAIL_COVER_EDGE, mid)) *
                     (1.0 - smoothstep(TRAIL_FADE_FROM, 1.0, u));
            if (aLine > 0.0) {
                // The estimator is 18 taps and an O(n^2) colour vote, so it
                // runs only for the handful of fragments actually on the
                // line, never for the window at large.
                vec2 cs2 = iCellSize;
                vec2 c02 = floor((fragCoord - iGridOrigin) / cs2);
                // Only `tPaper` is used: the streak is drawn in the cursor
                // colour, and paper is what the background mask needs.
                vec3 tPaper, tInk;
                estimatePaperInk(c02, cs2, boxed, tPaper, tInk);
                // Background pixels only, same rule as the smoke: a pixel
                // matching either the row's paper or its own cell's
                // background is background.
                vec3 corner2 = texture(iChannel0, (iGridOrigin + c02 * cs2 + cs2 * 0.08) / iResolution.xy).rgb;
                float onBg2 = 1.0 - smoothstep(0.10, 0.25,
                    min(distance(boxed, tPaper), distance(boxed, corner2)));
                vec3 trailColor = iCurrentCursorColor.rgb;
                base = mix(base, trailColor, TRAIL_MAX * aLine * onBg2);
            }
        }
    }

    // ---- cursor glow -----------------------------------------------------
    // Added light, so text and background around the cursor both brighten.
    // The theme is judged from the background of the cursor's own cell
    // (the frontend leaves the cursor to this shader, so that cell still
    // shows its plain background).
    if (ENABLE_GLOW && iCursorVisible != 0 && iCurrentCursor.z > 0.0 && iCurrentCursor.w > 0.0 &&
        iCellSize.y > 0.0) {
        vec2 gc = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5,
                       iCurrentCursor.y - iCurrentCursor.w * 0.5);
        float sigma = GLOW_SIGMA_CELL * iCellSize.y;
        vec2 dg = fragCoord - gc;
        if (dot(dg, dg) < (GLOW_REACH_SIGMA * sigma) * (GLOW_REACH_SIGMA * sigma)) {
            vec2 probe = vec2(iCurrentCursor.x, iCurrentCursor.y - iCurrentCursor.w) +
                         iCellSize * 0.08;
            vec4 cellBg = texture(iChannel0, probe / iResolution.xy);
            // backTex is premultiplied; judge the straight colour.
            vec3 bgStraight = cellBg.rgb / max(cellBg.a, 1e-3);
            float luma = dot(bgStraight, vec3(0.2126, 0.7152, 0.0722));
            if (luma < GLOW_DARK_LUMA) {
                float g = exp(-0.5 * dot(dg, dg) / (sigma * sigma));
                // A lamp's light reads paler than the lamp itself: a fully
                // saturated cursor colour stains the text instead of lighting it.
                vec3 lightColor = mix(iCurrentCursorColor.rgb, vec3(1.0), GLOW_WHITEN);
                vec3 light = lightColor * (GLOW_MAX * g);
#ifdef ZONVIE_PRESERVE_ALPHA
                // Scaled by the pixel's alpha so the result stays a valid
                // premultiplied colour on a translucent window.
                base += light * alpha;
#else
                // Decorated surfaces (ext-cmdline, popupmenu) compile without
                // preserve_alpha and are drawn opaque, but their margin keeps
                // a backTex alpha of 0: scaling by it would cut the glow off
                // at the margin's edge.
                base += light;
#endif
            }
        }
    }

    // ---- cursor ----------------------------------------------------------
    // `guicursor` still picks the SHAPE — it arrives as iCurrentCursorStyle
    // and every shape is handled below, block included. The frontend hands
    // the cursor over wholesale once this shader declares
    // @zonvie-owns-cursor, so nothing else draws it.
    // The cursor is drawn at its new position immediately, streak or no
    // streak. (The demo withholds it for the streak's whole life and only
    // materialises it afterwards; that lag is not wanted here.)
    float cursorLevel = iCursorVisible != 0 ? 1.0 : CURSOR_BLINK_OFF_LEVEL;
    bool shaderDrawsCursor =
        cursorLevel > 0.0 &&
        iCurrentCursor.z > 0.0 && iCurrentCursor.w > 0.0;

    if (shaderDrawsCursor) {
        float m = clamp((iTime - iTimeCursorChange) / SHEAR_DURATION_S, 0.0, 1.0);
        float e = (1.0 - m) * (1.0 - m);
        if (!cursorActive) e = 0.0;

        float dx = iCurrentCursor.x - iPreviousCursor.x;
        // Vertical moves (Enter, arrow keys between lines) get no shear: the
        // effect reads as a typing smear, and shearing sideways on a pure line
        // change looks wrong.
        float d = (abs(dx) > 0.5) ? sign(dx) : 0.0;

        float w = iCurrentCursor.z;
        float h = iCurrentCursor.w;
        // Cursor-local coordinates: origin at the rect's left/bottom, with
        // p.y in [-h, 0] going up (fragCoord.y grows downward).
        vec2 p = fragCoord - vec2(iCurrentCursor.x, iCurrentCursor.y);

        // Shear about the vertical centre so the tilt does not also shift the
        // cursor sideways. `off` runs -h/2 at the top edge to +h/2 at the
        // bottom; ADDING it to the sample coordinate displaces the drawn shape
        // by -off, so a positive SHEAR_DIR pushes the TOP edge in the
        // direction of travel.
        float off = p.y + h * 0.5;
        p.x += d * SHEAR_DIR * SHEAR_MAX * e * off;

        // Stretch: widen SYMMETRICALLY while moving. Growing only on the
        // trailing side turned the box into a wedge, and on a wide block that
        // wedge reads as a lean of its own — which makes the shear direction
        // impossible to judge. Keeping the stretch symmetric leaves the shear
        // as the only thing that carries a direction.
        float grow = STRETCH_MAX * e * w * 0.5;
        vec2 centre = vec2(w * 0.5, -h * 0.5);
        vec2 halfSize = vec2(w * 0.5 + grow, h * 0.5);

        float sd = sdRoundBox(p - centre, halfSize,
                              min(CURSOR_RADIUS_PX, min(halfSize.x, halfSize.y)));
        float a = 1.0 - smoothstep(-0.5, 0.5, sd);
        // Treat a fully transparent cursor colour as "unset" and fall back to
        // opaque, so a theme that never filled the alpha still shows a cursor.
        float ca = iCurrentCursorColor.a > 0.0 ? iCurrentCursorColor.a : 1.0;

        // The cursor colour, with the glyph under it kept readable: where
        // the cursor covers a glyph, that part is painted in the colour
        // Neovim draws text on the cursor (iCursorText) instead, as the
        // native pass does. How much of a pixel is glyph is read off the
        // frame against its cell's own foreground and background, which
        // Zonvie gives exactly; nothing is guessed from neighbouring pixels.
        // It is read off the frame as Neovim drew it, so under the cursor a
        // box, a table rule or faded done text gives way to the character
        // that is really there.
        vec3 cursorPaint = iCurrentCursorColor.rgb * cursorLevel;
        ivec2 gCell;
        vec2 gMin, gCs;
        if (CURSOR_SHOW_GLYPH && zonvieCellGeom(fragCoord, gCell, gMin, gCs)) {
            vec3 cellBg = zonvieCellBgAt(gCell);
            vec3 axis = zonvieCellFgAt(gCell) - cellBg;
            float glyph = clamp(dot(sharp.rgb - cellBg, axis) / max(dot(axis, axis), 1e-4), 0.0, 1.0);
            cursorPaint = mix(cursorPaint, iCursorText * cursorLevel, glyph);
        }
        float cover = a * ca;
        base = mix(base, cursorPaint, cover);
        // Opaque where it is drawn, like the smoke: on a translucent window
        // the blurred backdrop would otherwise wash the cursor out, and the
        // dimmed blink-off cursor most of all.
        alpha = mix(alpha, 1.0, cover);
    }

    fragColor = vec4(base, alpha);
}

// Everything above is worked out where the picture comes from, so a
// heading takes its cursor, its smoke and its colours along as it grows.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    thymerImage(fragColor, ENABLE_HEADINGS ? headingSource(fragCoord) : fragCoord);
}
