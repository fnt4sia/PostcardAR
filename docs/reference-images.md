# Reference images

The cards the app looks for. Everything here lives in one asset catalog folder:

```
PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/
```

Every image in that group is a card. The group is read whole at startup, so nothing in the
code names an individual one — see [models.md](models.md) for the other half of the pairing.

## Adding one

In Xcode:

1. Open `Assets.xcassets` and select **AR Resources**.
2. Drag the card's image (PNG or JPG) into it.
3. Name the entry after the model it should show. The app pairs image to `.usdz` by that exact
   string: `Showcase_postcard` draws `Showcase_postcard.usdz`.

   **The prefix picks the card's kind.** A name starting `Simulation` runs a minigame on that
   card; anything else is a showcase card that only stands its model up to be looked at. Prefix
   showcase cards `Showcase` for readability — the code only tests for `Simulation`. See
   [simulation.md](simulation.md).
4. In the Attributes Inspector, set the **physical size** of the printed card. For a standard A6
   postcard that is 148 × 105 mm. Xcode fills in the second dimension from the aspect ratio.

Each card carries its own physical size, so a business card and a poster can sit in the same
group without either one's model coming out wrong.

## What the physical size actually affects

It does **not** affect whether the image is detected. ARKit matches feature points, which is
scale-invariant — it finds the image whatever number is in that field.

The size turns a 2D match into a 3D pose: how far away the card is, and how big the anchor is.
It does **not** affect the model's size — `fit(_:named:)` scales each model to a fixed target
width in `modelWidths` (`docs/models.md`), independent of the card's own printed size, precisely
so the two can't fight each other.

So a wrong value means the anchor's distance reads wrong — the model floats at the wrong depth,
even though its own size is unaffected. It never means "nothing detected". If nothing is
detected, the image is the problem, not the size.

Measure the printed card once with a ruler and enter it. Approximately right is fine.

## Choosing an image that actually tracks

This is the part that decides whether the app works at all. ARKit tracks by finding many small
high-contrast feature points and needs them **spread across the whole image**.

Bad, and the reason a target usually fails:

- Large flat or uniform areas — plain backgrounds, solid colour fills, smooth gradients.
- Detail concentrated in one corner with the rest empty.
- Narrow histogram: everything one hue, or low overall contrast.
- Product renders and studio shots on white backgrounds. Nearly all of the frame is featureless.
- Images upscaled or "enhanced" by an AI tool. That smoothing removes exactly the fine texture
  ARKit matches on, so it makes a target measurably worse, not better.

Good:

- Busy artwork, dense photographic texture, visible grain, text, patterned illustration.
- Detail reaching into all four corners and the middle.
- Wide, flat histogram — a real range of light and dark.
- Shot from the actual printed card, flat on, evenly lit, no glare, cropped exactly to the
  card's edges. The reference image should match what the camera will see.
- Shortest side at least 480px.
- **Longest side no more than about 1800px.** See below — this one is a performance requirement,
  not a tracking one.

Xcode grades the image on build and prints warnings into the asset catalog. Treat those
warnings as failures, not suggestions — an image that trips them will usually not track at all.

### Resolution: there is a ceiling, and overshooting it is expensive

Detection quality comes from contrast and detail, not from pixel count, and ARKit extracts the
same features from a 1400px scan as from a 5800px one. Pixels past that ceiling buy nothing and
cost a great deal, because `ARReferenceImage.referenceImages(inGroupNamed:)` has to decode every
image in the group to full-size RGBA before it can look at any of it:

| Image | Pixels | On disk | Decoded |
|---|---|---|---|
| 5855 × 7605 | 44.5 MP | 5.9 MB | **178 MB** |
| 1399 × 1818 | 2.5 MP | 1.1 MB | 10 MB |

Both cards shipped at the first size once, so opening the camera screen decoded **356 MB** of
bitmap — a multi-second hang and a memory spike large enough to be a plausible cause of the
random stalls that went with it. Downscaling both to 1399 × 1818 changed nothing about detection
and removed the hang.

The physical size in the Attributes Inspector is unaffected by any of this: it describes the
printed card in the world, not the file, so re-exporting an image at a different resolution never
means re-measuring the card.

Export from the original artwork at ~1400px on the long edge rather than handing over a camera
photo or a print-resolution PDF render. If an oversized image is already in the catalog,
`sips -Z 1818 <file>` resamples it in place.

### Detail helps, repetition hurts

The instinct that a busy, text-heavy card is "too much for it to match" is backwards: dense
text, illustrations, and high local contrast are exactly what feature detection wants. The one
pattern that genuinely defeats it is a *repeating* one — a grid of identical logos, regular
stripes — because the same local neighbourhood then appears in many places and there is no
unique fit.

### Image quality also decides stability

A weak image does not only fail to be detected. It is also the single biggest source of the
pose jitter that [smoothing.md](smoothing.md) exists to hide: fewer, more clustered feature
points mean a worse-conditioned fit, so the same pixel noise moves the answer further. No
amount of filtering beats fixing the image.

## Several cards at once

`maximumNumberOfTrackedImages` is set to the size of the group, so every card in view gets a
solved pose in the same frame. Past that limit ARKit keeps *detecting* images; it simply will
not start tracking another until one currently tracked is lost.

Two cards that look alike to a feature matcher will compete. If one card only ever appears when
the other is out of frame, suspect shared artwork — a common border, logo, or background —
before suspecting the app.

## Printing

You need the cards **physically printed**. Showing a target on another screen works, but tracks
noticeably worse because of glare and moiré.
