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
// one thing lost versus the native pass is the glyph under a block cursor,
// which the native pass painted in the cell background colour; a
// post-process shader does not know that colour, so a block is drawn solid.

// ---- switches ------------------------------------------------------------
// Turn each effect on or off. The cursor's shear and stretch are part of
// drawing the cursor and always stay on.
const bool ENABLE_SMOKE = true;  // smoke puffs on typed and deleted glyphs
const bool ENABLE_TRAIL = true;  // streak when the cursor jumps
const bool ENABLE_GLOW  = true;  // cursor glow on dark themes

// ---- tunables -------------------------------------------------------------

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

// ---- main -----------------------------------------------------------------

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    vec4 sharp = texture(iChannel0, uv);
    vec3 base = sharp.rgb;
    float alpha = sharp.a;

    bool cursorActive = (iTime - iTimeCursorChange) <= SHEAR_DURATION_S;

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
                estimatePaperInk(c02, cs2, sharp.rgb, tPaper, tInk);
                // Background pixels only, same rule as the smoke: a pixel
                // matching either the row's paper or its own cell's
                // background is background.
                vec3 corner2 = texture(iChannel0, (iGridOrigin + c02 * cs2 + cs2 * 0.08) / iResolution.xy).rgb;
                float onBg2 = 1.0 - smoothstep(0.10, 0.25,
                    min(distance(sharp.rgb, tPaper), distance(sharp.rgb, corner2)));
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

        // Solid cursor colour for every shape.
        //
        // A block hides the glyph underneath. The native pass avoided that by
        // painting the glyph in the cell's background colour, but a
        // post-process shader does not know that colour. Two heuristics were
        // tried and both failed visibly: probing two pixels above the rect hit
        // the ext-cmdline surface's padding and painted the cursor solid
        // black, and averaging the rect's four corners misread the background
        // often enough to paint the whole cursor in it, making the cursor
        // vanish in Normal mode. Guessing the colour is worse than not drawing
        // the glyph, so this draws none. Restoring the glyph properly needs
        // the real colour as a uniform (Ghostty exposes iCursorText).
        vec3 cursorPaint = iCurrentCursorColor.rgb * cursorLevel;
        float cover = a * ca;
        base = mix(base, cursorPaint, cover);
        // Opaque where it is drawn, like the smoke: on a translucent window
        // the blurred backdrop would otherwise wash the cursor out, and the
        // dimmed blink-off cursor most of all.
        alpha = mix(alpha, 1.0, cover);
    }

    fragColor = vec4(base, alpha);
}
