# Decoder: method and test results

Heptapod L Studio reads logograms in two ways.

## SVG: geometric decoding (exact)

The decoder reads only the structural `<path>` elements. It never uses the embedded provenance metadata to produce text.

1. **Classify each path.**
   - Ring segment: narrow radial spread and long arc.
   - Two-sided bar: crosses the ring. A 68-unit bar is the start bar; a 40-unit bar is a word boundary.
   - Tendril: a tapered polygon whose centreline is recovered from its two edges.
2. **Classify each tendril.** A primary stroke starts on a ring. A barb starts on a primary stroke and is attached to the nearest one.
3. **Read the features.**
   - Direction: the sign of the radial displacement.
   - Curl: the sign of the lateral displacement.
   - Length: the arc length, compared with thresholds midway between the three classes.
   - Barbs: the number of attached barbs.
4. **Assemble the sentence.** Order glyphs clockwise from the start bar, ring by ring. Group them into units (glyphs closer than 53 units). Split words at boundary bars. Map glyph sequences to letters, specials or escapes.
5. **Check the start.** Compare the start angle with the canonical start of the first decoded unit.

## PNG / JPEG: shape-matching decoding

Implemented in C# 5 (`src/hsraster.cs`) and compiled locally by Windows PowerShell when the server starts.

1. **Ink map.**
   - The background tone is the most common grey level.
   - If the logogram sits on a different tone inside a screenshot (for example a paper logogram in a dark window), the decoder tries the second-most-common tone and crops to that panel.
   - Ink at 68% or more is kept. This separates the full-strength strokes from the pigment, which is capped at 55%.
2. **Centre and scale.**
   - A coarse-to-fine search finds the centre that concentrates ink at a single radius.
   - An algebraic circle fit refines it. Scale is the ring radius divided by 240.
   - Large images are reduced before analysis.
3. **Bases and bars.**
   - Two rows are sampled at ±13 units from the ring.
   - A run of ink on one side marks a tendril base.
   - Matching runs on both sides mark a bar. The bar is a start bar if ink continues to ±24 units on both sides. It is a boundary bar only if it stops short on both sides and neither half fits a full glyph.
4. **Model fitting.**
   - For every base, all 18 shapes for its side (curl × barbs × length) are rendered at sub-pixel offsets.
   - Each is scored by overlap with the observed stroke.
   - Barbs are counted separately, on pixels outside the main stroke, with each barb position allowed to shift slightly along the stem.
5. **Refinement.**
   - Each glyph is refitted with the ink already explained by its neighbours removed. This repeats three times.
   - Fragments that belong to a neighbour (for example a barb close to the ring) are discarded.
6. **Refusal.** If the median shape fit is below 0.55, the image is reported as unresolved. Native logograms score about 0.8–0.9.

Each result reports the following:

- the recovered text
- an overall confidence score
- any uncertain glyphs
- the detected centre, scale and rings
- a check of the start angle against the first unit

## Test results

| Test | Result |
|---|---|
| Full inventory from SVG: every letter, dicast and tricast (18,278) plus every special (35 testable), 12 per sentence | **18,313 / 18,313 exact** |
| Mandatory sentences (`LARRY`, `HUMANITY`, `LARRY KNOWS IAN`, `WHAT IS YOUR NAME?`, `HUMANITY SEEKS PEACE.`, punctuation, accented letters, emoji, a 3-ring sentence), SVG | all exact |
| Synthetic rasters of the mandatory sentences at scales 1.0 and 0.7, both inks | 18 / 18 exact |
| 100 random sentences rendered by Chrome and exported as PNG (1×, 2×) and JPEG quality 0.75 (0.7×, 1×), both inks | **96 / 100 exact**; all 4 misses flagged as partial, with no confident wrong results |
| Pangrams and named examples, 6 formats each | 65 / 66 exact |
| Studio page screenshots, both inks | decoded |
| Five AI-generated "heptapod" reference images | all refused |

**Known limits.**

- Accuracy falls on images smaller than about 500 px across.
- Heavy blur or perspective distortion is not handled.
- The decoder reads only Heptapod L logograms produced by the engine. HL-1.0 images, made before barbs were enlarged and re-spaced, are not readable as images, although their SVGs still decode.
