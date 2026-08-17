# Troubleshooting

Start with the status panel, then match the symptom.

## Reading the status panel

The camera screen has a panel in the top corner:

| Line | Meaning |
|---|---|
| **Looking for a card…** / **Detected: `name`, `name`** | Which reference images ARKit is tracking *right now*, from `Entity.isAnchored`. The model can lag behind this during a brief occlusion — see "Tracking loss" in [tracking.md](tracking.md) — so the label going to "not detected" does not mean the model vanished. |
| **Loading models (n/total)…** / **Models loaded (n)** | How many `.usdz` files have finished loading, one per reference image. |
| Red text | An `ARSession` error, or a model that failed to load — named, one line each. |

Read them together:

- Never says *Detected* → the reference image is the problem.
- One card detected and another never → that one image, not the app.
- *Detected* but nothing visible on that card → the model. Still loading, missing, or loaded at a
  scale that puts it off-screen or inside the camera.
- Red text → the message names which file or which half failed.

A large `.usdz` can take several seconds, and they load one after another, so the count climbs
rather than jumping. *Models loaded* is what tells you the queue is done.

## Symptoms

### Nothing is ever detected

The image, essentially always. Feature matching is scale-invariant, so the physical size field
cannot cause this — a wrong value means "wrong size or distance", never "nothing detected".

Check Xcode's asset-catalog warnings for that image first; treat them as failures rather than
advice. Then see [reference-images.md](reference-images.md) for what makes a target trackable.

### One card works, another never does

Compare the two images, not the code — every card goes through identical code. The usual causes
are a weak second image, or two cards that share enough artwork (a border, a logo, a background)
that they compete for the same features.

Also confirm the second entry is actually in the group and named as you think: the pairing to its
`.usdz` is by exact name.

### Detected, but no model appears on that card

In order of likelihood:

1. Its `.usdz` is missing or misnamed. A red line names the file it tried to load.
2. Still loading. Watch the count.
3. It loaded and was scaled wrong — see the next two entries.

### The screen fills with texture, or the app looks frozen while the camera still moves

The camera is *inside* the model. A model authored in metres, left unscaled on a card a few
centimetres wide, does exactly this. Normally `fit(_:toCardWidth:named:)` prevents it; if the
measurement failed, a red line says so and names the card. Check that card's physical size field.

### The passthrough camera freezes completely, with no error

A `PerspectiveCamera` entity got into the scene — a `.usdz` exported from Blender carries the
viewport camera, and RealityKit hands rendering over to it. `removeCameras(from:)` strips them at
load, so this means either that call was removed or a camera arrived some other way. See "What
else is in your .usdz" in [models.md](models.md), including how to dump an asset's prim types.

Note that file size proves nothing here: the shipped 9 MB coral froze the camera, a 52 MB model
did not.

### The model shivers when the card is still

Expected without filtering, and the filter is tuned by three constants — see
[smoothing.md](smoothing.md). Before touching them, consider that a weak reference image is the
biggest single cause: fewer feature points mean a worse-conditioned pose fit, so the same pixel
noise moves the answer further.

Being close to the card also exaggerates it — the angular error is unchanged, but it now sweeps
across more pixels.

### The model lags behind the card

`smoothingFactor` closes 15% of the gap per frame. Raise it to track more responsively, lower it
for a calmer model. Do not lower it to fix shiver; that is what the dead bands are for.

### The camera stops delivering images

```
ARSession: The delegate of ARSession is retaining 11 ARFrames. The camera will stop
delivering camera images…
```

Per-frame work ended up in `session(_:didUpdate frame:)`. Those callbacks queue up holding frames
when the main thread runs behind, without your code storing anything. Per-frame work belongs on
`SceneEvents.Update` — see "Render loop, not session delegate" in [tracking.md](tracking.md).

### A model disappears while the card is in plain view

If the code was changed to store an `ARImageAnchor` and re-read `isTracked` from it: `ARAnchor` is
a snapshot. ARKit hands out a fresh copy per update, so a stored one's `isTracked` is frozen
`true` forever, and any timeout built on it fires wrongly. Read `Entity.isAnchored` on the render
loop instead — see the dead end at the end of [tracking.md](tracking.md).

### Everything is slow, or the camera stutters while loading

Model weight. Everything runs on the main thread alongside ARKit and SwiftUI, and every model in
the group loads at launch and stays resident. Budget 512² textures and under ~50k triangles per
model, and remember the budget is shared across cards — see "Weight" in [models.md](models.md).

### Pinching does nothing, or grabs the wrong snail

See [interaction.md](interaction.md) for the whole mechanism. In order of likelihood:

1. `pinchCloseRatio`/`pinchOpenRatio` don't match your hand — these were tuned against one hand
   at one distance from the camera. Widen the gap between them if the pinch feels unreliable.
2. The pinch point landed more than `pinchPickRadius` screen points from every snail. Grabbing
   is nearest-by-screen-position, not a hit test, so it can pick a snail behind the one you meant.
3. Lighting or hand angle — Vision's hand-pose detector needs the hand clearly in frame, same as
   ARKit needs the card clearly in frame.

### It does not run on the simulator

It cannot. There is no camera feed, `ARWorldTrackingConfiguration.isSupported` is false, and the
app shows a message instead of crashing. AR needs a real device and a physically printed card.

### Xcode shows errors that the build does not

```
Cannot find type 'UIViewRepresentable' in scope
Cannot find 'ARReferenceImage' in scope
```

SourceKit resolving against the macOS SDK. The compiler is the authority — `xcodebuild` builds
clean. Ignore these, or build to confirm.
