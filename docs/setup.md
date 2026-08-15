# Setup

Both assets live under `PostcardAR/` and the code expects them to be named `postcard`.

## 1. The reference image

The AR Resource Group is at:

```
PostcardAR/Assets.xcassets/AR Resources.arresourcegroup/
```

In Xcode:

1. Open `Assets.xcassets` and select **AR Resources**.
2. Drag the postcard image (PNG or JPG) into it.
3. Rename the entry to **`postcard`** — the code looks it up by that exact name.
4. In the Attributes Inspector, set the **physical size** of the printed card. For a standard
   A6 postcard that is 148 × 105 mm. Xcode fills in the second dimension from the image's
   aspect ratio.

### What the physical size actually affects

It does **not** affect whether the image is detected. ARKit matches feature points, which is
scale-invariant — it finds the image whatever number is in that field.

The size is used only to turn a 2D match into a 3D pose: how far away the card is and how big
the anchor is. So a wrong value means the model appears at the wrong scale or floating at the
wrong distance. It never means "nothing detected". If nothing is detected, the image is the
problem, not the size.

Measure the printed card once with a ruler and enter it. Approximately right is fine.

### Choosing an image that actually tracks

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

Xcode grades the image on build and prints warnings into the asset catalog. Treat those
warnings as failures, not suggestions — an image that trips them will usually not track at all.

## 2. The 3D model

Drop `postcard.usdz` directly into the `PostcardAR/` folder (next to the Swift files). The
target uses a synchronized folder group, so Xcode picks it up with no further action.

If the file is named something else, change `modelName` at the top of
`PostcardAR/PostcardARView.swift`.

### Model size

A `.usdz` carries real-world units. RealityKit honours them literally: a model authored two
metres tall renders two metres tall, floating over a 15 cm postcard. The anchor does not scale
its children, and the card's physical size does not feed into the model at all — the two are
completely independent. That is why the model's apparent size seems unrelated to the card.

Rather than requiring the `.usdz` to be authored at exactly the right size, `fit(_:toCardWidth:)`
in `PostcardARView.swift` derives the scale from the card at load time:

1. Measure the model with `visualBounds`.
2. Scale it so its width equals the card's `physicalSize.width`.
3. Offset it by its measured centre, so it sits centred on the card with its base on the surface.

The consequence is that the model's authored scale stops mattering. Export from Blender at
whatever size is convenient; it will still land correctly on the card.

There is one dial, at the top of the file:

```swift
private let modelWidthRelativeToCard: Float = 1.0
```

`1.0` makes the model exactly as wide as the card. `0.5` makes it half as wide, `2.0` twice as
wide. Change that constant, not the model.

Because the scale is derived from the card, **the physical size field now matters for size as
well as distance.** An inaccurate value no longer only affects how far away the model sits; it
scales the model too. Measure the printed card properly.

If a model is very tall or very deep, matching widths may not be the right rule. In that case
divide by `bounds.extents.y` or `.z` instead of `.x` inside `fit(_:toCardWidth:)`.

### Making the model

- A plain `.usdz` exported from Blender, Maya, or Reality Composer Pro works directly.
- For animation, **Reality Composer Pro** (Xcode → Open Developer Tool) is the tool to use.
  It handles timeline animations, shader graph materials, particles, and spatial audio.
- The old Reality Composer app and its `.rcproject` format are gone from Xcode 26. Ignore
  tutorials that use it.
- Skeletal and transform animations in USDZ import fine. Blend shapes are unreliable.

## 3. Running

AR needs a real device. The simulator has no camera feed and image tracking reports itself
as unsupported there — the app logs a message and shows a blank view rather than crashing.

You also need the postcard **physically printed**. Showing the target on another screen works
but tracks noticeably worse because of glare and moiré.

## Diagnosing "nothing shows up"

The camera screen has a status panel in the top corner with two independent lines:

| Line | Meaning |
|---|---|
| **Looking for postcard…** / **Postcard detected** | Whether ARKit currently has a tracked `ARImageAnchor`. Driven by `ARImageAnchor.isTracked`, so it flips back when the card leaves the frame. |
| **Loading model…** / **Model loaded** | Whether the `.usdz` finished loading. |
| Red text | An `ARSession` error or a model load failure. |

Read them together:

- Never says *detected* → the reference image is the problem. See the image guidance above.
- *Detected* but nothing visible → the model. Either it is still loading, or it loaded at a
  scale that puts it off-screen or inside the camera. Check the physical size field and the
  model's own units.
- Red text → the message says which of the two failed.

Note that a large `.usdz` can take several seconds to load. *Model loaded* is what tells you
it has finished.

## Current state

Working: the button opens the camera, the image is tracked, and the model appears anchored to
the card — moving, rotating, and tilting with it as the card is handled. That behaviour comes
from the anchor parenting itself and needs no additional code.

Not implemented yet:

- **Tracking-loss handling.** When the card leaves the frame, RealityKit stops rendering the
  anchor's children on its own. If that ends up looking abrupt, add a fade with a few frames
  of hysteresis so a single dropped frame does not flicker the model.
- **User gestures on the model** (pinch to scale, drag to spin independently of the card).
  Not currently wanted. If added, put a pivot entity between the anchor and the model and
  write to the pivot, never to the anchor.
