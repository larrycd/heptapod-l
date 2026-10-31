# Heptapod L orthography, HL-1.1

*Heptapod L is a circular script by Larry Dalton. This document defines HL-1.1 as implemented by Heptapod L Studio, engine 1.1.1.*

All lengths are in logogram units: the first ring has a radius of 240 units, and an exported logogram is drawn at 1 px per unit.

---

## 1. The glyph

A **glyph** is a single tendril grown from the sentence ring. Each glyph has four independent features:

| Feature | Values | Code |
|---|---|---|
| **D**: direction | outward · inward | 0 · 1 |
| **C**: curl | clockwise · anticlockwise | 0 · 1 |
| **B**: barbs (side branches) | none · one · two | 0 · 1 · 2 |
| **L**: length | short 40 · medium 64 · long 92 | 0 · 1 · 2 |

This gives 2 × 2 × 3 × 3 = **36 glyph values**:

```
value = 18·D + 9·C + 3·B + L
```

### Glyph geometry

The centreline of a primary stroke, for *t* from 0 to 1 (18 sample points), starting from its point on the ring is:

```
a(t) = t − 0.25 t²            (radial progress)
b(t) = 0.5 t^2.2              (lateral curl)
P(t) = P₀ + u·d·len·a(t) + v·c·len·b(t)
```

where `u` is the outward radial direction, `v` is the clockwise tangent, `d = +1` for outward and −1 for inward, and `c = +1` for clockwise and −1 for anticlockwise.

- **Stroke width:** 13 × (1 − t)^0.9 × (1 + 0.35 sin πt), so the stroke tapers to a point.
- **Barbs:** 27 units long and 7 wide, rotated 50° from the stem towards the side opposite the curl.
  - One barb sits at stem point 11/17.
  - Two barbs sit at stem points 7/17 and 14/17.

### Letters

Letter *a* (A = 0 … Z = 25) uses glyph value

```
(7a + 3) mod 36
```

This spreads alphabetically neighbouring letters across very different shapes.

The remaining values are used as follows:

- **4** is the SPECIAL shift glyph.
- **5** is the ESCAPE shift glyph.
- **11, 12, 18, 19, 25, 26, 32 and 33** are reserved.

## 2. Units

A **unit** is one or more glyphs fused on a single ink mass and read clockwise.

| Unit | Glyphs | Example |
|---|---|---|
| Letter | 1 | `A` |
| Dicast | 2 | `RY` |
| Tricast | 3 | `LAR` |
| Special | SHIFT (4) + index glyph | `?` → [4, 12] |
| Escape | ESC (5) + 4 base-36 digits of the Unicode code point | `É` → [5, 0, 0, 5, 21] |

There are 26 + 676 + 17,576 = **18,278 letter units**. Each has a distinct form, because its identity is the ordered sequence of glyph values.

### Spacing inside a unit

- Glyphs in a unit are **32 units** apart.
- When two neighbouring glyphs are on the same side of the ring and curl towards each other (the first clockwise, the next anticlockwise), they are **46 units** apart. This prevents crossings that could hide a barb.

### Special register (36 symbols)

| Symbols | Start angles |
|---|---|
| Digits `0`–`9` | 347.00° to 349.25°, in steps of 0.25° |
| `(` `)` `@` | 350°, 352°, 354° |
| `-` `/` `&` `…` `–` `—` line break `#` `$` `%` `*` `+` `=` `_` `~` | 355.0° to 357.8°, in steps of 0.2° |
| `.` `;` `"` `:` `'` `,` `?` `!` | 358.00°, 359.10°, 359.20°, 359.30°, 359.40°, 359.00°, 359.50°, 359.75° |
| Escape units | 357.95° |

## 3. Segmentation: tricast first

Each word is split into runs of letters and other characters.

- Each run of letters is cut into **tricasts from the left**. The remainder becomes a dicast (2 letters) or a single letter.
- Every other character becomes a special or an escape unit, and stays in the word it belongs to.

| Text | Units |
|---|---|
| `HUMANITY` | `HUM` · `ANI` · `TY` |
| `NAME?` | `NAM` · `E` · `?` |
| `LARRY'S` | `LAR` · `RY` · `'` · `S` |

The cut can be recovered without ambiguity from the glyph count of each unit.

## 4. Positions: angled starts

Every unit has a **canonical start angle**, measured clockwise from 12 o'clock:

```
letter    θ₁(a)     = 360° · a / 26
dicast    θ₂(a,b)   = 360° · (26a + b) / 676
tricast   θ₃(a,b,c) = 360° · (676a + 26b + c) / 17,576
```

The specials use the register angles in §2.

The **first unit of a sentence sets the origin**, which is where the logogram starts. All other units follow clockwise from it.

The angles provide orientation only. A unit's **identity is its shape**, so collisions such as A, AA and AAA all starting at 0° are harmless.

## 5. Sentence composition

- **One sentence = one logogram.** Sentences split after `.` `?` `!` `…`.
- **The ring:** radius 240. Overflow continues on further rings at radius 240 + 220k, each read clockwise from the same origin.
- **Start bar:** a two-sided bar, 68 units long, across the ring at the origin angle.
- **Word boundary:** a two-sided bar, 40 units long, plus a break in the ring.
- **Gaps:** units are at least 60 units apart. Words are 84 units apart before even spreading.
- **Spreading:** units are spread evenly round each ring.
- **Grouping when reading:** a reader groups glyphs closer than 53 units into one unit.

## 6. Normalisation

- Text is converted to upper case.
- Runs of spaces and tabs collapse to a single word boundary.
- CR/LF becomes the line-break special.
- Any character outside A–Z and the special register is written as an escape unit.

## 7. Ink layers

| Layer | SVG elements | Opacity | Carries meaning |
|---|---|---|---|
| Structure | `<path>` (ring, bars, glyphs) | 100% | Yes |
| Pigment | `<circle>`, `<ellipse>`, `<polyline>`, blurred `<use>`, in one group | at most 55% | No |

Because the pigment is capped at 55%, an image reader that keeps only ink of 68% or more recovers exactly the structure.

## 8. Provenance

Each exported SVG carries a `<metadata>` record of the source text, the engine version and the orthography. Decoders may compare against it, but **must not use it to decode**.
