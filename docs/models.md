# 3D models

What appears on a card, and what makes a `.usdz` usable here.

## Naming and placement

Drop each `.usdz` directly into the `PostcardAR/` folder, next to the Swift files, named exactly
after its reference image:

```
PostcardAR/
  Assets.xcassets/AR Resources.arresourcegroup/
    postcard.arreferenceimage      ← the image ARKit looks for
    menu.arreferenceimage
  postcard.usdz                    ← what appears on it
  menu.usdz
```

The target uses a synchronized folder group, so Xcode picks up new files with no further action,
and nothing has to be registered in code. Renaming a model means renaming its reference image to
match — that pairing is the whole mechanism.

A card with an image but no matching `.usdz` still tracks; it just shows nothing, and the status
panel names the missing file. A `.usdz` with no matching image is never loaded.

## Sizing

### The problem

A `.usdz` stores real-world units. RealityKit honours them literally: a model authored two metres
tall renders two metres tall, hanging over a 15 cm postcard.

Nothing connects the two. The anchor supplies position and rotation, never scale. The card's
physical size positions the anchor and never touches the model. They are independent, which is
exactly why the model appears at an arbitrary size.

### The fix

Rather than demand every `.usdz` be authored at the correct size, `fit(_:toCardWidth:named:)`
measures it at load time and derives the scale from its card:

```swift
let bounds = model.visualBounds(relativeTo: nil)
let scale = cardWidth * modelWidthRelativeToCard / bounds.extents.x
model.scale = .init(repeating: scale)

model.position = [
    -bounds.center.x * scale,
    (bounds.extents.y / 2 - bounds.center.y) * scale,
    -bounds.center.z * scale
]
```

`visualBounds` returns a `BoundingBox` with a `center` and `extents` (full width, not half),
computed over the entity and all its descendants.

The scale line is straightforward: to make width `extents.x` become `cardWidth`, multiply by
their ratio.

The position line handles a detail that bites everyone: **the `.usdz` origin is wherever the
artist left it.** Often it is at the model's feet, sometimes off to one side, rarely at the
centre. Assuming it is centred is why models show up half-buried or floating beside the card.

So we measure and correct. In the anchor's coordinate space, x runs across the card's width,
z down its height, and y points out of its surface. A point `p` in the model lands at
`scale * p + position`. Solving for what we want:

- **Centred on the card** — put the box centre at the origin in x and z:
  `scale * center + position = 0`, so `position = -scale * center`.
- **Standing on the card** — put the box *bottom* at y = 0. The bottom is
  `center.y - extents.y / 2`, so `position.y = scale * (extents.y / 2 - center.y)`.

`cardWidth` is the printed width of the card this particular model belongs to, read from that
reference image's `physicalSize`. Cards of different printed sizes each size their own model
correctly.

The payoff is that the model's authored scale stops mattering. Export from Blender at any size;
it still lands correctly.

### The one dial

```swift
private let modelWidthRelativeToCard: Float = 2.0
```

`1.0` makes the model exactly as wide as its card; the current `2.0` makes it twice as wide.
`0.5` would make it half as wide. Change that constant, not the model.

It applies to every card, and re-exporting one `.usdz` bigger will *not* make that one model
relatively larger: `fit` measures the model and normalises its authored scale away, which is the
whole point of it. A genuinely per-card size would need a per-card value in the code, and nothing
is asking for that yet.

If a model is very tall or very deep, matching widths may not be the right rule. In that case
divide by `bounds.extents.y` or `.z` instead of `.x` inside `fit(_:toCardWidth:named:)`.

The trade-off of deriving scale from the card: **the physical size field controls the model's
size as well as its distance.** An inaccurate measurement is visible — per card, and only for
that card's model. Measure the printed card properly.

If the measurement fails, the scale is skipped and a red line appears in the status panel. That
case is worth reporting rather than passing over quietly: a model authored in metres, left
unscaled on a card a few centimetres wide, puts the camera *inside* the model. The screen fills
with texture that barely moves, which reads as the app having frozen rather than as a sizing bug.

## What else is in your .usdz

A `.usdz` is a scene, not a mesh. Exporting from Blender takes everything in the scene with it —
the key/fill/rim lights, the environment light, and **the viewport camera**.

The camera is the dangerous one. RealityKit turns a USD `Camera` prim into a real
`PerspectiveCamera` entity, and putting one into an `ARView` scene hands rendering over to it.
The passthrough video stops following the device and the app looks completely frozen. There is no
error, nothing in the console, and it happens the moment the model is added to the scene — so it
looks like a hang in whatever code ran last, not like an asset problem.

`removeCameras(from:)` strips them at load time, so this is handled for any model you drop in.
Do not remove that call. Lights import as inert entities and are harmless.

To see what an asset actually contains, dump the prim types:

```sh
unzip -o model.usdz -d /tmp/model && cd /tmp/model
usdcat --flatten *.usdc | grep -oE '^\s*def [A-Za-z]+ "[^"]+"' | sort | uniq -c | sort -rn
```

Anything that is not `Mesh`, `Xform`, `Material`, `Shader`, or `Scope` is worth a second look.
Cleaner still is to fix it at the source: in Blender's USD exporter, uncheck cameras and lights,
or select only the mesh and export selection.

Diagnose an imported asset by walking the loaded entity tree and printing components, rather than
by reading the file size — the shipped coral is 9 MB and froze the camera, while a 52 MB model
did not.

## Weight

The scale fix says nothing about how heavy the model is, and weight is the thing most likely to
make the app feel broken. Everything runs on the main thread, alongside ARKit and SwiftUI, so a
heavy model does not degrade gracefully — it stalls the camera.

Two numbers matter, and neither is the file size:

| Budget | Why |
|---|---|
| **Texture pixels** | A 2048×2048 texture is ~16 MB decoded, ~21 MB with mipmaps, regardless of how well the PNG compressed. Six of them is ~134 MB of GPU memory. |
| **Triangles** | The model is drawn a few centimetres wide. Detail far beyond what those pixels can show costs the same as detail you can see. |

The coral model shipped here was originally 240k triangles with six 2048² textures in a 19 MB
file. The textures were reduced to 512² (`sips -Z 512`, then repacked with
`usdzip <out.usdz> --arkitAsset <root.usdc>`), which cut decoded texture memory from ~134 MB to
~8 MB and the file to 9.3 MB, with no visible difference at the size it is drawn.

Rules of thumb: **512×512 textures** and **under ~50k triangles**. Decimate in Blender (Decimate
modifier) before exporting if the source is denser. Check what you actually have rather than
trusting the file size — a `.usdz` is a zip of *uncompressed* assets, so a small file can still
be heavy, and a large one can be cheap to draw.

### The budget is shared

Every model in the group is loaded at launch and stays in memory whether or not its card is ever
shown. Ten cards means ten models resident and ten lots of texture memory.

They load one at a time, in name order: decoding is main-thread work either way, so overlapping
them would only lengthen the stall, and finishing the first card early means it is usable while
the rest arrive. The status panel counts them, so a long "Loading models (2/10)…" is that queue,
not a hang.

## Authoring

- A plain `.usdz` exported from Blender, Maya, or Reality Composer Pro works directly.
- For animation, **Reality Composer Pro** (Xcode → Open Developer Tool) is the tool to use. It
  handles timeline animations, shader graph materials, particles, and spatial audio.
- The old Reality Composer app and its `.rcproject` format are gone from Xcode 26. Ignore
  tutorials that use it.
- Skeletal and transform animations in USDZ import fine. Blend shapes are unreliable.
